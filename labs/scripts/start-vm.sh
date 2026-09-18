#!/usr/bin/env bash
# 用最简单方式启动一台 VM（无 KVM，纯 QEMU TCG，便于任何环境跑通）
# 用法: bash labs/scripts/start-vm.sh [disk.img]
set -euo pipefail

DISK="${1:-/tmp/lab03-disk.qcow2}"
MEM="${MEM:-1024}"
CPUS="${CPUS:-2}"
ISO="${ISO:-}"  # 可选：指定 ISO 启动安装

if [ ! -f "$DISK" ]; then
    echo "Disk $DISK 不存在，创建 20G qcow2"
    qemu-img create -f qcow2 "$DISK" 20G
fi

# 用 unix socket 让多个客户端可连接显示
SOCK="/tmp/lab03-monitor.sock"
rm -f "$SOCK"

ARGS=(
    -name "lab03-vm"
    -machine accel=tcg          # 纯软件模拟，不依赖 KVM
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
echo "VM 已后台启动"
echo "  PID: $(cat /tmp/lab03-vm.pid)"
echo "  VNC: :99  (用 vncviewer :99 或 virt-manager 连)"
echo "  Monitor socket: $SOCK"
echo
echo "停止: kill \$(cat /tmp/lab03-vm.pid)"
