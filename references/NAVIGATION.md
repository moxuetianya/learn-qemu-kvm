# 参考资料导航（refs/learn-kvm/）

> 本目录是 [yifengyou/learn-kvm](https://github.com/yifengyou/learn-kvm) 的镜像，
> 通过 `git subtree` 方式引入（见根目录 README.md）。

## 用法

- 当作**字典**：遇到课程里的术语，对应章节末尾的「参考资料」会指引你去看具体原文。
- 当作**考古**：参考文档偏静态，适合阅读理解；课程偏实战，会补充取舍和实验。
- 当作**索引**：仓库原本用 GitBook 排版，本导航给你重新组织成主题分组。

## 主题分组

### A. 虚拟化通识
- 虚拟化技术简介 → [`../refs/learn-kvm/docs/虚拟化技术简介/虚拟化技术简介.md`](../refs/learn-kvm/docs/虚拟化技术简介/虚拟化技术简介.md)
- 虚拟化实现技术 → [`../refs/learn-kvm/docs/虚拟化实现技术/虚拟化实现技术.md`](../refs/learn-kvm/docs/虚拟化实现技术/虚拟化实现技术.md)
- Intel 硬件虚拟化 → [`../refs/learn-kvm/docs/Intel硬件虚拟化技术/Intel硬件虚拟化技术.md`](../refs/learn-kvm/docs/Intel硬件虚拟化技术/Intel硬件虚拟化技术.md)
- AMD 硬件虚拟化 → [`../refs/learn-kvm/docs/AMD硬件虚拟化技术/AMD硬件虚拟化技术.md`](../refs/learn-kvm/docs/AMD硬件虚拟化技术/AMD硬件虚拟化技术.md)
- Xen → [`../refs/learn-kvm/docs/Xen虚拟化技术/Xen虚拟化技术.md`](../refs/learn-kvm/docs/Xen虚拟化技术/Xen虚拟化技术.md)
- Lguest → [`../refs/learn-kvm/docs/Lguest虚拟化技术/Lguest虚拟化技术.md`](../refs/learn-kvm/docs/Lguest虚拟化技术/Lguest虚拟化技术.md)

### B. QEMU
- 介绍/历史/结构/原理
  - [`../refs/learn-kvm/docs/QEMU介绍.md`](../refs/learn-kvm/docs/QEMU介绍.md)
  - [`../refs/learn-kvm/docs/QEMU介绍/QEMU历史.md`](../refs/learn-kvm/docs/QEMU介绍/QEMU历史.md)
  - [`../refs/learn-kvm/docs/QEMU基本结构.md`](../refs/learn-kvm/docs/QEMU基本结构.md)
  - [`../refs/learn-kvm/docs/QEMU工作原理.md`](../refs/learn-kvm/docs/QEMU工作原理.md)
- 功能（处理器/磁盘/网络/USB/显示/GDB/直启内核）
  - [`../refs/learn-kvm/docs/QEMU功能.md`](../refs/learn-kvm/docs/QEMU功能.md)
  - 子目录：[`../refs/learn-kvm/docs/QEMU功能/`](../refs/learn-kvm/docs/QEMU功能/)
- 不同架构（x86 / x86_64 / ARM / MIPS / PowerPC）
  - [`../refs/learn-kvm/docs/QEMU模拟不同体系架构系统.md`](../refs/learn-kvm/docs/QEMU模拟不同体系架构系统.md)
  - 子目录：[`../refs/learn-kvm/docs/QEMU模拟不同体系架构系统/`](../refs/learn-kvm/docs/QEMU模拟不同体系架构系统/)
- 使用
  - [`../refs/learn-kvm/docs/QEMU使用.md`](../refs/learn-kvm/docs/QEMU使用.md)
  - [`../refs/learn-kvm/docs/QEMU使用/QEMU运行x86_64虚拟机.md`](../refs/learn-kvm/docs/QEMU使用/QEMU运行x86_64虚拟机.md)

### C. KVM
- 介绍/历史
  - [`../refs/learn-kvm/docs/KVM介绍.md`](../refs/learn-kvm/docs/KVM介绍.md)
  - [`../refs/learn-kvm/docs/KVM介绍/KVM历史.md`](../refs/learn-kvm/docs/KVM介绍/KVM历史.md)
- 结构/原理 → [`../refs/learn-kvm/docs/KVM基本结构/`](../refs/learn-kvm/docs/KVM基本结构/), [`../refs/learn-kvm/docs/KVM工作原理/`](../refs/learn-kvm/docs/KVM工作原理/)
- 构建环境 → [`../refs/learn-kvm/docs/构建KVM环境/`](../refs/learn-kvm/docs/构建KVM环境/)
- 核心基础 → [`../refs/learn-kvm/docs/KVM核心基础功能/`](../refs/learn-kvm/docs/KVM核心基础功能/)
- 高级功能 → [`../refs/learn-kvm/docs/KVM高级功能/`](../refs/learn-kvm/docs/KVM高级功能/)
- 内核模块源码分析 → [`../refs/learn-kvm/docs/KVM内核模块源码分析/`](../refs/learn-kvm/docs/KVM内核模块源码分析/)
- 社区 → [`../refs/learn-kvm/docs/KVM开源社区/`](../refs/learn-kvm/docs/KVM开源社区/)

### D. 附录
- 参考书籍 → [`../refs/learn-kvm/docs/附录/参考书籍.md`](../refs/learn-kvm/docs/附录/参考书籍.md)
- 相关概念 → [`../refs/learn-kvm/docs/附录/相关概念.md`](../refs/learn-kvm/docs/附录/相关概念.md)

## 同步上游

```bash
# 拉取最新
git subtree pull --prefix=refs/learn-kvm \
    https://github.com/yifengyou/learn-kvm.git master --squash
```

冲突处理：如果课程在 `refs/learn-kvm/` 下做了一点点修正，建议把改动
迁到课程自己的章节里，让 `refs/learn-kvm/` 保持纯镜像。
