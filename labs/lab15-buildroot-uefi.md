# Lab 15 · Buildroot：亲手构建一个 UEFI 可启动的系统

> **难度**：★★★★★
> **前置**：lab11、lab14（OVMF/UEFI 概念）；会基本的 make/内核配置
> **预计时间**：90–120 分钟（其中编译 20–40 分钟，机器强则短）
> **实测环境**：Debian 13 x86_64 · 24 vCPU · buildroot 2025.02 · OVMF 2025.02

## 目标

- 用 buildroot 从源码构建一个**最小 Linux 系统**（工具链 → 内核 → rootfs → 引导器全链路）
- 产物是一块 **GPT + ESP 的完整磁盘**，直接被 OVMF/UEFI 引导，qemu 里登录使用
- 读懂上游 `pc_x86_64_efi_defconfig` 的每一层机制（grub2 EFI、genimage、post-image）
- 学会**定制**：裁剪、加包、串口 getty、内核 config fragment
- 进阶：**绕过 grub**，手工拼一个 ESP 让 OVMF 直接引导内核（EFI stub）
- 对照掌握 aarch64 + AAVMF 的做法（ARM 服务器上跑）

为什么是 buildroot 而不是发行版？——**你看得见并控制系统的每一字节**：没有
cloud-init、没有包管理器、rootfs 就是 busybox + 你勾选的东西。对理解「一台机器
从固件到 shell 到底需要什么」，它是最短路径。

## 1. Buildroot 心智模型

```text
buildroot 源码树                     输出（output/，全部可删可重建）
├── configs/      预置 defconfig      ├── images/    最终产物（bzImage/rootfs/disk.img）
├── board/        板级文件（内核      ├── build/     各包构建目录
│                 配置、genimage、    ├── staging/    交叉编译 staging（.usr 合一）
│                 grub.cfg…）         ├── host/       宿主工具（交叉工具链、genimage…）
├── package/      ~2500 个包的配方    └── target/     rootfs 原型（打包前）
└── Makefile      make <defconfig> → menuconfig → make
```

- 一切从 `make xxx_defconfig` 开始：把 `configs/xxx_defconfig` 展开成 `.config`。
- `make` 的顺序：**下载 dl/ → 宿主工具 → 交叉工具链（gcc/binutils/glibc）→ 内核 →
  包 → rootfs → 镜像生成（post-image 脚本）**。全增量：改一个包只重建那一个。
- 和 Yocto 比：buildroot 简单直接（make 一把梭），Yocto 适合产品级层叠定制。

## 2. x86_64 实操（本机实测路径）

### 步骤 1 · 获取源码

```bash
wget https://buildroot.org/downloads/buildroot-2025.02.tar.xz
tar xf buildroot-2025.02.tar.xz && cd buildroot-2025.02
```

### 步骤 2 · 读懂上游 EFI 配置

```bash
make pc_x86_64_efi_defconfig
grep -E 'GRUB2|EFI|POST_IMAGE|GENIMAGE|EXT2' .config
```

`pc_x86_64_efi_defconfig` 的骨架（有删减）：

```text
BR2_LINUX_KERNEL=y            自己编内核（board/pc/linux.config，virtio/串口全 built-in）
BR2_TARGET_ROOTFS_EXT2=y      rootfs 用 ext2（也得到 rootfs.ext4 文件）
BR2_TARGET_GRUB2=y
BR2_TARGET_GRUB2_X86_64_EFI=y ← grub2 编成 x86_64 EFI 应用（不是 BIOS stage1.5）
BR2_ROOTFS_POST_IMAGE_SCRIPT="board/pc/post-image-efi.sh"   ← 镜像生成钩子
BR2_PACKAGE_HOST_GENIMAGE=y   ← 用 genimage 拼磁盘镜像
```

三个 board 文件是这条流水线的"主板说明书"：

- `board/pc/linux.config`：内核配置（virtio-blk/net/串口控制台全 built-in，无 initrd）
- `board/pc/grub-efi.cfg`：`linux /bzImage root=PARTUUID=... console=tty1`
- `board/pc/post-image-efi.sh`：把 rootfs 的真实 UUID 注入 grub.cfg 和 genimage 配置，
  然后调用 genimage 按 `genimage-efi.cfg` 拼出 `disk.img`

`board/pc/genimage-efi.cfg` 的结构（这就是 lab14 Part D 说的 GPT/ESP 的产房）：

```text
image efi-part.vfat { vfat { EFI/ bzImage } }      ← 16MB FAT ESP
image disk.img {
  hdimage { partition-table-type = "gpt" }
  partition boot { image = "efi-part.vfat"; bootable; }   ← ESP 分区
  partition root  { image = "rootfs.ext2" }               ← 根分区
}
```

### 步骤 3 · 定制（每条都有原因）

用 `utils/config` 脚本改（不用进 menuconfig，可写进文档复现）：

```bash
# (1) 裁掉上游默认的整套 wifi 固件/connman——虚拟机不需要，省 300MB+ 下载和大量时间
./utils/config --disable BR2_PACKAGE_LINUX_FIRMWARE
./utils/config --disable BR2_PACKAGE_CONNMAN --disable BR2_PACKAGE_CONNMAN_WIFI
./utils/config --disable BR2_PACKAGE_CONNMAN_CLIENT --disable BR2_PACKAGE_WIRELESS_REGDB
./utils/config --disable BR2_PACKAGE_ACPID

# (2) 无头使用：getty 挂到串口（qemu -serial stdio 直接收割）
./utils/config --set-str BR2_TARGET_GENERIC_GETTY_PORT ttyS0

# (3) 给 root 设密码（默认空密码 ssh/console 都进不来；设了才能远程登录）
./utils/config --set-str BR2_TARGET_GENERIC_ROOT_PASSWD labroot

# (4) 加 dropbear（轻量 sshd）——"从能启动到能使用"
./utils/config --enable BR2_PACKAGE_DROPBEAR

# (5) 内核 config fragment：开 EFI stub + 内置 cmdline（Part 4 的关键伏笔）
cat > board/pc/efi-stub.fragment <<'EOF'
CONFIG_EFI_STUB=y
CONFIG_CMDLINE_BOOL=y
CONFIG_CMDLINE="root=/dev/vda2 rootwait console=ttyS0"
EOF
./utils/config --enable BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES
./utils/config --set-str BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES "board/pc/efi-stub.fragment"

# (6) grub 引导也要串口：kernel cmdline 加 console=ttyS0
sed -i 's/console=tty1/console=tty0 console=ttyS0/' board/pc/grub-efi.cfg

make olddefconfig     # 让 utils/config 的改动过一遍 Kconfig，落到 .config
```

### 步骤 3 补充 · 网络与远程访问（真实踩坑）

默认 rootfs **没有任何网卡配置**（`/etc/network/interfaces` 只有 lo）。症状：qemu
user 网络的 `hostfwd` 端口"能连上但永远没响应"（slirp 先 accept 再等 guest，guest
没 IP 就黑洞）。解法：rootfs overlay 一份 interfaces + 装 efibootmgr：

```bash
mkdir -p ../net-overlay/etc/network
cat > ../net-overlay/etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
./utils/config --set-str BR2_ROOTFS_OVERLAY "$(pwd)/../net-overlay"
./utils/config --enable BR2_PACKAGE_EFIBOOTMGR      # guest 里查启动项用（注意内核还要开 efivars，见坑 9）
make olddefconfig
```

> 真实教训：`utils/config --enable` 写错符号名**不会报错**（比如把 DROPBEAR 拼成
> DROPSBEAR），`make olddefconfig` 会静默丢弃不认识的行。**改完必须
> `grep '^BR2_XXX' .config` 验证**再 make。

### 步骤 4 · 构建前检查（两个真实坑）

```bash
echo $LD_LIBRARY_PATH   # 非空就会在 dependencies 检查时被拒！
# 坑 1：构建前 env -u LD_LIBRARY_PATH
# 坑 2：国内直连 cdn.kernel.org/gnu 镜像很慢——大文件可以提前下到 dl/：
#   dl/linux-6.1.24.tar.xz  gcc-13.3.0.tar.xz  binutils-2.43.1.tar.xz  grub-2.12.tar.xz
#   （TUNA 镜像有：https://mirrors.tuna.tsinghua.edu.cn/kernel/v6.x/... 与 /gnu/...）
#   buildroot 会先校验 sha256 再复用，不放心就让它自己下
```

### 步骤 5 · make

```bash
env -u LD_LIBRARY_PATH make -j$(nproc) 2>&1 | tee build.log
```

会发生什么（对号入座地看日志）：`>>> host-skeleton`（宿主工具）→
`host-gcc-final`（交叉工具链，最耗时）→ `linux`（内核）→ rootfs 各包 →
`grub2`（编两次：host 工具 + x86_64-efi 目标）→ `post-image-efi.sh`（拼 disk.img）。
本机（24 vCPU）实测全程约 50 分钟，工具链占了大头；之后任何单包增量重编都在 1 分钟内
（加 dropbear 实测 36 秒）。

### 步骤 6 · 产物解剖（真实输出）

```text
$ ls -lh output/images/
bzImage 6.3M   rootfs.ext2 120M   efi-part.vfat 16M   disk.img 137M

$ partx --show output/images/disk.img        # 读 GPT（sfdisk 未装时；sfdisk -d 同理）
NR START    END SECTORS SIZE NAME UUID
 1    64  32767   32704  16M boot bc7ba988-...     ← ESP（genimage 布局：32K 偏移起）
 2 32768 278527  245760 120M root 781dbace-...     ← root，PARTUUID 注入 grub.cfg

$ mdir -i output/images/efi-part.vfat :: ::/EFI/BOOT
BZIMAGE        6595808  bzImage                 ← 内核放在 ESP 根目录
bootx64  efi    622592  EFI/BOOT/bootx64.efi    ← grub（走 lab14 讲的万能路径）
grub     cfg       162  EFI/BOOT/grub.cfg       ← grub 配置也在 ESP 上

$ cat board/pc/grub-efi.cfg（构建后已注入真实 UUID 和我们的 sed）
menuentry "Buildroot" {
 linux /bzImage root=PARTUUID=781dbace-... rootwait console=tty0 console=ttyS0
}
```

### 步骤 7 · 用 OVMF 启动（pflash 双盘 + KVM + 串口）

```bash
cp /usr/share/OVMF/OVMF_VARS_4M.fd VARS.fd    # 每次实验独立 vars
qemu-system-x86_64 -machine q35 -m 1G -accel kvm -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=VARS.fd \
  -drive file=output/images/disk.img,if=virtio,format=raw \
  -netdev user,id=n0,hostfwd=tcp::10022-:22 \
  -device virtio-net-pci,netdev=n0 \
  -display none -serial stdio
```

真实串口输出（节选，完整链一气呵成）：

```text
Starting system message bus: done
Starting iptables: OK
Starting network: OK
Starting crond: OK
Starting dropbear sshd: OK            ← 增量加的包已在跑

Welcome to Buildroot
buildroot login: root                 ← 串口直接登录（root / labroot）
# uname -a
Linux buildroot 6.1.24 #1 SMP PREEMPT_DYNAMIC ... x86_64 GNU/Linux
# df -h /
/dev/root 107.0M 38.8M 59.8M 39% /
# poweroff -f
ACPI: PM: Preparing to enter system sleep state S5
reboot: Power down
```

宿主机侧验证 SSH 转发（eth0 经 overlay 的 DHCP 拿到 10.0.2.15）：

```text
$ python3 -c "import socket;s=socket.create_connection(('127.0.0.1',10022));print(s.recv(64))"
b'SSH-2.0-dropbear_2024.86...'        ← hostfwd 10022 → guest:22 全通
```

**注意**：上游 `board/pc/readme.txt` 的 UEFI 章节还在用 `-bios OVMF.fd` 老写法
（变量不持久），本 lab 用的是 pflash 双盘——这就是 lab11/14 讲过的差别。

### 步骤 8 · 迭代定制（增量构建的威力，实测耗时）

```bash
# 加个包：只有新包 + rootfs 重打包
./utils/config --enable BR2_PACKAGE_DROPBEAR && make olddefconfig && make   # 实测 36s
# 加 rootfs overlay + 另一个包                                                        # 实测 45s
# 改内核选项
make linux-menuconfig     # 勾完保存，自动生成对应的 fragment/更新
make linux-rebuild
# 改 rootfs 内容再重打包（不重编任何包）
touch output/target/etc/motd && make
```

## 3. 手工拼 ESP：绕过 grub，让 OVMF 直接引导内核

前置知识（lab14 已铺）：UEFI 引导 = 「找到 EFI 应用并运行」。Linux 内核开了
`CONFIG_EFI_STUB` 后，**bzImage 自己就是合法的 EFI 应用**（文件头带 PE 签名）——
grub 那一层对"只会引导一个固定内核"的场景是可省的。

### 3.1 拼一块「ESP + root」双分区 GPT 盘（全程无 root）

宿主机可能连 `mkfs.vfat`/`sfdisk` 都没装——没关系，**buildroot 刚替你编好了全套
host 工具**（这也解释了 defconfig 里那些 `HOST_*` 选项的存在意义）：

```bash
H=../output/host; IMG=../output/images; cd $IMG

# 1) 16MB 的 FAT ESP，内核放到"万能路径"
#    注意：mkfs.vfat -C 的单位是 KiB！16MB 要写 16384（写 16M 会当块数解析报错）
$H/sbin/mkfs.vfat -C esp-stub.img 16384
$H/bin/mmd  -i esp-stub.img ::/EFI ::/EFI/BOOT
$H/bin/mcopy -i esp-stub.img bzImage ::/EFI/BOOT/BOOTX64.EFI

# 2) 用 host-genimage 拼 GPT（和上游 post-image 同一个工具，自定义 cfg）
cat > ../genimage-stub.cfg <<'EOF'
image disk-stub.img {
	hdimage { partition-table-type = "gpt" }
	partition boot {
		image = "esp-stub.img"
		partition-type-uuid = U          # genimage 的 ESP 类型简写
		offset = 1M
		bootable = true
	}
	partition root {
		image = "rootfs.ext2"
		partition-type-uuid = 44479540-f297-41b2-9af7-d131d5f0458a  # Linux fs
	}
}
EOF
$H/bin/genimage --rootpath . --tmppath ../output/build/genimage-stub.tmp \
  --inputpath . --outputpath . --config ../genimage-stub.cfg
partx --show disk-stub.img
# NR START    END SECTORS SIZE NAME UUID
#  1  2048  34815   32768  16M boot 6680326a-...   ← ESP（1MiB 起）
#  2 34816 280575  245760 120M root f9af34c1-...   ← root
```

### 3.2 OVMF 自动引导（走万能路径 + 内置 cmdline）

```bash
qemu-system-x86_64 -machine q35 -m 1G -accel kvm \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=VARS2.fd \
  -drive file=disk-stub.img,if=virtio,format=raw \
  -display none -serial stdio
```

真实串口输出（节选）——注意全程**没有 grub**：

```text
BdsDxe: loading Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0)
BdsDxe: starting Boot0001 "UEFI Misc Device" ...     ← OVMF 为这块盘动态生成的入口
Linux version 6.1.24 (peter@debian13) (x86_64-buildroot-linux-gnu-gcc ... 13.3.0)
Kernel command line: root=/dev/vda2 rootwait console=ttyS0   ← CONFIG_CMDLINE 原样生效
VFS: Mounted root (ext4 filesystem) readonly on device 254:2.
Welcome to Buildroot
buildroot login:
```

启动逻辑：盘上没有 Boot#### → OVMF 为块设备**动态生成**一个入口（"UEFI Misc
Device"），它最终落到万能路径 `\EFI\BOOT\BOOTX64.EFI` → 直接加载内核 EFI stub →
万能路径启动**不传任何参数**，内核用 `CONFIG_CMDLINE` 内置的 `root=/dev/vda2
console=ttyS0`（vda1=ESP、vda2=rootfs，正好对上）→ 登录。固件直接启动内核。

### 3.3 对照实验：Shell 手动引导，眼见"参数变 cmdline"

再做一块 `disk-manual.img`：流程同上，但内核文件名用 `vmlinuz.efi`（**不是**
BOOTX64.EFI）→ OVMF 找不到任何可引导项，报
`BdsDxe: failed to load Boot0001 "UEFI Misc Device": Not Found` 后落入 UEFI Shell。
在 Shell 里手动引导并加参数：

```text
Shell> FS0:\EFI\BOOT\vmlinuz.efi console=ttyS0 brlab=from-shell
Command line: FS0:\EFI\BOOT\vmlinuz.efi console=ttyS0 brlab=from-shell
...（内核启动）
# cat /proc/cmdline
root=/dev/vda2 rootwait console=ttyS0 FS0:\EFI\BOOT\vmlinuz.efi console=ttyS0 brlab=from-shell
```

三个观察：

1. Shell 把**整条命令行（含镜像路径本身）**当作加载选项传给 EFI 应用；
2. 内核 stub 把加载选项**追加**到内置 cmdline 之后（x86 语义：后面的同名胜出）；
3. 自造参数 `brlab=from-shell` 原样进了 `/proc/cmdline`——这就是"内核是 EFI
   应用、命令行是加载选项"的实锤。

接着可以顺手做 lab14 Part C 的 bcfg 实验：`bcfg boot add 0 FS0:\EFI\BOOT\vmlinuz.efi
"MyLinux"` 把它变成正式启动项，验证 BootOrder 与 vars 持久化（实测：写完重启，
`BdsDxe: loading Boot0003 "MyLinux"`，不再进 Shell）。

## 4. aarch64 + AAVMF 对照（ARM 服务器路径）

lab13 的原命令用的 `AAVMF_CODE.ms.fd` 就是这套流程的 ARM 版固件。在 ARM 服务器上：

```bash
# 固件（Ubuntu/Debian 包名 qemu-efi-aarch64）
ls /usr/share/AAVMF/
# AAVMF_CODE.fd / AAVMF_VARS.fd            普通（无 Secure Boot 钥匙）
# AAVMF_CODE.ms.fd / AAVMF_VARS.ms.fd      预置微软钥匙（Windows 兼容 Secure Boot）

# buildroot 侧
make qemu_aarch64_virt_defconfig           # aarch64 virt 板的最小配置
# EFI 化二选一：
#   A. grub2 路线：BR2_TARGET_GRUB2_ARM64_EFI=y（产物 BOOTAA64.EFI，同 x86 流程）
#   B. 内核 stub 路线：CONFIG_EFI_STUB=y（aarch64 内核同样支持）
make
qemu-system-aarch64 -machine virt -cpu host -accel kvm -m 1G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
  -drive if=pflash,format=raw,file=VARS-a64.fd \
  -drive file=disk.img,if=virtio -display none -serial stdio
```

与 x86 的三处不同：机型 `virt`（没有 q35，lab14 Part A 讲过）、固件 AAVMF、
万能路径文件名 `BOOTAA64.EFI`。其余（GPT/ESP/grub.cfg/stub/串口）完全一致——
**UEFI 的意义就是把"引导"这件事跨架构统一了**。

`--cpu host` + `-accel kvm` 只在同架构宿主可用；x86 机器上想试 aarch64 用
`-cpu cortex-a72 -accel tcg`（纯软件翻译，见 course/15，慢 5–50 倍但能跑）。

## 5. 常见坑（全部真实翻车，含血泪）

1. **`LD_LIBRARY_PATH` 非空 → dependencies 检查失败**：`env -u LD_LIBRARY_PATH make`。
2. **下载卡死/龟速**：`dl/` 预置大文件（见步骤 4）；小包慢就耐心等或设
   `BR2_BACKUP_SITE=https://sources.buildroot.net`。
3. **`utils/config` 符号写错静默丢弃**：拼错包名（如把 DROPBEAR 拼成 DROPSBEAR）
   不会报错，`make olddefconfig` 直接丢行。改完必 `grep '^BR2_XXX' .config` 验证。
4. **grub.cfg 里 root= 设备名**：genimage 的 UUID 注入只对 `disk.img` 单盘形态
   有效；手工拼盘/多盘时 root= 要自己算（`/dev/vda2`、`/dev/vdb`…）。
4. **串口没输出**：三个环节任缺一个就哑——内核 `console=ttyS0`（grub.cfg 或
   CONFIG_CMDLINE）、grub.cfg 里也带上、getty 挂 ttyS0。
5. **rootfs 放不下**（ENOSPC during mkfs）：`BR2_TARGET_ROOTFS_EXT2_SIZE` 调大。
6. **Secure Boot 固件拒绝启动**：secboot 版 OVMF/AAVMF(.ms) 会拒绝未签名内核/
   grub（Access Denied）。实验请用非 secboot 固件，或关闭 Secure Boot。
7. **qemu hostfwd 端口"通而无响应"**：slirp 会先 accept 再等 guest——guest 没拿到
   IP（没配 DHCP）时表现为黑洞。给 rootfs 配 network overlay（步骤 3 补充）。
8. **guest 里 `efibootmgr` 无输出**：内核 fragment 需补 `CONFIG_EFIVAR_FS=y`，
   否则 efibootmgr 没有 `/sys/firmware/efi/efivars` 可读。
9. **`mkfs.vfat -C xxx 16M` 报 Bad block count**：`-C` 的单位是 **KiB**，写 `16384`。
10. **`make clean` 冲动**：output 全删重来要 30+ 分钟；增量思维——单包
    `make <pkg>-rebuild`、配置改完 `make` 即可（实测加包 36 秒）。

## 6. 思考题

1. `pc_x86_64_efi_defconfig` 的内核不需要 initrd 就能挂 rootfs，靠什么？如果 rootfs
   换成需要内核模块的存储（如 NVMe）会遇到什么？
2. grub 和内核 EFI stub 都能当"第一个 EFI 应用"，各自的取舍是什么？
   （提示：grub.cfg、多内核选择、Secure Boot、initrd 加载）
3. buildroot 为什么给 grub 编两次（host 与 target）？genimage、mtools 为什么是
   host 工具？
4. 把本 lab 的 disk.img 用 lab13 的方式交给 virt-install `--import`，需要改哪
   几处？（固件、机型、盘）
5. `dl/` 里预置的 tarball 如何保证没被篡改？（顺着 buildroot 源码找到校验代码）

## 参考资料

- [lab14 · q35 与 OVMF 全流程](lab14-q35-uefi.md)（本 lab 的前置概念）
- [21 · 固件加载与 UEFI 启动](../course/21-UEFI固件加载.md)
- [15 · 跨架构模拟实战](../course/15-跨架构模拟实战.md)（TCG）
- buildroot manual：<https://buildroot.org/downloads/manual/manual.html>
- edk2 / grub2 / genimage 上游文档

## 输出记录

- 时间：
- make 总耗时：
- `ls -lh output/images/`：
- OVMF → grub → login 各阶段串口关键行：
- EFI stub 直接引导是否成功：
- 遇到的问题 / 解决：
