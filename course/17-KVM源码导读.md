# 17 · KVM 源码导读

> 读 KVM 源码是理解硬件辅助虚拟化的最佳路径。这章给一份「从零开始」的导览。

## 学习目标

- 能找到 KVM 子系统的所有关键文件
- 描述一次 `KVM_RUN` 的内核路径
- 理解 VMCS 在源码里如何被填
- 知道 EPT 缺页处理流程

## 1. 内核源码位置

```
linux/
├── virt/kvm/
│   ├── kvm_main.c       # 通用框架（~3500 行）
│   ├── kvm_mm.h         # 内存管理
│   └── ...
├── arch/x86/kvm/
│   ├── x86.c            # x86 通用入口（~15000 行）
│   ├── mmu/mmu.c        # 内存虚拟化（~5000 行）
│   ├── vmx/vmx.c        # Intel VMX 实现（~10000 行）
│   ├── vmx/vmcs.h       # VMCS 字段宏
│   ├── svm/svm.c        # AMD SVM 实现
│   └── lapic.c          # APIC 虚拟化
├── include/linux/kvm*.h
└── include/uapi/linux/kvm.h  # 用户态 API
```

## 2. 数据结构顶层

### 2.1 `struct kvm`（每 VM）

```c
// include/linux/kvm_host.h
struct kvm {
    spinlock_t mmu_lock;
    struct mutex slots_lock;
    struct kvm_memslots __rcu *memslots[KVM_ADDRESS_SPACE_NUM];
    struct kvm_vcpu *vcpus[KVM_MAX_VCPUS];
    unsigned long nr_vcpus;
    struct kvm_arch arch;        // 架构相关
    // ...
};
```

### 2.2 `struct kvm_vcpu`

```c
struct kvm_vcpu {
    int vcpu_id;
    struct kvm *kvm;
    struct preempt_notifier preempt_notifier;
    struct kvm_run *run;        // 与用户态共享
    struct mutex mutex;
    struct kvm_mmu mmu;
    struct kvm_x86_ops *kvm_x86_ops;  // 关键分发
    // ...
};
```

### 2.3 `struct kvm_x86_ops`

```c
// arch/x86/kvm/x86.c
struct kvm_x86_ops {
    int (*hardware_enable)(void);
    void (*hardware_disable)(void);
    int (*vcpu_create)(struct kvm_vcpu *vcpu);
    void (*vcpu_free)(struct kvm_vcpu *vcpu);
    int (*vcpu_reset)(struct kvm_vcpu *vcpu, u64 init_event);
    void (*vcpu_load)(struct kvm_vcpu *vcpu, int cpu);
    void (*vcpu_put)(struct kvm_vcpu *vcpu);
    int (*vcpu_run)(struct kvm_vcpu *vcpu);
    int (*handle_exit)(struct kvm_vcpu *vcpu);
    int (*set_msr)(struct kvm_vcpu *vcpu, struct msr_data *msr);
    int (*get_msr)(struct kvm_vcpu *vcpu, struct msr_data *msr);
    // ... 几十个
};
```

## 3. 启动流程

### 3.1 kvm_init

```c
// virt/kvm/kvm_main.c
static int __init kvm_init(void)
{
    // 1. 注册字符设备 → /dev/kvm
    misc_register(&kvm_dev);

    // 2. 注册 cpuhp 回调（CPU 热插拔）
    cpuhp_setup_state_nocalls(CPUHP_AP_KVM_STARTING,
                              "kvm/cpu:starting",
                              kvm_starting_cpu, kvm_cpu_dying);

    // 3. 注册架构 ops
    r = kvm_arch_init();

    return r;
}
```

### 3.2 架构初始化

```c
// arch/x86/kvm/x86.c
int kvm_arch_init(void)
{
    // 1. 注册 perf KVM 子系统
    perf_register_guest_info_callbacks(...);

    // 2. 检查 CPU
    if (boot_cpu_has(X86_FEATURE_VMX))
        kvm_x86_ops = &vmx_x86_ops;
    else if (boot_cpu_has(X86_FEATURE_SVM))
        kvm_x86_ops = &svm_x86_ops;
    else
        return -EOPNOTSUPP;

    return kvm_x86_ops->hardware_setup();
}
```

### 3.3 vmx_init（kvm-intel.ko）

```c
// arch/x86/kvm/vmx/vmx.c
static int __init vmx_init(void)
{
    // 1. 检查 VMX 支持
    if (!cpu_has_vmx()) return -EOPNOTSUPP;

    // 2. 分配 VMXON 区
    vmcs_conf = &vmcs_config;
    adjust_vmx_controls(...);

    // 3. 注册 ops
    kvm_x86_ops = &vmx_x86_ops;
    kvm_init();
    return 0;
}
module_init(vmx_init);
```

## 4. /dev/kvm 的 file_operations

```c
// virt/kvm/kvm_main.c
static struct file_operations kvm_chardev_ops = {
    .unlocked_ioctl = kvm_device_ioctl,
    .mmap = kvm_device_mmap,
    // ...
};

static const struct file_operations kvm_vm_fops = {
    .release = kvm_vm_release,
    .ioctl = kvm_vm_ioctl,
    // ...
};

static const struct file_operations kvm_vcpu_fops = {
    .release = kvm_vcpu_release,
    .unlocked_ioctl = kvm_vcpu_ioctl,
    .mmap = kvm_vcpu_mmap,
    // ...
};
```

三套 fops：

- `/dev/kvm` → `kvm_chardev_ops`（创 VM）
- VM fd → `kvm_vm_fops`（创 vCPU、设内存）
- vCPU fd → `kvm_vcpu_fops`（KVM_RUN、读寄存器）

## 5. 一次 VM 创建

```c
// virt/kvm/kvm_main.c
static long kvm_device_ioctl(struct file *filp, unsigned int ioctl,
                              unsigned long arg)
{
    switch (ioctl) {
    case KVM_CREATE_VM:
        return kvm_dev_ioctl_create_vm(arg);
    }
}

static int kvm_dev_ioctl_create_vm(unsigned long type)
{
    // 1. 分配 struct kvm
    kvm = kvm_create_vm(type);
    //    → kvm_arch_init_vm
    //    → hardware_enable
    //    → kvm_mmu_init

    // 2. fdinstall
    file = anon_inode_getfile("kvm-vm", &kvm_vm_fops, kvm, O_RDWR);
    fd = get_unused_fd_flags(O_RDWR);

    // 3. 返回 fd
    return fd;
}
```

## 6. 创 vCPU

```c
// virt/kvm/kvm_main.c
static int kvm_vm_ioctl_create_vcpu(struct kvm *kvm, u32 id)
{
    // 1. 分配
    vcpu = kvm_arch_vcpu_create(kvm, id);

    // 2. 注册
    // file = anon_inode_getfile("kvm-vcpu", &kvm_vcpu_fops, vcpu, O_RDWR);

    // 3. 启动 vCPU 线程（如果 enabled）
    return kvm_arch_vcpu_create_finished(vcpu);
}
```

```c
// arch/x86/kvm/x86.c
struct kvm_vcpu *kvm_arch_vcpu_create(struct kvm *kvm, unsigned int id)
{
    // 1. 分配
    vcpu = kmem_cache_zalloc(kvm_vcpu_cache, GFP_KERNEL_ACCOUNT);

    // 2. 架构相关
    r = kvm_x86_ops->vcpu_create(vcpu);

    // 3. 初始化 vCPU 字段
    vcpu->arch.cr3 = 0;
    // ...

    return vcpu;
}
```

## 7. KVM_RUN 主循环

### 7.1 ioctl 入口

```c
// virt/kvm/kvm_main.c
static int kvm_vcpu_ioctl(struct file *filp, unsigned int ioctl,
                          unsigned long arg)
{
    switch (ioctl) {
    case KVM_RUN:
        return kvm_arch_vcpu_ioctl_run(vcpu);
    }
}
```

### 7.2 vCPU 入口

```c
// arch/x86/kvm/x86.c
int kvm_arch_vcpu_ioctl_run(struct kvm_vcpu *vcpu)
{
    for (;;) {
        // 1. 让出 CPU
        kvm_vcpu_block(vcpu);

        // 2. 跑 vCPU
        kvm_x86_ops->vcpu_run(vcpu);  // ← vmx_vcpu_run 或 svm_vcpu_run

        // 3. 处理 exit
        r = kvm_x86_ops->handle_exit(vcpu);  // ← vmx_handle_exit

        // 4. 根据结果决定
        if (r <= 0)
            return r;
    }
}
```

### 7.3 vmx_vcpu_run（Intel）

```c
// arch/x86/kvm/vmx/vmx.c
static int vmx_vcpu_run(struct kvm_vcpu *vcpu)
{
    // 1. 加载 host state 到 VMCS host area
    vmx_vcpu_load(vcpu, cpu);

    // 2. 加载 guest state
    vmx_vcpu_put(vcpu);

    // 3. 关键：VM entry
    asm volatile(
        "push %%" _ASM_BP "%%\n"
        "mov %%rsp, %0\n"
        "push %%" _ASM_BP "%%\n"
        ...
        "vmx_restore_regs %1\n"
        "jmp vmx_return\n"
        ...
        : : "r"(&vcpu->arch.user_rsp),
            ASM_VMX_VMRESUME
    );

    // 4. VM exit 后会回到这里
    return 1;
}
```

### 7.4 vmx_handle_exit

```c
// arch/x86/kvm/vmx/vmx.c
static int vmx_handle_exit(struct kvm_vcpu *vcpu)
{
    u32 exit_reason = vmx_get_exit_reason(vcpu);

    // 1. 快速路径
    if (exit_reason < kvm_vmx_max_exit_handlers &&
        kvm_vmx_exit_handlers[exit_reason])
        return kvm_vmx_exit_handlers[exit_reason](vcpu);

    // 2. 通用路径
    return kvm_emulate_instruction(vcpu);
}
```

几十个 handler：

```c
// arch/x86/kvm/vmx/vmx.c
static int (*kvm_vmx_exit_handlers[])(struct kvm_vcpu *vcpu) = {
    [EXIT_REASON_EXCEPTION_NMI]           = handle_exception_nmi,
    [EXIT_REASON_EXTERNAL_INTERRUPT]      = handle_external_interrupt,
    [EXIT_REASON_IO_INSTRUCTION]          = handle_io,
    [EXIT_REASON_CR_ACCESS]               = handle_cr,
    [EXIT_REASON_CPUID]                   = handle_cpuid,
    [EXIT_REASON_EPT_VIOLATION]           = handle_ept_violation,
    [EXIT_REASON_HLT]                     = handle_halt,
    [EXIT_REASON_INVD]                    = handle_invd,
    // ...
};
```

## 8. EPT 缺页处理

```c
// arch/x86/kvm/mmu/mmu.c
static int handle_ept_violation(struct kvm_vcpu *vcpu)
{
    gpa_t gpa = vmcs_read64(GUEST_PHYSICAL_ADDRESS);
    u64 error_code = vmcs_read64(EXIT_QUALIFICATION);

    // 1. 找对应的 memory slot
    slot = kvm_vcpu_gfn_to_memslot(vcpu, gpa_to_gfn(gpa));

    // 2. 找 HVA
    hva = gfn_to_hva_memslot(slot, gpa_to_gfn(gpa));

    // 3. page fault 处理
    return kvm_tdp_page_fault(vcpu, gpa, error_code, hva);
}

static int kvm_tdp_page_fault(struct kvm_vcpu *vcpu, gpa_t gpa, u64 error_code,
                              unsigned long hva)
{
    // 1. 分配 EPT page table entry
    // 2. 映射 HPA
    // 3. 填 EPT
    return direct_page_fault(vcpu, gpa, error_code, hva);
}
```

## 9. VMCS 编程

### 9.1 VMCS 字段宏

```c
// arch/x86/kvm/vmx/vmcs.h
#define VMCS_FIELD(number, name, type, ...) \
    FIELD(number, name, type)
enum vmcs_field {
    GUEST_ES_SELECTOR = 0x00000800,
    GUEST_CS_SELECTOR = 0x00000802,
    // ... 几百个
    HOST_ES_SELECTOR = 0x00000c00,
    // ...
};
```

### 9.2 填 VMCS

```c
// arch/x86/kvm/vmx/vmx.c
static void vmx_vcpu_reset(struct kvm_vcpu *vcpu, u64 init_event)
{
    // 1. alloc VMCS
    vmx->vmcs01.vmcs = alloc_vmcs();

    // 2. 加载到 CPU
    vmcs_load(vmx->vmcs01.vmcs);

    // 3. 清空 VMCS
    vmcs_write16(GUEST_CS_SELECTOR, 0);
    vmcs_write32(GUEST_ESP, 0);
    // ...

    // 4. 配控制字段
    vmcs_set_control(PIN_BASED_VM_EXEC_CONTROL, ...);
    vmcs_set_control(CPU_BASED_VM_EXEC_CONTROL, ...);
    // ...

    // 5. 配 host state
    vmcs_writel(HOST_CR0, ...);
    // ...
}
```

## 10. 中断虚拟化

### 10.1 中断注入

```c
// arch/x86/kvm/x86.c
int kvm_queue_interrupt(struct kvm_vcpu *vcpu, u32 irq)
{
    // 把中断放进 vcpu->arch.interrupt_queue
    // 在下次 VM entry 时由硬件注入
}

void kvm_inject_irq(struct kvm_vcpu *vcpu, u32 irq)
{
    // 注入硬件中断
    kvm_queue_interrupt(vcpu, irq);
}
```

### 10.2 APICv（硬件辅助）

```c
// arch/x86/kvm/vmx/vmx.c
static void vmx_deliver_posted_interrupt(struct kvm_vcpu *vcpu, int vector)
{
    // 用 posted-interrupt 机制，避免 VM exit
    pi_set_on(vmx->pi_desc);
}
```

## 11. 调试 KVM

### 11.1 trace

```bash
cd /sys/kernel/debug/tracing
echo 1 > events/kvm/enable
cat trace | head -50
# 输出 kvm_exit / kvm_entry 等事件
```

### 11.2 kvm_stat

详见 lab10。

### 11.3 gdb

```bash
# 主机 kgdboc 配置
echo ttyS0,115200 > /sys/module/kgdboc/parameters/kgdboc
echo g > /proc/sysrq-trigger

# 另一台连
gdb vmlinux
(gdb) target remote /dev/ttyS0
(gdb) b handle_ept_violation
(gdb) c
```

## 12. 推荐阅读顺序

| 文件 | 推荐理由 |
| --- | --- |
| `virt/kvm/kvm_main.c` | 总入口，ioctl 分发 |
| `arch/x86/kvm/x86.c` | x86 通用 |
| `arch/x86/kvm/vmx/vmx.c` | Intel VMX 实现 |
| `arch/x86/kvm/mmu/mmu.c` | 内存虚拟化 |
| `include/uapi/linux/kvm.h` | API 定义 |

## 13. 实战操作

[`labs/lab10-debug-kernel.md`](../labs/lab10-debug-kernel.md)

## 14. 小结

- KVM = `virt/kvm` + `arch/x86/kvm`
- `kvm_x86_ops` 抽象 Intel/AMD
- `kvm_vcpu_ioctl(KVM_RUN)` 是主循环入口
- VMCS / VMCB 是 KVM 与硬件的协议
- EPT 缺页走 `handle_ept_violation` → `kvm_tdp_page_fault`

## 15. 思考题

1. KVM_RUN 一次 ioctl 平均耗时多少？跟 TLB miss 有关吗？
2. vmx_vcpu_run 用汇编实现的目的是什么？
3. EPT 缺页会不会触发 VM exit 风暴？
4. APICv 跟传统 LAPIC 模拟的 latency 差多少？

## 16. 参考资料

- [`refs/learn-kvm/docs/KVM内核模块源码分析/KVM内核模块源码分析.md`](../refs/learn-kvm/docs/KVM内核模块源码分析/KVM内核模块源码分析.md)
- [`refs/learn-kvm/docs/KVM内核模块源码分析/kernel-2.6-KVM源码目录树分析.md`](../refs/learn-kvm/docs/KVM内核模块源码分析/kernel-2.6-KVM源码目录树分析.md)
- [`refs/learn-kvm/docs/KVM内核模块源码分析/kernel-4.2-KVM源码目录树分析.md`](../refs/learn-kvm/docs/KVM内核模块源码分析/kernel-4.2-KVM源码目录树分析.md)
- [`refs/learn-kvm/docs/KVM内核模块源码分析/KVM源码分析-基本工作原理.md`](../refs/learn-kvm/docs/KVM内核模块源码分析/KVM源码分析-基本工作原理.md)
- [`refs/learn-kvm/docs/KVM内核模块源码分析/KVM的初始化流程.md`](../refs/learn-kvm/docs/KVM内核模块源码分析/KVM的初始化流程.md)
- [`refs/learn-kvm/docs/KVM内核模块源码分析/KVM源码分析-虚拟机的创建与运行.md`](../refs/learn-kvm/docs/KVM内核模块源码分析/KVM源码分析-虚拟机的创建与运行.md)
- [`refs/learn-kvm/docs/KVM内核模块源码分析/KVM源码分析-CPU虚拟化.md`](../refs/learn-kvm/docs/KVM内核模块源码分析/KVM源码分析-CPU虚拟化.md)
