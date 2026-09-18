# Labs · 实验目录

> 每个实验都是独立可跑的单元。建议顺序：**lab01 → lab10**。

## 总览

| # | 标题 | 难度 | 时间 | 前置 |
| --- | --- | --- | --- | --- |
| 01 | [检查 CPU 虚拟化支持](lab01-check-vt-support.md) | ★ | 5 min | – |
| 02 | [安装 QEMU + KVM + libvirt](lab02-install-qemu-kvm.md) | ★★ | 15 min | lab01 |
| 03 | [第一个虚拟机](lab03-first-vm.md) | ★★ | 30 min | lab02 |
| 04 | [磁盘镜像格式对比](lab04-storage-formats.md) | ★★ | 30 min | lab03 |
| 05 | [5 种网络模式](lab05-network-modes.md) | ★★★ | 45 min | lab03 |
| 06 | [virtio 性能基准](lab06-virtio-perf.md) | ★★★ | 30 min | lab03 |
| 07 | [PCI/GPU 直通](lab07-pci-passthrough.md) | ★★★★ | 60 min | lab03+VT-d |
| 08 | [CPU pin + NUMA + hugepage](lab08-cpu-pinning-numa.md) | ★★★ | 30 min | lab03 |
| 09 | [实时迁移](lab09-live-migration.md) | ★★★★ | 60 min | lab03+共享存储 |
| 10 | [调试 KVM 内核模块](lab10-debug-kernel.md) | ★★★★★ | 120 min | 内核编译 |

## 配套脚本（`scripts/`）

| 脚本 | 用途 |
| --- | --- |
| [`check-vt.sh`](scripts/check-vt.sh) | 一键检查硬件虚拟化能力 |
| [`install-qemu.sh`](scripts/install-qemu.sh) | 多发行版装 QEMU/KVM/libvirt |
| [`start-vm.sh`](scripts/start-vm.sh) | 一键后台启动 VM（最简命令） |

## 实验报告建议格式

每跑完一个 lab，把以下写到对应 md 文件末尾的「输出记录」处：

```markdown
## 输出记录
- 时间：2026-xx-xx
- 宿主机：xxxx / Linux 6.x
- 关键命令输出：
  ```
  ...
  ```
- 遇到的问题 / 解决：
- 思考题答案（直接写）
```

## 实验环境保护

- 实验 VM 镜像统一放 `/var/lib/libvirt/images/lab0X.qcow2`
- 实验脚本生成的临时文件用 `/tmp/lab0X/`
- 不要在生产机器上跑实验脚本
