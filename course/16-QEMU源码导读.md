# 16 · QEMU 源码导读

> QEMU 是百万行级 C 代码。这章挑一条「启动 VM」的主线，带你走一遍。

## 学习目标

- 能描述 QEMU 启动 VM 的函数调用栈
- 知道 `vl.c` `hw/` `softmmu/` 各是什么
- 能找到 TCG 翻译的具体实现
- 知道前端 / 后端 / 总线模型在源码中怎么组织

## 1. 仓库结构

```
qemu/
├── vl.c                   # 主入口 main()
├── softmmu/               # 整个系统仿真入口
│   ├── main.c             # vl.c 移过来
│   ├── runstate.c         # 运行状态机
│   └── ...
├── hw/                    # 设备模型
│   ├── core/              # 总线框架
│   ├── x86/               # x86 设备
│   ├── arm/               # ARM 设备
│   ├── virtio/            # virtio 设备
│   ├── net/               # 网络设备
│   └── ...
├── target/                # 每个客户机架构
│   ├── i386/              # x86 翻译
│   ├── aarch64/           # ARM64 翻译
│   └── ...
├── accel/                 # 加速器
│   ├── kvm/
│   ├── tcg/
│   └── ...
├── block/                 # 块设备层（qcow2、raw...）
├── net/                   # 网络层
├── migration/             # 迁移
└── ...
```

## 2. 启动 VM 主线

```c
// softmmu/main.c
int main(int argc, char **argv)
{
    qemu_init(argc, argv);            // 解析参数
    machine_class = find_machine(...); // 找 machine type
    accel_init_machine(...);           // 初始化加速器
    qemu_create_machine(...);          // 创建机器
    qemu_create_devices(...);          // 创建设备
    qemu_system_run();                 // 跑！
}
```

### 2.1 qemu_system_run 是什么

```c
// softmmu/runstate.c
void qemu_system_run(void)
{
    while (1) {
        // 1. 主循环
        main_loop();
    }
}
```

### 2.2 main_loop

```c
// softmmu/main.c
static void main_loop(void)
{
    while (1) {
        // 1. 处理事件（vnc、迁移、IO 等）
        main_loop_wait(false);

        // 2. 跑 vCPU
        qemu_clock_run_all_timers();

        // 3. 处理 CPU 同步
        qemu_tcg_cpu_thread_fn();  // TCG 模式
        // 或者 qemu_kvm_cpu_thread_fn();  // KVM 模式
    }
}
```

## 3. TCG 模式运行（无 KVM）

```c
// accel/tcg/tcg-accel-ops.c
void *qemu_tcg_cpu_thread_fn(void *arg)
{
    while (1) {
        // 1. 等 vCPU 该跑
        qemu_wait_io_event();
        cpu_exec(cpu);    // 关键：跑一个 vCPU
    }
}
```

`cpu_exec` 是 TCG 核心：

```c
// accel/tcg/cpu-exec.c
int cpu_exec(CPUState *cpu)
{
    while (1) {
        // 1. 翻译一个 TB（translation block）
        tb = tb_lookup__cpu_state(...);
        if (!tb) {
            tb = tb_gen_code(cpu, pc, cs->singlestep_enabled);
        }

        // 2. 执行 TB
        cpu_tb_exec(cpu, tb);

        // 3. 处理退出（exit、irq 等）
        if (cpu_handle_exception(cpu)) {
            return -1;
        }
    }
}
```

## 4. KVM 模式运行

```c
// accel/kvm/kvm-accel-ops.c
void *qemu_kvm_cpu_thread_fn(void *arg)
{
    while (1) {
        kvm_cpu_exec(cpu);
    }
}
```

```c
// accel/kvm/kvm-cpus.c
int kvm_cpu_exec(CPUState *cpu)
{
    do {
        // 1. 调用 KVM_RUN ioctl
        kvm_vcpu_ioctl(cpu, KVM_RUN, 0);

        // 2. 处理 exit
        switch (run->exit_reason) {
            case KVM_EXIT_IO:       kvm_handle_io(...); break;
            case KVM_EXIT_MMIO:     address_space_rw(...); break;
            case KVM_EXIT_HLT:      // 让出 CPU
                                  kvm_vcpu_ioctl(cpu, KVM_RUN, 0); // 再进
                                  break;
            // ...
        }
    } while (!cpu->exit_request);
}
```

## 5. 设备模型

### 5.1 总线 + 设备 + 控制器

QEMU 用 QOM（QEMU Object Model）组织对象：

```c
// hw/core/qdev.c
typedef struct DeviceState {
    Object parent_obj;
    const char *id;
    BusState *parent_bus;
    int realized;
    // ...
} DeviceState;

typedef struct BusState {
    Object parent_obj;
    DeviceState *parent;
    const char *name;
    BusClass *class;
    // ...
} BusState;
```

```c
// hw/virtio/virtio.c
static void virtio_device_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    dc->realize = virtio_device_realize;
    // ...
}
type_register_static(&virtio_device_info);
```

### 5.2 设备生命周期

```
1. 类型注册（type_register）
2. 实例化（object_new）
3. 属性设置（qdev_prop_set_*）
4. realize（qdev_realize）
5. 连接到总线（qdev_connect_gpio_out 等）
6. 启动后处理 MMIO / PIO / IRQ
```

## 6. MMIO / PIO 路径

```c
// softmmu/memory.c
void address_space_rw(AddressSpace *as, hwaddr addr, ...)
{
    // 1. 查 MemoryRegion 树
    mr = address_space_lookup(as, addr);
    // 2. 调对应 ops
    mr->ops->read(mr->opaque, addr, ...);
}
```

VM exit 后，KVM 把 GPA + 长度交给 QEMU 的 `address_space_rw`，QEMU 找到对应 MemoryRegion，调用 backend 函数（如 virtio-mmio 读）。

## 7. virtio 后端实现

```c
// hw/virtio/virtio.c
bool virtio_queue_ready(VirtQueue *vq)
{
    return vq->vring.num && vring_avail_idx(vq) != vq->last_avail_idx;
}

void virtio_queue_notify(VirtIODevice *vdev, int n)
{
    // 通知 KVM 注入中断
    virtio_irq(vq);
}
```

```c
// hw/block/virtio-blk.c
static void virtio_blk_handle_output(VirtIODevice *vdev, VirtQueue *vq)
{
    while ((req = virtqueue_pop(vq, sizeof(req)))) {
        // 读描述符、处理请求、写回结果
        virtio_blk_submit_request(vdev, req);
    }
}
```

## 8. QCOW2 实现

```c
// block/qcow2.c
int qcow2_open(BlockDriverState *bs, QDict *options, int flags, Error **errp)
{
    // 1. 读 header
    // 2. 读 L1/L2 表
    // 3. 缓存映射
}

int qcow2_co_preadv(BlockDriverState *bs, int64_t offset, int64_t bytes,
                     QEMUIOVector *qiov, int flags)
{
    // 1. 查 L2 表找 cluster
    // 2. 若 compressed → 解压
    // 3. 若 backing_file → 递归读 base
    // 4. 返回数据
}
```

## 9. 网络后端

```c
// net/tap.c
static void tap_send(void *opaque)
{
    // 把 tap 上收到的包送进 QEMU
    qemu_net_queue_send(qemu_get_queue(nc), ...);
}
```

```c
// hw/net/virtio-net.c
static void virtio_net_handle_rx(VirtIODevice *vdev, VirtQueue *vq)
{
    // 1. 从 tap 收包
    // 2. 描述符化
    // 3. 推给客户机
}
```

## 10. 调试 QEMU

### 10.1 trace

```bash
qemu-system-x86_64 -d trace:virtio* ...
# 启动后会输出 virtio 所有 trace
```

源码里：

```c
// hw/virtio/virtio.c
trace_virtio_queue_notify(vdev, vq - vdev->vq, vq->vring.avail->idx);
```

打开：

```bash
meson configure -Dtrace=log:virtio_*
ninja
```

### 10.2 monitor

```bash
(qemu) info qtree          # 设备树
(qemu) info mtree          # 内存树
(qemu) info qom-tree       # QOM 对象树
(qemu) info cpus
(qemu) info network
(qemu) info block
```

### 10.3 GDB 跟 QEMU

```bash
qemu-system-x86_64 -s -S ...
gdb
(gdb) target remote :1234
(gdb) b kvm_cpu_exec
(gdb) c
```

## 11. 速读建议

1. 先读 `vl.c` / `softmmu/main.c` 走主流程
2. 读 `accel/kvm/kvm-accel-ops.c` 理解 KVM 加速
3. 读 `accel/tcg/cpu-exec.c` 理解 TCG
4. 挑一个设备（如 `hw/virtio/virtio-blk.c`）通读
5. 读 `block/qcow2.c` 看镜像格式实现

## 12. 推荐阅读顺序

| 文件 | 行数 | 必读章节 |
| --- | --- | --- |
| `softmmu/main.c` | ~700 | `main` 和 `main_loop` |
| `accel/kvm/kvm-cpus.c` | ~500 | `kvm_cpu_exec` |
| `accel/tcg/cpu-exec.c` | ~1000 | `cpu_exec` |
| `target/i386/tcg/translate.c` | 巨大 | 函数片段 |
| `hw/core/qdev.c` | ~600 | 类型注册流程 |
| `hw/virtio/virtio.c` | ~2000 | virtio 核心 |

## 13. 实战操作

[`labs/lab10-debug-kernel.md`](../labs/lab10-debug-kernel.md) 用 gdb 跟 QEMU。

## 14. 小结

- `vl.c` 是入口
- `accel/` 区分 TCG / KVM
- `hw/` 按总线 + 设备组织
- `target/` 是每种架构的翻译器
- 调试用 trace、monitor、gdb

## 15. 思考题

1. QEMU 用 QOM 替代了 C++ 的「类」机制，为什么？
2. TCG 的 TB（translation block）是什么？为什么这么设计？
3. QEMU 的「内存树」（mtree）是怎么组织的？
4. `virtio-net` 与 `vhost-net` 的代码在哪里分流？

## 16. 参考资料

- [`refs/learn-kvm/docs/QEMU基本结构.md`](../refs/learn-kvm/docs/QEMU基本结构.md)
- [`refs/learn-kvm/docs/QEMU工作原理.md`](../refs/learn-kvm/docs/QEMU工作原理.md)
