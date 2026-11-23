# 27 · 虚拟机如何使用 GPU

> 从「VM 里有没有 GPU 接口」到「VM 里的应用真的跑在 GPU 上」，中间隔着好几层。
> 本章把 virtio-gpu / VirGL / Venus / GPU 直通四条路径一次理清，并复盘一个典型案例：
> **为什么 VM 里装好了 virtio-gpu，LVGL 还是调不了 3D？**

## 学习目标

- 能分清 `virtio-gpu` / `virtio-gpu-gl` / VirGL / Venus / GPU 直通 / vGPU 的定位与关系
- 知道每条 3D 加速路径在「QEMU 参数 / 宿主栈 / 客户机栈」三侧的要求
- 理解**「路通了 ≠ 车会跑」**：虚拟化层提供接口，应用还得自己有 GPU 渲染后端
- 遇到「VM 里 3D 不可用」时，能按分层排查链定位问题出在哪一层

## 1. 先建立分层模型

「虚拟机用 GPU」不是一件事，是一串事。任何一层断了，最上层看到的就是"没有 3D"：

```
┌────────────────────────────────────────────────────┐
│ ⑤ 客户机应用（LVGL / 游戏 / 浏览器 / glmark2）        │ ← 应用得主动用 GPU
├────────────────────────────────────────────────────┤
│ ④ 客户机图形库（Mesa：OpenGL / EGL / Vulkan）        │ ← 得选中"真"驱动而非 llvmpipe
├────────────────────────────────────────────────────┤
│ ③ 客户机内核 DRM 驱动（virtio_gpu / amdgpu…）        │
├────────────────────────────────────────────────────┤
│ ② 虚拟化通道（virtio-gpu 3D 通道 / PCIe 直通）       │ ← virtio-gpu 默认只有 2D！
├────────────────────────────────────────────────────┤
│ ① QEMU（virglrenderer）/ VFIO                       │ ← QEMU 得编译 virgl 支持
├────────────────────────────────────────────────────┤
│    宿主机 GPU 驱动（i915 / amdgpu / nvidia）→ GPU    │ ← 宿主自己得有硬加速
└────────────────────────────────────────────────────┘
```

两个最容易踩的认知误区：

**误区一：`virtio-gpu` = 有 3D。** 错。virtio-gpu 设备分两个型号：

| QEMU 设备 | 3D 加速 | 说明 |
| --- | --- | --- |
| `virtio-vga` / `virtio-gpu` | ❌ 纯 2D | 只有 display 通道 + 2D 命令（flush/copy），渲染全靠客户机 CPU（llvmpipe） |
| `virtio-vga-gl` / `virtio-gpu-gl` | ✅ | 打开 virgl/venus 3D 通道，要求 QEMU 编译了 virglrenderer |

**误区二：虚拟化层通了，应用自然会加速。** 错。`virtio-gpu-gl` 只是让客户机**有了一个 OpenGL/Vulkan 设备**；应用（如 LVGL）如果编译时没启用 GPU 绘制单元，它照样用 CPU 软件渲染，根本不会去调那个设备。**路通了，车也得存在且被启动。**

## 2. 四条路径总览

| 路径 | 客户机 API | 性能 | 多 VM 共享 | 宿主要求 | 客户机要求 | 典型场景 |
| --- | --- | --- | --- | --- | --- | --- |
| virtio-gpu（2D） | 无 3D | ★★ | ✅ | 无特殊 | 内核支持 virtio-gpu | 纯 UI、console |
| **VirGL**（virtio-gpu-gl） | OpenGL 4.3/4.6 | ★★★ | ✅ | QEMU 带 virglrenderer + 宿主 GL | Mesa（自带 virgl 驱动） | 轻量 3D、桌面合成、LVGL |
| **Venus**（virtio-gpu-gl） | Vulkan | ★★★ | ✅ | virglrenderer ≥ 1.0.0（编译开 venus）+ 宿主 Vulkan | 内核 5.16+、Mesa 24.2+ | Vulkan 应用 |
| **GPU 直通 / vGPU** | 全部（含 CUDA） | ★★★★★ | ❌（直通）/ ✅（vGPU） | IOMMU + vfio-pci | 驱动直接跑在客户机 | AI 训练、重度 3D |

> 展望：新的 virtio-gpu `rutabaga` 框架（gfxstream/cross-domain capset）与 DRM native context（内核 6.14+，客户机直接跑 amdgpu/i915 等内核驱动）是下一代方案，本章不展开。

## 3. 路径一：virtio-gpu（2D 基线）

纯 2D 模式下，virtio-gpu 只是一个「帧缓冲搬运工」：客户机把渲染好的像素通过 virtqueue 提交，QEMU 把它交给显示后端（VNC/SPICE/gtk）。

- 客户机里所有绘制（包括 3D）都由 **CPU 软件渲染**完成（Mesa 的 llvmpipe）
- `glxinfo` 会诚实告诉你：`OpenGL renderer string: llvmpipe (LLVM x.x, 256 bits)`
- 适用：无 GUI 服务器、简单桌面、嵌入式 2D 界面——够用，但别指望 3D

> 顺带回答一个高频对比：**那 QXL 呢？** 它的「2D 加速」同样不涉及 GPU——guest
> 驱动发绘图命令，QEMU 在宿主 CPU 上逐条模拟执行；而本节的 virtio-gpu 2D 是
> guest 画好整帧后 DMA 直出，通常更快、更省 CPU。QXL 的优势只在 SPICE 远程
> 桌面的命令级增量传输，且无 Wayland 驱动、纯 2D（连 render node 都不暴露，
> GBM/EGL 会直接失败）。对比表与 SPICE 的分层关系见
> [10 章 §2.4/§5.4](10-图形与显示方案对比.md)。

## 4. 路径二：VirGL —— OpenGL 加速（最常用）

### 4.1 原理

```
客户机                          宿主机
──────                          ──────
应用调 OpenGL
  │
Mesa virgl 驱动（gallium）
  │ 把 GL 命令序列化
virtio-gpu 3D 通道 ═══════════▶ QEMU virglrenderer
                                  │ 翻译成宿主 OpenGL
                                  ▼
                                宿主 GPU 渲染
                                  │ 结果回传（资源同步/dmabuf）
画面 ◀───────────────────────────┘
```

本质是**命令转发 + 宿主代渲染**：客户机不发像素，发的是 GL 命令流。这也是它比直通慢一个量级的原因——路径长，且要等宿主渲染再回传。

### 4.2 三侧配置

**QEMU 侧**——两个条件缺一不可：

```bash
# ① 显卡设备用 -gl 变体
-device virtio-vga-gl          # 带 VGA 兼容（一般桌面用这个）
# 或
-device virtio-gpu-gl          # 纯 virtio 设备（另配显示）

# ② 显示后端必须支持 GL 上下文（virglrenderer 要有地方渲染）
-display gtk,gl=on             # 本地 gtk 窗口
# 或 -display sdl,gl=on
# 或 -spice port=5900,gl=on    # SPICE 远程（client 侧也需 GL）
# 或 -display egl-headless     # 无头渲染（CI/自动化）
```

只写 ① 不写 ② 会直接报错（无法创建 GL 上下文）。QEMU 二进制本身要编译了 virglrenderer 支持（主流发行版默认带）。

**宿主机侧**：一块有驱动的 GPU（Intel/AMD/NVIDIA 开源驱动均可）。宿主自己都是 llvmpipe 的话，virgl 等于用 CPU 模拟 GPU，没有意义。

**客户机侧**：Mesa 自带 virgl 驱动，Linux 内核只要支持 virtio-gpu 即可，无额外版本门槛。libvirt 写法：

```xml
<graphics type='spice'>
  <gl enable='yes'/>
</graphics>
<video>
  <model type='virtio' heads='1'>
    <acceleration accel3d='yes'/>
  </model>
</video>
```

### 4.3 细节

- 默认客户机里 OpenGL 版本上限 **4.3**；开 host blob（`hostmem` + `blob`，见下节）后可达 **4.6**
- 验证：`glxinfo -B | grep renderer`，看到 `virgl` 即生效；看到 `llvmpipe` 就是没生效

## 5. 路径三：Venus —— Vulkan 加速

VirGL 只转发 OpenGL；Vulkan 应用（以及很多新图形栈）需要 **Venus** 协议：

```bash
-device virtio-gpu-gl,hostmem=8G,blob=true,venus=true
```

| 参数 | 含义 |
| --- | --- |
| `venus=true` | 开启 Venus capset（virtio-gpu 能力集） |
| `blob=true` + `hostmem=N` | host blob 支持——Venus 的硬前提，`hostmem` 是宿主侧内存窗口，典型 256M~8G |
| 需要 virglrenderer ≥ 1.0.0 | 且宿主侧编译时开了 `-Dvenus=true` |

完整示例（blob 内存依赖 memfd 后端）：

```bash
qemu-system-x86_64 \
    -enable-kvm -M q35 -cpu host -m 4G -smp 4 \
    -device virtio-vga-gl,hostmem=4G,blob=true,venus=true \
    -display gtk,gl=on \
    -object memory-backend-memfd,id=mem1,size=4G \
    -machine memory-backend=mem1 \
    ... 磁盘/网络略
```

客户机要求（按 QEMU 官方文档）：

| 能力 | 客户机内核 | 客户机 Mesa |
| --- | --- | --- |
| OpenGL（VirGL） | 任意支持 virtio-gpu 的版本 | 现代版本均可 |
| **Vulkan（Venus）** | **5.16+**（需 CONTEXT_INIT、RESOURCE_BLOB 等 virtio-gpu 参数） | **24.2.0+**（含 venus 驱动） |

验证：`vulkaninfo --summary`，看到 driverName 为 `venus` 即生效。

## 6. 路径四：GPU 直通 / vGPU —— 接近原生

把整块 GPU（vfio-pci 直通）或厂商切分的 vGPU（NVIDIA vGPU / SR-IOV VF）直接交给客户机，驱动原样跑在客户机里，CUDA/完整 OpenGL/Vulkan 都可用。

- 优点：性能 ≈ 原生九成以上，是 AI 训练、重度 3D 的唯一选择
- 代价：直通时宿主机不能用该卡、需要 IOMMU；vGPU 需要专有驱动和授权

详见 [10 · 图形与显示方案对比 §6-7](10-图形与显示方案对比.md) 与 [lab07 · PCI/GPU 直通](../labs/lab07-pci-passthrough.md)，本章不重复。

## 7. 案例复盘：VM 里 LVGL 为什么用不了 3D？

问：装了 virtio-gpu，VM 里的 LVGL 程序还是不能调 3D 接口，为什么？

答：**virtio-gpu 提供的只是「路」，LVGL 默认根本没造「车」。**

### 7.1 LVGL 的渲染架构

- LVGL 核心是绘制任务管线，默认 `LV_USE_DRAW_SW`（软件绘制单元），**所有像素都由 CPU 算**
- GPU 是**可选的绘制单元**，必须在 `lv_conf.h` 里显式启用，LVGL 才会把任务派发给它
- 3D 控件（如 `lv_3dtexture`）产生 `LV_DRAW_TASK_TYPE_3D` 任务，**必须**有支持 3D 任务的绘制单元（OpenGL / NanoVG）才会被渲染

### 7.2 相关编译配置（LVGL 9.3+；宏名在 9.3/9.4/9.5 间有微调，以所用版本的 `lv_conf_template.h` 为准）

| 宏 | 作用 |
| --- | --- |
| `LV_USE_OPENGLES` | OpenGL ES 上下文基础（依赖 EGL） |
| `LV_USE_DRAW_OPENGLES` | OpenGL ES 绘制单元（软件渲染结果存 GPU 纹理合成） |
| `LV_USE_DRAW_NANOVG` | **NanoVG 绘制单元，Linux 上官方推荐的 GPU 渲染器**，支持矢量与 3D（依赖 `LV_USE_NANOVG`、`LV_USE_OPENGLES`、`LV_USE_MATRIX`） |
| `LV_USE_LINUX_DRM` + `LV_LINUX_DRM_USE_EGL` | DRM 显示后端走 EGL（无 X/Wayland 的嵌入式场景） |

### 7.3 排查链（自底向上三步）

1. **QEMU 侧**：设备是不是 `virtio-gpu-gl`？显示后端是不是 `gl=on`？
2. **客户机图形栈**：`glxinfo -B` / `eglinfo -B` 看 renderer——是 `virgl` 还是 `llvmpipe`？后者说明 3D 通道根本没通，LVGL 配置得再对也是 CPU 渲染
3. **应用侧**：`lv_conf.h` 是否启用了 GPU 绘制单元 + EGL 显示后端？

这三步分别对应分层模型的第②④⑤层。任何一层断，现象都一样：慢，或 3D 功能缺失——但病因完全不同。

## 8. 通用排查清单

```bash
# ① 宿主：QEMU 有没有 -gl 设备型号（没有 = 编译时没带 virglrenderer）
qemu-system-x86_64 -device help | grep -i 'virtio.*gpu'

# ② 宿主：自己有没有硬加速（llvmpipe 说明宿主都是软渲染）
glxinfo -B | grep renderer

# ③ 客户机：virtio-gpu 驱动就绪？
dmesg | grep -i virtio_gpu
lsmod | grep virtio_gpu

# ④ 客户机：3D 通道通了吗？—— 关键一步
glxinfo -B | grep renderer      # virgl = 通；llvmpipe = 没通
eglinfo -B                      # 无 X 环境用这个
vulkaninfo --summary            # Venus 场景看 driverName: venus
```

现象 → 结论速查：

| 现象 | 结论 |
| --- | --- |
| 设备型号里找不到 `virtio-gpu-gl` | QEMU 没编译 virglrenderer → 换发行版包或自编译 |
| 启动报 virgl/GL 上下文错误 | 显示后端没开 `gl=on`，或宿主无 GPU 驱动 |
| renderer = `llvmpipe` | 3D 通道没通：设备用错（非 -gl）/ Mesa 回退 |
| renderer = `virgl` 但仍慢 | 宿主侧是软渲染，或负载本身受限于回传带宽 |
| `vulkaninfo` 无 venus | 内核 < 5.16 / Mesa < 24.2 / QEMU 参数缺 `blob+hostmem+venus` |
| 图形栈全通、应用仍不用 GPU | 应用自身没编 GPU 后端（回到 §7 LVGL 案例） |

## 9. 小结

- **virtio-gpu = 2D 基线；`virtio-gpu-gl` = 3D 的门票**，且显示后端必须 `gl=on`
- **VirGL 转发 OpenGL，Venus 转发 Vulkan**，都是「命令转发 + 宿主代渲染」，比直通慢但可多 VM 共享
- **直通/vGPU 是极致性能**，代价是硬件与授权
- **路通了车未必跑**：应用层（LVGL 等）必须自己启用 GPU 绘制单元
- 排查永远**自底向上**：通道 → 客户机驱动（llvmpipe/virgl）→ 应用配置

## 10. 思考题

1. 用 `-device virtio-gpu`（非 -gl）+ 客户机装好 Mesa，`glxinfo` 为什么还是 llvmpipe？
2. VirGL 的数据面为什么天然比 GPU 直通慢？
3. Venus 为什么必须 `blob=true` + `hostmem`，还要求客户机内核 5.16+？
4. 一套 LVGL 应用想在 VM 里吃到 GPU 3D 加速，链路上要打开哪三层？

<details>
<summary>参考答案（先自己想再看）</summary>

1. 因为纯 `virtio-gpu` 设备根本不实现 3D 通道（没有 virgl capset），客户机 Mesa 找不到硬件 GL 驱动，只能回退到 llvmpipe 软件渲染。装 Mesa 不解决问题——Mesa 里 virgl 驱动需要设备侧 3D 能力集才会被选中。
2. VirGL 是命令转发模型：客户机把 GL 命令序列化 → 陷入 QEMU → virglrenderer 翻译成宿主 OpenGL → 宿主 GPU 渲染 → 结果再同步回客户机。路径长、有两次翻译、渲染结果回传有同步开销；直通则是客户机驱动直接操作真实硬件，几乎无中间层。
3. Venus 的 Vulkan 语义需要客户机与宿主之间共享大块可见内存（blob = buffer object 资源，绕开逐命令转发的资源回传），所以必须开 host blob（`blob=true` + `hostmem` 指定宿主内存窗口）。而内核 5.16 才引入 Venus 依赖的 virtio-gpu 参数：`RESOURCE_BLOB`、`HOST_VISIBLE`、`CONTEXT_INIT` 等，缺一个 Venus 都起不来。
4. ① 虚拟化通道层：QEMU 用 `virtio-gpu-gl` + 显示后端 `gl=on`（VirGL 生效）；② 客户机图形栈层：Mesa 选中 virgl 而非 llvmpipe（`glxinfo` 验证）；③ 应用层：LVGL 编译时启用 GPU 绘制单元（`LV_USE_DRAW_NANOVG` 或 `LV_USE_DRAW_OPENGLES` + `LV_USE_OPENGLES`，DRM 场景再加 `LV_LINUX_DRM_USE_EGL`）。三层全通，3D 才真正跑在宿主 GPU 上。

</details>

## 11. 参考资料

- QEMU 官方文档 · VirtIO GPU：<https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html>（capset / hostmem / blob / venus 与客户机版本要求）
- Mesa 文档 · Venus 驱动：<https://docs.mesa3d.org/drivers/venus.html>
- LVGL 官方文档 · NanoVG Draw Unit / OpenGL ES Draw Unit / 3D Texture（lvgl.io）
- virglrenderer：<https://gitlab.freedesktop.org/virgl/virglrenderer>
- 本仓库：[10 · 图形与显示方案对比](10-图形与显示方案对比.md)、[lab07 · PCI/GPU 直通](../labs/lab07-pci-passthrough.md)

---

⬅️ 上一章：[26 · QEMU 设备与机型答疑](26-QEMU设备答疑.md) · [📚 返回目录](../INDEX.md) · 下一章 ➡️：[98 · 学习问答 QA](98-QA-学习问答.md)
