# Lab 05 · 5 种网络模式

> **难度**：★★★  
> **前置**：Lab 03  
> **预计时间**：45 分钟

## 目标

跑通 QEMU/KVM 五种最常用网络拓扑，每种都验证连通性。

## 实验步骤

### 模式 1：user mode（NAT，最省事）

```bash
qemu-system-x86_64 \
    -name usernet \
    -machine accel=kvm \
    -m 512 -smp 2 \
    -drive file=/var/lib/libvirt/images/lab03.qcow2,format=qcow2,if=virtio \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=n0 \
    -nographic
```

VM 内：

```sh
ip addr show eth0
# 拿到 10.0.2.15/24
ip route
# default via 10.0.2.2
ping 10.0.2.2     # 通（host 视角的网关）
ping 8.8.8.8      # 通（NAT 出去）
```

宿主通过 `localhost:2222` 连 VM 的 22：

```bash
ssh -p 2222 root@127.0.0.1
```

✅ **适用**：本地开发、临时调试；**不适用**：需要 VM 被外网访问。

### 模式 2：bridge（libvirt default）

libvirt 装完会自带一个 `virbr0`（NAT bridge）。

```bash
brctl show virbr0
# 看到空，VM 启动后会加 vnet0
```

```bash
virt-install --name brnet --ram 512 --vcpus 2 \
    --import \
    --disk path=/var/lib/libvirt/images/lab03.qcow2,format=qcow2 \
    --network network=default,model=virtio \
    --graphics none --noautoconsole \
    --os-variant alpinelinux3.18
```

VM 内 `ip addr` 看到 `192.168.122.x`，能 ping 通 host 的 `192.168.122.1`，能上外网（NAT）。

宿主 → VM：

```bash
ssh root@192.168.122.x
```

### 模式 3：bridge（直连物理网桥，让 VM 跟 host 同网段）

> 🤖 网桥的创建/查看/删除可用 [`scripts/setup-bridge.sh`](scripts/setup-bridge.sh)：
>
> ```bash
> sudo bash labs/scripts/setup-bridge.sh create eth0   # 创建 br0 并挂 eth0
> sudo bash labs/scripts/setup-bridge.sh status        # 查看
> sudo bash labs/scripts/setup-bridge.sh delete        # 还原
> ```
>
> ⚠️ 把正在使用的物理网卡挂上桥会短暂断网；远程 SSH 操作请先看下面「常见失败」。

```bash
# 创建桥
sudo ip link add br0 type bridge
sudo ip link set br0 up
sudo ip addr add 192.168.10.100/24 dev br0

# 启动 VM
qemu-system-x86_64 \
    -name bridged \
    -m 512 -smp 2 \
    -drive file=/var/lib/libvirt/images/lab03.qcow2,format=qcow2,if=virtio \
    -netdev bridge,id=n0,br=br0 \
    -device virtio-net-pci,netdev=n0 \
    -nographic
```

VM 内手动配 IP：

```sh
ip addr add 192.168.10.101/24 dev eth0
ip link set eth0 up
ip route add default via 192.168.10.1
ping 192.168.10.1    # 通
```

✅ **适用**：VM 跟 host / 其他物理机在同一网段；**不适用**：单机开发（杀鸡用牛刀）。

### 模式 4：isolated（私网，只 VM 之间通信）

```bash
qemu-system-x86_64 \
    -name isolated1 -m 512 -smp 2 \
    -drive file=lab03.qcow2,format=qcow2,if=virtio \
    -netdev socket,id=n0,listen=:1234 \
    -device virtio-net-pci,netdev=n0 \
    -nographic &

qemu-system-x86_64 \
    -name isolated2 -m 512 -smp 2 \
    -drive file=lab03.qcow2,format=qcow2,if=virtio \
    -netdev socket,id=n0,connect=:1234 \
    -device virtio-net-pci,netdev=n0 \
    -nographic
```

两台 VM 用同一个 socket 通信，能 ping 通彼此，但不通 host，不通外网。

✅ **适用**：测试两 VM 通信、抓包调试；**不适用**：需要外网。

### 模式 5：macvtap（直连物理网卡，性能最优）

```bash
# 假设物理网卡是 eth0
qemu-system-x86_64 \
    -name macvtap -m 512 -smp 2 \
    -drive file=lab03.qcow2,format=qcow2,if=virtio \
    -netdev tap,id=n0,vhost=on \
    -device virtio-net-pci,netdev=n0 \
    -nographic
```

需要：

```bash
sudo ip link add link eth0 name macvtap0 type macvtap mode bridge
sudo ip link set macvtap0 up
# chmod 给 qemu 进程打开 /dev/tap* 的权限
```

✅ **适用**：高性能（不走 Linux bridge）；**不适用**：同一网卡上 VM 多时需要 switch 行为。

## 常见失败

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| 挂桥后 SSH 立即断开、再也连不上 | 物理网卡 IP 没清干净 / 桥没配管理地址 | 见下方「断网自救」 |
| VM 拿不到同网段 IP | br0 上没起 DHCP，VM 内没静态配 IP | VM 内 `ip addr add` 静态配（见步骤） |
| `qemu-system-x86_64: bridge helper failed` | qemu-bridge-helper 无权限 | `sudo chmod u+s /usr/lib/qemu/qemu-bridge-helper` 并配置 `/etc/qemu/bridge.conf` |
| 物理网卡是 WiFi | 802.11 帧头决定 WiFi 做不了普通桥 | 换有线，或改用 macvtap/ routed 模式 |
| 重启后 br0 消失 | ip 命令配置不持久 | 用 nmcli/netplan 持久化，或每次实验重建 |

**断网自救**（挂桥前先读）：

```bash
# 1. 物理机上提前开一个 root shell 或 tmux，断了也能操作
sudo tmux new -s rescue

# 2. 断网后还原（在 rescue 会话里）
sudo ip link set eth0 nomaster
sudo ip link delete br0
sudo ip addr add <原IP>/<掩码> dev eth0
# DHCP 环境: sudo dhclient eth0
```

远程机房无控制台时，先在测试机/虚机里演练一遍再上生产。

## 优劣对比速记

| 模式 | 性能 | 配置难度 | VM 与外网通 | VM 与 host 通 | 多 VM 互通 | 适用场景 |
| --- | --- | --- | --- | --- | --- | --- |
| user/NAT | ★★★ | ★ | ✅（出） | ❌（要转发） | ✅ | 本地开发 |
| bridge (virbr0) | ★★★ | ★ | ✅（NAT） | ✅ | ✅ | 通用 |
| bridge (br0) | ★★★★ | ★★★ | ✅（同网段） | ✅ | ✅ | 生产网络 |
| isolated | ★★★ | ★ | ❌ | ❌ | ✅ | 隔离测试 |
| macvtap | ★★★★★ | ★★★ | ✅（同网段） | ⚠️ | ⚠️ | 极致性能 |

## 验证清单

| 模式 | VM ↔ Host | VM ↔ 外网 | VM ↔ VM | 配置位置 |
| --- | --- | --- | --- | --- |
| user | ❌ | ✅ NAT | ✅ | `-netdev user` |
| virbr0 | ✅ | ✅ NAT | ✅ | `network=default` |
| br0 | ✅ | ✅ | ✅ | `-netdev bridge` |
| isolated | ❌ | ❌ | ✅ | `-netdev socket` |
| macvtap | ⚠️ | ✅ | ⚠️ | `-netdev tap` + macvtap |

## 输出记录

1. 五种模式各跑通了吗？
2. 哪种模式 VM 直接拿到公网 IP？哪种需要转发？
3. macvtap 跟普通 bridge 在性能上差多少？（可用 iperf3 测）

## 下一步

[Lab 06 - virtio 性能](lab06-virtio-perf.md)
