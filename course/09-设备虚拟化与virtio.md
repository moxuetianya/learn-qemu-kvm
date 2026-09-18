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

### 9.3 内核态 vhost

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
