# libvirt XML 速查

## 最小骨架

```xml
<domain type='kvm'>
  <name>demo</name>
  <memory unit='KiB'>2097152</memory>
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
    <console type='pty'/>
    <graphics type='vnc' port='-1'/>
  </devices>
</domain>
```

## domain 顶层

| 元素 | 含义 |
| --- | --- |
| `<name>` | 名字 |
| `<uuid>` | UUID |
| `<title>` | 描述 |
| `<memory>` | 最大内存 |
| `<currentMemory>` | 启动时分配 |
| `<vcpu>` | vCPU 数 |
| `<os>` | OS 信息 |
| `<features>` | 特性开关 |
| `<cpu>` | CPU model |
| `<clock>` | 时钟 |
| `<on_poweroff>` | 关机动作 |
| `<on_reboot>` | 重启动作 |
| `<on_crash>` | 崩溃动作 |
| `<devices>` | 设备列表 |
| `<cputune>` | CPU 调度 |
| `<numatune>` | NUMA 调度 |
| `<memoryBacking>` | 内存策略 |
| `<migration_features>` | 迁移特性 |

## OS 与启动

```xml
<os>
  <type arch='x86_64' machine='q35'>hvm</type>
  <boot dev='hd'/>
  <boot dev='cdrom'/>
  <bootmenu enable='yes'/>
  <smbios mode='sysinfo'/>
  <bios useserial='yes'/>
</os>
```

UEFI：

```xml
<os>
  <type arch='x86_64' machine='q35'>hvm</type>
  <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE.fd</loader>
  <nvram template='/usr/share/OVMF/OVMF_VARS.fd'/>
</os>
```

## CPU

```xml
<cpu mode='host-passthrough'>
  <topology sockets='1' cores='4' threads='2'/>
  <feature policy='require' name='ssse3'/>
  <feature policy='disable' name='avx512'/>
  <numa>
    <cell id='0' cpus='0-3' memory='2097152' unit='KiB'/>
  </numa>
</cpu>
```

| mode | 含义 |
| --- | --- |
| `host-passthrough` | 透传宿主机 |
| `host-model` | 尽量匹配 host |
| `custom` | 完全自定 |

## 内存

```xml
<memory unit='KiB'>4194304</memory>
<currentMemory unit='KiB'>2097152</currentMemory>
<memoryBacking>
  <hugepages/>
  <nosharepages/>
  <locked/>
</memoryBacking>
<numatune>
  <memory mode='strict' nodeset='0'/>
  <memnode cellid='0' mode='strict' nodeset='0'/>
</numatune>
```

## 设备

### 磁盘

```xml
<disk type='file' device='disk' snapshot='external'>
  <driver name='qemu' type='qcow2'
          cache='none' io='native'
          queues='4' iothread='1'/>
  <source file='/var/lib/libvirt/images/demo.qcow2' index='1'/>
  <backingStore/>
  <target dev='vda' bus='virtio'/>
  <serial>disk-serial</serial>
  <wwn>0x5000c5006abcdef0</wwn>
  <iotune>
    <read_bytes_sec>104857600</read_bytes_sec>
    <write_iops_sec>1000</write_iops_sec>
  </iotune>
  <shareable/>
</disk>
```

`type`：file / block / network / volume
`device`：disk / cdrom / floppy
`bus`：virtio / ide / scsi / sata / usb / nvme

### 网络

```xml
<interface type='network'>
  <source network='default'/>
  <mac address='52:54:00:11:22:33'/>
  <model type='virtio'/>
  <driver name='vhost' queues='4'/>
  <mtu size='9000'/>
  <link state='up'/>
</interface>
```

| type | 含义 |
| --- | --- |
| `network` | 用 libvirt 网络 |
| `bridge` | 直连 Linux bridge |
| `direct` | macvtap 直连物理网卡 |
| `user` | QEMU user mode |
| `vhostuser` | vhost-user socket |
| `hostdev` | PCI 直通 |

### 显示

```xml
<graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1' keymap='en-us'>
  <listen type='address' address='127.0.0.1'/>
</graphics>

<graphics type='spice' port='5900' tlsPort='5901' autoport='no'>
  <listen type='network' network='default'/>
</graphics>
```

### 控制台

```xml
<console type='pty'>
  <target type='serial' port='0'/>
</console>

<serial type='pty'>
  <target port='0'/>
</serial>
```

## 调度

```xml
<cputune>
  <vcpupin vcpu='0' cpuset='4'/>
  <vcpupin vcpu='1' cpuset='5'/>
  <emulatorpin cpuset='0-3'/>
  <shares>1024</shares>
  <period>100000</period>
  <quota>50000</quota>
  <global_period>100000</global_period>
  <global_quota>200000</global_quota>
</cputune>
```

## 直通

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
  </source>
</hostdev>
```

USB 直通：

```xml
<hostdev mode='subsystem' type='usb'>
  <source>
    <vendor id='0x1234'/>
    <product id='0x5678'/>
  </source>
</hostdev>
```

## 常用命令

```bash
# 定义
virsh define vm.xml

# 启动
virsh start vm

# 编辑
virsh edit vm

# 看 XML
virsh dumpxml vm > vm.xml

# 删定义
virsh undefine vm --remove-all-storage
```
