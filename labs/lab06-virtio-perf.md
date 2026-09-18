# Lab 06 · virtio 性能基准

> **难度**：★★★  
> **前置**：Lab 03  
> **预计时间**：30 分钟

## 目标

对比 virtio vs 全模拟设备在磁盘 I/O 和网络上的性能差异。

## 实验步骤

### 1. 准备基线 VM

```bash
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/virtio-test.qcow2 4G
# 用 lab03 的 Alpine 装一遍
```

### 2. 装 iperf3 / fio（VM 内）

```sh
apk add iperf3 fio
```

### 3. 磁盘性能对比

#### 3.1 virtio-blk

```bash
# virt-install 默认就是 virtio
virsh edit virtio-test
# 确认 disk 总线是 virtio
# <target dev='vda' bus='virtio'/>
```

VM 内：

```sh
fio --name=randwrite --filename=/dev/vda \
    --size=1G --bs=4k --rw=randwrite \
    --ioengine=libaio --iodepth=32 \
    --runtime=10 --time_based --direct=1 \
    --output-format=normal
```

#### 3.2 IDE（改成全模拟）

```bash
virsh edit virtio-test
# 把 bus='virtio' 改成 bus='ide'，重启 VM
# 在 VM 内设备会变成 /dev/sda
```

VM 内：

```sh
fio --name=randwrite --filename=/dev/sda \
    --size=1G --bs=4k --rw=randwrite \
    --ioengine=libaio --iodepth=32 \
    --runtime=10 --time_based --direct=1 \
    --output-format=normal
```

### 4. 网络性能对比

#### 4.1 virtio-net

```bash
# 默认就是 virtio-net
```

```sh
# VM 内跑服务端
iperf3 -s

# 宿主机跑客户端
iperf3 -c 192.168.122.x
```

#### 4.2 e1000（全模拟）

```bash
virsh edit virtio-test
# 把 model='virtio' 改成 <model type='e1000'/>
```

重启后 VM 内重跑 iperf3。

### 5. 期望结果

| 维度 | virtio | e1000 / IDE |
| --- | --- | --- |
| 网络吞吐 | ~9.4 Gbps | ~3 Gbps |
| 网络 PPS | 1M+ | 200k |
| 磁盘 IOPS | 100k+ | 30-60k |
| CPU 占用 | 低 | 高 |

## 优劣对比

| 设备类型 | 性能 | 兼容性 | 推荐场景 |
| --- | --- | --- | --- |
| virtio | ✅✅ | ⚠️ OS 要有驱动 | 生产 |
| IDE/e1000 | ❌ | ✅ 任何 OS | 老 OS / 调试 |
| vhost-net/vhost-scsi | ✅✅✅ | 同 virtio | 极致性能 |
| vfio-pci 直通 | ✅✅✅ | ⚠️ 设备独占 | 数据库、高频交易 |

## 输出记录

1. virtio vs e1000 网络吞吐量对比
2. virtio vs IDE 磁盘 IOPS 对比
3. 整机 CPU 占用差多少？（用 `top`）

## 下一步

[Lab 07 - PCI/GPU 直通](lab07-pci-passthrough.md)
