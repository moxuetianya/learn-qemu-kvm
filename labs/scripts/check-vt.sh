#!/usr/bin/env bash
# 检查 CPU 是否支持 KVM 所需的硬件虚拟化能力
# 用法: bash labs/scripts/check-vt.sh
set -euo pipefail

echo "=========================================="
echo "  CPU 硬件虚拟化能力检查"
echo "=========================================="

ok=true

# 1. CPU flags
echo
echo "[1] CPU flags 检查"
flags=$(egrep -m1 -o '^flags\s+:.*' /proc/cpuinfo || true)
echo "  ${flags}"

# 2. VT-x / AMD-V
echo
echo "[2] 硬件辅助虚拟化 (VT-x / AMD-V)"
if egrep -q '\<vmx\>' /proc/cpuinfo; then
    echo "  ✅ 检测到 vmx (Intel VT-x)"
    vendor=intel
elif egrep -q '\<svm\>' /proc/cpuinfo; then
    echo "  ✅ 检测到 svm (AMD-V)"
    vendor=amd
else
    echo "  ❌ 未检测到 vmx 或 svm"
    echo "     进入 BIOS 打开 Intel VT-x 或 AMD SVM"
    ok=false
    vendor=none
fi

# 3. EPT / NPT
echo
echo "[3] 二阶段页表 (EPT / NPT)"
if egrep -q '\<ept\>' /proc/cpuinfo; then
    echo "  ✅ 检测到 ept (Intel EPT)"
elif egrep -q '\<npt\>' /proc/cpuinfo; then
    echo "  ✅ 检测到 npt (AMD NPT)"
else
    echo "  ❌ 未检测到 ept/npt，将回退到影子页表（性能极差）"
    ok=false
fi

# 4. VPID / ASID
echo
echo "[4] TLB 标签 (VPID / ASID)"
if egrep -q '\<vpid\>' /proc/cpuinfo; then
    echo "  ✅ 检测到 vpid"
fi
if egrep -q '\<invpcid\>' /proc/cpuinfo; then
    echo "  ✅ 检测到 invpcid"
fi

# 5. IOMMU / VT-d
echo
echo "[5] IOMMU (VT-d / AMD-Vi)"
if [ -d /sys/class/iommu ] && [ -n "$(ls -A /sys/class/iommu 2>/dev/null || true)" ]; then
    echo "  ✅ 检测到 IOMMU:"
    ls /sys/class/iommu/
else
    echo "  ⚠️  未检测到 IOMMU 设备直通将受限"
fi

# 6. KVM 模块是否已加载
echo
echo "[6] KVM 内核模块"
if lsmod | grep -q '^kvm '; then
    echo "  ✅ kvm 模块已加载:"
    lsmod | grep '^kvm'
else
    echo "  ⚠️  kvm 模块未加载（暂不致命，需要时再 modprobe）"
fi

# 7. nested
echo
echo "[7] 嵌套虚拟化支持 (运行 VM 在 VM 中)"
if [ -f /sys/module/kvm_intel/parameters/nested ]; then
    nested=$(cat /sys/module/kvm_intel/parameters/nested)
    echo "  kvm_intel.nested = $nested"
elif [ -f /sys/module/kvm_amd/parameters/nested ]; then
    nested=$(cat /sys/module/kvm_amd/parameters/nested)
    echo "  kvm_amd.nested = $nested"
fi

# 8. /dev/kvm
echo
echo "[8] /dev/kvm 设备文件"
if [ -e /dev/kvm ]; then
    ls -l /dev/kvm
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        echo "  ✅ 当前用户可读写"
    else
        echo "  ⚠️  当前用户无权限，把用户加入 kvm 组或用 sudo"
        echo "     sudo usermod -aG kvm \$USER  (然后重新登录)"
        ok=false
    fi
else
    echo "  ❌ /dev/kvm 不存在"
    echo "     modprobe kvm && modprobe kvm_intel    # Intel"
    echo "     modprobe kvm && modprobe kvm_amd      # AMD"
    ok=false
fi

echo
echo "=========================================="
if $ok; then
    echo "  ✅ 检查通过，可以跑 KVM"
else
    echo "  ⚠️  存在警告，请按上面提示修复"
fi
echo "=========================================="
