# QEMU 命令行速查

## 启动模板

### 极简（TCG，无 KVM）

```bash
qemu-system-x86_64 \
    -m 1024 -smp 2 \
    -hda /tmp/disk.qcow2 \
    -cdrom /tmp/install.iso \
    -boot d \
    -netdev user,id=n0 \
    -device e1000,netdev=n0 \
    -vnc :0 \
    -monitor stdio
```

### 生产（KVM，virtio）

```bash
qemu-system-x86_64 \
    -name demo \
    -machine accel=kvm,type=q35 \
    -cpu host \
    -m 4G -smp 4 \
    -drive file=/var/lib/libvirt/images/demo.qcow2,format=qcow2,if=virtio \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=n0 \
    -vnc :0 \
    -daemonize -pidfile /tmp/vm.pid
```

### UEFI + TPM

```bash
qemu-system-x86_64 \
    -machine q35,accel=kvm,smm=on \
    -drive file=/usr/share/OVMF/OVMF_CODE.fd,if=pflash,format=raw,readonly=on \
    -drive file=/tmp/OVMF_VARS.fd,if=pflash,format=raw \
    -drive file=/tmp/swtpm/log,format=raw,if=floppy,readonly=on \
    -chardev socket,id=chrtpm,path=/tmp/swtpm/swtpm-sock \
    -tpmdev emulator,chardev=chrtpm,id=tpm0 \
    -device tpm-tis,tpmdev=tpm0
```

## 关键参数

### 机器

| 参数 | 含义 |
| --- | --- |
| `-machine accel=kvm,type=q35` | KVM + q35 芯片组 |
| `-cpu host` | 透传 CPU |
| `-cpu kvm64` | 通用稳定 |
| `-smp N` | N 个 vCPU |
| `-m SIZE` | 内存（如 4G） |
| `-mem-path /dev/hugepages` | 大页 |
| `-mem-prealloc` | 预分配 |
| `-boot order=c` | 启动顺序 |

### 磁盘

| 参数 | 含义 |
| --- | --- |
| `-hda file.qcow2` | IDE 主盘 |
| `-drive file=,format=,if=,cache=` | 通用 |
| `-cdrom file.iso` | 光盘 |
| `-snapshot` | 写到临时，不影响原文件 |

### 网络

| 参数 | 含义 |
| --- | --- |
| `-netdev user,id=n0` | NAT |
| `-netdev tap,id=n0,ifname=tap0` | 接 tap |
| `-netdev bridge,id=n0,br=br0` | 接桥 |
| `-netdev socket,id=n0,listen=:1234` | socket |
| `-device virtio-net-pci,netdev=n0` | virtio-net |
| `-device e1000,netdev=n0` | 全模拟 |

### 显示

| 参数 | 含义 |
| --- | --- |
| `-display none` | 无 |
| `-nographic` | 串口 + 监控到 stdio |
| `-vnc :N` | VNC 5900+N |
| `-spice port=5900,...` | SPICE |
| `-monitor stdio` | 监控口 |

### 调试

| 参数 | 含义 |
| --- | --- |
| `-d strace` | 系统调用 |
| `-d guest_errors` | 客户机错误 |
| `-D /tmp/log` | 日志文件 |
| `-s` | gdb 1234 |
| `-S` | 启动时暂停 |

## monitor 命令

```
info status           # 状态
info network          # 网络
info block            # 磁盘
info cpus             # vCPU
info qtree            # 设备树
info mtree            # 内存树
info migrate          # 迁移状态

system_poweroff       # 关机
q                     # 强制退出
change ide1-cd0 /path/new.iso  # 换盘
device_add ...        # 热插
device_del ...        # 热拔
migrate "exec:cat > /tmp/state"  # 迁移
savevm / loadvm       # 快照
```

## 镜像管理

```bash
qemu-img create -f qcow2 -o preallocation=falloc out.qcow2 10G
qemu-img create -f qcow2 -b base.qcow2 -F qcow2 delta.qcow2
qemu-img info disk.qcow2
qemu-img check disk.qcow2
qemu-img convert -O raw in.qcow2 out.raw
qemu-img convert -c -O qcow2 in.qcow2 compressed.qcow2
qemu-img snapshot -l disk.qcow2
qemu-img snapshot -c snap1 disk.qcow2
qemu-img rebase -b newbase.qcow2 disk.qcow2
qemu-img resize disk.qcow2 +5G
qemu-img amend -f qcow2 -o compat=1.1 disk.qcow2
```

## qemu-nbd

```bash
modprobe nbd
qemu-nbd -c /dev/nbd0 disk.qcow2
mount /dev/nbd0p1 /mnt
qemu-nbd -d /dev/nbd0
```
