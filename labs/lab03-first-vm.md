# Lab 03 · 第一个虚拟机

> **难度**：★★  
> **前置**：Lab 01、02 通过  
> **预计时间**：30 分钟

## 目标

- 用 `qemu-img` 创建 qcow2 镜像
- 用 `virt-install` 装一台 Alpine Linux
- 从 VNC 完成系统安装
- SSH 登录 VM

## 实验步骤

### 1. 创建磁盘镜像

```bash
sudo qemu-img create -f qcow2 \
    /var/lib/libvirt/images/lab03.qcow2 4G

qemu-img info /var/lib/libvirt/images/lab03.qcow2
```

### 2. 下载 Alpine ISO

```bash
cd /var/lib/libvirt/images
sudo wget https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-virt-3.20.3-x86_64.iso
```

### 3. 启动 VM

```bash
sudo virt-install \
    --name lab03 \
    --ram 1024 \
    --vcpus 2 \
    --disk path=/var/lib/libvirt/images/lab03.qcow2,format=qcow2,bus=virtio \
    --cdrom /var/lib/libvirt/images/alpine-virt-3.20.3-x86_64.iso \
    --network network=default,model=virtio \
    --graphics vnc,listen=127.0.0.1,port=5903 \
    --os-variant alpinelinux3.18 \
    --noautoconsole

virsh list
#  Id   Name   State
# --------------------------
#  1    lab03  running
```

### 4. VNC 客户端连

```bash
vncviewer :5903
```

或：

```bash
virt-viewer lab03
```

### 5. 装系统

在 VNC 窗口里：

```sh
# Alpine 登录
login: root
# 无密码

# 装系统
setup-alpine
# 一路回车，镜像源选 fastest，root 密码设一个

# 装到磁盘
apk add cfdisk e2fsprogs
cfdisk /dev/vda        # 注意：virtio 块设备是 /dev/vda
# 分一个区，type=Linux（83），write，quit
mkfs.ext4 /dev/vda1
mount /dev/vda1 /mnt
setup-disk -m sys /mnt

# 重启（从磁盘）
mount /dev/vda1 /mnt
mkdir -p /mnt/etc
echo '/dev/vda1 / ext4 defaults 0 0' > /mnt/etc/fstab

reboot
# 在 virt-manager 或 virsh 里把 cdrom 切掉，让 VM 从 disk 启动
```

从 libvirt 角度切 cdrom：

```bash
virsh shutdown lab03
virsh edit lab03
# 找到 <disk device="cdrom"> 那段，整段删除或注释
virsh start lab03
```

或者在 monitor 里临时切：

```bash
virsh qemu-monitor-command lab03 --pretty '{ "execute": "change", "arguments": {"device": "ide0-1-0", "target": "/dev/null"}}'
```

### 6. 装 SSH 并启动

```sh
apk add openssh
rc-update add sshd
service sshd start
```

### 7. 宿主 SSH 进去

```bash
# 查 IP
virsh domifaddr lab03
# 192.168.122.x

ssh root@192.168.122.x
```

### 8. （进阶）装 qemu-guest-agent

```sh
apk add qemu-guest-agent
rc-update add qemu-guest-agent
service qemu-guest-agent start
```

宿主机验证：

```bash
virsh domifaddr lab03 --source agent
# 应返回 IP（不再靠 arp 探测）
```

## 进阶：cloud-init 无人值守

```bash
mkdir -p /tmp/lab03-ci

cat > /tmp/lab03-ci/user-data <<'EOF'
#cloud-config
hostname: lab03-vm
users:
  - name: peter
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/ash
    passwd: "$6$rounds=4096$saltsalt$Z8wL.4Jv0z5wHjQwMTwMoqKj2lT8HOz4lzQ3WCZJYD/"
ssh_pwauth: true
package_update: true
runcmd:
  - apk add openssh qemu-guest-agent
  - rc-update add sshd default
  - rc-update add qemu-guest-agent default
EOF

cat > /tmp/lab03-ci/meta-data <<'EOF'
instance-id: lab03-vm
local-hostname: lab03-vm
EOF

genisoimage -output /tmp/lab03-ci.iso \
    -volid cidata -joliet -rock \
    /tmp/lab03-ci/user-data \
    /tmp/lab03-ci/meta-data
```

把这个 ISO 当 cdrom 挂上去，VM 启动时会自动跑 cloud-init。

## 输出记录

1. `qemu-img info` 输出
2. `virsh list` 输出
3. `virsh domifaddr` 输出
4. `uname -a`（在 VM 里）
5. 你用了几分钟完成首次 SSH？

## 常见失败

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| VNC 连不上 | 5903 被防火墙挡 | `firewall-cmd --add-port=5903/tcp` 或换 `127.0.0.1` |
| 找不到 /dev/vda | 用了 IDE 总线 | `--bus virtio` |
| VM 起不来但 `virsh list` 显示 running | libvirt 状态滞后 | `virsh destroy && virsh start` |
| 装完重启又进 ISO | cdrom 没切 | `virsh edit` 删 cdrom 段 |

## 下一步

[Lab 04 - 磁盘镜像格式对比](lab04-storage-formats.md)
