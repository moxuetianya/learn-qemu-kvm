# 24 · 为 QEMU 开发自定义设备

> 前两章是「用」QEMU 的设备；这章是「造」。我们会写一个最小可用的 PCI 设备，
> 编译进 QEMU，用 `-device mydev` 挂到 q35 上，再从客户机读写它的 MMIO。

## 学习目标

- 理解 QOM 的 `TypeInfo` 注册 + `realize` 生命周期
- 会写一个带 MMIO 读写、能迁移的 **PCI 设备**
- 知道怎么把它接进 QEMU 的 Kconfig / meson 构建系统
- 会从客户机和 qtest 两侧验证设备工作正常
- 认识 `hw/misc/edu.c` 这个"教学用设备"参考实现

## 1. 两条路线：sysbus 设备 vs PCI 设备

| 路线 | 难度 | 能否 `-device` 挂到 q35 | 适合 |
| --- | --- | --- | --- |
| SysBus 设备 | ★★ | ⚠️ 需要机器支持 `has_dynamic_sysbus` | ARM `virt`、`microvm` |
| PCI 设备 | ★★★ | ✅ 直接挂 | x86 q35 / pc，最常见 |

> **重要坑**：x86 的 `pc`/`q35` 机型默认 `has_dynamic_sysbus = false`，
> 所以一个 SysBus 设备**不能**直接 `-device mydev` 挂上去，会报
> `machine does not support dynamic sysbus device`。要跑在 x86 上，就写 PCI 设备。
> 这章的示例走 PCI。

## 2. 必备概念：QOM 设备的一生

```
① 类型注册（TypeInfo + DEFINE_TYPES）
        │  QOM 知道"存在 mydev 这个类型"
        ▼
② 实例化（object_new / -device mydev）
        │  分配 MyDevState 内存，跑 instance_init
        ▼
③ 设属性（qdev_prop_set / 命令行 key=value）
        │  DEFINE_PROP_* 定义的属性被赋值
        ▼
④ realize（DeviceClass.realize）   ★ 真正干活的地方
        │  建 MemoryRegion、注册 BAR、申请 IRQ
        ▼
⑤ 运行（guest 读写 → MemoryRegionOps.read/write 回调）
        │
        ▼
⑥ reset / 迁移 / 释放
```

记住三个回调名：`realize`、`read/write`（`MemoryRegionOps`）、`reset`。

## 3. 参考实现：`hw/misc/edu.c`

QEMU 自带的 `hw/misc/edu.c` 就是**专门给学习者看的 PCI 设备**，
建议对照它读本章：

```bash
qemu-system-x86_64 -device edu            # 直接就能用！
lspci | grep -i edu                       # 客户机里能看到 (1b36:11e8)
```

它演示了：PCI 配置空间、BAR、MMIO 读写、DMA、中断、定时器。
本章的 `mydev` 是它的"瘦身版"。

## 4. 写一个最小 PCI 设备：`mydev`

在 QEMU 源码树里新建 `hw/misc/mydev.c`：

```c
/*
 * hw/misc/mydev.c —— 一个最小可用的 PCI MMIO 设备
 */
#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "hw/pci/pci.h"
#include "hw/pci/pci_device.h"
#include "hw/qdev-properties.h"
#include "migration/vmstate.h"

#define TYPE_MYDEV "mydev"
OBJECT_DECLARE_SIMPLE_TYPE(MyDevState, MYDEV)

#define MYDEV_MMIO_SIZE 0x1000
#define MYDEV_ID_REG    0x00        /* 只读：设备魔数 */
#define MYDEV_DATA_REG  0x04        /* 可读写：数据寄存器 */
#define MYDEV_IRQ_REG   0x08        /* 写 1 触发一次中断 */

struct MyDevState {
    PCIDevice parent_obj;
    MemoryRegion mmio;
    uint32_t regs[4];
    qemu_irq irq;
};

/* ---- MMIO 读 ---- */
static uint64_t mydev_read(void *opaque, hwaddr addr, unsigned size)
{
    MyDevState *s = MYDEV(opaque);
    uint64_t val = 0;

    switch (addr) {
    case MYDEV_ID_REG:
        val = 0x4d594445;               /* "MYDE" */
        break;
    case MYDEV_DATA_REG:
        val = s->regs[1];
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "%s: bad read at 0x%" HWADDR_PRIx "\n", __func__, addr);
        break;
    }
    return val;
}

/* ---- MMIO 写 ---- */
static void mydev_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
    MyDevState *s = MYDEV(opaque);

    switch (addr) {
    case MYDEV_DATA_REG:
        s->regs[1] = val;
        break;
    case MYDEV_IRQ_REG:
        if (val) {
            qemu_irq_pulse(s->irq);     /* 拉一下中断线 */
        }
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "%s: bad write at 0x%" HWADDR_PRIx "\n", __func__, addr);
        break;
    }
}

static const MemoryRegionOps mydev_ops = {
    .read  = mydev_read,
    .write = mydev_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
    .impl = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
};

/* ---- 复位 / 迁移 ---- */
static void mydev_reset(DeviceState *dev)
{
    MyDevState *s = MYDEV(dev);
    memset(s->regs, 0, sizeof(s->regs));
}

static const VMStateDescription vmstate_mydev = {
    .name = TYPE_MYDEV,
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (VMStateField[]) {
        VMSTATE_UINT32_ARRAY(regs, MyDevState, 4),
        VMSTATE_END_OF_LIST()
    }
};

/* ---- realize：建 MMIO、挂 BAR、要一条中断 ---- */
static void mydev_realize(PCIDevice *pci_dev, Error **errp)
{
    MyDevState *s = MYDEV(pci_dev);
    uint8_t *pci_conf = pci_dev->config;

    pci_config_set_interrupt_pin(pci_conf, 1);   /* 用 INTA# */
    s->irq = pci_allocate_irq(pci_dev);          /* 申请一条中断线 */

    memory_region_init_io(&s->mmio, OBJECT(s), &mydev_ops, s,
                          TYPE_MYDEV, MYDEV_MMIO_SIZE);
    pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->mmio);
}

/* ---- 元数据：vendor/device id 等 ---- */
static void mydev_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    k->realize   = mydev_realize;
    k->vendor_id = PCI_VENDOR_ID_REDHAT;   /* 0x1b36 */
    k->device_id = 0x1234;                 /* 自定义，别撞车 */
    k->revision  = 0x01;
    k->class_id  = PCI_CLASS_OTHERS;       /* 0x00ff00 */

    dc->desc     = "mydev: minimal PCI MMIO example";
    dc->reset    = mydev_reset;
    dc->vmsd     = &vmstate_mydev;
    set_bit(DEVICE_CATEGORY_MISC, dc->categories);

    /* 需要给设备加属性时：
     * device_class_set_props(dc, mydev_properties);
     */
}

static const TypeInfo mydev_types[] = {
    {
        .name          = TYPE_MYDEV,
        .parent        = TYPE_PCI_DEVICE,
        .instance_size = sizeof(MyDevState),
        .class_init    = mydev_class_init,
        .interfaces    = (InterfaceInfo[]) {
            { INTERFACE_CONVENTIONAL_PCI_DEVICE },
            { },
        },
    },
};

DEFINE_TYPES(mydev_types)
```

几个容易踩的点：

- `memory_region_init_io` 的 `size` 必须是 2 的幂，BAR 才能对齐
- `.valid` / `.impl` 决定 guest 能用的访问宽度；填错会触发 `guest_errors`
- `pci_config_set_interrupt_pin` 让 guest 知道用哪条 INTx；用 MSI 则另配
- `dc->vmsd` 决定这个设备能否被迁移；不写就无法迁移

## 5. 接进构建系统

QEMU 用 **Kconfig + meson** 管理编译。加两处：

`hw/misc/Kconfig`：

```kconfig
config MYDEV
    bool
    default y          # 教学用，所有目标都编进去；正式设备应挂到具体机型
```

`hw/misc/meson.build`：

```meson
system_ss.add(when: 'CONFIG_MYDEV', if_true: files('mydev.c'))
```

（`system_ss` 表示"系统仿真"通用源集合；`CONFIG_MYDEV` 由 Kconfig 生成。）

### 5.1 可选：加 trace

`hw/misc/trace-events`：

```
mydev_read(uint64_t addr, uint64_t val) "mydev read  addr 0x%"PRIx64" val 0x%"PRIx64
mydev_write(uint64_t addr, uint64_t val) "mydev write addr 0x%"PRIx64" val 0x%"PRIx64
```

然后在 `mydev.c` 里加 `#include "trace.h"`，并在 `mydev_read` 返回前、
`mydev_write` 结尾各加一行：

```c
    trace_mydev_read(addr, val);      /* mydev_read 里 */
    trace_mydev_write(addr, val);     /* mydev_write 里 */
```

用法：

```bash
qemu-system-x86_64 -device mydev -trace enable=mydev_* ...
```

## 6. 编译

```bash
git clone https://gitlab.com/qemu-project/qemu.git
cd qemu
mkdir build && cd build
../configure --target-list=x86_64-softmmu --enable-debug
ninja

# 改完源码只需增量编译
ninja
```

> 第一次全量编译可能要 10~30 分钟；之后改一个设备文件只需几十秒。

## 7. 挂到机型上运行

### 7.1 启动并自省

```bash
build/qemu-system-x86_64 \
    -machine q35,accel=kvm -m 512 \
    -device mydev \
    -display none -monitor stdio

(qemu) info qtree
# ...会出现 "mydev"，能看到它的 BAR/MMIO 地址
(qemu) info pci
# 0000:00:04.0  Red Hat, Inc. Device 1234
```

`-device mydev,help` 能列出它暴露的属性（目前是 PCI 通用属性如 `addr`）。

### 7.2 客户机侧验证

在 guest 里：

```bash
# 1) 认出设备（1b36 = Red Hat）
lspci -nn | grep 1b36
# 00:04.0 Unclassified device [00ff]: Red Hat, Inc. Device [1b36:1234]

# 2) 找到 BAR0 的物理地址
lspci -vv -s 00:04.0 | grep -A1 "Region 0"
# Region 0: Memory at feb00000 (32-bit, non-prefetchable) [size=4K]

# 3) 读魔数（需要 root）
#    用 busybox devmem 或自写 mmap 小工具
devmem 0xfeb00000 32            # 期望 0x4d594445 ("MYDE")
devmem 0xfeb00004 32 0xdeadbeef # 写数据寄存器
devmem 0xfeb00004 32            # 读回 0xdeadbeef
devmem 0xfeb00008 32 1          # 触发中断
```

> 直接 `/dev/mem` 访问 MMIO 只适合实验。真实驱动应写 PCI driver
> （`pci_register_driver` + `pci_iomap`），把 `mydev_read/write` 当作后端。

### 7.3 用 qtest 做自动化验证（进阶）

`tests/qtest/mydev-test.c`（示意）：

```c
static void test_mydev_id(void)
{
    QTestState *qts = qtest_init("-machine q35 -device mydev");

    /* 通过 PCI 配置空间找 BAR0，再读 MYDEV_ID_REG —— 具体地址获取略 */
    /* qtest_readl(qts, bar0 + 0x00) == 0x4d594445 */

    qtest_quit(qts);
}
```

qtest 不跑 guest OS，直接对 MMIO 发读写，适合放进 CI。真实写法参考
`tests/qtest/` 下现有用例。

## 8. 调试手段

| 手段 | 用途 |
| --- | --- |
| `-d guest_errors -D qemu.log` | 看 guest 非法访问（配合 `qemu_log_mask`） |
| `-d trace:mydev_*` | 看我们的 read/write 轨迹 |
| `(qemu) info qtree` / `info mtree -f` | 看设备树 / MMIO 地址映射 |
| `(qemu) info pci` | 看 PCI 配置空间、BAR |
| `gdb` + `b mydev_write` | 断点跟回调 |
| `-device mydev,help` | 自省属性 |

## 9. 从 MMIO 升级到真实功能

会写"存寄存器"之后，加功能就是加回调：

- **DMA**：用 `pci_dma_read` / `pci_dma_write` 搬客户机内存（对照 `edu.c`）
- **中断**：`pci_init_irq` + `msi_init` 支持 MSI/MSI-X
- **定时器**：`timer_new_ns` 周期触发中断
- **热插迁移**：`VMStateDescription` 里把设备状态补齐
- **属性**：`DEFINE_PROP_UINT32(...)` 暴露可配参数，命令行 `-device mydev,xxx=1`

## 10. 小结

- 开发新设备 = 注册 `TypeInfo` + 写 `realize` + 填 `MemoryRegionOps`
- x86 上要能被 `-device` 挂载，**优先写 PCI 设备**（SysBus 受 `has_dynamic_sysbus` 限制）
- 接入构建两步：`hw/misc/Kconfig` 加 `config MYDEV`，`hw/misc/meson.build` 加 `system_ss` 行
- 参考实现首选 `hw/misc/edu.c`
- 验证顺序：`info qtree` → guest `lspci` → `devmem` 读写 → qtest
- 记得写 `vmsd`，否则设备无法迁移

## 11. 思考题

1. SysBus 设备为什么不能随便 `-device` 挂到 q35？`has_dynamic_sysbus` 是什么语义？
2. `MemoryRegionOps` 的 `.valid` 和 `.impl` 分别是什么含义？只填一个会怎样？
3. 如果设备不实现 `VMStateDescription`，迁移时会报什么？为什么这是个问题？
4. `PCI_VENDOR_ID_REDHAT` 是给谁用的？自定义设备应该怎么选 vendor/device id？
5. 想把 `mydev` 做成能 DMA 的，需要在 `realize` 里准备什么额外信息？

<details>
<summary>参考答案（先自己想再看）</summary>

1. SysBus 设备没有固定挂载点，必须由机器在 `init` 时主动创建并连到某条总线；`has_dynamic_sysbus` 表示该机型允许用户从命令行用 `-device` 动态创建 sysbus 设备，并提供一个动态 sysbus 容器。x86 的 `pc`/`q35` 默认是 false，所以直接 `-device mydev` 会报 `machine does not support dynamic sysbus device`。ARM `virt`、`microvm` 则为 true，可以动态挂。
2. `.valid` 描述 guest 能合法访问的地址与宽度集合，`.impl` 描述设备实现实际支持的访问宽度，QEMU 在两者之间做拆分/合并（例如把 guest 的 8 字节访问拆成两次 4 字节）。只填一个时另一个会放宽默认值，可能导致 guest 的越界宽度访问直接落到设备、触发 `guest_errors` 或错误行为。按设备真实能力两者都填最安全。
3. 迁移时 QEMU 会因设备没有状态描述而报错（如未知的 savevm 段）并导致迁移失败，因为它不知道如何序列化设备状态。即便勉强迁过去，设备内部寄存器（例如此处的 `regs`）也会丢失或被复位，guest 看到的状态与迁移前不一致。所以有状态的设备必须实现 `VMStateDescription` 才能迁移。
4. `PCI_VENDOR_ID_REDHAT`（`0x1b36`）是上游虚拟设备（virtio、edu 等）使用的 vendor id，普通自定义设备冒用会与真实设备定义冲突。自定义设备应选一个不与现有厂商撞车的 id，device id 也要避开同 vendor 下已有设备。正式产品通常去申请自己的 PCI Vendor ID。
5. DMA 需要设备知道客户机地址空间：在 realize 里拿到 `PCIDevice` 的 `AddressSpace`（如 `pci_get_address_space` / bus master 地址空间），并确保开启了 bus master（`PCI_COMMAND_MASTER`）。之后用 `pci_dma_read` / `pci_dma_write` 在该地址空间上搬 guest 内存，同时把 DMA 相关的源/目标/长度寄存器纳入 MMIO 与 vmstate。对照 `edu.c` 能看到完整写法。

</details>

## 12. 实战操作

- 主实验：[`labs/lab12-qemu-device.md`](../labs/lab12-qemu-device.md)
- 相关：[`labs/lab06-virtio-perf.md`](../labs/lab06-virtio-perf.md)（对照 virtio 设备的数据面）

## 13. 参考资料

- [`refs/learn-kvm/docs/QEMU基本结构.md`](../refs/learn-kvm/docs/QEMU基本结构.md)
- [`refs/learn-kvm/docs/QEMU工作原理.md`](../refs/learn-kvm/docs/QEMU工作原理.md)
- [`refs/learn-kvm/docs/QEMU功能/其他虚拟外设.md`](../refs/learn-kvm/docs/QEMU功能/其他虚拟外设.md)

---

⬅️ 上一章：[23 · 添加自定义硬件实战](23-添加自定义硬件.md) · [📚 返回目录](../INDEX.md) · 下一章 ➡️：[25 · 机型与固件：客户机看到了什么](25-机型与固件的客户机视角.md)
