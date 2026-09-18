# Lab 01 · 检查 CPU 硬件虚拟化支持

> **难度**：★  
> **前置**：任意 Linux x86_64 主机（物理机或虚拟机）  
> **预计时间**：5 分钟

## 目标

确认你的机器能不能跑 KVM。课程的所有实验都依赖这一步。

## 实验步骤

### 1. 运行一键检查脚本

```bash
bash labs/scripts/check-vt.sh
```

期望看到：

```
[2] 硬件辅助虚拟化 (VT-x / AMD-V)
  ✅ 检测到 vmx (Intel VT-x)        # 或 svm (AMD-V)
[3] 二阶段页表 (EPT / NPT)
  ✅ 检测到 ept (Intel EPT)         # 或 npt
[8] /dev/kvm 设备文件
  ✅ 当前用户可读写
```

如果全部 ✅，跳到 lab02。

### 2. 如果没检测到 VT-x / SVM

进入 BIOS：

- Intel 平台找：`Advanced → CPU Configuration → Intel Virtualization Technology` 设为 `Enabled`
- AMD 平台找：`SVM Mode` 设为 `Enabled`
- 注意部分机器叫 `VT-x`、`Intel VMX`、`Virtualization`、`SVM` 等

部分笔记本默认关闭，桌面 BIOS 里有时藏在 `Security` 或 `OC` 子菜单。

### 3. 如果有 vmx 但没 /dev/kvm

```bash
# 内核模块未加载
sudo modprobe kvm
sudo modprobe kvm_intel    # 或 kvm_amd

# 让开机自动加载
echo 'kvm' | sudo tee /etc/modules-load.d/kvm.conf
echo 'kvm_intel' | sudo tee -a /etc/modules-load.d/kvm.conf   # 或 kvm_amd

# 检查
lsmod | grep kvm
ls -l /dev/kvm
```

### 4. 如果 /dev/kvm 当前用户没权限

```bash
sudo usermod -aG kvm $USER
# 重新登录或
newgrp kvm
# 验证
ls -l /dev/kvm
# crw-rw---- 1 root kvm 10, 232 ... 应该看到组是 kvm
```

### 5. 如果是嵌套虚拟化（VM 里跑 VM）

要确认 KVM 模块 nested 参数已开：

```bash
# 主机
cat /sys/module/kvm_intel/parameters/nested   # 应为 Y 或 1
cat /sys/module/kvm_amd/parameters/nested

# 若没开
echo 1 | sudo tee /sys/module/kvm_intel/parameters/nested
# 持久化：在 /etc/modprobe.d/kvm.conf 中加
# options kvm_intel nested=1
```

云厂商默认通常不开，AWS / GCP 大机型可以手动开。

## 输出记录

把你的检查脚本输出贴到 lab 报告里，并回答：

1. CPU 是 Intel 还是 AMD？
2. BIOS 里 VT-x / SVM 开关原本是开还是关？
3. /dev/kvm 当前用户能直接读写吗？
4. 如果是嵌套虚拟化，nested 是开还是关？

## 下一步

[Lab 02 - 安装 QEMU + KVM + libvirt](lab02-install-qemu-kvm.md)
