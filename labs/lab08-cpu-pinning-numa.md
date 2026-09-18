# Lab 08 · CPU pin + NUMA + hugepage

> **难度**：★★★  
> **前置**：Lab 03 + 多核 CPU  
> **预计时间**：30 分钟

## 目标

通过 CPU 绑定、NUMA 亲和、大页减少调度抖动，提升 VM 性能稳定性。

## 实验步骤

### 1. CPU pinning（绑核）

```bash
# 看 VM 当前 vCPU 在哪几个物理 CPU
virsh vcpupin lab03
# 输出类似：
# VCPU   CPU Affinity
# --------------------------
# 0      0-3
# 1      0-3
```

绑定到指定物理核：

```bash
virsh vcpupin lab03 0 4    # vCPU 0 绑到物理 CPU 4
virsh vcpupin lab03 1 5    # vCPU 1 绑到物理 CPU 5
```

XML 写：

```xml
<vcpu placement='static'>2</vcpu>
<cputune>
    <vcpupin vcpu='0' cpuset='4'/>
    <vcpupin vcpu='1' cpuset='5'/>
</cputune>
```

VM 内验证：

```sh
taskset -cp 1      # PID 1 的 CPU 亲和
cat /proc/cpuinfo | grep "physical id"
```

### 2. 内存 + NUMA

看 host NUMA 拓扑：

```bash
luma-info
numactl -H
```

绑 NUMA：

```xml
<numatune>
    <memory mode='strict' nodeset='0'/>
    <memnode cellid='0' mode='strict' nodeset='0'/>
</numatune>
```

VM 内：

```sh
apk add numactl
numactl -H
# 期望只看到一个 node
```

### 3. 大页（HugePage）

#### 3.1 host 配

```bash
# 临时配 2G 大页
sudo sysctl -w vm.nr_hugepages=1024
# 永久
echo 'vm.nr_hugepages=1024' | sudo tee -a /etc/sysctl.d/99-hugepage.conf
```

预留：

```bash
# 启动 libvirtd 之前预分配大页给 VM 用
sudo mkdir -p /dev/hugepages/libvirt
sudo mount -t hugetlbfs hugetlbfs /dev/hugepages/libvirt -o pagesize=2M
```

#### 3.2 VM 用

```xml
<memoryBacking>
    <hugepages/>
    <locked/>
</memoryBacking>
```

启动 VM 后看 host：

```bash
cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
cat /sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages
```

VM 内验证：

```sh
cat /proc/meminfo | grep Huge
# HugePages_Total:    512
```

### 4. CPU 拓扑（暴露 host 拓扑）

```xml
<cpu mode='host-passthrough'>
    <topology sockets='1' cores='4' threads='2'/>
    <feature policy='require' name='ssse3'/>
</cpu>
```

VM 内 `lscpu` 看到的拓扑跟 host 一样。

## 优劣对比

| 技术 | 适用场景 | 副作用 |
| --- | --- | --- |
| CPU pin | 实时 / 高频交易 / NFV | 调度变差、CPU 浪费 |
| NUMA bind | 大内存 VM | 内存热点 |
| hugepage | 大内存（>4G） | 启动慢、浪费 |
| 隔离核（isolcpu） | 实时 | host 也跑不动 |

## 输出记录

1. `virsh vcpupin lab03` 输出（绑定前后）
2. `numactl -H`（host 与 VM）
3. 大页分配前后 `/proc/meminfo` 对比

## 下一步

[Lab 09 - 实时迁移](lab09-live-migration.md)
