# 04 · QEMU 基础与命令行

> 不靠 libvirt，纯 QEMU 命令行启动虚拟机。先搞清楚这一层，再学 libvirt 会轻松很多。

## 学习目标

- 能独立写 `qemu-system-x86_64` 命令启动一台 VM
- 理解「machine type」「cpu model」「drive」「netdev」「device」的拆解思路
- 知道 TCG 和 KVM 加速的差别

## 1. 命令结构总览

```
qemu-system-<arch> [machine opts] [cpu opts] [memory] [devices] [other]
```

按功能分组：

```
机器类型: -machine ..., -cpu ..., -smp ..., -m ...
启动:     -bios ..., -kernel ..., -initrd ..., -append ..., -drive ...
显示:     -display ..., -vnc ..., -nographic, -monitor ...
网络:     -netdev ..., -device e1000/virtio-net/...
存储:     -drive ..., -device virtio-blk/ide/...
其它:     -name ..., -uuid ..., -daemonize, -pidfile
```

## 2. 拆解一段典型命令

```bash
qemu-system-x86_64 \
    -name demo \
    -machine accel=kvm,type=q35 \
    -cpu host \
    -smp 4 \
    -m 4G \
    -drive file=/var/lib/libvirt/images/demo.qcow2,format=qcow2,if=virtio \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0 \
    -vnc :0 \
    -monitor stdio
```

| 部分 | 含义 |
| --- | --- |
| `-name demo` | VM 名字 |
| `-machine accel=kvm,type=q35` | q35 芯片组，KVM 加速 |
| `-cpu host` | 把所有宿主 CPU flags 透传给 VM（**性能最优，迁移受限**） |
| `-smp 4` | 4 个 vCPU |
| `-m 4G` | 4G 内存 |
| `-drive file=...qcow2` | 磁盘镜像 |
| `-netdev user,id=n0` | user 模式网络（NAT） |
| `-device virtio-net-pci,netdev=n0` | virtio 网卡 |
| `-vnc :0` | VNC 监听 5900 |
| `-monitor stdio` | 监控口绑到当前终端 |

## 3. machine type 选型

### 3.1 q35 vs i440fx

| 特性 | i440fx（默认） | q35 |
| --- | --- | --- |
| PCIe 原生支持 | ❌（模拟） | ✅ 原生 PCIe |
| 性能 | 一般 | 较好 |
| 兼容老 OS | ✅ | ⚠️ 老 OS 可能不识别 |
| 推荐 | 兼容性 | **生产推荐** |

### 3.2 accel 选型

| 值 | 含义 | 何时用 |
| --- | --- | --- |
| `kvm` | Linux KVM | 默认，**生产必选** |
| `tcg` | QEMU 自带软件模拟 | 跨架构、无 KVM 时 |
| `whpx` | Windows Hypervisor Platform | Windows 上 |
| `hvf` | macOS Hypervisor | macOS 上 |
| `nvmm` | NetBSD | NetBSD 上 |

> `qemu-system-x86_64` 支持多个 accel，运行时按优先级自动选择。

## 4. CPU model 选型

### 4.1 三种模式

```bash
-cpu host          # 透传宿主所有 flags（最快，迁移差）
-cpu kvm64         # 一套「假装是 KVM 优化过」的稳定 CPU（迁移友好）
-cpu Broadwell     # 模拟特定一代 Intel
-cpu host,-avx512  # host 但去掉 avx512（兼容性）
```

### 4.2 怎么选

| 场景 | 推荐 |
| --- | --- |
| 单一物理机临时用 | `host` |
| OpenStack / oVirt / 集群 | `kvm64` 或指定同型号 |
| 需要跑老 OS（如 Win7） | 选 `Nehalem` 之前 |
| 需要 AES-NI / AVX 但迁移多 | 选同型号 CPU |

### 4.3 查看可用 model

```bash
qemu-system-x86_64 -cpu help
# 列出来所有 model，末尾有 + 开头的可加 flag
```

## 5. 设备三件套：drive / netdev / device

QEMU 把「设备」拆成「总线」（drive / netdev / chardev）和「设备」（device）。

### 5.1 磁盘

```bash
# 经典：virtio-blk + qcow2
-drive file=/path/disk.qcow2,format=qcow2,if=virtio

# 控制器选 virtio-scsi（支持更多高级特性）
-drive file=/path/disk.qcow2,format=qcow2,if=none,id=disk0 \
-device virtio-scsi-pci,id=scsi0 \
-device scsi-hd,drive=disk0,bus=scsi0.0

# 直通 NVMe
-drive file=/dev/nvme0n1,format=raw,if=none,id=nvme0 \
-device nvme,drive=nvme0,serial=nvme0

# ISO 光盘
-drive file=/path/install.iso,format=raw,media=cdrom,readonly=on
```

### 5.2 网络

| 写法 | 含义 |
| --- | --- |
| `-netdev user,id=n0` | user NAT（默认出栈，VM 无外部 IP） |
| `-netdev tap,id=n0,ifname=tap0` | 接到 host 的 tap 接口 |
| `-netdev bridge,id=n0,br=virbr0` | 接 bridge |
| `-netdev socket,id=n0,listen=:1234` | 跨主机 socket（实验用） |

`device` 部分指定前端设备：

```bash
-device e1000,netdev=n0              # 全模拟
-device virtio-net-pci,netdev=n0     # virtio（推荐）
-device rtl8139,netdev=n0            # 老网卡
```

### 5.3 内存气球（balloon）

```bash
-device virtio-balloon
```

VM 内装 `virtio_balloon` 后可动态调整 VM 占用内存，对宿主机内存复用非常有用。

## 6. 显示与监控

### 6.1 显示

| 写法 | 用途 |
| --- | --- |
| `-display none` | 无显示，常用于 headless 服务 |
| `-nographic` | 串口 + 监控重定向到 stdio |
| `-vnc :N` | VNC 监听 5900+N |
| `-vnc 0.0.0.0:0` | 所有接口开放（**生产别这么干**） |
| `-spice port=5900,addr=127.0.0.1,...` | SPICE |
| `-display gtk` / `sdl` | 本地图形 |

### 6.2 监控（monitor）

监控口可以：

- 切盘、热插设备、看统计、savevm/loadvm
- 强制关机（`quit` / `powerdown`）

```bash
# 三种接法
-monitor stdio                          # 当前终端
-monitor tcp:127.0.0.1:4444,server,nowait  # TCP
-monitor unix:/tmp/mon.sock,server,nowait  # Unix socket
```

进入 monitor 后常用命令：

```
info status           # 看 VM 状态
info network          # 看网络
info block            # 看磁盘
system_poweroff      # 关机
q                    # 强制退出
change ide1-cd0 /path/new.iso   # 换 ISO
device_add ...        # 热插设备
```

> `-nographic` / `-display none` / `-monitor` 三者各控制什么、为什么
> `-nographic` 不能与 `-monitor stdio` 同用，见 6.3 的前端/后端模型。

### 6.3 `-nographic` 控制的到底是谁？（前端/后端模型）

`-nographic` / `-display none` / `-monitor` 这三个参数**只改 QEMU 宿主侧的数据路由，
不改变 guest 看到的硬件**：串口还是那个 0x3F8 端口的 16550 UART，显卡还是那张 VGA 卡，
变的只是"这些设备的数据线另一端插在宿主机哪里"。

QEMU 把每个外设拆成两半：

- **前端**：模拟出来的硬件芯片，guest 驱动和它打交道（`-serial` / `-vga` / `-device` 决定**存在与否**）
- **后端**：数据在宿主机上的真实去向（本节这三个参数只动这半边）

```
┌──────────────── Guest ────────────────┐
│ printk("boot...") → 写 /dev/ttyS0      │
│ 驱动 out 0x3F8（UART 寄存器）           │
└──────────────┬────────────────────────┘
               │ 模拟硬件边界
        ┌──────┴──────┐
        │ 串口前端     │ ← guest 只看到这半边
        └──────┬──────┘
               │ 后端路由（-nographic / -monitor / -display 管这里）
   ┌───────────┼───────────┬─────────────┐
   ▼           ▼           ▼             ▼
 stdio     tcp socket    file         vc / null
（终端）   （telnet）   （日志）     （不可见/丢弃）
```

QEMU 里有**三条互相独立**的流，混淆都来自把它们当成一条：

| 流 | 数据由谁产生 | 内容 |
| --- | --- | --- |
| 显卡输出 | guest | BIOS 自检画面、framebuffer、桌面 |
| 串口数据 | guest | 内核 `console=ttyS0` 日志、getty 登录提示符 |
| monitor | **QEMU 自己** | `info` / `stop` / `savevm` / `migrate` 管理命令 |

monitor 是 QEMU 进程自己的管理控制台，guest 完全不知道它的存在——类比物理服务器
的 iDRAC/iLO 带外管理口，而不是机箱上接的显示器。

**`-nographic` 是一条复合快捷方式**：

```
-nographic  ≈  -display none  +  -serial mon:stdio  （+ 并口 → null）
```

即：关图形 + 串口接到终端 + monitor **复用同一条 stdio**（`mon:` 就是"把 monitor
也复用进来"），所以需要 `Ctrl-A c` 在串口 ↔ monitor 之间切换。

用 `info chardev` 可以亲眼看路由（QEMU 8.2 实测）：

```
$ ... -display none -S -monitor stdio
compat_monitor0: filename=stdio    ← monitor 独占终端
serial0:         filename=vc       ← 串口留在不可见的虚拟标签页

$ ... -nographic -S
parallel0:      filename=null      ← 并口直接丢弃
serial0:        filename=mux       ← 串口接"复用器"
serial0-base:   filename=stdio     ← 复用器底座是终端，monitor 也挂在这上面
```

组合对照表：

| 命令 | guest 显卡输出 | guest 串口 | QEMU monitor | 适用场景 |
| --- | --- | --- | --- | --- |
| 默认（桌面环境） | GTK 窗口 | 窗口内标签页 | 窗口内标签页（Ctrl-Alt-2） | 本地图形实验 |
| `-nographic` | 丢弃 | **你的终端** | 同一终端复用，`Ctrl-A c` 切换 | SSH/服务器、串口控制台 guest |
| `-display none` | 丢弃 | 丢弃（vc 不可见） | 丢弃（vc 不可见） | 纯后台跑（配 `-daemonize`） |
| `-display none -monitor stdio` | 丢弃 | 丢弃 | **你的终端，独占** | 只要管理口（lab02 验证 KVM） |
| `-display none -serial stdio -monitor none` | 丢弃 | **你的终端，独占** | 关闭 | 只看 guest 串口日志 |

两个易踩的坑：

- `-nographic -monitor stdio` 必然报 `cannot use stdio by multiple character
  devices`——stdio 已经挂在 mux 上，`-monitor stdio` 又要独占第二份，QEMU 拒绝
- guest 不配 `console=ttyS0` / getty 的话，`-nographic` 终端永远只有 QEMU 横幅：
  线递过去了，guest 得愿意说话（cloud 镜像默认开串口，桌面 ISO 默认不开）

真正增删 guest 硬件的是另一类参数：`-vga none`（拔显卡）、`-serial none`（拔串口）、
`-nodefaults`（不给默认设备）。一句话：**这三个参数是在机房里插拔"线缆"，
guest 机箱上的接口一个没动。**

## 7. 命令速查

| 想做什么 | 命令 |
| --- | --- |
| 看所有支持的 machine type | `qemu-system-x86_64 -machine help` |
| 看所有支持的 CPU model | `qemu-system-x86_64 -cpu help` |
| 看所有支持的 device | `qemu-system-x86_64 -device help` |
| 看某设备的参数 | `qemu-system-x86_64 -device virtio-net-pci,help` |
| 看 qemu 启动帮助 | `qemu-system-x86_64 --help` |

## 8. 优劣对比：直 qemu 命令 vs libvirt

| 维度 | 直接 qemu 命令 | libvirt (virsh/virt-manager) |
| --- | --- | --- |
| 学习曲线 | ❌ 命令长 | ✅ 友好 |
| 自动化 | ⚠️ 自己写脚本 | ✅ ansible/CLI |
| 复杂配置（多设备） | ❌ 容易乱 | ✅ XML 配置 |
| 远程管理 | ❌ 自己实现 | ✅ libvirt 原生支持 |
| 性能差异 | 无（最终都调 qemu） | 无 |

> **生产建议**：学习阶段先用直接命令（明白底层），生产用 libvirt。  
> 99% 的场景你都可以两种都跑。

## 9. 实战操作

### 9.1 命令行启一台 VM（不依赖任何镜像）

```bash
# 用 TinyCore 或 alpine 的 ISO；先用 alpine-virt 试试
wget https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-virt-3.20.3-x86_64.iso

qemu-system-x86_64 \
    -machine accel=kvm,type=q35 \
    -cpu host \
    -m 1G -smp 2 \
    -drive file=alpine-virt-3.20.3-x86_64.iso,media=cdrom,readonly \
    -drive file=/tmp/test.qcow2,format=qcow2,if=virtio \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0 \
    -vnc :0 \
    -daemonize -pidfile /tmp/vm.pid

# 看进程
ps aux | grep qemu

# VNC 连：vncviewer :0   或者 remmina / virt-manager
```

### 9.2 体验 TCG 模式（不依赖 KVM）

把 `accel=kvm` 换成 `accel=tcg`，任何环境都能跑（包括嵌套虚拟化关掉时），但性能差 5-10 倍。

### 9.3 一键脚本

```bash
bash labs/scripts/start-vm.sh /tmp/test.qcow2
```

## 10. 小结

- qemu 命令按 `machine/cpu/smp/m/devices` 分层
- **`-cpu host` 性能最好但不可迁移**；集群用 `-cpu kvm64`
- 生产用 q35 + virtio + KVM
- 显示 / 监控 / 设备热插全在 monitor 口里

## 11. 思考题

1. 为什么 `-cpu host` 不可迁移？哪些情况下必须用一致 CPU model？
2. user 模式网络能不能 ping 通 host？为什么？
3. 把 `-vnc :0` 改成 `:0` + `password` 加密码怎么做？（提示：`qemu-system-x86_64 --help | grep password`）

## 12. 参考资料

- [`refs/learn-kvm/docs/QEMU介绍.md`](../refs/learn-kvm/docs/QEMU介绍.md)
- [`refs/learn-kvm/docs/QEMU介绍/QEMU历史.md`](../refs/learn-kvm/docs/QEMU介绍/QEMU历史.md)
- [`refs/learn-kvm/docs/QEMU基本结构.md`](../refs/learn-kvm/docs/QEMU基本结构.md)
- [`refs/learn-kvm/docs/QEMU工作原理.md`](../refs/learn-kvm/docs/QEMU工作原理.md)
- [`refs/learn-kvm/docs/QEMU使用.md`](../refs/learn-kvm/docs/QEMU使用.md)
- [`refs/learn-kvm/docs/QEMU使用/QEMU运行x86_64虚拟机.md`](../refs/learn-kvm/docs/QEMU使用/QEMU运行x86_64虚拟机.md)

---

⬅️ 上一章：[03 · 环境搭建实战](03-环境搭建实战.md) · [📚 返回目录](../INDEX.md) · 下一章 ➡️：[05 · 第一个虚拟机实战](05-第一个虚拟机实战.md)
