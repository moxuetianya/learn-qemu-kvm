# 26 · QEMU 设备与机型答疑

> 本页把学习 20–25 章过程中最常追问的一批问题集中回答。每条都尽量给出
> 「结论 + 原理 + 相关章节」，方便当速查用。

**目录**

- [Q1 ARM 模拟为什么不需要 q35 那样的机型？](#q1)
- [Q2 不同机型 QEMU 如何处理？如何作用到客户机？](#q2)
- [Q3 UEFI 要枚举 PCIe，QEMU 准备了什么？要构造内存内容吗？](#q3)
- [Q4 QEMU 如何区分内存访问与外设访问？要虚拟 PCIe root 吗？](#q4)
- [Q5 ACPI 表是如何提交给客户机的？靠填内存吗？](#q5)
- [Q6 每 VM 一份 vars / 4M 固件报错，virt-install 会自动处理吗？](#q6)
- [Q7 现在外设都走 PCIe 吗？还有哪些类型？](#q7)
- [Q8 那 6 条"感知通道"都是靠填客户机内存实现的吗？](#q8)

---

## Q1 <a id="q1"></a>ARM 模拟为什么不需要 q35 那样的机型？

**结论**：ARM **也要选机型**，`-machine virt` 就是机型选择，`virt` ≈ ARM 世界的 q35。
只是它没有 i440fx / q35 那种"二选一"。

**为什么 x86 有、ARM 没有**：

- `pc-i440fx` = 真实芯片组 Intel 440FX + PIIX3（1996）
- `pc-q35` = 真实芯片组 Intel Q35 MCH + ICH9（2009）

x86 有几十年 PC 向下兼容包袱，所以要保留多套芯片组。而 ARM 的 `virt` 是
**QEMU 定义的标准虚拟平台**（GIC、generic timer、PL011、virtio-mmio、GPEX PCIe…），
不是模拟某块真板子，所以"一套通吃"。

**关键事实**：

- `virt` 同样**版本化**（`virt-8.2`、`virt-7.0`…），`virt` 是"最新版"别名
- ARM 也有"真板子"机型：`raspi3b`、`vexpress-a15`、`sbsa-ref`、`xlnx-zcu102`
- ARM 的"拧芯片组"入口在 machine 参数：`gic-version` / `its` / `pci` / `iommu` /
  `highmem` / `virtualization` / `secure`
- ARM 也用 CPU 型号选择（`-cpu cortex-a72`），对应 x86 的 `-cpu host/kvm64`

详见 [25 · 机型与固件：客户机看到了什么](25-机型与固件的客户机视角.md) §6。

---

## Q2 <a id="q2"></a>不同机型 QEMU 如何处理？如何作用到客户机？

**结论**：机型就是一段 C 代码（`MachineClass.init()`）。客户机**从来不知道"机型"这个词**，
它只看到一组硬件原语 + 表，然后自己"推断"出机型。

`init()` 干三件事，正好对应客户机能感知的 6 条通道：

| 通道 | i440fx vs q35 |
| --- | --- |
| 总线拓扑 | `pci.0`(传统 PCI) vs `pcie.0`(PCIe 根复合体) |
| PCI 配置空间 | host bridge `8086:1237` vs `8086:29c0`；`CF8/CFC` vs **ECAM** |
| 物理地址映射（MemoryRegion） | ECAM、IOAPIC/LAPIC/HPET 布局不同 |
| ACPI 表 | q35 有 `MCFG`(ECAM)、PCIe 根端口；i440fx 没有 |
| SMBIOS | `dmidecode` 直说 `Standard PC (Q35 + ICH9, 2009)` |
| fw_cfg | QEMU → 固件的传话筒 |
| （ARM）Device Tree | ARM 用 FDT 替代 ACPI |

作用链路：

```
init() 造总线/设备 + 映射地址
  → QEMU 构造 ACPI/SMBIOS/DT 字节流，经 fw_cfg 交给固件
  → 固件搬到客户机 RAM、发布 RSDP
  → OS 读 ACPI/DT + 枚举 PCI
  → "我看到一块 Q35+ICH9 主板"
```

详见第 25 章 §2–§4。

---

## Q3 <a id="q3"></a>UEFI 要枚举 PCIe，QEMU 准备了什么？要构造内存内容吗？

**分工一句话**：**QEMU 造"能被枚举的原料"和"告诉固件去哪枚举的表"；
真正的枚举（读 ID、分 BAR、配中断）由固件运行时完成。**

QEMU 准备的原料：

1. **配置空间访问通路**：q35 映射 ECAM（默认 `0xB0000000`，256MB）并生成 `MCFG`；
   i440fx 提供 `CF8/CFC` 端口
2. **总线/桥/根端口设备**：host bridge、`pcie-root-port`、下游设备
3. **每个设备的配置空间内容**（**属于要构造的内存内容**）：`PCIDevice.config` 里
   的 Vendor/Device ID、BAR 类型位、能力链表（MSI-X Table/PBA）、PCIe Cap、ROM 指针
   —— 以及"写全 1 读回得到大小"的 BAR 探测语义
4. **地址窗口**：host bridge 经 ACPI `_CRS` 声明 32 位 MMIO 空洞、I/O、64 位窗口
5. **ACPI 表 + fw_cfg 投递**：`MCFG/DSDT/FADT/MADT` 经 `etc/acpi/tables` + `etc/table-loader`
6. **固件镜像 + option ROM**：OVMF 放复位向量/pflash；VGA BIOS/PXE 放 ROM 区

固件做的（QEMU 不做）：逐 bus/dev/func 读 Vendor ID → 探 BAR → 分配地址写回 →
配 MSI-X/INTx → 生成面向 OS 的 ACPI → 交棒。

**"要不要构造内存内容"的准确回答**：

- ✅ 要构造**原料**：固件镜像、PCI 配置空间、option ROM、ACPI/SMBIOS 表、地址映射
- ❌ 不构造**枚举结果**：BAR 实际地址由固件运行时写（QEMU 的 `pci_update_mappings`
  只是在固件写 BAR 后把 MemoryRegion 挂上去）

详见第 25 章 §5。

---

## Q4 <a id="q4"></a>QEMU 如何区分内存访问与外设访问？要虚拟 PCIe root 吗？

**结论**：物理机靠 System Agent/root complex 做地址译码；**QEMU 用一棵 MemoryRegion
树替代译码器**，不需要虚拟一个"能译码的芯片"。

```
物理机                                   QEMU
────────────────────────            ─────────────────────────
物理地址 → 译码器 → DRAM / PCIe       GPA → AddressSpace(MemoryRegion 树) → RAM / 设备回调
```

- vCPU 的内存访问最终走 `address_space_rw()`，**唯一动作就是按地址查树**；
  命中的 `MemoryRegion` 要么是 RAM，要么是设备的 `MemoryRegionOps.read/write`
- **这就是"区分内存/外设"的全部机制**：软件查表，不是硬件比较地址

**root complex 虚拟了吗？** 虚拟了，但职责是"容器"而非"译码器"：

```
q35-pcihost (MCH)
  ├── 提供 pcie.0 总线 + 桥/根端口
  ├── 注册孔径：pci_hole(32位) / pci_hole64 / pci_io / ECAM
  └── 提供配置空间访问机制
```

设备 BAR 的 MemoryRegion 被"挂进"孔径（`pci_update_mappings`）。

**KVM 下**：QEMU 只把 **RAM** 注册成 memory slot；访问落在 MMIO 时 EPT 无条目 →
EPT violation → `KVM_EXIT_MMIO` → QEMU 用 MemoryRegion 树处理。
**"这是 MMIO"的判据 = "这个 GPA 不在任何 memory slot 里"。**

---

## Q5 <a id="q5"></a>ACPI 表是如何提交给客户机的？靠填内存吗？

**结论**：**不是 QEMU 直接往客户机 RAM 写**，而是 QEMU → fw_cfg → **固件** → 固件写进 RAM。

```
QEMU (acpi-build.c)
  │ 生成 DSDT/MCFG/FADT/MADT 字节流
  │ fw_cfg_add_file("etc/acpi/tables", ...)
  │ fw_cfg_add_file("etc/table-loader", ...)   ← "链接脚本"
  ▼
fw_cfg 设备（端口 0x510/0x511 或 DMA）
  ▼
固件 (SeaBIOS / OVMF) 开机读取
  │ 按 table-loader：分配地址、拷贝、修指针、校验
  ▼
把表写进客户机 RAM 保留区 + 发布 RSDP
  ▼
OS 扫 RSDP → 找到全部 ACPI 表
```

- **QEMU 构造的是"表的字节流"**（放在 QEMU 侧 / fw_cfg blob）
- **把表写进客户机 RAM 的是固件**
- `etc/table-loader` 就是"怎么搬、搬哪、指针怎么修"的指令序列
- ARM 同理（或改用 Device Tree）

---

## Q6 <a id="q6"></a>每 VM 一份 vars / 4M 固件报错，virt-install 会自动处理吗？

**① 每 VM 一份 vars —— 自动 ✅**

用 UEFI 时 libvirt/virt-install 会：

- 通过 `<os firmware='efi'>` 自动挑固件（含 secure boot 会挑 `_4M`/`secboot`）
- 自动为每台 VM 生成独立 NVRAM：
  `/var/lib/libvirt/qemu/nvram/<vm-name>_VARS.fd`
- 删除时用 `virsh undefine <vm> --nvram` 连 NVRAM 一起删

**② "4M 固件占用 32 位地址空间"报错 —— 默认帮你躲，踩到手动修 ⚠️**

- 这是 **QEMU 层地址空间约束**，virt-install 不会去"修"它
- 好处：RAM 超过约 3.5G 时 QEMU 会**自动把内存挪到 4G 以上**；libvirt 对 UEFI
  默认倾向 q35，一般不会触发
- 真触发只能手动：改 q35、减少 below-4g 设备、调内存布局

一句话：**vars 隔离 = libvirt 自动；地址空间 = QEMU 默认躲开，踩到手动。**

---

## Q7 <a id="q7"></a>现在外设都走 PCIe 吗？还有哪些类型？

**结论**：不是。PCIe 只是"高速可插拔设备"的主干道。

| 通道 | 典型设备 | QEMU 设备名 |
| --- | --- | --- |
| ISA / LPC | 串口、PS/2、RTC、PIT、FDC、并口、TPM | `isa-serial`, `i8042`, `mc146818rtc` |
| MMIO 平台设备 | LAPIC、IOAPIC、HPET、GIC、ARM 串口 | 直接 MemoryRegion，非总线设备 |
| PCIe | 网卡、NVMe、GPU、virtio-pci、直通 | `virtio-net-pci`, `nvme`, `vfio-pci` |
| virtio-mmio | ARM `virt` 上的 virtio | `virtio-mmio`（**完全不走 PCI**） |
| USB | 键鼠、存储 | 控制器挂 PCI，设备挂 USB |
| SCSI / SSI / I2C / SPI | 存储、嵌入式 | `virtio-scsi`, `ssi-*`, `i2c-*` |
| fw_cfg | 固件配置通道 | I/O 端口，非总线设备 |

要点：低速固定功能设备留 LPC/ISA；高速可插拔走 PCIe；ARM `virt` 大量用 virtio-mmio。
所以 guest 里 `lspci` **只看到一部分设备**，串口/RTC/中断控制器根本不在 PCI 上。

---

## Q8 <a id="q8"></a>那 6 条"感知通道"都是靠填客户机内存实现的吗？

**结论**：不是。**"地址空间" ≠ "一块 RAM"。** 分三类：

**A. 纯 QEMU 中介（不是客户机 RAM，访问时现场算）**

| 通道 | 实现 |
| --- | --- |
| PCI 配置空间 | `PCIDevice.config` 在 QEMU 里；ECAM 是设备后备 MMIO，CF8/CFC 是 I/O 端口 |
| MemoryRegion 地址映射 | 它就是映射表本身，不是内存内容 |
| fw_cfg | I/O 端口 + QEMU 数据结构 |
| IOAPIC/LAPIC/HPET | QEMU 设备，MMIO 访问触发回调 |

**B. 真·客户机 RAM 内容，但由固件写入**

| 通道 | 谁写 |
| --- | --- |
| ACPI 表 / SMBIOS | QEMU 造字节流 → fw_cfg → **固件搬进 RAM** |
| e820 内存图 | 同上 |

**C. QEMU 直接写进客户机可见存储的**

| 通道 | 说明 |
| --- | --- |
| 固件镜像（OVMF） | 放复位向量/pflash |
| option ROM | 放 ROM 区，经 ROM BAR 暴露 |
| Device Tree（ARM 直启内核） | QEMU 把 DTB 放进 RAM 并传指针 |

一句话：**只有一部分通道是"填内存"，而且很多是固件代填；配置空间、地址映射、
fw_cfg 更像 QEMU 提供的接口/服务，不存在一块预填好的客户机内存。**

---

## 延伸阅读

- [20 · QEMU 启动虚拟机全流程](20-QEMU启动虚拟机全流程.md)
- [21 · 固件加载与 UEFI 启动](21-UEFI固件加载.md)
- [22 · 机型解析与 Q35 芯片组](22-机型解析与Q35.md)
- [23 · 添加自定义硬件实战](23-添加自定义硬件.md)
- [24 · 为 QEMU 开发自定义设备](24-为QEMU开发自定义设备.md)
- [25 · 机型与固件：客户机看到了什么](25-机型与固件的客户机视角.md)

---

⬅️ 上一章：[25 · 机型与固件：客户机看到了什么](25-机型与固件的客户机视角.md) · [📚 返回目录](../INDEX.md) · 下一章 ➡️：[98 · 学习问答 QA](98-QA-学习问答.md)
