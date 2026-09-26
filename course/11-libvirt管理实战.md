# 11 · libvirt 管理实战

> libvirt 是虚拟化的「说明书」。学会它，生产环境的 VM 管理都靠它。

## 学习目标

- 能用 `virsh` 完成日常运维
- 能写 libvirt XML 配置 VM
- 理解 libvirt 的存储池、网络池概念
- 能用 virt-manager 远程管理

## 1. libvirt 是什么

```
QEMU/KVM  ←→  libvirtd（后台）  ←→  virsh/virt-manager/virt-install
   │
   └─── 也能管 Xen / VirtualBox / LXC / bhyve / VMware
```

libvirt = **统一的虚拟化管理 API**。同一套命令管理不同 hypervisor。

## 2. libvirt 组件

| 组件 | 角色 |
| --- | --- |
| `libvirtd` | 后台守护进程 |
| `virsh` | 命令行客户端 |
| `virt-manager` | GUI 客户端 |
| `virt-install` | 命令行装机 |
| `virt-viewer` | 远程桌面客户端 |
| `libvirt-python` | Python SDK |
| `libvirt-java` | Java SDK |

## 3. URI 体系

```
qemu:///system          # 系统 hypervisor（root）
qemu:///session         # 用户态
qemu+ssh://host/system  # 远程
test:///default         # 测试用 mock
```

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
virsh uri
virsh -c qemu+ssh://user@host/system list
```

## 4. 核心对象模型

```
Node（宿主机）
├── StoragePool（存储池）
│   └── Volume（卷，对应一个镜像）
├── Network（虚拟网络）
│   └── Forward（转发方式：NAT/bridge/isolated）
├── Domain（VM）
├── Interface（宿主机网卡抽象）
└── NWFilter（防火墙规则集）
```

## 5. virsh 速查

### 5.1 主机

```bash
virsh nodeinfo            # CPU 架构、内存、CPU 数
virsh hostname
virsh version
virsh capabilities        # 详细能力
```

### 5.2 域（VM）

```bash
virsh list                # 运行中
virsh list --all          # 全部
virsh dominfo vm
virsh domstate vm
virsh domid vm            # ID（运行时）
virsh domuuid vm          # UUID
virsh domxml-from-native qemu-argv /path/to/qemu-cmdline.xml  # 从命令行转 XML
virsh domxml-to-native qemu-argv vm.xml  # XML 转命令行

virsh start vm
virsh shutdown vm          # ACPI 优雅关机
virsh destroy vm           # 强制断电
virsh reboot vm
virsh reset vm            # 硬重启
virsh suspend vm           # 挂起
virsh resume vm
virsh save vm /tmp/vm.state  # 保存到文件
virsh restore /tmp/vm.state

virsh undefine vm                  # 删定义
virsh undefine vm --remove-all-storage  # 删定义 + 磁盘
virsh undefine vm --nvram          # 删定义 + UEFI NVRAM
```

### 5.3 设备

```bash
virsh domiflist vm
virsh domifaddr vm                  # 用 arp 探测
virsh domifaddr vm --source agent   # qemu-guest-agent
virsh domblklist vm
virsh domblkstat vm vda
virsh domcontrol vm
virsh setmem vm 4G --live --config
virsh setvcpus vm 4 --live --config
virsh vcpupin vm 0 4
virsh emulatorpin vm 0-3
virsh domperf vm                    # KVM perf events
```

### 5.4 快照

```bash
virsh snapshot-list vm
virsh snapshot-create vm --name snap1
virsh snapshot-create-as vm snap1 "before upgrade"
virsh snapshot-revert vm snap1
virsh snapshot-current vm
virsh snapshot-delete vm snap1
virsh snapshot-dumpxml vm snap1
```

### 5.5 监控

```bash
virsh domstats vm                # 一次性大量统计
virsh domblkinfo vm vda
virsh domifstat vm vnet0
virsh dommemstat vm
virsh domcpustat vm
virsh top                        # top 风格的 VM 视图
```

### 5.6 事件 / 调度

```bash
virsh event                     # 实时事件
virsh schedinfo vm              # 看调度参数（cap、shares）
virsh schedinfo vm --weight 1024
virsh schedinfo vm --cap 100     # 限制 CPU %
```

## 6. XML 配置

### 6.1 最小可用

```xml
<domain type='kvm'>
  <name>demo</name>
  <memory unit='KiB'>1048576</memory>
  <vcpu placement='static'>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/lib/libvirt/images/demo.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <graphics type='vnc' port='-1'/>
    <console type='pty'/>
  </devices>
</domain>
```

### 6.2 关键字段

| 标签 | 含义 | 常用值 |
| --- | --- | --- |
| `<type>` | hypervisor | kvm / qemu |
| `<memory>` | 内存 | 单位 KiB / MiB / GiB |
| `<currentMemory>` | 启动时内存 | – |
| `<vcpu>` | vCPU 数 | placement: static / auto |
| `<os><type>` | 架构 | x86_64 / aarch64 |
| `<features>` | CPU flags | acpi / apic / pae |
| `<cpu>` | CPU model | host-passthrough / kvm64 |
| `<clock>` | 时钟 | offset=utc/localtime |
| `<on_poweroff>` | 关机动作 | destroy / restart / preserve |
| `<devices>` | 设备列表 | disk / interface / ... |

### 6.3 块设备高级

```xml
<disk type='file' device='disk' snapshot='external'>
  <driver name='qemu' type='qcow2' cache='none' io='native' queues='4' iothread='1'/>
  <source file='/var/lib/libvirt/images/demo.qcow2' index='1'/>
  <target dev='vda' bus='virtio'/>
  <iotune>
    <read_bytes_sec>104857600</read_bytes_sec>
    <write_bytes_sec>52428800</write_bytes_sec>
    <read_iops_sec>2000</read_iops_sec>
    <write_iops_sec>1000</write_iops_sec>
  </iotune>
</disk>
```

### 6.4 内存调优

```xml
<memory unit='KiB'>4194304</memory>
<currentMemory unit='KiB'>2097152</currentMemory>
<memoryBacking>
  <hugepages/>
  <nosharepages/>
  <locked/>
  <source type='file'/>
  <access mode='shared'/>
</memoryBacking>
<numatune>
  <memory mode='strict' nodeset='0'/>
  <memnode cellid='0' mode='strict' nodeset='0'/>
</numatune>
```

## 7. 存储池

### 7.1 概念

存储池 = 一组镜像的集合，对应一个目录 / LVM 卷组 / NFS 挂载点 / Ceph pool。

### 7.2 创建

```bash
# 目录池
virsh pool-define-as default2 dir --target /var/lib/libvirt/images2
virsh pool-start default2
virsh pool-autostart default2

# LVM 池
virsh pool-define-as vg0 logical --source-name vg0 --target /dev/vg0
virsh pool-start vg0

# NFS 池
virsh pool-define-as nfs0 netfs \
    --source-host 192.168.122.10 \
    --source-path /srv/kvm \
    --target /mnt/nfs0
virsh pool-start nfs0
```

### 7.3 卷

```bash
virsh vol-create-as default2 myvm 10G --format qcow2
virsh vol-list default2
virsh vol-info default2/myvm
virsh vol-resize default2/myvm 20G
virsh vol-delete default2/myvm
```

## 8. 网络池

```bash
virsh net-list --all
virsh net-define /tmp/net.xml
virsh net-start demo
virsh net-autostart demo

# 默认网络
virsh net-dumpxml default
```

NAT 网 XML：

```xml
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
```

桥接网 XML：

```xml
<network>
  <name>br0</name>
  <forward mode='bridge'/>
  <bridge name='br0'/>
</network>
```

## 9. 远程管理

```bash
# 本地起 libvirtd 监听 TCP（生产用 TLS）
sudo vim /etc/libvirt/libvirtd.conf
# 去掉注释：
# listen_tcp = 1
# listen_tls = 0    # 演示用
# auth_tcp = "none" # 演示用
sudo systemctl restart libvirtd

# 远程连
virsh -c qemu+tcp://host:16509/system list
```

**生产用 TLS + SASL / Kerberos**。

## 10. 自动化

### 10.1 Ansible

```yaml
- name: create VM
  community.libvirt.virt:
    name: "{{ vm_name }}"
    state: running
    command: define
    xml: "{{ lookup('template', 'vm.xml.j2') }}"
```

### 10.2 Terraform

```hcl
resource "libvirt_domain" "vm" {
    name   = "demo"
    memory = 2048
    vcpu   = 2
    disk {
        volume_id = libvirt_volume.vm.id
    }
    network_interface {
        network_name = "default"
    }
}
```

### 10.3 Python SDK

```python
import libvirt
conn = libvirt.open('qemu:///system')
dom = conn.defineXML(xml_str)
dom.create()
```

## 11. 优劣对比：libvirt vs 其他

| 维度 | libvirt | 直接 qemu | oVirt | OpenStack |
| --- | --- | --- | --- | --- |
| 单机管理 | ✅✅ | ✅ | – | – |
| 多机集群 | ⚠️（KubeVirt/OpenStack） | ❌ | ✅✅ | ✅✅✅ |
| 学习曲线 | ★★ | ★★★ | ★★★★ | ★★★★★ |
| 灵活性 | ★★★★ | ★★★★★ | ★★★ | ★★★ |
| 自动化 | ✅ | ⚠️ | ✅✅ | ✅✅✅ |

## 12. 实战操作

```bash
# 基础
virsh list --all
virsh dominfo lab03
virsh dumpxml lab03 > /tmp/lab03.xml

# 编辑后重新载入
virsh define /tmp/lab03.xml
virsh create /tmp/lab03.xml        # 不改定义直接跑

# 看网络/存储
virsh net-list --all
virsh net-dumpxml default
virsh pool-list --all
virsh vol-list default

# 性能统计
virsh domstats lab03
```

## 13. 小结

- libvirt = 统一虚拟化 API
- virsh + XML 是核心
- 存储池 / 网络池让多主机一致
- **生产必学**

## 14. 思考题

1. `virsh shutdown` 和 `virsh destroy` 的本质区别？
2. `qemu:///system` vs `qemu:///session` 的权限差异？
3. 为什么生产推荐 XML 而不是命令行参数？
4. `virsh setmem` 跟 `<currentMemory>` 哪个生效？

## 15. 参考资料

- [`refs/learn-kvm/docs/KVM核心基础功能/KVM核心基础功能.md`](../refs/learn-kvm/docs/KVM核心基础功能/KVM核心基础功能.md)
- [`refs/learn-kvm/docs/KVM核心基础功能/Qemu-KVM基本格式.md`](../refs/learn-kvm/docs/KVM核心基础功能/Qemu-KVM基本格式.md)
- [`refs/learn-kvm/docs/KVM核心基础功能/Qemu-KVM网络配置.md`](../refs/learn-kvm/docs/KVM核心基础功能/Qemu-KVM网络配置.md)
- [`refs/learn-kvm/docs/KVM核心基础功能/Qemu-KVM图形界面.md`](../refs/learn-kvm/docs/KVM核心基础功能/Qemu-KVM图形界面.md)

---

⬅️ 上一章：[10 · 图形与显示方案对比](10-图形与显示方案对比.md) · [📚 返回目录](../INDEX.md) · 下一章 ➡️：[12 · 性能调优与诊断](12-性能调优与诊断.md)
