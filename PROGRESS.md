# 学习进度追踪

> 复制本文件开始打卡：`cp PROGRESS.md MY-PROGRESS.md`（`MY-PROGRESS.md` 已被 .gitignore 忽略）。
> 打卡规则：读完章节记 `R`，跑完实验记 `L`。两者都完成才算过一关。

**图例**：`[ ]` 未开始 ｜ `[R]` 只读了 ｜ `[L]` 实验也跑了 ｜ `[-]` 跳过（写原因）

## 第一阶段：入门（能跑起一台 VM）

- [ ] 00 [课程介绍与学习方法](course/00-课程介绍与学习方法.md)
- [ ] 01 [虚拟化基础理论](course/01-虚拟化基础理论.md)
- [ ] 02 [硬件虚拟化（Intel VT-x / AMD-V）](course/02-硬件虚拟化.md)
      lab01 [检查 CPU 虚拟化支持](labs/lab01-check-vt-support.md)
- [ ] 03 [环境搭建实战](course/03-环境搭建实战.md)
      lab02 [安装 QEMU + KVM + libvirt](labs/lab02-install-qemu-kvm.md)
- [ ] 04 [QEMU 基础与命令行](course/04-QEMU基础与命令行.md)
- [ ] 05 [第一个虚拟机实战](course/05-第一个虚拟机实战.md)
      lab03 [第一台虚拟机](labs/lab03-first-vm.md)

里程碑自测（都答「是」才进入第二阶段）：

1. 能一口气说出 QEMU 和 KVM 各自负责什么吗？
2. VM 能 SSH 登录吗？`virsh list` 能看到吗？

## 第二阶段：核心机制（知道快与慢的原因）

- [ ] 06 [KVM 内核工作原理](course/06-KVM内核工作原理.md)
- [ ] 07 [存储虚拟化详解](course/07-存储虚拟化详解.md)
      lab04 [磁盘镜像格式对比](labs/lab04-storage-formats.md)
- [ ] 08 [网络虚拟化详解](course/08-网络虚拟化详解.md)
      lab05 [5 种网络模式](labs/lab05-network-modes.md)
- [ ] 09 [设备虚拟化与 virtio](course/09-设备虚拟化与virtio.md)
      lab06 [virtio 性能基准](labs/lab06-virtio-perf.md)
- [ ] 10 [图形与显示方案对比](course/10-图形与显示方案对比.md)

里程碑自测：

1. virtio 为什么快？能不看书画出数据路径吗？
2. fio/iperf3 的 virtio vs 全模拟数据手里有吗？

## 第三阶段：生产运维（能搭能调能救）

- [ ] 11 [libvirt 管理实战](course/11-libvirt管理实战.md)
- [ ] 12 [性能调优与诊断](course/12-性能调优与诊断.md)
      lab08 [CPU pin + NUMA + hugepage](labs/lab08-cpu-pinning-numa.md)
- [ ] 13 [实时迁移与高可用](course/13-实时迁移与高可用.md)
      lab09 [实时迁移](labs/lab09-live-migration.md)
- [ ] 14 [安全与隔离](course/14-安全与隔离.md)
      lab07 [PCI/GPU 直通](labs/lab07-pci-passthrough.md)
- [ ] 19 [常见故障排查](course/19-常见故障排查.md)

里程碑自测：

1. 给你一台慢的 VM，能按决策树定位到层吗？
2. 迁移一台运行中的 VM 成功过吗？

## 第四阶段：深入与拓展（选学）

- [ ] 15 [跨架构模拟实战](course/15-跨架构模拟实战.md)
- [ ] 16 [QEMU 源码导读](course/16-QEMU源码导读.md)
- [ ] 17 [KVM 源码导读](course/17-KVM源码导读.md)
      lab10 [调试 KVM 内核模块](labs/lab10-debug-kernel.md)
- [ ] 18 [与容器 / 云原生的取舍](course/18-与容器云原生的取舍.md)
- [ ] 98 [学习问答 QA](course/98-QA-学习问答.md)
- [ ] 99 [附录](course/99-附录.md)

## 速查表（随用随查，不算进度）

- [QEMU 命令行](cheatsheet/qemu-cli.md) · [libvirt XML](cheatsheet/libvirt-xml.md)
- [KVM 调优参数](cheatsheet/kvm-tuning.md) · [故障排查](cheatsheet/troubleshooting.md)

## 我的实验环境

| 项 | 值 |
| --- | --- |
| 宿主机 CPU / 内存 | |
| 宿主机 OS / 内核 | |
| QEMU / libvirt 版本 | |
| 基线 VM 镜像路径 | |

## 学习日志

| 日期 | 做了什么 | 卡在哪 / 怎么解决的 |
| --- | --- | --- |
|  |  |  |
