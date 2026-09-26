# 09 · 设备虚拟化与 virtio

> virtio 是 KVM 性能的核心。理解它的工作方式，是理解整个 I/O 虚拟化的钥匙。

## 学习目标

- 知道 virtio 的「前端 / 后端 / 环形缓冲区」模型
- 能区分 virtio-blk / virtio-net / virtio-scsi / virtio-balloon / vhost
- 理解 vhost-net、vhost-scsi、vhost-vsock 的角色
- 知道 Windows 怎么用 virtio

## 1. 为什么需要 virtio

**全模拟**的问题：

```
客户机驱动 → 真实设备行为（PIO/MMIO）→ VM exit → QEMU 模拟
```

每次 PIO/MMIO 都 VM exit，性能差。

**virtio 的解法**：

```
客户机驱动（前端）  ⇆  virtqueue 环形缓冲区  ⇆  QEMU 后端
                       (共享内存，无 VM exit)
```

数据平面走共享内存，控制平面用 KICK/中断通知。

## 2. virtio 架构

### 2.1 三层

```
┌──────────────────────────────────────────────┐
│  客户机 OS                                     │
│  ┌────────────────────────────────────────┐  │
│  │ virtio 驱动（前端）                       │  │
│  │ virtio-net / virtio-blk / ...            │  │
│  └────────────────┬───────────────────────┘  │
│                   │ virtqueue                  │
└───────────────────┼──────────────────────────┘
                    │ 共享内存 (VRing)
┌───────────────────┼──────────────────────────┐
│  宿主机          ▼                           │
│  ┌──────────────────────────────────────┐    │
│  │ virtio 后端                              │    │
│  │  QEMU 进程  ── 或 ──  vhost-net 内核线程 │    │
│  └──────────────────────────────────────┘    │
└──────────────────────────────────────────────┘
```

### 2.2 virtqueue

```c
struct vring {
    struct vring_desc  *desc;     // 描述符表
    struct vring_avail *avail;    // 可用环（驱动填）
    struct vring_used  *used;     // 已用环（设备填）
};
```

```
┌──────┐      avail: [idx, ring[idx], ...]     ┌──────┐
│Driver│ ─────►  写入可用描述符  ───────►  │Device│
│ 前端 │                                       │ 后端 │
│      │ ◄────── used: [idx, ring[idx], ...]  │      │
└──────┘      后端写入已用描述符     ◄────── └──────┘
```

驱动写请求到 `desc`，更新 `avail->ring[idx]`；后端从 `avail` 读请求，处理完写 `used->ring[idx]`。

### 2.3 通知机制

- **KICK**：驱动 → 后端（写 MMIO/PIO 寄存器）
- **NOTIFY**：后端 → 驱动（KVM_IRQFD 注入中断）

### 2.4 一次发包的完整旅程（数据路径走读）

以 virtio-net 发一个 TCP 包为例，把三层模型串起来：

```
① 客户机应用 write(socket)
        │
② 内核协议栈构好 skb，交给 virtio_net 驱动
        │
③ 驱动把数据帧写进共享内存，描述符挂到 desc 表，
   头索引写入 avail->ring[idx]，idx++
        │  （到此为止：全是客户机普通内存写，零 VM exit）
④ 驱动 KICK：写设备的 notify 寄存器（一次 MMIO 写 → VM exit）
        │
⑤ KVM 把这次 exit 直接路由给后端：
   ├─ virtio-net-pci（QEMU 后端）→ QEMU 线程被唤醒
   └─ vhost-net（内核后端）→ 内核线程被唤醒（eventfd，不进 QEMU）
        │
⑥ 后端从 avail 环取描述符，读出数据帧
   ├─ QEMU 后端：走宿主机 tap 设备 → 内核网络栈
   └─ vhost-net：直接调内核网络栈发送（零拷贝路径）
        │
⑦ 发送完成，后端把描述符索引写进 used->ring[idx]
   并通过 irqfd 向客户机注入一个 virtio 中断（一次 VM entry）
        │
⑧ 客户机 virtio_net 中断处理：回收描述符，唤醒等待的发送队列
```

数一数硬件级代价：**只有 ④（一次 VM exit）和 ⑦（一次中断注入）**。
中间所有数据搬运都在共享内存里完成——这就是 virtio 快的本质。

对比全模拟 e1000：驱动要写十几个寄存器（每写一次都可能 VM exit），
数据还要经 QEMU 在设备模拟层搬运。一次发包的 VM exit 次数差一个数量级。

### 2.5 通知优化：avail 缓冲与 event idx

上面 ④⑦ 两步还能再省：

**批量与延迟通知（driver 侧）**：协议栈一次 often 有多个包要发。
驱动攒一批，只 KICK 一次；后端同理，处理完一批只注入一个中断。
这就是「中断合并」在 virtio 上的自然实现。

**VRING_F_EVENT_IDX（双方协商的特性位）**：

```
used->avail_event  ← 后端写：驱动看到这个值之前不必再 KICK
avail->used_event  ← 驱动写：后端看到这个值之前不必再注入中断
```

本质是**生产者-消费者之间的背压**：对方还没消费到某个水位，就先别叫醒它。
高频小包场景（网络 PPS、存储 iodepth 高时）能显著减少通知次数。

```bash
# 宿主机侧观察 vhost-net 的通知抑制效果（需要 root）
sudo cat /sys/kernel/debug/vhost/net0 2>/dev/null || \
sudo cat /proc/net/vhost-net 2>/dev/null
```

> 一句话：virtqueue 负责让数据搬运免费（共享内存），
> event idx 负责让「叫醒对方」也尽可能免费（少通知）。

## 3. virtio 设备家族

| 设备 | 前端驱动 | 后端 | 用途 |
| --- | --- | --- | --- |
| virtio-net | `virtio_net` | `virtio-net-pci` / vhost-net | 网卡 |
| virtio-blk | `virtio_blk` | `virtio-blk-pci` | 块设备 |
| virtio-scsi | `virtio_scsi` | `virtio-scsi-pci` | SCSI 控制器 |
| virtio-balloon | `virtio_balloon` | `virtio-balloon-pci` | 内存动态调整 |
| virtio-gpu | `virtio_gpu` + `drm_virtio` | `virtio-gpu-pci` | 图形 |
| virtio-input | `virtio_input` | `virtio-keyboard-pci` 等 | 输入 |
| virtio-crypto | `virtio_crypto` | `virtio-crypto-pci` | 加解密 |
| virtio-vsock | `vsock` / `vhost_vsock` | `vhost-vsock-pci` | host-guest socket |
| virtio-fs | `virtio_fs` | `virtiofsd` | 文件共享 |
| virtio-mem | `virtio_mem` | `virtio-mem-pci` | 动态内存 |
| virtio-iommu | `virtio_iommu` | `virtio-iommu-pci` | 设备隔离 |

## 4. vhost 系列：把后端搬到内核

### 4.1 vhost-net

```c
// QEMU 启动时
vhost_net_init(&net->vhost_net);
vhost_net_set_backend(&net->vhost_net, &tap);
```

vhost-net 在内核里起一个 kernel 线程直接处理 virtqueue 数据。QEMU 只负责控制。

### 4.2 vhost-vsock

让 VM 和 host 用 socket 直接通信（不需要网络栈）。

```xml
<vsock model='virtio'>
  <cid auto='yes'/>
</vsock>
```

VM 内：

```sh
# 装 socat / ncat
socat - UNIX-CONNECT:vsock/host/1234
```

宿主机：

```sh
socat UNIX-LISTEN:/tmp/vsock.sock,fork UNIX-CONNECT:vsock/2/1234
```

### 4.3 vhost-user

后端跑在用户态（DPDK/SPDK）。

```bash
# OVS-DPDK 作为后端
vhost-user.socket=/tmp/vhost-user.sock
```

### 4.4 vhost-scsi

```xml
<controller type='scsi' index='0' model='virtio-scsi'/>
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' queues='4'/>
  <source dev='/dev/sdb'/>
  <target dev='sda' bus='scsi'/>
</disk>
```

### 4.5 数据路径对比：QEMU 后端 vs vhost-net

```
【virtio-net-pci：QEMU 用户态后端】

  客户机 KICK
      │ VM exit
      ▼
  KVM ──唤醒──► QEMU 线程（用户态切换 + 上下文切换）
      │             │ 从 virtqueue 取包
      │             ▼
      │          tap 字符设备（内核）
      │             │
      │             ▼
      │          宿主机网络栈 ──► 物理网卡
      │
      └── 数据路径：客户机内存 → QEMU（可能两次拷贝）→ tap → 内核栈

【vhost-net：内核态后端】

  客户机 KICK
      │ VM exit
      ▼
  KVM ──eventfd 直达──► vhost 内核线程
                          │ 从 virtqueue 取包（直接读共享内存）
                          ▼
                       宿主机网络栈 ──► 物理网卡
                          （大包走 zero-copy 直接到 tap/物理设备）

   省掉了：QEMU 用户态唤醒、QEMU↔内核的系统调用、
   部分场景的数据拷贝
```

| 维度 | QEMU 后端 | vhost-net |
| --- | --- | --- |
| 每包上下文切换 | VM exit + 内核↔用户态 | 仅 VM exit |
| 数据拷贝 | 通常 2 次 | 大包可 zero-copy |
| 可配置性 | 高（QEMU 参数） | 中 |
| 出问题排查 | 容易（strace/gdb QEMU） | 难（要看内核线程） |
| 适用 | 默认就好 | 高 PPS / 网络密集型 |

> 经验：Linux 客户机 + virtio-net 时，vhost-net 默认就是开着的（`-netdev tap,vhost=on`）。
> 刻意关掉（`vhost=off`）通常只为了调试。

## 5. Windows 怎么用 virtio

Windows 默认没 virtio 驱动。两种方法：

### 5.1 安装 virtio driver ISO

```bash
wget https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
```

挂在 VM 上手动装：

```xml
<disk type='file' device='cdrom'>
  <source file='/var/lib/libvirt/images/virtio-win.iso'/>
</disk>
```

### 5.2 用 cloud-init 注入驱动

把驱动解压到 cloud-init ISO，加 `virtio_drivers` 项。

### 5.3 直接用 IDE 装 OS，装完换 virtio

传统做法：安装时用 IDE，OS 装好后切到 virtio-blk（驱动已经从 ISO 装好）。

## 6. balloon 内存动态调整

### 6.1 概念

客户机 OS 主动「释放」一些内存给宿主用。

```
宿主: 16GB 物理
 ├── VM1 申请 8GB (气球最大 8G)
 ├── VM2 申请 8GB (气球最大 8G)
实际: VM1 只用 4GB，VM2 只用 4GB
     气球各填到 8GB（VM 内 OS 看到的可用内存 = 8GB，但实际可回收 = 4GB）
     此时宿主可把 VM1 气球「放大」到 12GB，让 VM1 OS 把 4GB 真的让出来
```

### 6.2 启用

```xml
<devices>
  <memballoon model='virtio'/>
</devices>
```

VM 内（Linux）：

```sh
# 装驱动（一般已编入内核）
# 看当前
cat /sys/kernel/debug/virtio_balloon/balloon_inflate
cat /sys/kernel/debug/virtio_balloon/balloon_deflate
```

宿主机调整：

```bash
virsh setmem vm1 4G --live   # 限制 VM 最多用 4G
```

## 7. virtio-gpu

```xml
<video>
  <model type='virtio' heads='1'/>
</video>
```

需要 VM 内装 `virtio-gpu` 驱动（Linux 5.2+ 已支持）。

特点：
- 支持 3D（virgl）
- 支持 KMS、原子模式设置
- 比 QXL、VGA 性能更好

## 8. virtio-vsock 实战

```bash
# VM 内
socat - UNIX-CONNECT:vsock/host/1234
```

替代方案：

| 方案 | 用途 |
| --- | --- |
| vsock | 任意 Linux VM 通信（无需 IP） |
| guest agent | qemu-ga 提供的 RPC |
| 9p / virtiofs | 文件共享 |
| serial/console | 调试 |

## 9. 调试 virtio

### 9.1 客户机端

```sh
# Linux
lsmod | grep virtio
ls /sys/bus/virtio/devices/
cat /sys/bus/virtio/devices/virtio0/status

# virtio-blk 队列
cat /sys/block/vda/queue/nr_requests
```

### 9.2 宿主机端

```bash
# QEMU 内部看 virtqueue
(qemu) info virtqueues

# 抓 virtio MMIO
qemu-system-x86_64 -d guest_errors,trace:virtio* ...
```

### 9.3 客户机内真实输出（Alpine/Linux 6.x 示例）

```sh
# 客户机：ls /sys/bus/virtio/devices/
virtio0   # 块设备
virtio1   # 网卡

# 每个 virtio 设备能看到协商出来的特性位
cat /sys/bus/virtio/devices/virtio1/device_features
# 0x180023c1d3b24bd  （每位一个特性，如 EVENT_IDX、MQ、ANY_LAYOUT...）

# 网卡多队列是否生效
ls /sys/class/net/eth0/queues/
rx-0  rx-1  rx-2  rx-3  tx-0  tx-1  tx-2  tx-3   # 4 队列

# 中断合并参数（驱动侧）
ethtool -c eth0
```

宿主机侧（vhost-net 视角）：

```bash
# 看 QEMU 进程的线程：vhost 内核线程以进程形式出现
ps -T -p $(pidof qemu-system-x86_64) | grep vhost
#  PID SPID TTY TIME CMD
#  1234 1240 ? 00:00:01 vhost-1234

# 每队列统计（tracepoint，需要 root）
sudo perf stat -e vhost:vhost_virtqueue_ioctl \
    -a -- sleep 5
```

> 排查思路：客户机 `ethtool -l eth0`（队列数）→ 宿主机 `ps -T`（vhost 线程数）
> → `perf -e virtio:*`（通知频率），三层对得上说明多队列真的通了。

### 9.4 内核态 vhost

```bash
sudo cat /sys/kernel/debug/vhost/net 0
# TX queue 0:
#   tx kick = ...
#   ...
```

## 10. 优劣对比速记

| 设备类型 | 性能 | 兼容性 | 推荐场景 |
| --- | --- | --- | --- |
| virtio-blk/scsi | ★★★★★ | ⚠️ 需驱动 | 生产 |
| IDE/e1000 | ★★ | ✅ 任何 OS | 老 OS |
| vfio-pci 直通 | ★★★★★ | ⚠️ 需 IOMMU | 高性能设备 |
| vhost-net | ★★★★★ | 同 virtio-net | 网络默认 |
| vhost-vsock | ★★★★★ | Linux 3.9+ | host-guest 通信 |

## 11. 实战操作

- [`labs/lab06-virtio-perf.md`](../labs/lab06-virtio-perf.md) — virtio vs 全模拟

## 12. 小结

- **virtio = 共享内存环形队列**：驱动 ↔ 设备无 VM exit
- 一次 I/O 只有 KICK（一次 VM exit）+ NOTIFY（一次中断注入）两处硬件级代价；
  event idx 进一步把通知也省了
- **vhost** 把后端搬到内核，进一步省 QEMU 上下文切换
- **Windows 装 virtio** 用专用 ISO
- **virtio-gpu / vsock / balloon** 是高级特性

## 13. 思考题

1. virtio 一次数据传输需要几次 KICK / NOTIFY？能否合并？
2. 多队列 virtio-net 怎么保证同一连接不发到不同队列（避免乱序）？
3. vhost-net 跟 vhost-user 的根本区别？
4. 客户机里 balloon 驱动把内存「还」给宿主机，是直接物理页交换吗？

## 14. 参考资料

- [`refs/learn-kvm/docs/QEMU功能/虚拟处理器.md`](../refs/learn-kvm/docs/QEMU功能/虚拟处理器.md)
- [`refs/learn-kvm/docs/QEMU功能/虚拟USB.md`](../refs/learn-kvm/docs/QEMU功能/虚拟USB.md)
- [`refs/learn-kvm/docs/QEMU功能/其他虚拟外设.md`](../refs/learn-kvm/docs/QEMU功能/其他虚拟外设.md)

---

⬅️ 上一章：[08 · 网络虚拟化详解](08-网络虚拟化详解.md) · [📚 返回目录](../INDEX.md) · 下一章 ➡️：[10 · 图形与显示方案对比](10-图形与显示方案对比.md)
