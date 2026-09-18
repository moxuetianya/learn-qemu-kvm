# 故障排查速查

## 第一刀

```bash
# 1. 日志
journalctl -xeu libvirtd --no-pager | tail -50
dmesg | tail -50
virsh console vm

# 2. VM 状态
virsh list --all
virsh dominfo vm
virsh domstate vm

# 3. 资源
top
iostat -x 1
sar -n DEV 1
free -h
```

## 启动失败

| 报错 / 现象 | 第一检查 |
| --- | --- |
| `permission denied /dev/kvm` | `ls -l /dev/kvm`，用户是否在 kvm 组 |
| `monitor socket already in use` | `rm /tmp/monitor.sock` |
| `cannot find OVMF.fd` | `apt install ovmf` |
| `cpu kvm64 not supported` | 改 `<cpu mode='host-passthrough'>` |
| `unsupported configuration` | 检查 machine / cpu |
| `qemu-system exited with status 1` | 看 `journalctl -u libvirtd` |

## VM 内问题

| 现象 | 检查 |
| --- | --- |
| 找不到磁盘 | `virsh domblklist vm` |
| 没网络 | `virsh domiflist vm`，`tcpdump -i virbr0` |
| 没 IP | `journalctl -u systemd-networkd` |
| 启动卡住 | `virsh console vm`，看 console 输出 |
| OOM | `virsh dommemstat vm` |

## 性能问题

```bash
# VM exit
sudo kvm_stat

# host CPU
top
mpstat -P ALL 1

# host 磁盘
iostat -x 1

# host 网络
sar -n DEV 1

# VM 内
mpstat -P ALL 1
iostat -x 1
pidstat -d 1
```

## 迁移问题

```bash
virsh domjobinfo vm
virsh domjobabort vm

# 看迁移进度
virsh migrate --live --verbose vm --desturi qemu+ssh://host/system
```

## 网络故障树

```
VM 上不了网
├── VM 内能 ping host 吗？
│   ├── 不能 → 网卡没起来 / 驱动问题
│   └── 能 → NAT 问题
│       ├── host iptables FORWARD？
│       ├── ip_forward=1？
│       └── DHCP 有响应吗？
└── VM 之间能 ping 吗？
    ├── 不能 → 桥配置
    └── 能 → 外网路由
```

## 存储故障树

```
VM 写盘慢 / 报错
├── dmesg host 有 IO error？ → 硬件
├── qemu-img check？ → 镜像损坏
├── cache 设置？ → cache=none
├── 镜像在 NFS？ → 检查权限
└── 共享盘？ → shareable 标记
```

## 内存故障树

```
VM OOM / 慢
├── host OOM？ → free -h
├── swap 在用？ → 禁 swap
├── balloon？ → virsh setmem
└── NUMA 跨节点？ → numatune 绑
```

## CPU 故障树

```
VM 性能差
├── vCPU 数？ → 太多反而差
├── 绑核？ → virsh vcpupin
├── VM exit 多？ → kvm_stat 看类型
└── 调度？ → isolcpus + cpuset
```

## 常用排查命令

```bash
# 1. 看 QEMU 进程
ps aux | grep qemu-system

# 2. 看 /proc/<pid>/status
cat /proc/$(pidof qemu-system-x86_64)/status

# 3. 跟踪 QEMU 系统调用
sudo strace -p $(pidof qemu-system-x86_64)

# 4. 看资源占用
pidstat -r -p $(pidof qemu-system-x86_64) 1
pidstat -d -p $(pidof qemu-system-x86_64) 1

# 5. 看 VM 内部 CPU 占用（guest 内）
top
htop

# 6. perf
sudo perf top -p $(pidof qemu-system-x86_64)
sudo perf top -e kvm:* -a

# 7. 抓 MMIO 跟踪
qemu-system-x86_64 -d trace:virtio_mmio_write,trace:virtio_mmio_read ...

# 8. 内存 dump
virsh dump vm /tmp/vm.dump --live --crash
```

## SELinux 拒绝

```bash
# 找拒绝
sudo ausearch -m avc -ts recent | tail -30

# 临时放行（debug）
sudo setenforce 0

# 永久放行
sudo ausearch -m avc -ts recent | audit2allow -M myqemu
sudo semodule -i myqemu.pp
```

## 网络深度排查

```bash
# 桥配置
brctl show
ip link show type bridge
ip link show master virbr0

# 抓包
sudo tcpdump -i virbr0 -nn -e
sudo tcpdump -i vnet0 -nn -e

# 路由
ip route
ip rule

# conntrack
sudo conntrack -L -n

# NAT
sudo iptables -t nat -L -n -v
```

## 存储深度排查

```bash
# 看镜像
qemu-img info /var/lib/libvirt/images/vm.qcow2
qemu-img check /var/lib/libvirt/images/vm.qcow2
qemu-img compare vm1.qcow2 vm2.qcow2

# 看磁盘 / IO
lsblk
iostat -x 1
iotop

# virtio-blk 多队列
cat /sys/block/vda/queue/nr_requests
ls /sys/block/vda/mq/

# 共享盘锁
ls -la /var/lib/libvirt/images/*.lock
fuser /var/lib/libvirt/images/vm.qcow2  # 谁在用
```

## 安全相关

```bash
# QEMU 版本
qemu-system-x86_64 --version

# 升级
sudo apt update && sudo apt upgrade qemu-*

# sVirt 状态
ps -eZ | grep qemu
ls -laZ /var/lib/libvirt/images/

# 关 sVirt（不推荐）
security_driver = "none"
```

## 性能基线模板

```bash
# 磁盘
fio --name=randwrite --filename=/dev/vda --rw=randwrite \
    --bs=4k --size=1G --runtime=10 --time_based --direct=1 \
    --ioengine=libaio --iodepth=32 --output-format=normal

# 网络（VM 内 server）
iperf3 -s

# 网络（host client）
iperf3 -c 192.168.122.x -t 30 -P 4

# CPU
sysbench cpu --cpu-max-prime=20000 run
```

## 报警信号

| 信号 | 含义 |
| --- | --- |
| `kvm_stat` EPT misconfig 涨 | 内存配置错 |
| `kvm_stat` IO 涨 | 客户机驱动异常 |
| `top` qemu %CPU 高 | 模拟逻辑多（无 KVM） |
| `iostat` %util > 80 | 存储瓶颈 |
| `sar` rxerr / txerr > 0 | 网络包丢 |
| `dmesg` `kvm: ... disabled by BIOS` | BIOS 没开 VT-x |

## 紧急操作

```bash
# 强制关 VM
virsh destroy vm

# 强制重启
virsh reset vm

# 备份配置
virsh dumpxml vm > /tmp/vm-$(date +%s).xml

# 紧急恢复
virsh define /tmp/vm-*.xml
```
