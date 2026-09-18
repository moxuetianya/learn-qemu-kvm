# KVM 调优参数速查

## CPU

### VM CPU model

```xml
<cpu mode='host-passthrough'/>            <!-- 性能最好，迁移差 -->
<cpu mode='custom'>
  <model>kvm64</model>                   <!-- 通用稳定，迁移好 -->
</cpu>
```

### vCPU 绑定

```xml
<cputune>
  <vcpupin vcpu='0' cpuset='4'/>
  <emulatorpin cpuset='0-1'/>            <!-- 把 QEMU 线程也隔开 -->
</cputune>
```

```bash
# 命令行
virsh vcpupin vm 0 4
virsh emulatorpin vm 0-1
```

### 调度权重

```xml
<cputune>
  <shares>2048</shares>    <!-- 默认 1024，权重高 = 多分时间 -->
  <quota>-1</quota>         <!-- 不限 -->
  <period>100000</period>
</cputune>
```

### 隔离核（host）

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX="isolcpus=4,5,6,7 nohz_full=4,5,6,7 rcu_nocbs=4,5,6,7"
```

### APICv / Posted Interrupt

```xml
<features>
  <apic/>
</features>
<clock offset='localtime'>
  <timer name='rtc' tickpolicy='catchup'/>
  <timer name='pit' tickpolicy='delay'/>
  <timer name='hpet' present='no'/>
</clock>
```

## 内存

### 大页

```bash
# host
sysctl -w vm.nr_hugepages=2048

# 挂载
mount -t hugetlbfs hugetlbfs /dev/hugepages/libvirt -o pagesize=2M
```

```xml
<memoryBacking>
  <hugepages/>
  <locked/>
</memoryBacking>
```

### 1G 大页

```bash
# host
sysctl -w vm.nr_hugepages=8         # 1G 大页数

# kernel cmdline
default_hugepagesz=1G hugepagesz=1G hugepages=8
```

### NUMA 绑定

```xml
<numatune>
  <memory mode='strict' nodeset='0'/>
  <memnode cellid='0' mode='strict' nodeset='0'/>
</numatune>
```

### KSM（不推荐生产）

```bash
echo 1 > /sys/kernel/mm/ksm/run
```

### balloon

```xml
<memballoon model='virtio'/>
```

```bash
virsh setmem vm 4G --live --config
```

## 磁盘

### 多队列 + iothread

```xml
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2'
          cache='none' io='native'
          queues='4' iothread='1'/>
  <source file='/var/lib/libvirt/images/vm.qcow2'/>
  <target dev='vda' bus='virtio'/>
</disk>

<iothreads>2</iothreads>
```

### 写穿透 / 缓存

```xml
<driver cache='none' io='native'/>      <!-- 生产默认 -->
<driver cache='writethrough'/>
<driver cache='writeback'/>             <!-- 不推荐 -->
```

### I/O 限速

```xml
<iotune>
  <read_bytes_sec>104857600</read_bytes_sec>      <!-- 100 MB/s -->
  <write_bytes_sec>52428800</write_bytes_sec>      <!-- 50 MB/s -->
  <read_iops_sec>2000</read_iops_sec>
  <write_iops_sec>1000</write_iops_sec>
</iotune>
```

### 主机磁盘调度

```bash
echo none > /sys/block/nvme0n1/queue/scheduler   # 极致性能
echo mq-deadline > /sys/block/sda/queue/scheduler # 默认
```

### 文件系统

```bash
# ext4 mount options
mount -o noatime,nodiratime /var/lib/libvirt
```

## 网络

### vhost-net 多队列

```xml
<interface type='bridge'>
  <source bridge='virbr0'/>
  <model type='virtio'/>
  <driver name='vhost' queues='4'/>
</interface>
```

VM 内：

```sh
ethtool -L eth0 combined 4
```

### 巨帧

```bash
ip link set br0 mtu 9000
```

VM 内：

```sh
ip link set eth0 mtu 9000
```

### SR-IOV

```bash
echo 4 > /sys/class/net/eth0/device/sriov_numvfs
```

VM:

```xml
<hostdev mode='subsystem' type='pci'>
  <source>
    <address domain='0x0000' bus='0x04' slot='0x10' function='0x0'/>
  </source>
</hostdev>
```

## 实时 / 低延迟

### host cmdline

```
GRUB_CMDLINE_LINUX="quiet splash
    isolcpus=4,5,6,7
    nohz_full=4,5,6,7
    rcu_nocbs=4,5,6,7
    intel_idle.max_cstate=0
    intel_pstate=disable
    idle=poll
    transparent_hugepage=never
    nmi_watchdog=0
    mitigations=off
    processor.max_cstate=0"
```

### VM CPU pin

```xml
<cputune>
  <vcpupin vcpu='0' cpuset='4'/>
  <emulatorpin cpuset='5-7'/>
</cputune>
```

## kvm_stat 速用

```bash
sudo kvm_stat
# 关注：
# - io / mmio        （设备访问）
# - halt             （正常）
# - ept_misconfig    （配置错）
# - pause_intercept  （正常）
# - apic / irq_window（中断）
```

## perf 速用

```bash
# KVM 全事件
sudo perf top -e 'kvm:*'

# 客户机执行热路径
sudo perf kvm --host stat record -a
sudo perf kvm --guest stat report

# 跟踪
sudo perf trace -e 'kvm:kvm_entry' -a
```

## bpftrace 模板

```bash
# VM entry → exit 延迟
sudo bpftrace -e '
kprobe:kvm_vcpu_run {
    @start[tid] = nsecs;
}
kretprobe:kvm_vcpu_run /@start[tid]/ {
    @ns = hist(nsecs - @start[tid]);
    delete(@start[tid]);
}
'

# 看某种 exit_reason
sudo bpftrace -e '
kprobe:vmx_handle_exit {
    printf("exit_reason=%d\n", arg1->exit_reason);
}
'
```
