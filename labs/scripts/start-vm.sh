#!/usr/bin/env bash
# 用最简单方式启动一台 VM（自动检测 KVM，没有则回退纯软件模拟 TCG）
# 用法: bash labs/scripts/start-vm.sh [disk.img]
# 可选环境变量: MEM=1024 CPUS=2 ISO=xxx.iso ACCEL=tcg
set -euo pipefail

DISK="${1:-/tmp/lab03-disk.qcow2}"
MEM="${MEM:-1024}"
CPUS="${CPUS:-2}"
ISO="${ISO:-}"        # 可选：指定 ISO 启动安装
ACCEL="${ACCEL:-auto}"  # auto / kvm / tcg

# 选择加速器：auto 时优先 KVM（/dev/kvm 可用），否则 TCG
if [ "$ACCEL" = "auto" ]; then
    if [ -w /dev/kvm ]; then
        ACCEL=kvm
    else
        ACCEL=tcg
    fi
fi
if [ "$ACCEL" = "kvm" ] && [ ! -w /dev/kvm ]; then
    echo "❌ /dev/kvm 不可用，无法使用 KVM（跑 bash labs/scripts/check-vt.sh 排查）"
    exit 1
fi
# kvm:tcg 表示优先 KVM、失败自动回退；写死单值则强制
if [ "$ACCEL" = "kvm" ]; then
    MACHINE_ACCEL="kvm:tcg"
else
    MACHINE_ACCEL="tcg"
fi

if [ ! -f "$DISK" ]; then
    echo "Disk $DISK 不存在，创建 20G qcow2"
    qemu-img create -f qcow2 "$DISK" 20G
fi

# 用 unix socket 让多个客户端可连接显示
SOCK="/tmp/lab03-monitor.sock"
rm -f "$SOCK"

ARGS=(
    -name "lab03-vm"
    -machine accel="${MACHINE_ACCEL}"
    -m "$MEM"
    -smp "$CPUS"
    -drive "file=${DISK},format=qcow2,if=virtio"
    -netdev user,id=n0
    -device virtio-net-pci,netdev=n0
    -vnc :99
    -monitor "unix:${SOCK},server,nowait"
    -daemonize
    -pidfile /tmp/lab03-vm.pid
)

if [ -n "$ISO" ] && [ -f "$ISO" ]; then
    ARGS+=( -cdrom "$ISO" -boot d )
fi

qemu-system-x86_64 "${ARGS[@]}"

echo
echo "VM 已后台启动（accel=$ACCEL）"
if command -v socat >/dev/null 2>&1; then
    echo "info kvm" | timeout 2 socat - "UNIX-CONNECT:${SOCK}" 2>/dev/null \
        | grep -i 'kvm' | sed 's/^/  /' || true
fi
echo "  PID: $(cat /tmp/lab03-vm.pid)"
echo "  VNC: :99  (用 vncviewer :99 或 virt-manager 连)"
echo "  Monitor socket: $SOCK"
echo
echo "停止: kill \$(cat /tmp/lab03-vm.pid)"
