#!/usr/bin/env bash
# 安装 QEMU + KVM + libvirt
# 用法: sudo bash labs/scripts/install-qemu.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 或 sudo 执行: sudo $0"
    exit 1
fi

. /etc/os-release

echo "=========================================="
echo "  QEMU / KVM / libvirt 安装"
echo "  发行版: ${PRETTY_NAME}"
echo "=========================================="

case "${ID:-unknown}" in
    ubuntu|debian)
        apt-get update
        # 注意: Debian/Ubuntu 没有 qemu-efi 包, x86 的 UEFI 固件由 ovmf 提供
        # 注意: Debian/Ubuntu 上 virt-install 命令由 virtinst 包提供（RHEL 系才叫 virt-install）
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            qemu-system-x86 qemu-utils \
            qemu-kvm bridge-utils \
            libvirt-daemon-system libvirt-clients libvirt-daemon \
            virtinst virt-viewer \
            ovmf genisoimage \
            cloud-image-utils \
            libguestfs-tools
        ;;
    rhel|centos|rocky|almalinux|fedora)
        dnf -y install \
            qemu-kvm qemu-img libvirt virt-install \
            virt-viewer \
            libguestfs-tools \
            bridge-utils \
            edk2-ovmf \
            genisoimage
        ;;
    opensuse*|sles)
        zypper --non-interactive install \
            qemu qemu-tools qemu-x86 qemu-arm \
            libvirt libvirt-client virt-install \
            libguestfs \
            bridge-utils \
            ovmf
        ;;
    *)
        echo "未识别的发行版 ${ID:-unknown}，请手动安装："
        echo "  - qemu-system-x86_64 (含 qemu-img / qemu-kvm)"
        echo "  - libvirt (libvirtd + virsh)"
        echo "  - virt-install"
        echo "  - OVMF (UEFI 固件)"
        exit 1
        ;;
esac

# 启动 libvirt
systemctl enable --now libvirtd || true

# 把当前 sudo 调用者加入 libvirt 组（如果不是 root）
if [ -n "${SUDO_USER:-}" ]; then
    usermod -aG libvirt,kvm "${SUDO_USER}"
    echo "已将 ${SUDO_USER} 加入 libvirt,kvm 组，请重新登录生效"
fi

echo
echo "=========================================="
echo "  安装完成，验证"
echo "=========================================="
which qemu-system-x86_64 qemu-img virsh virt-install
echo
qemu-system-x86_64 --version | head -1
virsh --version
