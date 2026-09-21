# INDEX · 课程与参考完整索引

> 本文是课程的总目录，按学习路径组织。每个条目都标注
> 「课程章（自写）/ 参考 ref（来自 `refs/learn-kvm/`）」。

## 🟦 课程正篇（`course/`）

| 编号 | 标题 | 主题 | 实验 |
| --- | --- | --- | --- |
| 00 | [课程介绍与学习方法](course/00-课程介绍与学习方法.md) | 学习路径 | – |
| 01 | [虚拟化基础理论](course/01-虚拟化基础理论.md) | 概念、分类、模型 | – |
| 02 | [硬件虚拟化（Intel VT-x / AMD-V）](course/02-硬件虚拟化.md) | VMX / SVM | lab01 |
| 03 | [环境搭建实战](course/03-环境搭建实战.md) | 装包、内核模块 | lab02 |
| 04 | [QEMU 基础与命令行](course/04-QEMU基础与命令行.md) | qemu-img / qemu-system | lab02 |
| 05 | [第一个虚拟机实战](course/05-第一个虚拟机实战.md) | 跑起来 | lab03 |
| 06 | [KVM 内核工作原理](course/06-KVM内核工作原理.md) | /dev/kvm、ioctl | lab10 |
| 07 | [存储虚拟化详解](course/07-存储虚拟化详解.md) | qcow2/virtio-blk/共享存储 | lab04 |
| 08 | [网络虚拟化详解](course/08-网络虚拟化详解.md) | 5 种模式对比 | lab05 |
| 09 | [设备虚拟化与 virtio](course/09-设备虚拟化与virtio.md) | virtio 框架、vhost | lab06 |
| 10 | [图形与显示方案对比](course/10-图形与显示方案对比.md) | VNC/SPICE/GPU 直通 | – |
| 11 | [libvirt 管理实战](course/11-libvirt管理实战.md) | virsh/virt-manager | – |
| 12 | [性能调优与诊断](course/12-性能调优与诊断.md) | CPU pin/NUMA/hugepage | lab08 |
| 13 | [实时迁移与高可用](course/13-实时迁移与高可用.md) | migration | lab09 |
| 14 | [安全与隔离](course/14-安全与隔离.md) | sVirt、cgroup、隔离 | – |
| 15 | [跨架构模拟实战](course/15-跨架构模拟实战.md) | ARM/MIPS | – |
| 16 | [QEMU 源码导读](course/16-QEMU源码导读.md) | 启动流程、TCG | – |
| 17 | [KVM 源码导读](course/17-KVM源码导读.md) | vm entry/exit | lab10 |
| 18 | [与容器 / 云原生的取舍](course/18-与容器云原生的取舍.md) | VM vs Container | – |
| 19 | [常见故障排查](course/19-常见故障排查.md) | troubleshooting | – |
| 98 | [学习问答 QA](course/98-QA-学习问答.md) | 环境实践 + 硬件原理答疑 | – |
| 99 | [附录](course/99-附录.md) | 速查表、术语 | – |

## 🟩 实验（`labs/`）

| 编号 | 标题 | 前置 | 难度 |
| --- | --- | --- | --- |
| lab01 | [检查 CPU 虚拟化支持](labs/lab01-check-vt-support.md) | – | ★ |
| lab02 | [安装 QEMU + KVM + libvirt](labs/lab02-install-qemu-kvm.md) | lab01 | ★★ |
| lab03 | [第一台虚拟机](labs/lab03-first-vm.md) | lab02 | ★★ |
| lab04 | [磁盘镜像格式对比](labs/lab04-storage-formats.md) | lab03 | ★★ |
| lab05 | [5 种网络模式](labs/lab05-network-modes.md) | lab03 | ★★★ |
| lab06 | [virtio 性能基准](labs/lab06-virtio-perf.md) | lab03 | ★★★ |
| lab07 | [PCI/GPU 直通](labs/lab07-pci-passthrough.md) | lab03, 主板支持 | ★★★★ |
| lab08 | [CPU pin + NUMA + hugepage](labs/lab08-cpu-pinning-numa.md) | lab03 | ★★★ |
| lab09 | [实时迁移](labs/lab09-live-migration.md) | lab03 + 共享存储 | ★★★★ |
| lab10 | [调试 KVM 内核模块](labs/lab10-debug-kernel.md) | 内核编译基础 | ★★★★★ |

## 🟨 速查（`cheatsheet/`）

- [QEMU 命令行速查](cheatsheet/qemu-cli.md)
- [libvirt XML 速查](cheatsheet/libvirt-xml.md)
- [KVM 调优参数速查](cheatsheet/kvm-tuning.md)
- [故障排查速查](cheatsheet/troubleshooting.md)

## 🟥 参考资料（`refs/learn-kvm/`，git subtree 自上游仓库）

> 该目录由 `git subtree add --prefix=refs/learn-kvm learn-kvm/master --squash`
> 引入，**更新方式见 README.md**。

- 原始仓库: <https://github.com/yifengyou/learn-kvm>
- 导航: [references/NAVIGATION.md](references/NAVIGATION.md)
- 原始目录: [refs/learn-kvm/SUMMARY.md](refs/learn-kvm/SUMMARY.md)

### ref → 课程章节映射

| 参考文档 | 课程章节 |
| --- | --- |
| `虚拟化技术简介/虚拟化技术简介.md` | 01 |
| `虚拟化实现技术/虚拟化实现技术.md` | 01, 06 |
| `Intel硬件虚拟化技术/Intel硬件虚拟化技术.md` | 02 |
| `AMD硬件虚拟化技术/AMD硬件虚拟化技术.md` | 02 |
| `Xen虚拟化技术/Xen虚拟化技术.md` | 18（对比） |
| `Lguest虚拟化技术/Lguest虚拟化技术.md` | 18（对比） |
| `QEMU介绍.md` / `QEMU介绍/QEMU历史.md` | 04, 16 |
| `QEMU基本结构.md` | 04, 16 |
| `QEMU工作原理.md` | 04, 16 |
| `QEMU功能.md` 及其子目录 | 04, 07, 08, 09, 10 |
| `QEMU模拟不同体系架构系统*.md` | 15 |
| `QEMU使用.md` / `QEMU使用/QEMU运行x86_64虚拟机.md` | 03, 05 |
| `KVM介绍.md` / `KVM介绍/KVM历史.md` | 06, 17 |
| `KVM基本结构/` | 06 |
| `KVM工作原理/` | 06 |
| `构建KVM环境/` | 03 |
| `KVM核心基础功能/` | 11 |
| `KVM高级功能/` | 12, 13 |
| `KVM内核模块源码分析/` | 17 |
| `KVM开源社区/` | 99 |
| `附录/参考书籍.md` | 99 |
| `附录/相关概念.md` | 99 |
