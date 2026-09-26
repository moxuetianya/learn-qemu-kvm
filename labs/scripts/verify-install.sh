#!/usr/bin/env bash
# 安装完成后的环境验证（对应 lab02）
# 逐项检查 QEMU / KVM / libvirt 是否可用，最后给出结论
# 用法: bash labs/scripts/verify-install.sh
set -uo pipefail

pass=0
fail=0
warn=0

ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
warnf(){ echo "  ⚠️  $1"; warn=$((warn+1)); }

echo "=========================================="
echo "  lab02 安装验证"
echo "=========================================="

echo
echo "[1] 命令存在性"
for cmd in qemu-system-x86_64 qemu-img virsh virt-install; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd -> $(command -v $cmd)"
    else
        bad "$cmd 不在 PATH 里"
    fi
done

echo
echo "[2] 版本"
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    qemu-system-x86_64 --version | head -1 | sed 's/^/  /'
fi
if command -v virsh >/dev/null 2>&1; then
    virsh --version | sed 's/^/  virsh /'
fi

echo
echo "[3] KVM 内核模块"
if lsmod | grep -q '^kvm '; then
    lsmod | grep -E '^(kvm|kvm_intel|kvm_amd) ' | sed 's/^/  /'
    ok "kvm 模块已加载"
else
    bad "kvm 模块未加载: sudo modprobe kvm && sudo modprobe kvm_intel(或 kvm_amd)"
fi

echo
echo "[4] /dev/kvm"
if [ -e /dev/kvm ]; then
    ls -l /dev/kvm | sed 's/^/  /'
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        ok "当前用户可读写"
    else
        warnf "无权限: sudo usermod -aG kvm \$USER 后重新登录"
    fi
else
    bad "/dev/kvm 不存在"
fi

echo
echo "[5] libvirt 守护进程"
if systemctl is-active libvirtd >/dev/null 2>&1 \
   || systemctl is-active libvirtd.socket >/dev/null 2>&1; then
    ok "libvirtd 运行中"
else
    # 模块化守护进程（新版 libvirt 拆成 virtqemud 等）
    if systemctl is-active virtqemud >/dev/null 2>&1; then
        ok "virtqemud 运行中（模块化守护进程）"
    else
        bad "libvirtd 未运行: sudo systemctl enable --now libvirtd"
    fi
fi

echo
echo "[6] libvirt 连接（qemu:///system）"
if virsh -c qemu:///system uri >/dev/null 2>&1; then
    ok "$(virsh -c qemu:///system uri)"
else
    bad "无法连接 qemu:///system（检查用户是否在 libvirt 组）"
fi

echo
echo "[7] 默认 NAT 网络"
if virsh -c qemu:///system net-info default >/dev/null 2>&1; then
    virsh -c qemu:///system net-info default | sed 's/^/  /'
    # 用英文 locale 解析，避免本地化输出导致 awk 匹配失败
    active=$(LC_ALL=C virsh -c qemu:///system net-info default 2>/dev/null | awk -F': *' '/^Active/{print $2}')
    if [ "$active" = "yes" ]; then
        ok "default 网络已激活"
    else
        warnf "default 网络未激活: sudo virsh net-start default && sudo virsh net-autostart default"
    fi
else
    warnf "default 网络不存在（lab05 模式 2 需要它）"
fi

echo
echo "[8] UEFI 固件（OVMF）"
for f in /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/ovmf/OVMF.fd \
         /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    if [ -f "$f" ]; then
        ok "找到 $f"
        found=1
        break
    fi
done
[ -z "${found:-}" ] && warnf "未找到 OVMF（UEFI 启动的 VM 需要，BIOS 启动不受影响）"

echo
echo "=========================================="
echo "  结果: $pass 通过 / $warn 警告 / $fail 失败"
if [ "$fail" -gt 0 ]; then
    echo "  请先修复 ❌ 项，再进入 lab03"
    exit 1
elif [ "$warn" -gt 0 ]; then
    echo "  ⚠️ 项不阻塞 lab03，但相关实验前建议修复"
else
    echo "  ✅ 环境就绪，可以开始 lab03"
fi
echo "=========================================="
