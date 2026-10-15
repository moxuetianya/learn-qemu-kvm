# 20 · QEMU 启动虚拟机全流程

> 16 章给了张地图，这章带你从 `main()` 走到第一条客户机指令真正执行。读完你会知道
> 「敲下回车后，QEMU 到底按什么顺序干了哪些事」。

## 学习目标

- 能用一句话说清 QEMU 进程里有哪几类线程、各自干什么
- 能背出 `qemu_init()` 的五个阶段：解析 → 选机型 → 建对象 → 加载固件 → 起 vCPU
- 能在源码里定位固件加载、内存映射、`KVM_RUN` 三个关键点
- 会用 `-S` / `-d` / `info qtree` 亲手验证启动顺序

## 1. 先建立心智模型：QEMU 进程里跑着谁

启动一台 VM 时，宿主机上只有一个 `qemu-system-x86_64` 进程，但它内部有**多条线程**：

```
qemu-system-x86_64 (一个进程)
├── main 线程          ← 事件循环：VNC、monitor、定时器、迁移、异步 IO 完成回调
├── vCPU 线程 × N      ← 每个 vCPU 一条，反复 KVM_RUN（或 TCG 执行）
├── iothread × M       ← 可选，把磁盘/网卡的后端 IO 挪出 main 线程
└── 其它            ← RCU、migration、VNC 等按需创建
```

**关键认知**：客户机指令不是在 main 线程里执行的，是在 vCPU 线程里执行的。
main 线程负责「接待」，vCPU 线程负责「干活」，两者通过事件循环 + 信号/IPI 协调。

```
        ┌──────────────── main 线程 ────────────────┐
        │  qemu_main_loop()                          │
        │    └─ main_loop_wait()  ← poll/epoll       │
        │         处理 fd 事件、定时器、BH、迁移      │
        └───────────────┬───────────────────────────┘
                        │ 唤醒 / 暂停 / 注入中断
        ┌───────────────▼───────────────────────────┐
        │  vCPU 线程（每个 vCPU 一条）                │
        │    while (1) kvm_cpu_exec(cpu)             │
        │        └─ ioctl(fd, KVM_RUN)  ← 真正执行    │
        └───────────────────────────────────────────┘
```

## 2. 全景时序：从 main() 到第一条客户机指令

下面这张图是**简化示意**（函数名真实，但省掉了错误分支和次要调用），
记住 5 个阶段即可：

```
main()                                 [softmmu/main.c]
 │
 ├─ qemu_init(argc, argv)              [softmmu/vl.c]  ← 99% 的工作都在这
 │   │
 │   ├─ ① 初始化 & 解析命令行
 │   │     qemu_init_main_loop()        建 AioContext / 主循环
 │   │     module_call_init(...)        trace/opts 等模块
 │   │     qemu_opts_parse...           -machine -cpu -m -drive -device ...
 │   │
 │   ├─ ② 选机型 & 建 QOM 对象
 │   │     select_machine()             q35? i440fx? microvm?
 │   │     object_new(TYPE_Q35_MACHINE)
 │   │     configure_accelerators()     kvm / tcg
 │   │
 │   ├─ ③ 建机器：machine_run_board_init()   [hw/core/machine.c]
 │   │     mc->init()                   → pc_q35_init()：CPU、RAM、芯片组
 │   │     qdev_realize(...)            每个设备"上电"
 │   │     固件加载 & reset vector       OVMF / SeaBIOS 就位
 │   │
 │   ├─ ④ 起 vCPU
 │   │     qemu_init_vcpu() → kvm_init_vcpu()
 │   │     KVM_CREATE_VM / KVM_CREATE_VCPU（内核侧）
 │   │
 │   └─ qemu_machine_creation_done()    → vm_start() 让 vCPU 线程准备好
 │
 └─ qemu_main_loop()                   [softmmu/runstate.c]
       while (!main_loop_should_exit())
           main_loop_wait(false)        事件循环
```

对应到源码文件：

| 阶段 | 关键函数 | 文件 |
| --- | --- | --- |
| 入口 | `main` | `softmmu/main.c` |
| 初始化总控 | `qemu_init` | `softmmu/vl.c` |
| 选机型 | `select_machine` | `softmmu/vl.c` |
| 建机器 | `machine_run_board_init` | `hw/core/machine.c` |
| x86 机型实现 | `pc_q35_init` / `pc_piix.c` | `hw/i386/pc_q35.c` |
| 起 vCPU | `qemu_init_vcpu` → `kvm_init_vcpu` | `softmmu/cpus.c` / `accel/kvm/kvm-all.c` |
| 事件循环 | `main_loop_wait` | `util/main-loop.c`（历史在 vl.c） |

## 3. 阶段详解

### 3.1 ① 命令行解析：一切从字符串开始

QEMU 的命令行不是「一个参数一个变量」，而是一套 **QemuOpts** 小框架：

```
-device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56
        └────┬─────┘ └────┬────┘ └────────┬────────┘
           type        property        property
```

`-machine` / `-drive` / `-netdev` / `-device` 都会被解析成结构化 opt，
后续按 `id=` 互相引用（比如网卡 `netdev=n0` 找到后端）。

> 记住这个模型，第 23 章讲热插拔时，`device_add` 用的就是同一套 opt 解析器。

### 3.2 ② 选机型：谁能代表这块「虚拟主板」

`select_machine()` 根据 `-machine type=...` 找到一个 `MachineClass`，然后
`object_new()` 出 `MachineState`。**这一层只选"造哪种主板"，还没真正造硬件。**

```bash
qemu-system-x86_64 -machine help          # 所有机型
qemu-system-x86_64 -M q35,help            # 该机型可配的属性
```

### 3.3 ③ 建机器：真正把硬件拼出来

`machine_run_board_init()` 做三件事：

1. 调用机型自己的 `mc->init()` —— 对 q35 就是 `pc_q35_init()`
2. 逐个 `qdev_realize()` 设备（PCI 枚举、BAR 分配、MMIO 挂入内存树）
3. 加载固件并布置复位向量

```c
/* hw/core/machine.c（简化） */
void machine_run_board_init(MachineState *machine, const char *mem_path,
                            Object *memdev, bool *paused)
{
    ...
    if (machine->memdev) { ... } else {
        machine->ram = machine_ram_allocate(machine, mem_path); /* 建 RAM */
    }
    machine_class->init(machine);      /* ← pc_q35_init() 在这里 */
    ...
    qdev_machine_creation_done();      /* 设备全部 realized */
}
```

RAM 的创建、地址映射（`memory_region_init_ram` + `address_space_map`）
都在这一阶段，用 `info mtree` 能直观看到。

### 3.4 ④ 起 vCPU：把 CPU 交给 KVM

x86 机型的 `pc_cpus_init()` 为每个 CPU 调 `qemu_init_vcpu()`，最终到 KVM：

```c
/* accel/kvm/kvm-all.c（简化） */
int kvm_init_vcpu(CPUState *cpu, Error **errp)
{
    ...
    ret = kvm_vm_ioctl(kvm_state, KVM_CREATE_VCPU, (void *)cpu->cpu_index);
    ...
    cpu->thread = g_malloc0(sizeof(QemuThread));
    qemu_thread_create(cpu->thread, ... /* vCPU 线程入口 */);
}
```

vCPU 线程入口最终进 `kvm_cpu_exec()` 的循环（第 17 章讲过）：

```c
/* accel/kvm/kvm-cpus.c（简化） */
int kvm_cpu_exec(CPUState *cpu)
{
    do {
        kvm_vcpu_ioctl(cpu, KVM_RUN, 0);     /* ← 这里才真正跑客户机 */
        switch (run->exit_reason) { ... }     /* VM exit 处理 */
    } while (!cpu->exit_request);
}
```

### 3.5 ⑤ 事件循环：服务所有"外设"

main 线程的 `main_loop_wait()` 是一个基于 `poll`/`epoll` 的循环，负责：

- VNC / monitor socket 有数据
- 定时器到期（RTC、计时器、迁移心跳）
- 异步 IO（Linux AIO / io_uring）完成
- 信号（`-S` 后收到继续、Ctrl-C）

**它不是"执行客户机"的循环**——客户机由 vCPU 线程跑，这点务必分清楚。

## 4. KVM 与 TCG 的分叉点

| 阶段 | KVM 路径 | TCG 路径 |
| --- | --- | --- |
| 加速器初始化 | `kvm_init()` → `KVM_CREATE_VM` | `tcg_init()` |
| 内存映射 | `KVM_SET_USER_MEMORY_REGION` | 直接建 `MemoryRegion` |
| vCPU 创建 | `KVM_CREATE_VCPU` | 纯用户态线程 |
| vCPU 循环 | `KVM_RUN` ioctl | `cpu_exec()` 翻译执行 TB |
| 设备访问 | 触发 `KVM_EXIT_MMIO` → QEMU | 直接函数调用 |

用 `-accel tcg` 或 `-accel kvm` 切换，观察 `-d` 输出与 `kvm_stat` 的差别。

## 5. 实战：亲手验证启动顺序

### 5.1 冻结在启动前（`-S`）

```bash
qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -m 512 -smp 2 \
    -display none -monitor stdio \
    -S

# 进入 monitor（没有 -S 的话第一道指令早就执行了）
(qemu) info status
VM status: paused (prelaunch)     # ← 还没跑
(qemu) info cpus
* CPU #0: cpu_index 0 (halted)   # vCPU 已创建，但暂停
```

`-S` 的作用是「建好机器但不 `vm_start()`」，正好卡在阶段 ③④ 与 ⑤ 之间。

### 5.2 看设备树和内存树

```bash
(qemu) info qtree        # 机型生成了哪些设备、挂在哪条总线
(qemu) info mtree        # RAM / MMIO / PCI 窗口怎么做地址映射
(qemu) info mtree -f     # 带扁平化视图，找地址最方便
```

### 5.3 打开启动 trace

```bash
qemu-system-x86_64 -d trace:kvm_*  ... -S 2>start.log
# 或
qemu-system-x86_64 -d unimp,guest_errors -D qemu.log ...
```

看 `kvm_entry` / `kvm_exit` / 设备 trace 的先后，就能把上面的图对上号。

### 5.4 用 gdb 跟一遍（可选，接 lab10）

```bash
qemu-system-x86_64 -s -S -machine q35 ... &
gdb build/qemu-system-x86_64
(gdb) target remote :1234
(gdb) b machine_run_board_init
(gdb) b kvm_init_vcpu
(gdb) b kvm_cpu_exec
(gdb) c
```

## 6. 一张图总结

```
 命令行字符串
   │ qemu_opts_parse（QemuOpts）
   ▼
 MachineClass（选主板型号）
   │ object_new
   ▼
 MachineState ── mc->init() ──► CPU / RAM / 芯片组 / 设备 realize
   │
   ├──► 固件加载 & 复位向量（第 21 章）
   ├──► KVM_CREATE_VM / KVM_CREATE_VCPU
   ▼
 vCPU 线程 ── KVM_RUN ──► 客户机第一条指令
   ▲
 main 线程 ── main_loop_wait ──► 服务外设事件
```

## 7. 小结

- QEMU 是**一个进程、多线程**：main 线程做事件循环，vCPU 线程跑客户机
- 启动 5 阶段：**解析 → 选机型 → 建机器 → 加载固件 → 起 vCPU**
- `qemu_init()` 是绝对主角，`machine_run_board_init()` 是建硬件的分界点
- `KVM_RUN` 才真正执行客户机；之前全在"搭台子"
- 用 `-S`、`info qtree`、`info mtree`、`-d trace` 随时验证

## 8. 思考题

1. 为什么客户机指令不能放在 main 线程里执行？（提示：一个 vCPU 卡死会怎样）
2. `-S` 与在客户机里执行 `hlt` 有什么区别？
3. `machine_run_board_init()` 之前有没有可能已经创建 vCPU 对象？什么时候？
4. 如果 VM 有 8 个 vCPU，`qemu-system-x86_64` 进程里大概有多少条线程？怎么数出来？

<details>
<summary>参考答案（先自己想再看）</summary>

1. 因为 main 线程还要跑事件循环，处理 VNC、monitor、定时器、异步 IO 完成回调和迁移等。如果客户机指令在 main 线程里同步执行，某个 vCPU 一旦卡住或长时间占用，整个事件循环和所有外设服务都会停摆；所以每个 vCPU 独立成线程，main 线程只负责「接待」。
2. `-S` 是 QEMU 侧建好机器后不调用 `vm_start()`，vCPU 线程还没进入 `KVM_RUN`，状态显示 prelaunch，一条客户机指令都没执行。`hlt` 是客户机已经跑起来后执行的特权指令，触发 `KVM_EXIT_HLT`，vCPU 在客户机内挂起等中断，而 QEMU 主循环照常运行。
3. 有可能。CPU 是 QOM 设备，如果命令行用 `-device` 等方式显式创建 CPU 设备，QEMU 在解析/对象实例化阶段就可能已经 `qdev_new` 出 CPU 对象，早于 `machine_run_board_init()`。但要注意「CPU 对象存在」不等于「已 `KVM_CREATE_VCPU`」，后者一般在机型 `init`（`pc_cpus_init` → `qemu_init_vcpu`）阶段完成。
4. 大致是 8 条 vCPU 线程 + 1 条 main 线程，再加上 RCU、migration 等按需线程，通常 10 条上下（若配了 iothread 每个再加一条）。可用 `ps -T -p $(pidof qemu-system-x86_64)`、`top -H` 或 `ls /proc/<pid>/task | wc -l` 数出来。

</details>

## 9. 实战操作

- 主实验：[`labs/lab12-qemu-device.md`](../labs/lab12-qemu-device.md)（会在启动全流程里插一个自定义设备）
- 固件相关：[`labs/lab11-uefi-ovmf.md`](../labs/lab11-uefi-ovmf.md)

## 10. 参考资料

- [`refs/learn-kvm/docs/QEMU工作原理.md`](../refs/learn-kvm/docs/QEMU工作原理.md)
- [`refs/learn-kvm/docs/QEMU基本结构.md`](../refs/learn-kvm/docs/QEMU基本结构.md)
- [`refs/learn-kvm/docs/QEMU功能/虚拟处理器.md`](../refs/learn-kvm/docs/QEMU功能/虚拟处理器.md)
- [`refs/learn-kvm/docs/QEMU使用/QEMU运行x86_64虚拟机.md`](../refs/learn-kvm/docs/QEMU使用/QEMU运行x86_64虚拟机.md)

---

⬅️ 上一章：[19 · 常见故障排查](19-常见故障排查.md) · [📚 返回目录](../INDEX.md) · 下一章 ➡️：[21 · 固件加载与 UEFI 启动](21-UEFI固件加载.md)
