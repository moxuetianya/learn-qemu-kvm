# Lab 13 · virt-install 半自动安装：cloud-init seed + UEFI + macvtap

> **难度**：★★★★
> **前置**：lab02（环境）、lab03（第一台 VM）、lab11（OVMF 基础）
> **预计时间**：60 分钟
> **实测环境**：Debian 13 (trixie) x86_64 · QEMU 10.0.13 · libvirt 11.3 · OVMF 2025.02 · Ubuntu noble 云镜像

## 目标

- 读懂那条流传很广的 ARM `virt-install` 命令——**每个参数**在做什么
- 用**云镜像 + cloud-init seed ISO** 半自动装出一台开机即可 SSH 的 VM
- 说清 NoCloud seed 的工作原理：卷标、三个文件、cloud-init 四个阶段
- 说清 `--boot loader=...,nvram_template=...` 与 pflash 的关系（对照 lab11）
- 说清 macvtap 网络的原理、优点和三个经典坑
- 学会装完之后的二次定制：热插网卡、补 guest-agent、调内存

## 0. 三种装法，为什么选「半自动」

| 方式 | 过程 | 耗时 | 适用 |
| --- | --- | --- | --- |
| 交互式 ISO 安装（lab03） | 挂 ISO → VNC 点点选选装系统 | 15–40 min | 桌面系统、一次性的怪系统 |
| **云镜像 + seed（本 lab）** | 预装好的系统盘 + 一张「身份盘」 | **2–4 min** | 服务器批量、CI、开发机 |
| 手写 XML + `virsh define`（纯手工） | 全部自己来 | 看手速 | 理解每一行；特殊定制 |

云镜像 = 厂商已经装好的系统盘（自带 grub、cloud-init、ssh），但**没有任何身份**：
没有用户、没有密钥、没有主机名、不知道磁盘该多大。这些全部由 **seed ISO** 注入。
所谓「半自动」= virt-install 仍然帮你生成 domain XML 并拉起 VM（管机型、固件、磁盘、
网络的默认值），但**安装过程本身不需要人**——seed 替你「装」。

> 「纯手工写 XML」不推荐作为日常：pflash 双盘、nvram 模板、macvtap 源设备这些细节
> 极易漏，而 virt-install 生成 XML 后你再 `virsh dumpxml` 改，两头的好处都占。

## 1. 逐参数读懂那条 ARM 命令

原命令（在一台 **ARM64 物理服务器**上执行）：

```bash
virt-install --name u24-dev --memory 16384 --vcpus 16 --cpu host \
  --machine virt-6.2 \
  --boot loader=/usr/share/AAVMF/AAVMF_CODE.ms.fd,loader_ro=yes,loader_type=pflash,nvram_template=/usr/share/AAVMF/AAVMF_VARS.ms.fd \
  --import \
  --disk /data/vm/u24-dev.qcow2,bus=virtio \
  --disk /data/vm/seed-u24-dev.iso,device=cdrom \
  --network type=direct,source=enp2s0f0,source_mode=bridge,model=virtio \
  --noautoconsole --autostart
```

| 参数 | 含义 | 背后的原理 |
| --- | --- | --- |
| `--name u24-dev` | 域名 | 同时决定 NVRAM 文件名（`u24-dev_VARS.fd`）、日志名 |
| `--memory 16384 --vcpus 16` | 16G / 16 vCPU | 开发机规格；`--cpu host` 直通宿主 CPU 型号，guest 看到 Neoverse 之类真实型号 |
| `--machine virt-6.2` | **aarch64 `virt` 虚拟开发板**，锁定 6.2 版行为 | 见下「机型」小节 |
| `--boot loader=AAVMF_CODE.ms.fd,loader_ro=yes,loader_type=pflash,nvram_template=AAVMF_VARS.ms.fd` | 用两块 pflash 装 UEFI 固件 | 见下「固件」小节 |
| `--import` | 把系统盘当作「已装好」直接开机，跳过安装流程 | libvirt 不会给盘挂安装 ISO，也不会跑 POST-install |
| `--disk u24-dev.qcow2,bus=virtio` | 系统盘，virtio 总线 | ARM virt 机型上 virtio-pci 直接可用，内核自带驱动 |
| `--disk seed-u24-dev.iso,device=cdrom` | seed ISO 挂成光驱 | cloud-init NoCloud 靠**卷标**识别它，不在意是光驱还是磁盘 |
| `--network type=direct,source=enp2s0f0,source_mode=bridge,model=virtio` | **macvtap(bridge)** 直连物理网卡 | 见「网络」小节 |
| `--noautoconsole` | 不自动弹 console/VNC 窗口 | 脚本化装机的标配 |
| `--autostart` | libvirtd 启动时自动拉起该域 | 服务器开机自愈用；实验机不要 |

### 1.1 这条命令为什么是 ARM 的？三个铁证

1. **AAVMF** = *ARM Architecture Firmware*（edk2 的 ARM64 UEFI 实现）。x86 的对应物叫
   **OVMF**（`/usr/share/OVMF/OVMF_CODE_4M.fd`）。
2. **`virt-6.2`** 是 QEMU 的 **aarch64 `virt`** 机型（给 ARM 虚拟开发的通用开发板）。
   x86 上没有 `virt`，对应机型是 `q35` / `i440fx`。
3. `--cpu host` 在 ARM 服务器上直通 Neoverse 系核心；这套盘和固件搬到 x86 机器上
   根本无法引导（架构不同）。

### 1.2 `.ms` 后缀是什么

`AAVMF_CODE.ms.fd` 的 `.ms` = 固件里**预置了微软的 Secure Boot 密钥**
（PK/KEK/db，用于验签 Windows bootloader 等）。不带 `.ms` 的 `AAVMF_CODE.fd`
变量库是空的。对装 Ubuntu/Debian 这类自带 shim + 微软签名的发行版，两种都能启动；
要做 Secure Boot 实验（自签内核、 enrollment）时才需要在意区别。

### 1.3 `--machine virt-6.2` 为什么带版本号

和 course/22 讲的 `pc-q35-8.2` 一个道理：机型**版本化冻结行为**。写 `virt-6.2`
表示「即使宿主 QEMU 升级到 9.x，也按 6.2 的设备默认值/兼容性来造板子」——
迁移和长期复现都安全。偷懒写 `virt` 则永远指向最新版。

## 2. x86 等价命令（本 lab 实测版本）

概念 1:1 对应，只有三处名字要换：

| ARM 原命令 | x86 等价 | 说明 |
| --- | --- | --- |
| `--machine virt-6.2` | `--machine q35` | 实际解析为 `pc-q35-10.0`（本机 QEMU 10.0.13） |
| `AAVMF_CODE.ms.fd` / `AAVMF_VARS.ms.fd` | `OVMF_CODE_4M.fd` / `OVMF_VARS_4M.fd` | edk2 的两个架构移植；`4M` 指固件总大小 |
| `--cpu host`（Neoverse） | `--cpu host`（直通宿主 x86 型号） | 新写法建议 `host-model` |
| `source=enp2s0f0` | `source=enp1s0` | macvtap 上联的物理口，按你机器改 |

```bash
# 完整可复刻版（$LAB 目录放镜像；路径需 libvirt-qemu 可读，见步骤 5）
virt-install --connect qemu:///system \
  --name u24-dev \
  --memory 4096 --vcpus 4 --cpu host \
  --machine q35 \
  --boot loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader_ro=yes,loader_type=pflash,nvram_template=/usr/share/OVMF/OVMF_VARS_4M.fd \
  --import \
  --disk $LAB/u24-dev.qcow2,bus=virtio \
  --disk $LAB/seed-u24-dev.iso,device=cdrom \
  --network type=direct,source=enp1s0,source_mode=bridge,model=virtio \
  --noautoconsole
```

装好后生成的 XML（`virsh dumpxml u24-dev`，真实输出节选）：

```xml
<os firmware='efi'>
  <type arch='x86_64' machine='pc-q35-10.0'>hvm</type>   <!-- q35 别名解析成了带版本的机型 -->
  <loader readonly='yes' type='pflash' format='raw'>/usr/share/OVMF/OVMF_CODE_4M.fd</loader>
  <nvram template='/usr/share/OVMF/OVMF_VARS_4M.fd' templateFormat='raw' format='raw'>
    /var/lib/libvirt/qemu/nvram/u24-dev_VARS.fd          <!-- 注意：libvirt 把模板拷贝成了每域私有的副本 -->
  </nvram>
  <boot dev='hd'/>
</os>
...
<interface type='direct'>
  <mac address='52:54:00:51:91:0a'/>
  <source dev='enp1s0' mode='bridge'/>                    <!-- type=direct + mode=bridge = macvtap bridge -->
  <target dev='macvtap0'/>
  <model type='virtio'/>
</interface>
```

两个要点：

- **`nvram_template` 的语义**：模板本身永远不被写；libvirt 为每个域拷贝一份
  `u24-dev_VARS.fd`，之后 UEFI 变量的写入（启动项、BootOrder）都落在副本里。
  这就是为什么删域要 `virsh undefine u24-dev --nvram` 才连副本一起删。
- **`loader_ro=yes`**：code 盘只读挂载；vars 盘可写。和 lab11 手敲的两条
  `-drive if=pflash` 完全同构，virt-install 只是替你写了 XML。

## 3. 原理：云镜像 + NoCloud seed 如何配合

### 3.1 云镜像的分区表（实测 `lsblk`）

```text
vda      40G
├─vda1   39G  ext4          ← 根分区（首启时 cloud-init growpart 自动扩到盘大小）
├─vda14   4M               ← BIOS boot（GRUB 的 BIOS 兜底引导分区）
├─vda15 106M  vfat          ← ESP：/EFI/ubuntu/shimx64.efi → grubx64.efi → grub.cfg
└─vda16 913M  ext4          ← /boot
```

GPT + ESP + 完整引导链都已就位，所以 `--import` 开机就能从 OVMF →
`\EFI\ubuntu\shimx64.efi` → grub → 内核一路走到底，**不需要你做任何引导配置**。

### 3.2 seed ISO：一个只认「卷标」的载体

`cloud-localds seed.iso user-data meta-data` 生成的 ISO 只有两样东西：

```text
卷标：cidata          ← NoCloud 数据源靠它认盘（大小写不敏感）
文件：/user-data /meta-data [/network-config]
```

NoCloud 扫描所有块设备找卷标 `CIDATA`/`cidata` 的那个，挂载、读取。所以 seed
可以是光驱、U 盘、virtio 盘——形态无所谓，卷标说了算。没有 `cloud-localds`
（来自 `cloud-image-utils` 包）时手工等价命令：

```bash
genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data
# 或 xorriso -as mkisofs -output seed.iso -volid cidata -joliet -rock user-data meta-data
```

### 3.3 cloud-init 的四个阶段（你的每条指令落在哪）

```text
内核起来后 systemd 拉起 cloud-init.service
  │
  ├─ cloud-init-local   本地阶段：读 seed、生成网络配置(netplan)
  ├─ cloud-init(init)   per-instance：主机名、users、ssh key、write_files
  ├─ cloud-config       模块阶段：apt update、packages 安装
  └─ cloud-final        收尾：runcmd、final_message
```

关键语义：**per-instance = instance-id 变了才重跑**。`meta-data` 里的
`instance-id: u24-dev-002` 就是这个开关——同一块盘重复实验时改一下它，
用户/密钥/装包逻辑就会重新执行；不改则只在原地跑 per-once/per-always 的部分。

### 3.4 首启完整时序（从按键到能 SSH）

```text
OVMF (pflash code+vars)          ← 固件：枚举 PCI/盘，按 BootOrder 找 \EFI\ubuntu\shimx64.efi
  └→ grub (ESP 里)               ← 加载 /boot 下内核+initrd，传 root=UUID
      └→ Linux kernel            ← virtio 盘就绪，systemd 启动
          └→ cloud-init 4 阶段   ← 找到 seed（卷标 cidata）：主机名/用户/密钥/扩盘/装包
              └→ sshd + qemu-ga  ← 你 ssh 上去；virsh domifaddr 也开始有数据
```

## 4. 实操步骤（x86 实测，全部可复刻）

### 步骤 1 · 拿云镜像

```bash
mkdir -p ~/vm/u24 && cd ~/vm/u24
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
# ~600MB；国内可换镜像站。aarch64 版把 amd64 换成 arm64（给 ARM 服务器用）
```

### 步骤 2 · 做系统盘

两种做法：

```bash
# A. 拷贝一份独立盘（原命令的做法；自包含，可随便搬）
cp noble-server-cloudimg-amd64.img u24-dev.qcow2
qemu-img resize u24-dev.qcow2 40G      # 只改 qcow2 头里的"虚拟大小"，1 秒完成
                                         # 分区/文件系统的扩张由首启时 growpart 完成

# B. 覆盖层（省磁盘；原镜像保持只读基底）
qemu-img create -f qcow2 -F qcow2 -b noble-server-cloudimg-amd64.img u24-dev.qcow2 40G
```

`qemu-img info` 确认 `virtual size: 40 GiB`。

### 步骤 3 · 写 seed 三件套

`user-data`（YAML，首行必须是 `#cloud-config`）：

```yaml
#cloud-config
hostname: u24-dev
timezone: Asia/Shanghai
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...你的公钥
ssh_pwauth: false
package_update: true
packages: [qemu-guest-agent, vim, htop]
write_files:
  - path: /etc/issue.d/90-lab13.msg
    content: |
      provisioned by lab13 seed
runcmd:
  - systemctl enable --now qemu-guest-agent
final_message: "cloud-init finished after $UPTIME seconds"
```

`meta-data`（instance-id 是 cloud-init 的重跑开关）：

```yaml
instance-id: u24-dev-001
local-hostname: u24-dev
```

`network-config`（netplan v2 格式；让**所有**网卡都 DHCP，见坑 4）：

```yaml
version: 2
ethernets:
  all-nics:
    match:
      name: "en*"
    dhcp4: true
    optional: true
```

> 不写 network-config 时 cloud-init 用「fallback」规则（对首启时存在的网卡 DHCP），
> 网卡更换/热插后可能不配。显式写 `match: name: "en*"` 一劳永逸。
> 需要静态 IP 也在这里写（dhcp4: false + addresses/routes）。

### 步骤 4 · 打包 seed ISO 并验证

```bash
cloud-localds -N network-config seed-u24-dev.iso user-data meta-data
# 验证内容与卷标（bsdtar 来自 libarchive-tools；isoinfo 来自 genisoimage 包）
bsdtar  -tf seed-u24-dev.iso            # 或: isoinfo -i seed-u24-dev.iso -J -f
isoinfo -d -i seed-u24-dev.iso | grep Volume   # Volume id: cidata
# 或直接用配套脚本: bash labs/scripts/mk-seed.sh seed.iso <目录>
file seed-u24-dev.iso                # → ISO 9660 ... 'cidata'
```

### 步骤 5 · 让 libvirt-qemu 能读你的文件

qemu 进程以 `libvirt-qemu` 用户跑。镜像放在 `/var/lib/libvirt/images/` 天生没问题；
放家目录则要给遍历+读写权限（ACL 方式最小侵入）：

```bash
setfacl -m u:libvirt-qemu:--x ~                     # 只给"路过"权，不给列目录权
setfacl -R -m u:libvirt-qemu:rX ~/vm/u24            # 目录只读
setfacl -m u:libvirt-qemu:rw ~/vm/u24/u24-dev.qcow2 ~/vm/u24/seed-u24-dev.iso
```

### 步骤 6 · virt-install（见第 2 节命令）

首次建议**不加** `--autostart`；确认一切正常再 `virsh autostart u24-dev`。

### 步骤 7 · 观察首启

```bash
virsh list --all                     # running
virsh domblkstat u24-dev vda         # rd_bytes 一路涨 = 在读盘启动
virsh domifaddr u24-dev --source lease   # NAT 网卡的 DHCP 租约（macvtap 无租约，看下一招）
ip neigh show dev macvtap0           # 学到对端 IP = macvtap 链路活了
virsh console u24-dev --force        # 串口控制台（Ctrl + ] 退出）
```

### 步骤 8 · 验收清单（真实结果）

```text
✔ ssh ubuntu@<guest-ip>          密钥直进
✔ hostname                       → u24-dev            （meta-data）
✔ lsblk /dev/vda                 → vda1 39G           （growpart 扩盘）
✔ dpkg -l htop qemu-guest-agent  → ii                 （packages）
✔ cat /etc/issue.d/90-lab13.msg  → 存在               （write_files）
✔ cloud-init status              → status: done
```

### 步骤 9 · 二次定制（装机之后想改怎么办）

```bash
# 热插一块默认 NAT 网卡（macvtap 被上层网络过滤时的管理面兜底）
virsh attach-interface u24-dev --type network --source default --model virtio --live

# 补 guest-agent 通道（--osinfo require=off 时 virt-install 不会自动加）
cat > agent-channel.xml <<'EOF'
<channel type='unix'>
  <target type='virtio' name='org.qemu.guest_agent.0'/>
</channel>
EOF
virsh attach-device u24-dev agent-channel.xml --live
virsh attach-device u24-dev agent-channel.xml --config    # 写回持久 XML
virsh domifaddr u24-dev --source agent                    # 现在能按"客户机视角"查 IP

# 内存/CPU 在线调整（需要 <memory> 预留 ballooning 空间）
virsh setmem u24-dev 2G --live
```

## 5. macvtap 网络详解

`--network type=direct,source_mode=bridge` 让 libvirt 在物理口上创建一个
**macvtap** 设备：guest 的 virtio 网卡后端直接绑在内核 macvlan 上，收发路径
**不经过宿主协议栈的 bridge/dnsmasq**。

```text
                 ┌─ 物理网络（LAN）────────────────┐
 enp1s0 ────────┤  交换机看到两个 MAC：宿主 + guest │
   ├─ 宿主协议栈 (192.168.4.x)
   └─ macvtap0 (bridge 模式) ── qemu ── guest eth0 (192.168.4.229, LAN DHCP 直发)
```

四种 `source_mode`：

| 模式 | 行为 | 场景 |
| --- | --- | --- |
| `bridge` | 同一物理口上的多个 macvtap 实例互通，对外如独立设备 | **默认选择**，LAN 有 DHCP |
| `vepa` | 全部流量上交外部交换机（需要 VEPA 交换机） | 数据中心 |
| `private` | macvtap 之间互相隔离 | 多租户 |
| `passthrough` | 独占物理口（每 PCI 设备一个 guest） | 性能/直通感 |

**优点**：零改造拿到 LAN 地址（像插了根网线）、性能接近线速、不动宿主网络栈。
**代价（两个经典限制）**：

1. **宿主 ↔ guest 不能直接互通**（流量被内核按 macvlan 规则旁路了）。解法：宿主
   上再建一个 macvlan 口，或给 VM 加一块 NAT 网卡做管理面（本 lab 就是这么做的）。
2. **上层网络可能过滤陌生 MAC**（云平台虚拟交换机、端口安全）。物理机/自家路由器
   不会；**在云 VM 里嵌套跑 KVM 时 macvtap 常拿不到 DHCP**——本 lab 实测第一块
   macvtap 网卡 DHCP 超时，属于预期内的坑，加 NAT 口兜底即可。

## 6. 常见坑（全部实测踩过）

1. **`macvtap0 ... Operation not permitted`**
   `virt-install` 默认连 `qemu:///session`（无特权会话 libvirtd），创建 macvtap 需要
   `CAP_NET_ADMIN`。加 `--connect qemu:///system`（你的用户需在 `libvirt` 组）。
   原命令在服务器上以 root 跑，所以从没暴露过这个问题。
2. **`--osinfo` 报错**：新版 virt-install 对 `--import` 强制要求 OS 信息。
   `VIRTINSTALL_OSINFO_DISABLE_REQUIRE=1`（或写 `--osinfo detect=on,require=off`）。
   代价是 virt-install 不再自动加 guest-agent channel、tablet 等 QoL 设备——见步骤 9。
3. **OVMF 4M/2M 混用**：code 与 vars 尺寸必须同套（4M 配 4M），否则 QEMU 报
   pflash size mismatch。统一用 `_4M`。
4. **热插的网卡不 DHCP**：首启时 cloud-init 已按当时的网卡生成了 netplan 配置
   （按接口名/MAC 匹配），后插的网卡不在其中。seed 里显式 `network-config`
   `match: name: "en*"` 即可（步骤 3）。
5. **undefine 后 seed ISO 属主变 libvirt-qemu**：libvirt 动态属主机制在域销毁时
   对可写盘会还原属主，对只读光驱镜像不会。`rm` 重做即可；在意就放存储池目录。
6. **同一块盘重复实验 cloud-init 不生效**：`instance-id` 没变 → per-instance 模块
   跳过。改 `meta-data` 里的 id 再生成 seed。
7. **ARM 盘/固件拿到 x86 机器上启动不了**：架构不同。云镜像要选对
   `amd64`/`arm64`；固件要 OVMF/AAVMF 对号入座。

## 7. 思考题

1. `--import` 与不带的本质差别是什么？如果给一张空盘加 `--import` 会发生什么？
2. 为什么 `nvram_template` 必须指定、而 `loader` 只读？两个域共用同一个 VARS 文件
   会发生什么？
3. macvtap(bridge) 模式下，宿主 ping guest 的 IP 通不通？为什么？怎么验证你的判断？
4. 想让这台 VM 每次开机都自动执行一段初始化脚本（幂等），应该放在 seed 的哪个
   阶段？`runcmd` 和 `bootcmd` 差在哪？
5. 把本 lab 的命令翻译回 ARM 服务器版本（提示：只有机型/固件/网卡名三处要动）。

## 参考资料

- [21 · 固件加载与 UEFI 启动](../course/21-UEFI固件加载.md)（pflash 双盘原理）
- [22 · 机型解析与 Q35 芯片组](../course/22-机型解析与Q35.md)（机型版本化）
- [11 · libvirt 管理实战](../course/11-libvirt管理实战.md)、[lab11 UEFI 实战](lab11-uefi-ovmf.md)
- cloud-init 文档：NoCloud 数据源、Module 阶段
- macvtap：<https://www.libvirt.org/formatdomain.html#direct-attachment-to-physical-interface>

## 输出记录

- 时间：
- 宿主机：
- guest IP（macvtap）：　　　guest IP（NAT）：
- `virsh dumpxml` 的 `<os>` 段：
- `cloud-init status` 输出：
- 遇到的问题 / 解决：
