# Lab 14 · q35 机型与 OVMF/UEFI 启动全流程观察

> **难度**：★★★★
> **前置**：lab11（pflash 基础）、建议先读 [22 · 机型解析与 Q35](../course/22-机型解析与Q35.md)
> **预计时间**：60 分钟
> **实测环境**：Debian 13 · QEMU 10.0.13（q35 → `pc-q35-10.0`）· OVMF 2025.02

## 目标

- 用 `info pci` **亲眼看到** q35 比 i440fx 多造了哪些硬件（真实 PCI ID）
- 不装任何系统，从**冷启动一路观察到 UEFI Shell**，读懂每一行输出
- 会用 UEFI Shell：`ver` / `map` / `bcfg`，并理解 Boot####/BootOrder 变量
- **验证 UEFI 变量真的被写进 vars pflash**（md5 前后对比）
- 解剖一块 GPT/ESP 磁盘，说清 `\EFI\BOOT\BOOTX64.EFI` 为什么是"万能 U 盘路径"
- 画出从 `0xFFFFFFF0` 到 login 提示符的完整时序

这个 lab 不装系统——**空机器 + 固件本身就是最好的教材**。OS 只是固件找到的一个
EFI 应用而已（lab15 会亲手造一个）。

## Part A · 机型：q35 到底造了什么板子

### A.1 实测对比

```bash
echo -e 'info pci\nquit' | qemu-system-x86_64 -machine q35 -S -display none -monitor stdio
echo -e 'info pci\nquit' | qemu-system-x86_64 -machine pc  -S -display none -monitor stdio
```

真实输出（本机，只留关键行）：

```text
=== q35 ===                            === pc (i440fx) ===
Bus 0, device 0: Host bridge           Bus 0, device 0: Host bridge
  PCI device 8086:29c0   ← Q35 MCH       PCI device 8086:1237   ← i440FX
Bus 0, device 31, function 0:          Bus 0, device 1, function 0:
  ISA bridge 8086:2918   ← ICH9 LPC      ISA bridge 8086:7000   ← PIIX4
Bus 0, device 31, function 2:          Bus 0, device 1, function 1:
  SATA controller 8086:2922 ← ICH9 AHCI   IDE controller 8086:7010  ← PIIX IDE
Bus 0, device 31, function 3:
  SMBus 8086:2930
```

解读：

- **q35 = Intel 3 系芯片组的虚拟化**（2009 年的桌面平台）：MCH（内存控制 hub，
  8086:29c0）+ ICH9 南桥（8086:2918/2922/2930）。真实芯片组的 PCI ID 被原样模拟，
  客户机里的 lspci、驱动绑定看到的和物理机一致。
- **i440fx = 1996 年的技嘉板**（8086:1237 + PIIX）：老到只有 IDE，没有 AHCI。
- 最重要的架构差：q35 的主总线是 **PCIe（pcie.0）**，i440fx 是 **PCI（pci.0）**。
  表现之一：virtio 网卡挂在 q35 上时地址是 `bus='0x01'`（通过隐式 PCIe root
  port 挂到 00:01.0 下游），而 i440fx 上直接 `bus='0x00'`。

```text
q35 拓扑（简化）                         i440fx 拓扑（简化）
CPU ── MCH(00.0) ── pcie.0               CPU ── i440FX(00.0) ── pci.0
                    ├─ PCIe root port 00:01.0          ├─ PIIX(01.0) IDE/ISA/USB
                    │    └─ 01:00.0 virtio-net 等       ├─ 02.0 VGA
                    ├─ 01:0x.0 更多 root port…          └─ 03.0 e1000
                    └─ ICH9 LPC(31.0) AHCI(31.2)…
```

### A.2 机型版本化：`q35` 只是别名

lab13 的 `virsh dumpxml` 已给出证据——命令行写 `--machine q35`，XML 里落盘的是：

```xml
<type arch='x86_64' machine='pc-q35-10.0'>hvm</type>
```

`q35` 是"最新 pc-q35-*"的**别名**，在定义域的那一刻被解析成具体版本并**永久固化**。
之后宿主升级 QEMU，这台 VM 的硬件行为不变（迁移/复现安全）。生产建议直接写死
`pc-q35-<ver>`。`qemu-system-x86_64 -machine help` 可看全部版本。

> ARM 对照（lab13 的 `--machine virt-6.2`）：aarch64 的 `virt` 机型同理，
> `virt-6.2` = 冻结在 QEMU 6.2 行为的虚拟开发板。

## Part B · OVMF 冷启动 → UEFI Shell

### B.1 无盘启动：固件自己就是"最后一个操作系统"

```bash
cp /usr/share/OVMF/OVMF_VARS_4M.fd VARS_test.fd     # 独立的 vars 副本，别污染模板
md5sum VARS_test.fd                                  # 记住启动前的指纹
qemu-system-x86_64 -machine q35 -m 256 -accel kvm \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=VARS_test.fd \
  -display none -serial stdio                        # 串口当控制台
```

真实串口输出（节选）：

```text
BdsDxe: loading Boot0001 "EFI Internal Shell" from Fv(7CB8BDC9-...)/FvFile(7C04A583-...)
BdsDxe: starting Boot0001 "EFI Internal Shell" from Fv(7CB8BDC9-...)/FvFile(7C04A583-...)
UEFI Interactive Shell v2.2
EDK II
UEFI v2.70 (Debian distribution of EDK II, 0x00010000)
Mapping table
     BLK0: Alias(s):
          PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x2,0xFFFF,0x0)     ← AHCI 光驱/盘位
Press ESC in 5 seconds to skip startup.nsh or any other key to continue.
Shell>
```

逐行解读，这就是 UEFI 的 **BDS（Boot Device Selection）阶段**在干活：

1. 找不到任何可引导设备（BootOrder 里只剩固件内置项）；
2. 选中 `Boot0001 "EFI Internal Shell"`——Shell 本身是**编进固件里的 EFI 应用**；
3. `loading`/`starting` 两行是 BDS 把它作为普通 EFI 程序启动的日志；
4. `Mapping table` 是 Shell 枚举出的文件系统映射（`FS0:`/`BLK0:`）。

### B.2 脚本化驱动 Shell（无头自动操作）

串口接 stdio 后，用管道喂按键即可自动化（lab 的所有"真实输出"都这么抓的）：

```bash
( sleep 2; printf '\n';                      # 提前敲掉 5 秒 startup.nsh 倒计时
  sleep 22; printf 'ver\r'; sleep 3
  printf 'map -r\r';  sleep 2
  printf 'bcfg boot dump\r'; sleep 4
) | timeout 55 qemu-system-x86_64 -machine q35 -m 256 -accel kvm \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=VARS_test.fd \
    -display none -serial stdio
```

`bcfg boot dump` 真实输出（空机器，只有固件内置项）：

```text
Option: 00. Variable: Boot0000
  Desc    - UiApp                          ← 固件设置界面（那个蓝底菜单）
  DevPath - Fv(7CB8BDC9-...)/FvFile(462CAA21-...)
Option: 01. Variable: Boot0001
  Desc    - EFI Internal Shell
  DevPath - Fv(7CB8BDC9-...)/FvFile(7C04A583-...)
```

### B.3 启动五阶段对照表

```text
0xFFFFFFF0 复位向量（code pflash 顶部，x86 特有）
   │
   ▼
SEC   最早期初始化，找到并跳到 PEI          ← ARM 上是 TF-A/AAVMF 的 SEC 等价物
   ▼
PEI   内存初始化（报告可用 RAM 给固件）
   ▼
DXE   驱动执行环境：枚举 PCI、挂存储/网络驱动   ← BdsDxe、AHCI 驱动都在这层
   ▼
BDS   启动决策：读 BootOrder → 逐个尝试 Boot#### → 找不到则 Shell/设置界面
   ▼
UEFI 应用 = Shell / Windows bootmgfw / grub(shim) / 内核 EFI stub（lab15）
```

> **debugcon 为什么没日志？** `-debugcon file:log -global isa-debugcon.iobase=0x402`
> 是抓 OVMF 内部 DEBUG 输出的口子，但发行版 OVMF 是 **RELEASE 构建**（DEBUG 宏
> 编译掉了），日志基本为空。要完整阶段日志需自编 edk2 的 DEBUG 版
>（`OvmfPkg/build.sh -D DEBUG_ON_SERIAL_PORT`）。日常观察走串口控制台就够。

## Part C · UEFI 变量：pflash 可写性的直接证据

### C.1 一次启动就会写 vars

接 Part B 的会话，退出 QEMU 后立刻：

```bash
md5sum /usr/share/OVMF/OVMF_VARS_4M.fd VARS_test.fd
# 模板（从未被写）:      173134c7c1593bad9cd101dc10bef49b
# 第 1 次启动后:         a31fd91624cec7a78fdaf9e6b13dca02   ← 变了
# 第 2 次启动后:         8e656e6c9c08ea888ccc7ec8526ada7e   ← 又变了
```

我们**没有改任何设置**，每次启动 OVMF 都会写变量存储（启动尝试记录、ConIn/ConOut
绑定等）。这就是 lab11 讲的"vars 盘必须可写"的实锤：只读会导致固件每次都带着
失忆症启动（功能上通常还能跑，但 BootOrder 等永不持久）。

### C.2 有系统盘时：Boot#### 是怎么来的

在装好 Ubuntu 的机器上（lab13 的 VM）看：

```text
# efibootmgr（guest 里执行）
BootCurrent: 0003
BootOrder: 0003,0001,0000,0002
Boot0000* UiApp
Boot0001* UEFI Misc Device  PciRoot(0x0)/.../...{auto_created_boot_option}
Boot0002* EFI Internal Shell
Boot0003* Ubuntu   HD(15,GPT,6ec49856-...)/File(\EFI\ubuntu\shimx64.efi)
```

- `Boot0003 Ubuntu`：**安装器/grub 安装时**用 efibootmgr 写进 vars 的（设备路径
  = GPT 第 15 分区 + ESP 里的 shim 文件），OVMF 的 BDS 按 BootOrder 试到它。
- `Boot0001 {auto_created_boot_option}`：OVMF **动态生成**的兜底项（对 NIC 等），
  存在于 vars 但标注了 auto 属性，设备没了会失效。
- 对照第 B.2 节：空机器只有 0000/0001（UiApp/Shell）。

### C.3 亲手写一个启动项：bcfg 全流程（真实会话）

材料：lab15 的 `disk-manual.img`（ESP 里有 `\EFI\BOOT\vmlinuz.efi`，故意**不用**
BOOTX64.EFI 这个名字，逼 OVMF 找不到可引导项）。冷启动第一幕就能看到 BDS 的
"逐项尝试"：

```text
BdsDxe: failed to load Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0): Not Found
BdsDxe: loading Boot0002 "EFI Internal Shell" ...
```

在 Shell 里新增启动项并置顶（`add 0` = 插到 BootOrder 第 0 位）：

```text
Shell> bcfg boot add 0 FS0:\EFI\BOOT\vmlinuz.efi "MyLinux"
bcfg: Add Boot0003 as 0

Shell> bcfg boot dump
Option: 00. Variable: Boot0003
  Desc    - MyLinux                                          ← 新项排第一
  DevPath - PciRoot(0x0)/Pci(0x3,0x0)/HD(1,GPT,B9892D94-...)/\EFI\BOOT\vmlinuz.efi
Option: 01. Variable: Boot0000
  Desc    - UiApp
...
```

重启（或干脆杀掉 QEMU 再起，用同一个 vars 文件），**不进 Shell** 直接引导：

```text
BdsDxe: loading Boot0003 "MyLinux" from PciRoot(0x0)/Pci(0x3,0x0)/HD(1,GPT,...)/\EFI\BOOT\vmlinuz.efi
BdsDxe: starting Boot0003 "MyLinux" ...
（内核启动，进入系统）
```

这一套就是 `efibootmgr`/Windows 安装器/grub-install 在你真机上做的事：**写两个
UEFI 变量（Boot#### 描述符 + BootOrder 顺序），存在 vars pflash 里，下次开机由
BDS 照单执行**。vARS 文件 md5 在会话前后必然不同（对照 C.1）。

顺带一个进阶观察（lab15 详述）：在 Shell 里手动引导时，整条命令行会变成内核的
cmdline——`FS0:\EFI\BOOT\vmlinuz.efi console=ttyS0 brlab=from-shell` 启动后
`cat /proc/cmdline` 原样可见。**UEFI 应用的"参数"就是加载选项，而内核 EFI stub
把加载选项当命令行**。

### C.4 \EFI\BOOT\BOOTX64.EFI：万能引导路径

UEFI 规范规定：找不到任何 Boot#### 时，对每个块设备尝试
`<分区>\EFI\BOOT\BOOTX64.EFI`（aarch64 上是 `BOOTAA64.EFI`）。这就是：

- U 盘在**任何**机器上都能启动的原因（安装盘 ESP 里放这个路径）；
- lab15 手工拼 ESP 的原理（把内核 EFI stub 放在这个路径，OVMF 自动加载）。

### C.5 `-bios`（只读整镜像）对照实验

```bash
qemu-system-x86_64 -machine q35 -bios /usr/share/OVMF/OVMF.fd ...   # code+vars 合一，只读 ROM
```

这种方式固件变量只能走"模拟变量"（RAM 里），重启全丢。快速验证口子可以，正式
VM 请永远用 pflash 双盘（lab11 详述）。ARM 的 AAVMF 同理：`-bios QEMU_EFI.fd`
是偷懒写法，正规是两块 pflash（lab13 原命令就是正确示范）。

## Part D · 解剖 GPT/ESP 磁盘

拿任意一块可启动镜像（lab13 的 qcow2 转 raw，或 lab15 的 disk.img）：

```bash
qemu-img convert -O raw u24-dev.qcow2 flat.img     # 或直接用 raw 的 disk.img
partx --show flat.img          # 读 GPT（sfdisk -d / sgdisk -p 同理，装了哪个用哪个）
# NR START    END SECTORS SIZE NAME UUID
# 14  ...     BIOS boot 分区
# 15  ...     ESP（类型 UUID C12A7328-F10F-11D2-BA4B-00A0C93EC93B）
```

用 mtools 无 root 读 ESP 内容（offset = 起始扇区 × 512）：

```bash
START=$(partx -o START -g -n 15 flat.img)   # 或从 partx 输出里取
mdir -i flat.img@@${START}s ::/EFI ::/EFI/ubuntu
# 会看到 shimx64.efi grubx64.efi ...
```

引导链（Ubuntu）：`OVMF → Boot0003 → shim → grubx64.efi → grub.cfg(也在 ESP) → /boot 内核`。
buildroot（lab15）则是 `OVMF → BOOTX64.EFI(grub) → /bzImage`——**grub.cfg 和内核
都放在 ESP 上**，最简形态。

## Part E · 总时序：从复位到 login

```text
QEMU 启动
 ├─ 载入 pflash code（0xFFC00000 起 4M） + vars
 ├─ vCPU 复位 → 0xFFFFFFF0 取指 → OVMF SEC/PEI/DXE
 ├─ BDS：读 vars 里 BootOrder → 试 Boot####
 │    ├─ 命中 HD(15,GPT,...)\EFI\ubuntu\shimx64.efi   ← 启动链开始
 │    └─ 全失败 → \EFI\BOOT\BOOTX64.EFI → 还失败 → Shell
 ├─ grub：读 ESP 上 grub.cfg → 加载内核+initrd → ExitBootServices()
 └─ Linux：挂 root → systemd → cloud-init/getty → login:
```

**UEFI 的一切引导本质都是一句话：找到并运行一个 EFI（PE 格式）应用，把机器
交出去。** Shell 是 EFI 应用，grub 是，Windows 引导器是，Linux 内核自己也可以是
（EFI stub，lab15 实测）。

## 常见坑

1. **4M/2M 混用** → pflash size mismatch，同套配同套。
2. **vars 写坏后无限重启/进不了设置**：拷贝新模板覆盖 vars 副本即可（模板的价值）。
3. **secboot 版固件拒绝启动**：`OVMF_CODE_4M.secboot.fd` 开着 Secure Boot 时未签名
   内核会被拒（"Access Denied"）——实验用非 secboot 版，或去设置里关 SB。
4. **q35 下老系统找不到光驱/硬盘**：q35 只有 AHCI，没有 IDE 控制器（准确说没有
   PIIX IDE）。Win7/XP 等老系统需要 `-device ide-cd` 显式加或改 i440fx。
5. **串口无输出**：发行版 OVMF 默认带串口终端，但 guest 的 grub.cfg/kernel 得有
   `console=ttyS0` 才会在串口打日志；固件阶段输出与 OS 无关，总能看到。

## 思考题

1. `q35` 别名解析成 `pc-q35-10.0` 发生在什么时候？为什么设计成"定义时固化"？
2. 把 vars pflash 改成 `readonly=on`，BDS 还能启动 Ubuntu 吗？哪些功能会异常？
   （动手试，别猜）
3. `Boot0001 UEFI Misc Device ... {auto_created_boot_option}` 是谁、在什么时机创建的？
4. 为什么 `\EFI\BOOT\BOOTX64.EFI` 在 aarch64 机器上叫 `BOOTAA64.EFI`？这个文件名
   是谁规定的？
5. `-bios` 单文件方式和 pflash 双盘方式，内存布局有何不同？

## 参考资料

- [21 · 固件加载与 UEFI 启动](../course/21-UEFI固件加载.md)
- [22 · 机型解析与 Q35 芯片组](../course/22-机型解析与Q35.md)
- [25 · 机型与固件的客户机视角](../course/25-机型与固件的客户机视角.md)（ARM 对照）
- edk2 OVMF 白皮书、UEFI 规范 2.x（Boot Manager 章节）

## 输出记录

- 时间：
- q35 `info pci` 关键三行（MCH/ICH9/AHCI ID）：
- `bcfg boot dump` 输出：
- VARS md5 前 / 后：
- 遇到的问题 / 解决：
