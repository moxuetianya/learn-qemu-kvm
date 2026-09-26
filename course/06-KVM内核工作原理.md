# 06 · KVM 内核工作原理

> 这一章把 KVM 当作「Linux 内核的一个子系统」来拆。

## 学习目标

- 理解 KVM 在 Linux 内核中的位置
- 能解释 `/dev/kvm` 是什么
- 知道一次 VM entry/exit 在内核里走过的函数
- 区分 KVM API 和硬件虚拟化

## 1. KVM 在内核里的角色

```
Linux 内核
 ├── 进程调度（CFS）
 ├── 内存管理（MM）
 ├── 网络协议栈（TCP/IP）
 ├── 文件系统（VFS）
 ├── ...
 └── KVM 子系统（arch/x86/kvm, virt/kvm）
        ├── kvm.ko               # 通用框架
        ├── kvm-intel.ko (vmx)   # Intel 后端
        └── kvm-amd.ko (svm)     # AMD 后端
```

KVM = Linux 内核里的一个**字符设备** + **子系统**。

- 字符设备：`/dev/kvm` —— 用户态通过它跟内核交互
- 子系统：提供 ioctl 接口、内存管理、调度集成

## 2. /dev/kvm 的本质

```bash
ls -l /dev/kvm
# crw-rw---- 1 root kvm 10, 232 ... /dev/kvm
# 主 10 = misc 设备类，次 232
```

- 每个进程（QEMU）打开 `/dev/kvm` 一次 = 一个 KVM instance
- 多个 QEMU 进程 → 多个独立 KVM instance
- 通过 ioctl 创建 VM、vCPU、注册内存等

## 3. 关键 ioctl

```c
// 简化的用户态流程（QEMU 源码里的 kvm-all.c）
int kvm_fd = open("/dev/kvm", O_RDWR);

// 1. 检查 KVM 能力
struct kvm_cap cap = { .cap = KVM_CAP_MAX_VCPUS };
ioctl(kvm_fd, KVM_CHECK_EXTENSION, ...);

// 2. 创建 VM
int vm_fd = ioctl(kvm_fd, KVM_CREATE_VM, 0);

// 3. 创建 vCPU（每个 vCPU 一个线程）
int vcpu_fd = ioctl(vm_fd, KVM_CREATE_VCPU, vcpu_id);

// 4. 分配 vCPU mmap 区（共享内存，保存 vCPU 状态）
void *vcpu_run = mmap(NULL, vcpu_size, PROT_READ|PROT_WRITE,
                      MAP_SHARED, vcpu_fd, 0);

// 5. 主循环
while (running) {
    ioctl(vcpu_fd, KVM_RUN, 0);   // 进入 VM entry，等 VM exit
    struct kvm_run *run = vcpu_run;
    switch (run->exit_reason) {
        case KVM_EXIT_IO:        handle_io(run->io); break;
        case KVM_EXIT_MMIO:      handle_mmio(run->mmio); break;
        case KVM_EXIT_HLT:       break;  // 让出 CPU
        case KVM_EXIT_SHUTDOWN:  return;
        // ... 几十种
    }
}
```

## 4. KVM 数据结构

### 4.1 顶层

```c
struct kvm {
    spinlock_t mmu_lock;
    struct mutex slots_lock;
    struct kvm_memslots __rcu *memslots;  // 客户机内存
    struct kvm_vcpu *vcpus[KVM_MAX_VCPUS];
    unsigned long nr_vcpus;
    // ... 每 VM 状态
};
```

每个 `struct kvm` **代表一个虚拟机**。多个 VM 在 host 里就是多个 `struct kvm` 指针。

### 4.2 vCPU

```c
struct kvm_vcpu {
    int vcpu_id;
    struct kvm *kvm;
    struct kvm_run *run;          // 与用户态共享
    struct mutex mutex;
    struct kvm_mmu mmu;
    struct kvm_x86_ops *kvm_x86_ops;  // 架构相关 ops
    // ... 上千行
};
```

### 4.3 内存 slot

```c
struct kvm_memory_slot {
    gfn_t base_gfn;     // Guest Frame Number 起点
    unsigned long npages;
    unsigned long *dirty_bitmap;
    struct kvm_userspace_memory_region userspace_addr;
    // ...
};
```

## 5. KVM 初始化流程

```c
// virt/kvm/kvm_main.c
static int __init kvm_init(void)
{
    // 1. 注册 misc 设备 → /dev/kvm
    misc_register(&kvm_dev);

    // 2. 注册 vcpu 子系统（debugfs、PMU 等）
    kvm_vcpu_cache = kmem_cache_create("kvm_vcpu", ...);

    // 3. 注册架构 ops（由 kvm-intel / kvm-amd 在初始化时填充）
    r = kvm_arch_init();

    // 4. 注册 cpuhp 回调（CPU 热插拔）
    cpuhp_setup_state_nocalls(CPUHP_AP_KVM_STARTING, "kvm/cpu:starting",
                              kvm_starting_cpu, kvm_cpu_dying);
    return 0;
}
```

## 6. 一次 VM 运行的内核旅程

### 6.1 QEMU 进程视角

```
QEMU (用户态)
  │
  │  ioctl(KVM_RUN)
  ▼
内核 kvm_vcpu_ioctl(vcpu_fd, KVM_RUN)
  │
  │  vcpu_load(vcpu)
  │  kvm_x86_ops->vcpu_run(vcpu)   ← 架构相关
  │
  ▼
  [ VM ENTRY ]  ← 硬件动作：CPU 切换到 non-root 模式
  [ 客户机跑 ... ]
  [ VM EXIT ]   ← 硬件动作：保存 Guest state 到 VMCS
  │
  ▼
  r = handle_exit(vcpu)   ← kvm_x86_ops->handle_exit
  │
  │  返回 kvm_run->exit_reason
  ▼
QEMU 处理 exit，根据 reason 决定下一步：
  - 是 I/O → 调用对应模拟函数
  - 是 HLT → 调 ioctl(KVM_RUN) 再次 VM entry
  - 是 shutdown → 退出循环
```

### 6.2 kvm_x86_ops 的两面性

```c
// arch/x86/kvm/x86.c
struct kvm_x86_ops *kvm_x86_ops;  // 全局变量

// arch/x86/kvm/vmx/vmx.c  (kvm-intel.ko)
static struct kvm_x86_ops vmx_x86_ops = {
    .hardware_enable = vmx_hardware_enable,
    .hardware_disable = vmx_hardware_disable,
    .vcpu_create = vmx_create_vcpu,
    .vcpu_run = vmx_vcpu_run,
    .handle_exit = vmx_handle_exit,
    // ...
};
module_init(vmx_init);   // 把 vmx_x86_ops 赋给全局

// arch/x86/kvm/svm/svm.c  (kvm-amd.ko)
static struct kvm_x86_ops svm_x86_ops = { ... };
module_init(svm_init);
```

**一份代码（kvm.ko + x86.c） + 两套实现（vmx / svm） = 支持 Intel + AMD**。

## 7. KVM 的内存虚拟化

### 7.1 EPT 管理

```c
// virt/kvm/kvm_main.c
int kvm_set_memory_region(struct kvm *kvm,
                          struct kvm_userspace_memory_region *mem)
{
    // 1. 找到或创建 kvm_memory_slot
    // 2. 调用 kvm_arch_commit_memory_region
    //    → kvm_mmu_topup_memory_cache
    //    → kvm_mmu_create
    //    → kvm_mmu_setup
}
```

### 7.2 EPT 缺页处理

```c
// arch/x86/kvm/mmu/mmu.c
static int handle_ept_violation(struct kvm_vcpu *vcpu)
{
    gpa_t gpa = vmcs_read64(GUEST_PHYSICAL_ADDRESS);
    // 1. 查 slot 找 HVA
    hva = gfn_to_hva(vcpu->kvm, gpa_to_gfn(gpa));
    // 2. map 用户态页到 EPT
    r = kvm_tdp_page_fault(vcpu, gpa, error_code, ...);
    // 3. 重新 VM entry
    return r;
}
```

## 8. KVM 与 QEMU 的边界

| 动作 | 谁做 |
| --- | --- |
| 调度 vCPU 线程 | Linux CFS |
| 客户机 CPU 模式切换 | KVM (VMX/SVM) |
| 客户机内存翻译 | KVM (EPT) |
| 客户机磁盘 I/O | QEMU + Linux AIO / virtio |
| 客户机网络 | QEMU tap + Linux 网络栈 |
| 客户机 BIOS/UEFI | QEMU（SeaBIOS / OVMF） |
| 客户机中断注入 | KVM（硬件辅助） |

> QEMU 是「壳」，KVM 是「心脏」。

## 9. KVM API 子系统

KVM 不只有 CPU/内存虚拟化，还有：

| 子系统 | 用途 |
| --- | --- |
| `KVM_IRQCHIP` | 模拟 PIC / IOAPIC / LAPIC |
| `KVM_IRQFD` | 把宿主机中断注入客户机 |
| `KVM_IOEVENTFD` | 客户机 MMIO 触发宿主机 eventfd |
| `KVM_SET_USER_MEMORY_REGION` | 注册客户机内存 |
| `KVM_GET/SET_MSRS` | 模型寄存器 |
| `KVM_GET/SET_CPUID2` | CPUID 透传 |
| `KVM_GET/SET_LAPIC` | LAPIC 状态 |
| `KVM_SET_GSI_ROUTING` | 中断路由 |
| `KVM_NR_IRQCHIPS` | … |

> 这就是为什么 vhost-net / vhost-vsock / VFIO 都能跟 KVM 配合——它们共享同一套 ioctl。

## 10. 优劣对比：KVM 在内核里还是用户态

| 设计 | 优 | 劣 |
| --- | --- | --- |
| KVM 在内核 | 直接调硬件；与 Linux 调度/内存深度集成 | 内核代码膨胀 |
| KVM 在用户态 | 灵活、易调试 | 每次 VM exit 都要内核↔用户态切换 |

KVM 选了第一种——这是它性能好的核心原因。

## 11. 小结

- KVM = Linux 内核的「虚拟化子系统」+ 字符设备 `/dev/kvm`
- 一台 VM = 一个 `struct kvm`
- QEMU 通过 ioctl 把控制权交给 KVM
- `kvm_x86_ops` 抽象了 Intel/AMD 差异
- 真正的 CPU/内存虚拟化都在内核态做

## 12. 思考题

1. 为什么把 KVM 放进 Linux 内核而不是单独一个 hypervisor？
2. `KVM_RUN` ioctl 是阻塞的还是非阻塞的？
3. KVM 关闭时会发生什么？QEMU 进程退出 → VM 自动停吗？
4. `kvm_x86_ops` 一共多少个函数指针？为啥这么设计？

## 13. 参考资料

- [`refs/learn-kvm/docs/KVM基本结构/KVM基本结构.md`](../refs/learn-kvm/docs/KVM基本结构/KVM基本结构.md)
- [`refs/learn-kvm/docs/KVM工作原理/KVM工作原理.md`](../refs/learn-kvm/docs/KVM工作原理/KVM工作原理.md)
- [`refs/learn-kvm/docs/KVM内核模块源码分析/KVM源码分析-基本工作原理.md`](../refs/learn-kvm/docs/KVM内核模块源码分析/KVM源码分析-基本工作原理.md)
- [`refs/learn-kvm/docs/KVM内核模块源码分析/KVM源码分析-虚拟机的创建与运行.md`](../refs/learn-kvm/docs/KVM内核模块源码分析/KVM源码分析-虚拟机的创建与运行.md)

---

⬅️ 上一章：[05 · 第一个虚拟机实战](05-第一个虚拟机实战.md) · [📚 返回目录](../INDEX.md) · 下一章 ➡️：[07 · 存储虚拟化详解](07-存储虚拟化详解.md)
