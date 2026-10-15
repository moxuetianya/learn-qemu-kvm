# Lab 12 · 为 QEMU 添加自定义设备

> **难度**：★★★★  
> **前置**：会编译 C 项目、读过 [24 · 为 QEMU 开发自定义设备](../course/24-为QEMU开发自定义设备.md)  
> **预计时间**：60–90 分钟（首次编译 QEMU 较慢）

## 目标

- 先用现成的 `edu` 设备热身，确认工具链与思路
- 从零写一个 PCI MMIO 设备 `mydev`，接进 QEMU 构建系统
- 用 `-device mydev` 挂到 q35，从 monitor 与客户机两侧验证
- 掌握 `-d guest_errors` / trace / `info qtree` 的调试套路

## 前置检查

```bash
nproc                 # 编译 QEMU 建议 ≥ 4 核
df -h .               # 源码 + 构建目录预留 ~5 GB
python3 --version     # 构建脚本需要
ninja --version || sudo apt install -y ninja-build
sudo apt install -y build-essential git pkg-config \
    libglib2.0-dev libpixman-1-dev libslirp-dev
```

## 热身：先玩自带的 edu 设备

QEMU 自带一个教学用 PCI 设备 `edu`，不用编译就能用：

```bash
# 系统装的 qemu 一般就带 edu
qemu-system-x86_64 -machine q35 -m 512 -display none -monitor stdio \
    -device edu
(qemu) info qtree | grep -i -A3 edu
(qemu) info pci
```

读一遍源码 `hw/misc/edu.c`（`edu` 演示了 MMIO / DMA / 中断 / 定时器），
本实验的 `mydev` 就是它的瘦身版。

## 实验步骤

### 1. 获取 QEMU 源码并配置

```bash
cd /opt    # 或你自己的开发目录
sudo git clone https://gitlab.com/qemu-project/qemu.git
cd qemu
mkdir -p build && cd build

../configure --target-list=x86_64-softmmu --enable-debug
ninja -j"$(nproc)"        # 第一次比较久，先去泡杯茶
```

> 想更快：`--disable-docs --disable-tools --without-default-features`
> 会编得更少，但为了少踩坑，本实验用上面的默认配置。

确认基线能用：

```bash
./qemu-system-x86_64 -machine q35 -m 256 -display none -monitor stdio -S
(qemu) info status
(qemu) quit
```

### 2. 写 `mydev.c`

```bash
cd /opt/qemu
cat > hw/misc/mydev.c <<'EOF'
/*
 * hw/misc/mydev.c —— 最小可用的 PCI MMIO 设备（教学用）
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
#define MYDEV_ID_REG    0x00     /* 只读：魔数 "MYDE" */
#define MYDEV_DATA_REG  0x04     /* 可读写 */
#define MYDEV_IRQ_REG   0x08     /* 写 1 触发中断 */

struct MyDevState {
    PCIDevice parent_obj;
    MemoryRegion mmio;
    uint32_t regs[4];
    qemu_irq irq;
};

static uint64_t mydev_read(void *opaque, hwaddr addr, unsigned size)
{
    MyDevState *s = MYDEV(opaque);
    uint64_t val = 0;

    switch (addr) {
    case MYDEV_ID_REG:
        val = 0x4d594445;    /* "MYDE" */
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

static void mydev_write(void *opaque, hwaddr addr, uint64_t val, unsigned size)
{
    MyDevState *s = MYDEV(opaque);

    switch (addr) {
    case MYDEV_DATA_REG:
        s->regs[1] = val;
        break;
    case MYDEV_IRQ_REG:
        if (val) {
            qemu_irq_pulse(s->irq);
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
    .valid = { .min_access_size = 4, .max_access_size = 4 },
    .impl  = { .min_access_size = 4, .max_access_size = 4 },
};

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

static void mydev_realize(PCIDevice *pci_dev, Error **errp)
{
    MyDevState *s = MYDEV(pci_dev);
    uint8_t *pci_conf = pci_dev->config;

    pci_config_set_interrupt_pin(pci_conf, 1);
    s->irq = pci_allocate_irq(pci_dev);

    memory_region_init_io(&s->mmio, OBJECT(s), &mydev_ops, s,
                          TYPE_MYDEV, MYDEV_MMIO_SIZE);
    pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->mmio);
}

static void mydev_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    k->realize   = mydev_realize;
    k->vendor_id = PCI_VENDOR_ID_REDHAT;   /* 0x1b36 */
    k->device_id = 0x1234;
    k->revision  = 0x01;
    k->class_id  = PCI_CLASS_OTHERS;

    dc->desc  = "mydev: minimal PCI MMIO example";
    dc->reset = mydev_reset;
    dc->vmsd  = &vmstate_mydev;
    set_bit(DEVICE_CATEGORY_MISC, dc->categories);
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
EOF
```

### 3. 接进构建系统

```bash
# 3.1 Kconfig：加一个开关，default y 表示所有目标都编
cat >> hw/misc/Kconfig <<'EOF'

config MYDEV
    bool
    default y
EOF

# 3.2 meson：把源文件加进 system_ss
cat >> hw/misc/meson.build <<'EOF'
system_ss.add(when: 'CONFIG_MYDEV', if_true: files('mydev.c'))
EOF
```

> 正式设备不该 `default y`，应该挂到具体机型的 `select` 上。教学阶段从简。

### 4. 增量编译

```bash
cd build
ninja -j"$(nproc)"
```

编译通过后，确认设备类型已注册：

```bash
./qemu-system-x86_64 -device help | grep -i mydev
# name "mydev", bus PCI, desc "mydev: minimal PCI MMIO example"
```

### 5. 挂到 q35 运行

```bash
./qemu-system-x86_64 \
    -machine q35,accel=kvm -m 512 \
    -device mydev \
    -display none -monitor stdio

(qemu) info pci
# 应出现 [1b36:1234] 的设备，含 BAR0
(qemu) info qtree | grep -i -A6 mydev
(qemu) info mtree -f | grep -i mydev
```

记录 BAR0 的地址，后面客户机要用。

### 6. 客户机侧验证

用任意可启动的 Linux（如 lab03 的 Alpine）加一块盘/一个 ISO 启动：
在 QEMU 命令里加上 `-drive` 与 `-device mydev` 即可。

guest 里：

```sh
# 1) 认出设备
lspci -nn | grep 1b36
# 00:04.0 Unclassified device [00ff]: Red Hat, Inc. Device [1b36:1234]

# 2) 找 BAR0 物理地址
lspci -vv -s 00:04.0 | grep -A1 'Region 0'
# Region 0: Memory at fea00000 (32-bit, non-prefetchable) [size=4K]

# 3) 读写 MMIO（需 root；busybox 自带 devmem）
apk add busybox-extras    # 若没有 devmem
devmem 0xfea00000 32              # 期望 0x4D594445 ("MYDE")
devmem 0xfea00004 32 0xdeadbeef   # 写数据
devmem 0xfea00004 32              # 读回 0xDEADBEEF
devmem 0xfea00008 32 1            # 触发中断（控制台可能看不到效果）
```

> 用虚拟机的实际 BAR 地址替换 `0xfea00000`。用 `info pci` 或 `lspci -vv`
> 都能查到。

### 7. 用例外的地址，观察 guest_errors

故意读一个没定义的偏移，同时在宿主机开 `guest_errors`：

```bash
./qemu-system-x86_64 -machine q35 -m 512 \
    -device mydev \
    -d guest_errors -D /tmp/qemu-mydev.log \
    -display none -monitor stdio
```

guest 里 `devmem 0xfea0000c 32`，然后宿主机：

```bash
grep mydev /tmp/qemu-mydev.log
# mydev_read: bad read at 0xc
```

这条日志来自 `qemu_log_mask(LOG_GUEST_ERROR, ...)`。

## 输出记录

1. `ninja` 成功后 `-device help | grep mydev` 输出
2. `info pci` / `info qtree` 里 mydev 的条目
3. guest 里 `lspci -nn | grep 1b36` 输出
4. `devmem` 读魔数、写读回的实测值
5. `-d guest_errors` 日志片段

## 常见失败

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| `-device help` 里没有 mydev | Kconfig/meson 没生效或没重编 | 检查两处改动，`ninja` 全量 |
| `Property 'mydev.x' not found` | 属性没定义 | 用 `DEFINE_PROP_*` + `device_class_set_props` |
| `machine does not support dynamic sysbus device` | 把设备写成了 SysBus 而不是 PCI | 改父类为 `TYPE_PCI_DEVICE` |
| guest `lspci` 看不到 | 没加 `-device mydev` 或机型不对 | 用 `-machine q35 -device mydev` |
| `devmem` 段错误/无输出 | 地址错或没加 `size=4` | 用 `lspci -vv` 确认 BAR |
| `bad read/write` 日志 | 访问了未定义的偏移/宽度 | 检查 `MemoryRegionOps.valid` |
| 迁移报 `Unknown savevm section` | 没写 `vmsd` | 加 `VMStateDescription` |

## 进阶挑战

1. 给 `mydev` 加一个 `DEFINE_PROP_UINT32`，命令行能配初值
2. 加 trace（`hw/misc/trace-events` + `-trace enable=mydev_*`）
3. 用 DMA 把 guest 内存拷进来（对照 `hw/misc/edu.c`）
4. 写一个 `tests/qtest/mydev-test.c` 放进 CI

## 下一步

回到 [INDEX](../INDEX.md)，或继续读 [24 · 为 QEMU 开发自定义设备](../course/24-为QEMU开发自定义设备.md) 的进阶小节。
