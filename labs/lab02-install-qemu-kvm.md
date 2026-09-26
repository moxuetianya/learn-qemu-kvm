# Lab 02 · 安装 QEMU + KVM + libvirt

> **难度**：★★  
> **前置**：Lab 01 通过  
> **预计时间**：15 分钟

## 目标

- 装好 QEMU / KVM / libvirt 一整套工具
- 验证 KVM 加速可用
- 了解每种工具的职责

## 实验步骤

### 1. 一键安装

```bash
sudo bash labs/scripts/install-qemu.sh
```

脚本会自动识别发行版并安装：
- `qemu-system-x86_64` — QEMU 主程序
- `qemu-img` — 镜像管理
- `libvirt-daemon` — 后台服务 `libvirtd`
- `virsh` — 命令行管理工具
- `virt-install` — 命令行装机工具
- `virt-manager` — GUI 管理工具
- `OVMF` — UEFI 固件

### 2. 验证

```bash
# QEMU 版本
qemu-system-x86_64 --version

# 镜像工具
qemu-img --version

# libvirt 版本 + 是否能连上
virsh --version
virsh uri              # 默认 qemu:///system
virsh nodeinfo         # 看 CPU 架构和频率

# KVM 加速是否就绪
ls -l /dev/kvm
```

### 3. 验证 KVM 加速能跑

```bash
# 启动一个空 VM（-S 表示 CPU 暂不执行），用 monitor 确认 KVM 生效
qemu-system-x86_64 -machine accel=kvm -m 512 -nographic -S -monitor stdio
```

在 `(qemu)` 提示符下：

```
(qemu) info kvm
kvm support: enabled
(qemu) quit
```

`kvm support: enabled` = KVM 加速可用。

注意：不要用 `-kernel /dev/null` 这类写法，`-kernel` 需要真实的内核镜像文件，
零字节文件会在加载阶段直接报错（报错信息还有误导性）。

如果启动时报 `failed to initialize kvm`，通常是 /dev/kvm 权限问题或 kvm 模块没加载，
回看上一节的检查项。

也可以用非交互方式做冒烟测试（没报错 = KVM 加速可用）：

```bash
qemu-system-x86_64 -machine accel=kvm,type=q35 -m 512 -nographic -S -pidfile /tmp/x.pid &
sleep 1
kill $(cat /tmp/x.pid) 2>/dev/null
rm -f /tmp/x.pid
```

### 4. 把用户加入组

```bash
sudo usermod -aG libvirt $USER
newgrp libvirt
# 验证
virsh -c qemu:///system list --all
# 应该看到：
#  Id    Name                           State
# -------------------------------------------
```

### 5. （可选）GUI 安装

桌面环境下安装 `virt-manager`：

```bash
# 已经在 install-qemu.sh 里装了
virt-manager
```

## 优劣对比：包管理方式

| 方式 | 命令 | 优劣 |
| --- | --- | --- |
| 系统包 | `apt install qemu-kvm` | ✅ 稳定、与发行版兼容<br>⚠️ 版本较旧（Ubuntu 22.04 = QEMU 6.2） |
| 上游 PPA | `add-apt-repository ppa:jacob/virtualisation` | ✅ 版本新<br>⚠️ 第三方维护 |
| 源码编译 | `./configure && make` | ✅ 最新、可定制<br>⚠️ 编译耗时、调试依赖 |
| docker | `docker run qemu/qemu` | ✅ 跨主机一致<br>⚠️ 不能跑 KVM（除非 `--device /dev/kvm`） |

**生产怎么选？**

- 物理机直接用发行版源，跟内核版本匹配最稳
- 测试新特性（如新 CPU model）才考虑编译
- CI 跑测试可用 docker，但 KVM 加速要透传 `/dev/kvm`

## 工具职责清单

| 命令 | 干什么 | 谁会用 |
| --- | --- | --- |
| `qemu-system-x86_64` | 启动一台虚拟机（用户态主程序） | 测试 / 嵌入式 |
| `qemu-img` | 创建、转换、查看镜像 | 所有人 |
| `qemu-nbd` | 把 qcow2 当 NBD 块设备挂载 | 运维 |
| `virsh` | libvirt 命令行 | 运维 |
| `virt-install` | 命令行创建 VM | 运维 |
| `virt-manager` | libvirt GUI | 桌面用户 |
| `virt-viewer` | VNC/SPICE 客户端 | 所有人 |
| `libvirtd` | libvirt 后台服务 | 自动跑 |
| `qemu-ga` | Guest Agent，跑在 VM 里给宿主机提供 info | 性能监控 |

## 输出记录

> 🤖 本 lab 可用 [`scripts/verify-install.sh`](scripts/verify-install.sh) 一键验证：
>
> ```bash
> bash labs/scripts/verify-install.sh
> # 期望最后一行: ✅ 环境就绪，可以开始 lab03
> ```

回答：

1. QEMU 版本是多少？
2. libvirt uri 是什么？`virsh nodeinfo` 输出哪些字段？
3. `/dev/kvm` 权限是什么？你的用户在 `kvm` 组吗？
4. 你打算用系统包还是编译？为什么？

## 下一步

[Lab 03 - 第一个虚拟机](lab03-first-vm.md)
