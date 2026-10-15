# 21 · 固件加载与 UEFI 启动

> 上一章说机型会把「固件」摆好。这章回答两个问题：固件**怎么被 QEMU 放进内存**，
> 以及 **UEFI（OVMF）从复位向量到引导 OS 都经历了什么**。

## 学习目标

- 明白客户机执行的第一条指令为什么是固件，而不是内核
- 分清 `-bios` 与 `-drive if=pflash` 两种投放方式的本质差别
- 说清 UEFI 为什么要 **code + vars 两块 pflash**，只读会有什么后果
- 能在 QEMU 源码里找到固件映射位置（`hw/i386/pc_sysfw.c`）
- 能独立用 OVMF 起一台能持久化 UEFI 变量的 VM

## 1. 为什么虚拟机也需要固件

x86 硬件复位后，CPU 会从物理地址 **`0xFFFFFFF0`**（4G 减 16 字节）取第一条指令。
这是 CPU 的设计，不是软件约定。所以「客户机加电」时，QEMU 必须保证这段地址上有
可执行的代码——这就是固件。

```
  复位
   │ PC = 0xFFFFFFF0
   ▼
 固件（SeaBIOS / OVMF）开始执行
   │ 初始化内存、芯片组、枚举总线
   │ 找到可引导设备
   ▼
 加载 bootloader / 内核
   │
   ▼
 操作系统
```

**固件负责的是「把机器带到一个 OS 能启动的状态」**：探测内存、枚举 PCI、
设置 ACPI 表、找启动盘。虚拟机和物理机在这件事上没有区别。

## 2. 三种固件角色

| 固件 | 类型 | QEMU 参数 | 特征 |
| --- | --- | --- | --- |
| SeaBIOS | Legacy BIOS | 默认（或不写） | 小、快、兼容老 OS；只认 MBR 引导 |
| OVMF | UEFI (edk2) | `-bios` / `if=pflash` | 支持 GPT、Secure Boot、UEFI Shell |
| u-boot / TF-A | ARM 常用 | `-bios` | ARM 平台（见第 15 章） |

> 桌面虚拟化、Windows 11、Secure Boot、需要 UEFI 变量持久化的场景，都选 OVMF。

## 3. QEMU 怎么把固件放进去：两种机制

### 3.1 `-bios <file>`：整体 ROM，只读

```bash
qemu-system-x86_64 -machine q35 -bios /usr/share/OVMF/OVMF.fd ...
```

QEMU 把整个文件当作一块 **ROM** 映射到 4G 下方（`0x100000000 - size`）。
好处是简单；坏处是**只读**——固件想写 UEFI 变量（`BootOrder` 等）也没地方存，
重启即丢。

### 3.2 `-drive if=pflash`：可写的 NOR Flash

```bash
qemu-system-x86_64 -machine q35 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=OVMF_CODE.fd \
    -drive if=pflash,format=raw,unit=1,file=OVMF_VARS.fd \
    ...
```

这里用的是 **pflash 设备**（`TYPE_PFLASH_CFI01`，模拟 CFI 接口的 NOR flash），
它比 ROM 多了一个能力：**可以按 flash 的规则被写**。UEFI 就靠它保存变量。

### 3.3 为什么是两块（code + vars）

UEFI 的固件分两部分语义：

```
┌─────────────────────────────────────────┐  4G
│  0xFFFFFFFF                             │  ← 复位向量 0xFFFFFFF0 在 code 顶部
│  ┌───────────────────────────────────┐  │
│  │  pflash0 = CODE  (只读)           │  │  OVMF_CODE.fd
│  │  固件代码/驱动/DXE 核心           │  │  含 reset vector
│  ├───────────────────────────────────┤  │
│  │  pflash1 = VARS  (可写)           │  │  OVMF_VARS.fd
│  │  UEFI 变量存储 (NVRAM)            │  │  BootOrder / Boot#### / KEK ...
│  └───────────────────────────────────┘  │
│  0xFF800000（示意，实际由文件大小决定） │
└─────────────────────────────────────────┘
```

- **code** 保持不变、可共享、只读 → 可以多个 VM 复用同一个文件
- **vars** 每个 VM 一份、可写 → 保存启动项、Secure Boot 密钥、超时时间

所以生产里常见做法：**code 用系统只读文件，vars 每个 VM 复制一份**。

```bash
# 给每台 VM 复制独立的 vars nvram
cp /usr/share/OVMF/OVMF_VARS_4M.fd /var/lib/libvirt/qemu/nvram/myvm_VARS.fd
chown qemu:qemu /var/lib/libvirt/qemu/nvram/myvm_VARS.fd
```

## 4. QEMU 源码里的固件映射

x86 的固件布置在 `hw/i386/pc_sysfw.c`：

```c
/* hw/i386/pc_sysfw.c（简化） */
void pc_system_firmware_init(PCMachineState *pcms, MemoryRegion *rom_memory)
{
    ...
    if (pcms->flash) {
        pc_system_flash_map(pcms, rom_memory);   /* pflash 路径 */
    } else {
        /* -bios 路径：把整个 bios 文件当作 ROM 映射到 4G 下方 */
        ...
    }
}

/* 把每个 pflash 映射到 4G 下方合适的位置 */
static void pc_system_flash_map(PCMachineState *pcms, MemoryRegion *rom_memory)
{
    ...
    for (i = 0; i < ARRAY_SIZE(pcms->flash); i++) {
        /* 逐个映射：code 在最顶，vars 紧随其后 */
        memory_region_add_subregion(rom_memory, ...);
    }
}
```

要点：
- 固件所在的窗口叫 **`rom_memory`**，位于 4G 下方
- **复位向量必须落在最上面那块 flash 的顶部**，否则 CPU 取不到第一条指令
- `pc_system_flash_create()` 创建 `pflash0` / `pflash1` 两个 flash 设备作为 machine 子对象

用 monitor 能看到这段映射：

```bash
(qemu) info mtree
# ...范围里会出现 pflash0 / pflash1 的 MemoryRegion
```

## 5. UEFI 启动的六个阶段

OVMF 是标准 edk2，启动阶段和物理机 UEFI 完全一致：

| 阶段 | 全称 | 干什么 |
| --- | --- | --- |
| SEC | Security | 复位后极早期，建立临时栈（CAR）、校验 |
| PEI | Pre-EFI Init | 早期内存初始化、准备 DXE |
| DXE | Driver Execution Environment | 加载大量驱动：PCI、SATA、网卡…… |
| BDS | Boot Device Selection | 读 UEFI 变量，按 `BootOrder` 找引导目标 |
| TSL | Transient System Load | 启动 OS loader（在启动服务的 BootServices 下） |
| RT | Runtime | OS 接管后，只剩 runtime 服务（变量、时间） |

你看到的「UEFI 菜单一闪而过」就是 **BDS** 在按 `BootOrder` 找盘。
`BootOrder`、`Boot0000`… 这些就是 **pflash1（vars）** 里的持久变量。

## 6. Secure Boot 与 SMM

Secure Boot 靠一串密钥（PK/KEK/db/dbx）验证引导链。要保证**变量不被 OS 篡改**，
固件需要 SMM（System Management Mode）把它保护起来。QEMU 侧要开：

```bash
qemu-system-x86_64 -machine q35,smm=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=OVMF_CODE.secboot.fd \
    -drive if=pflash,format=raw,unit=1,file=OVMF_VARS.secboot.fd \
    ...
```

- `smm=on`：机型提供 SMM（配合 `-global driver=cfi.pflash01,...`）
- `.secboot.fd`：带 Secure Boot 支持的 OVMF build
- 少了 `secure=on`，UEFI 变量保护会退化成"只读"，Secure Boot 往往起不来

> libvirt 里对应 `<loader ... secure='yes'>` + `<nvram template=...>`，
> 见 [`cheatsheet/libvirt-xml.md`](../cheatsheet/libvirt-xml.md) 与第 14 章。

## 7. 实战：OVMF 起一台 VM 并验证变量持久化

### 7.1 装固件

```bash
# Debian / Ubuntu
sudo apt install ovmf

# RHEL / CentOS
sudo dnf install edk2-ovmf

ls /usr/share/OVMF/
# OVMF_CODE.fd  OVMF_VARS.fd  OVMF_CODE_4M.fd  OVMF_VARS_4M.fd ...
```

### 7.2 准备 vars（一定不要直接写系统文件）

```bash
cp /usr/share/OVMF/OVMF_VARS_4M.fd /tmp/my-vars.fd
```

### 7.3 启动

```bash
qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host -m 1G -smp 2 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,file=/tmp/my-vars.fd \
    -drive file=/tmp/my.qcow2,format=qcow2,if=virtio \
    -vnc :1
```

进 VNC，就能看到 UEFI 界面 / Shell，而不是 SeaBIOS 的「Press DEL」。

### 7.4 在 UEFI Shell 里看一眼

在 OVMF 界面选 **EFI Internal Shell**，然后：

```
Shell> bcfg boot dump          # 看 BootOrder / Boot####
Shell> ver
```

### 7.5 验证变量真的被写回

```bash
# 启动后关掉 VM，看 vars 文件是否被修改（mtime / 内容变化）
ls -l --time-style=full-iso /tmp/my-vars.fd
```

只要用的是 `if=pflash`（非只读 vars），改动就会落盘；换成 `-bios OVMF.fd`
则不会。

## 8. 常见坑

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| 重启后 UEFI 启动项丢失 | 用了 `-bios`，或 vars 没给 / 只读 | 改 `if=pflash`，vars 可写 |
| 启动直接进 SeaBIOS | 没给 OVMF | 加 pflash / `-bios OVMF_CODE.fd` |
| `pflash device size mismatch` | code/vars 用错版本（2M vs 4M） | code 与 vars 版本一致 |
| Secure Boot 起不来 | 没开 `smm=on` / 没用 secboot 固件 | 见第 6 节 |
| 一台 VM 改动影响所有 VM | 多 VM 共用了同一份 vars | 每 VM 复制独立 vars |
| 4M 固件内存占用报错 | 32 位地址空间太挤（`above-4g`） | 加 `-m` 或调整 `below-4g` 布局 |

## 9. 优劣对比：BIOS vs UEFI

| 维度 | SeaBIOS (Legacy) | OVMF (UEFI) |
| --- | --- | --- |
| 启动速度 | 快 | 略慢（初始化驱动多） |
| 分区表 | MBR | GPT |
| 安全启动 | ❌ | ✅ Secure Boot |
| 变量持久化 | 无需 | 需要 vars pflash |
| 老 OS 兼容 | ✅ | ⚠️ 少数老系统不认 |
| GPU/直通 | 一般 | 更好（主要显卡初始化更规范） |
| 推荐 | 老 Windows / 极简 | **现代生产默认** |

## 10. 小结

- 客户机第一条指令是固件；复位向量在 `0xFFFFFFF0`
- QEMU 有两种投放固件方式：`-bios`（只读）与 `if=pflash`（可写、推荐）
- UEFI = code（只读）+ vars（可写）两块 pflash，变量存在 vars
- 源码入口：`hw/i386/pc_sysfw.c` 的 `pc_system_firmware_init` / `pc_system_flash_map`
- Secure Boot 还要 `smm=on` + `secure=on` + secboot 固件
- **每台 VM 一份 vars**

## 11. 思考题

1. 为什么不能直接把 OVMF_CODE 写成可读写，省掉 vars？
2. 复位向量在 4G 顶端，而 RAM 在低位——固件怎么在"还没初始化"时就把自己映射好？
3. 如果把 4M 的 code 和 2M 的 vars 混用，QEMU 会怎么报错？为什么？
4. UEFI 变量存在 vars 里，会不会成为迁移时的"不一致"来源？怎么处理？

<details>
<summary>参考答案（先自己想再看）</summary>

1. code 需要被多台 VM 共享且内容固定，若可写，任何一台 VM 的固件更新或异常写都会污染系统文件与其它 VM；而 UEFI 变量是每台 VM 独立的持久状态，塞进同一块 code 无法区分实例。拆成只读 code（可 mmap 共享）+ 每 VM 可写 vars，是语义、安全与共享复用的必然结果。只读 code 也让 SMM/secure flash 的保护更简单。
2. QEMU 在建板阶段就把 pflash 映射到 4G 下方的 `rom_memory`，并让复位向量落在最顶那块 flash 顶部，所以复位时该地址上已经有可执行代码。固件早期用 cache-as-RAM（CAR）当临时栈，完成内存控制器初始化后，再把自身搬到低位 RAM 并跳过去继续。因此"映射好"是 QEMU 做的，不是固件在未初始化内存上自己完成的。
3. QEMU 会以类似 `pflash device size mismatch` 的错误拒绝启动。因为 code 与 vars 必须拼成一段连续、大小一致的 flash 空间，变量区偏移和复位向量位置都由文件大小决定；4M 与 2M 混用会让两者拼不出合法布局，复位向量也可能落不到顶部。解决办法就是 code/vars 用同一版本（都 2M 或都 4M）。
4. 会。vars 里存 `BootOrder`、Secure Boot 密钥等每实例状态，它随 VM 走但不随迁移传输；两端 vars 不一致会让迁移后固件看到错误的启动项或密钥。做法是把 vars 文件连同实例一起复制并保证路径一致，libvirt 会管理 nvram，迁移前确认两端一致或在目标预置相同副本。必要时迁移后用 `efibootmgr` / `bcfg` 重建启动项。

</details>

## 12. 实战操作

- 主实验：[`labs/lab11-uefi-ovmf.md`](../labs/lab11-uefi-ovmf.md)
- 相关：[`labs/lab07-pci-passthrough.md`](../labs/lab07-pci-passthrough.md)（OVMF 对直通更友好）

## 13. 参考资料

- [`refs/learn-kvm/docs/QEMU功能/直接引导Linux内核.md`](../refs/learn-kvm/docs/QEMU功能/直接引导Linux内核.md)
- [`refs/learn-kvm/docs/QEMU使用/QEMU运行x86_64虚拟机.md`](../refs/learn-kvm/docs/QEMU使用/QEMU运行x86_64虚拟机.md)
- [`refs/learn-kvm/docs/QEMU工作原理.md`](../refs/learn-kvm/docs/QEMU工作原理.md)

---

⬅️ 上一章：[20 · QEMU 启动虚拟机全流程](20-QEMU启动虚拟机全流程.md) · [📚 返回目录](../INDEX.md) · 下一章 ➡️：[22 · 机型解析与 Q35 芯片组](22-机型解析与Q35.md)
