# Lab 07 · PCI / GPU 直通

> **难度**：★★★★  
> **前置**：Lab 03 + 主板 / BIOS 支持 VT-d + Linux 内核 ≥ 5.x  
> **预计时间**：1 小时

## 目标

把宿主的一块 PCI 设备（网卡、NVMe、GPU）直通给 VM，让 VM 直接驱动。

## 实验步骤

### 1. 确认硬件支持

```bash
# CPU flags
egrep -o '(vmx|svm)' /proc/cpuinfo | head -1

# IOMMU groups
find /sys/kernel/iommu_groups/ -type l | xargs -I {} sh -c \
    'echo "Group $(basename $(dirname {})): {}"'
# 应该看到非空 group 列表
```

### 2. 内核参数

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX="intel_iommu=on iommu=pt"   # Intel
# 或
GRUB_CMDLINE_LINUX="amd_iommu=on iommu=pt"      # AMD
```

```bash
sudo update-grub
sudo reboot
```

```bash
dmesg | grep -i -e DMAR -e AMD-Vi
# 期望看到 "IOMMU enabled"
```

### 3. 选一个设备直通

```bash
lspci -nn
# 找到目标设备，记下 [xxxx:yyyy] 形式
# 比如 0000:01:00.0 Network controller [8086:2723]
```

### 4. 解除宿主占用

```bash
# 把设备从宿主驱动解绑
echo "0000:01:00.0" | sudo tee /sys/bus/pci/devices/0000:01:00.0/driver/unbind
# 绑到 vfio-pci
echo "8086 2723" | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id
echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind
lspci -nn -d 8086:2723 -k
# 应该看到 "driver: vfio-pci"
```

### 5. 启动 VM 透传

```bash
qemu-system-x86_64 \
    -name passthrough \
    -machine accel=kvm \
    -m 4G -smp 4 \
    -drive file=lab03.qcow2,format=qcow2,if=virtio \
    -device vfio-pci,host=01:00.0 \
    -nographic
```

VM 内：

```sh
lspci
# 应该看到这块设备
ip addr    # 网卡会多一个
```

### 6. GPU 直通（简化版）

> 完整 GPU 直通很复杂（需要 reset bug workaround、VBIOS、UEFI...），仅给思路：

```bash
# 主机提前：把 GPU 从 nouveau/nvidia 卸载
echo "0000:01:00.0" > /sys/bus/pci/devices/0000:01:00.0/driver/unbind
echo "vfio-pci" > /sys/bus/pci/devices/0000:01:00.0/driver_override
echo "0000:01:00.0" > /sys/bus/pci/drivers/vfio-pci/bind

# VM 配置加：
qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host,kvm=on,vendor=GenuineIntel \
    -device vfio-pci,host=01:00.0,x-pci-vendor-id=0x8086,x-pci-device-id=0x.... \
    -device vfio-pci,host=01:00.1,... \
    ...
```

## 优劣对比

| 维度 | virtio | vfio-pci 直通 | SR-IOV |
| --- | --- | --- | --- |
| 性能 | ★★★★ | ★★★★★ | ★★★★★ |
| 设备独占 | ❌ | ✅ | ❌（虚拟多份） |
| 迁移 | ✅ | ⚠️（受限） | ✅ |
| 主板要求 | ❌ | ✅ VT-d | ✅ SR-IOV |
| 设备类型 | 半虚拟化设备 | 任意 PCI | 部分 NIC |

## 常见坑

| 现象 | 原因 |
| --- | --- |
| `vfio-pci` 绑定失败 | 内核没编 `CONFIG_VFIO` |
| `Operation not permitted` | 没开 IOMMU |
| VM 启动后设备不工作 | 设备在 PCIe group 不独立 |
| GPU reset 失败 | 设备有 FLR bug |
| 宿主机没网了 | 把唯一网卡直通了 |

> **永远别把宿主的唯一管理网卡直通给 VM**——会丢连接。

## 输出记录

1. 你机器 IOMMU group 列表
2. 直通的设备型号、厂商
3. 直通后 VM 内 `lspci` 输出
4. 性能对比（iperf3）

## 下一步

[Lab 08 - 性能调优](lab08-cpu-pinning-numa.md)
