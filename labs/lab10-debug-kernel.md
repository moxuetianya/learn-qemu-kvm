# Lab 10 · 调试 KVM 内核模块

> **难度**：★★★★★  
> **前置**：能编译 Linux 内核、有 gdb / ftrace 基础  
> **预计时间**：2 小时

## 目标

- 编译带 debug 信息的内核 + KVM 模块
- 用 gdb 跟 VM entry / VM exit
- 用 ftrace / bpftrace 看 VM exit 原因分布
- 读 KVM 源码并对照实验验证

## 实验步骤

### 1. 准备带调试信息的内核

```bash
# 推荐 Debian / Ubuntu，因为有现成的 debuginfo 包
sudo apt build-dep linux linux-image-$(uname -r)

apt source linux
cd linux-*/    # 解出来的源码目录

# 打开 KVM 调试选项（用 menuconfig 找 KVM 相关）
make menuconfig
# → Virtualization  →  <M> KVM
#                   →  <M> KVM for Intel/AMD processors
# → Kernel hacking  →  [*] KGDB
#                            [*] BUG in spinlocks / mutexes...
#                            [*] Verbose BUG
#                   →  Generic Kernel Debugging Instruments
#                            [*] Magic SysRq key

fakeroot make -j$(nproc) deb-pkg LOCALVERSION=-kvm-lab
sudo dpkg -i ../linux-*.deb
```

### 2. 加载并验证

```bash
sudo modprobe kvm
sudo modprobe kvm_intel
lsmod | grep kvm
dmesg | grep -i kvm
```

### 3. 启动 VM + 看 VM exit

```bash
# 起一个 VM，运行一段时间
qemu-system-x86_64 -name kvmtest -m 1024 -smp 2 \
    -machine accel=kvm -cpu host \
    -drive file=lab03.qcow2,format=qcow2,if=virtio \
    -nographic &

# 装 kvm_stat
sudo apt install kvmstat
# 或自己 git clone https://github.com/torvalds/linux/tools/kvm/kvm_stat
sudo kvm_stat
```

`kvm_stat` 输出：

```
Event                                        Total %Total CurAvg/s
exit                                       1234567  100.00     5678
ept_misconfig                                   12    0.00        0
pause_intercept                                234    0.01        1
irq_injection                                12345    1.00       56
...
```

观察：

- `mmio` / `pio` 数量（设备访问）
- `halt` / `pause_intercept`（CPU 空闲）
- `apic` / `irq_window`（中断）

### 4. 抓一个 VM exit 现场

#### 4.1 用 bpftrace

```bash
sudo bpftrace -e '
kprobe:kvm_vmx_vcpu_run {
    @start[tid] = nsecs;
}
kretprobe:kvm_vmx_vcpu_run /@start[tid]/ {
    $dur = nsecs - @start[tid];
    @hist = hist($dur);
    delete(@start[tid]);
}
'

# 跑一会儿 Ctrl+C
# 输出 latency 直方图（μs）
```

#### 4.2 看具体 VM exit reason

```bash
sudo bpftrace -e '
kprobe:kvm_vmx_handle_exit {
    printf("exit_reason=%d\n", arg1->exit_reason);
}
'
```

### 5. GDB 跟源码

#### 5.1 用 kgdb

```bash
# sysrq 触发 kgdb
echo g | sudo tee /proc/sysrq-trigger

# 另一台机器连
gdb vmlinux
(gdb) target remote <host>:1234
(gdb) b vmx_vcpu_run
(gdb) c
```

#### 5.2 直接 gdb 跟 qemu

```bash
# 起 qemu 时加 -s -S
qemu-system-x86_64 -s -S ...    # -s 等价 -gdb tcp::1234  -S 等价启动时停

# 另一终端
gdb qemu-system-x86_64
(gdb) target remote :1234
(gdb) b kvm_cpu_exec
(gdb) c
```

跟到 `kvm_cpu_exec`，看它调 ioctl(`KVM_RUN`) → 进 KVM → 等 VM exit → 处理。

### 6. 读 KVM 源码

```bash
# 找到 KVM 子系统入口
find linux -name 'kvm_main.c'
linux/arch/x86/kvm/x86.c        # 主入口
linux/arch/x86/kvm/vmx/vmx.c    # Intel 实现
linux/arch/x86/kvm/svm/svm.c    # AMD 实现
linux/virt/kvm/kvm_main.c       # 通用入口
```

#### 关键函数清单

| 函数 | 干什么 |
| --- | --- |
| `kvm_init` | 初始化子系统 |
| `kvm_arch_init` | 注册架构 ops |
| `kvm_vm_ioctl_create_vcpu` | 创建 vCPU |
| `kvm_vcpu_ioctl_run` | 客户机执行入口 |
| `vcpu_run` (vcpu_load) | 上下文切换 |
| `handle_exit` | 分发 exit 处理 |

### 7. 在源码加打印重编

```c
// linux/arch/x86/kvm/vmx/vmx.c 的 vmx_handle_exit 前加：
pr_info("KVM: exit_reason=%d\n", exit_reason);
```

重编模块：

```bash
make modules
sudo cp arch/x86/kvm/kvm.ko /lib/modules/$(uname -r)/kernel/
sudo cp arch/x86/kvm/kvm-intel.ko /lib/modules/$(uname -r)/kernel/
sudo rmmod kvm_intel
sudo rmmod kvm
sudo modprobe kvm
sudo modprobe kvm_intel
```

启动 VM，看 dmesg。

## 输出记录

1. `kvm_stat` 输出（哪种 exit 最多？）
2. bpftrace 测得的 VM entry 到 exit 平均延迟
3. 跟源码时哪个函数最复杂？

## 进阶方向

- 用 perf 看 KVM 内部热点
- 给某个 exit reason 写 perfetto tracepoint
- 修改 VMCS 字段看行为变化（实验用，不要在生产）

## 下一步

回到 [`course/17-KVM源码导读.md`](../course/17-KVM源码导读.md) 深入阅读。
