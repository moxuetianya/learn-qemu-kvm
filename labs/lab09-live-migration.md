# Lab 09 · 实时迁移

> **难度**：★★★★  
> **前置**：Lab 03 + 两台物理机或两台虚机（共享存储）  
> **预计时间**：1 小时

## 目标

把运行中的 VM 从 host A 迁移到 host B，**VM 无感**。

## 实验步骤

### 1. 准备共享存储

> 这是 live migration 的前提。两台 host 必须能访问**同一份磁盘**。

#### 方式 1：NFS

```bash
# host A
sudo apt install nfs-kernel-server
sudo mkdir -p /srv/kvm
sudo chown libvirt-qemu:kvm /srv/kvm
echo '/srv/kvm 192.168.122.0/24(rw,sync,no_subtree_check)' | sudo tee /etc/exports
sudo exportfs -a
sudo systemctl enable --now nfs-server
```

#### 方式 2：iSCSI（生产常用）

参考 lab 之外的 iSCSI 配置。

#### 方式 3：直接用 ceph / glusterfs（云原生场景）

### 2. 两台 host 准备

```bash
# host A、B 都装 libvirt，互相 ssh 信任
ssh-keygen
ssh-copy-id root@hostB

# /etc/hosts 加 A 和 B 的名字
192.168.122.10 hostA
192.168.122.11 hostB
```

### 3. 在 A 上启动 VM

```bash
# disk 放在共享目录
qemu-img create -f qcow2 /srv/kvm/lab09.qcow2 4G

virt-install --name lab09 --ram 1024 --vcpus 2 \
    --disk path=/srv/kvm/lab09.qcow2,format=qcow2,bus=virtio,shared=on \
    --import \
    --network network=default,model=virtio \
    --graphics vnc,listen=0.0.0.0,port=5909 \
    --noautoconsole --os-variant alpinelinux3.18
```

> ⚠️ `shared=on` 关键，否则 libvirt 会拒绝从共享盘启动。

### 4. 配置 migration URI

```bash
virsh edit lab09
# 加 <migration_features>:
# <migration_features>
#   <live/>
#   <transports>
#     <uri 'ssh'/>
#   </transports>
# </migration_features>
```

### 5. 迁移

```bash
# 在 VM 里跑个持续负载
ssh root@<vm-ip> 'while true; do echo $((1+1)) > /dev/null; done'

# 在 host A 上：
virsh migrate --live lab09 \
    --desturi qemu+ssh://hostB/system \
    --persistent --undefinesource
```

迁移过程：

```
Migration: [ 12 %]
```

VM 在 B 上跑起来。A 上 `virsh list` 看不到 lab09，B 上能。

### 6. 验证

```bash
# host B
virsh list
virsh domifaddr lab09
# 还是原来的 IP（除非用了 DHCP 中继）

# VM 内看状态
ssh root@<ip> uptime
# 时间连续
```

### 7. 回迁

```bash
virsh migrate --live lab09 --desturi qemu+ssh://hostA/system --persistent
```

## 优劣对比：迁移策略

| 策略 | 停机时间 | 适用 |
| --- | --- | --- |
| 非实时迁移（offline） | 整段 | 关停维护 |
| post-copy | 极短 | 高带宽 |
| pre-copy（默认） | 短暂 | 一般场景 |
| auto-converge | 较长但稳 | 网络差 |

### 强制参数

```bash
virsh migrate --live lab09 \
    --desturi qemu+ssh://hostB/system \
    --bandwidth 100      # MB/s
    --auto-converge      # 自动收敛脏页
    --timeout 3600
```

## 常见坑

| 现象 | 原因 |
| --- | --- |
| `unknown OS` 错误 | 两边 libvirt 版本不同 |
| `operation not supported` | 磁盘没用 `shared=on` |
| 迁移卡在 90%+ | 网络太慢、脏页太多 |
| 迁移后 VM 起不来 | CPU model 不一致 |

## 输出记录

1. 迁移耗时（VM 内存越大越慢）
2. 迁移过程中 VM 内的 ping 抖动？
3. 回迁是否成功？

## 下一步

[Lab 10 - 调试 KVM 内核](lab10-debug-kernel.md)
