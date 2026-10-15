# Lab 11 · UEFI 固件（OVMF）启动实战

> **难度**：★★★  
> **前置**：Lab 03 跑通、会用 `qemu-system-x86_64` 命令行  
> **预计时间**：40 分钟

## 目标

- 用 OVMF 让 VM 以 UEFI 方式启动（而不是默认 SeaBIOS）
- 亲手搭出 **code（只读）+ vars（可写）** 两块 pflash
- 进入 UEFI Shell，用 `bcfg` 改一次启动项，验证变量写回 vars 文件
- 对比 `-bios OVMF.fd` 的行为，体会"只读会丢变量"
- （选做）开启 `smm=on` + `secure=on` 验证 Secure Boot 路径

## 背景回顾

- 客户机第一条指令在 `0xFFFFFFF0`，由固件提供
- `-bios`：整体只读 ROM；`if=pflash`：可写 NOR flash
- UEFI 变量（`BootOrder`）保存在 **vars** 那块 pflash 里

详见 [21 · 固件加载与 UEFI 启动](../course/21-UEFI固件加载.md)。

## 实验步骤

### 1. 安装固件

```bash
# Debian / Ubuntu
sudo apt update && sudo apt install -y ovmf

# RHEL / CentOS / openEuler
sudo dnf install -y edk2-ovmf

# 看装了哪些
ls -l /usr/share/OVMF/ 2>/dev/null || ls -l /usr/share/edk2/ovmf/ 2>/dev/null
```

记录实际目录，下面用 `$OVMF_DIR` 代替：

```bash
export OVMF_DIR=/usr/share/OVMF      # Ubuntu
# export OVMF_DIR=/usr/share/edk2/ovmf   # RHEL/openEuler 可能是这个
```

### 2. 认清 code 与 vars

```bash
ls -l $OVMF_DIR/*.fd
```

| 文件 | 角色 |
| --- | --- |
| `OVMF_CODE_4M.fd` | 固件代码（只读），含复位向量 |
| `OVMF_VARS_4M.fd` | 变量存储模板（可写） |
| `OVMF_CODE_4M.secboot.fd` | 支持 Secure Boot 的 code |
| `OVMF.fd` | 旧式合并镜像（用 `-bios` 时用） |

> 4M 和 2M 版本不要混用，否则 QEMU 报 size mismatch。

### 3. 准备一份独立的 vars

```bash
mkdir -p /tmp/lab11
cp $OVMF_DIR/OVMF_VARS_4M.fd /tmp/lab11/vars.fd
ls -l --time-style=full-iso /tmp/lab11/vars.fd   # 记下初始 mtime
```

### 4. 用 q35 + pflash 启动

```bash
mkdir -p /tmp/lab11
truncate -s 128M /tmp/lab11/disk.img      # 随便一块空盘

qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host -m 1G -smp 2 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_DIR/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,unit=1,file=/tmp/lab11/vars.fd \
    -drive file=/tmp/lab11/disk.img,format=raw,if=virtio \
    -vnc :1
```

- VNC 连 `:1`（端口 5901），或改成 `-nographic` 看串口（OVMF 输出在串口需要额外配置，本实验用 VNC 更直观）
- 应看到 **UEFI 界面 / 图形 logo**，而不是 SeaBIOS 的 "Press F12"

### 5. 进 UEFI Shell 并在 monitor 里看结构

在 QEMU 窗口里按 `Esc` 进 Boot Manager，选 **EFI Internal Shell**。

同时另开一个 monitor（如果启动时没开，可用 `-monitor stdio` 或加 QMP socket）。
在 monitor 里：

```
(qemu) info mtree -f | grep -i -A2 pflash
(qemu) info qtree | grep -i -A3 pflash
```

记录 `pflash0` / `pflash1` 的映射范围。

### 6. Shell 里观察/修改启动项

在 UEFI Shell：

```
Shell> bcfg boot dump                 # 看当前 BootOrder / Boot####
Shell> map                            # 看有哪些设备
Shell> ver                            # 固件版本
```

尝试新建一个启动项（指向我们的空盘或任意 FS，能建出来即可）：

```
Shell> bcfg boot add 0 fs0:\EFI\BOOT\BOOTX64.EFI "lab11"
Shell> bcfg boot dump
Shell> reset                          # 重启
```

### 7. 验证变量真的写回了 vars 文件

```bash
# 关闭 VM 后（或重启后）在宿主机看
ls -l --time-style=full-iso /tmp/lab11/vars.fd
# mtime 应已更新

# 对比内容差异（可选）
cmp -l $OVMF_DIR/OVMF_VARS_4M.fd /tmp/lab11/vars.fd | head
```

只要用的是**可写 vars**，改动就会落盘；重启后 `bcfg boot dump` 还能看到
刚才加/改的启动项。

### 8. 对比实验：`-bios` 只读会丢变量

```bash
qemu-system-x86_64 \
    -machine q35,accel=kvm -m 1G \
    -bios $OVMF_DIR/OVMF.fd \
    -net none -display none -vnc :2
```

进入 Shell 改个启动项，重启，再 `bcfg boot dump`——改动**不会保留**。
（因为 `-bios` 是只读 ROM，没有 vars 落脚点。）

### 9. （选做）Secure Boot

```bash
qemu-system-x86_64 \
    -machine q35,accel=kvm,smm=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -cpu host -m 2G \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_DIR/OVMF_CODE_4M.secboot.fd \
    -drive if=pflash,format=raw,unit=1,file=/tmp/lab11/vars-secboot.fd \
    -vnc :3
```

进入 Setup，看 `Device Manager → Secure Boot Configuration` 是否出现。
（先把 `OVMF_VARS_4M.fd` 另存为 `vars-secboot.fd`。）

## 输出记录

1. `ls -l $OVMF_DIR/*.fd` 输出（实际目录与文件）
2. `info mtree -f | grep pflash` 的映射范围
3. `bcfg boot dump` 修改前后对比
4. `vars.fd` 的 mtime 变化
5. `-bios` 对比实验里变量丢失的截图/描述

## 常见失败

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| `pflash device size mismatch` | code/vars 版本不一致（2M/4M） | 用同一版本 |
| 启动直接进 SeaBIOS | 没给 OVMF | 加 pflash / `-bios` |
| Secure Boot 选项不出现 | 没 `smm=on` 或没用 secboot 固件 | 见步骤 9 |
| Secure Boot 起不来 | pflash 没 `secure=on` | 加 `-global driver=cfi.pflash01,property=secure,value=on` |
| `Permission denied` 打开 vars | 权限/被占用 | 换 `/tmp` 下一份，别直接改系统文件 |
| 两台 VM 互相干扰 | 共用同一份 vars | 每台 VM 复制独立 vars |

## 下一步

[Lab 12 - 为 QEMU 开发自定义设备](lab12-qemu-device.md)
