#!/usr/bin/env bash
# 管理实验网桥 br0（对应 lab05 模式 3：VM 直连物理网段）
# 用法:
#   sudo bash labs/scripts/setup-bridge.sh create  [eth0]      # 创建 br0 并把物理网卡挂上去
#   sudo bash labs/scripts/setup-bridge.sh status             # 查看网桥状态
#   sudo bash labs/scripts/setup-bridge.sh delete             # 删除 br0 并还原物理网卡
#
# ⚠️ 本脚本会临时改动宿主机网络。远程 SSH 环境先读 lab05 的警告！
#    建议在物理机控制台或 IPMI/iDRAC 可用时操作，避免把自己锁在门外。
set -euo pipefail

BRIDGE="${BRIDGE:-br0}"
SUBNET="${SUBNET:-192.168.10.100/24}"

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 或 sudo 执行: sudo $0"
    exit 1
fi

cmd="${1:-help}"

create() {
    local nic="${1:-}"
    if [ -z "$nic" ]; then
        # 取第一个非 lo / 非 virbr 的物理网卡
        nic=$(ls /sys/class/net | grep -v -E '^(lo|virbr|vnet|tap|br-|docker)' | head -1)
    fi
    if [ -z "$nic" ]; then
        echo "找不到可用的物理网卡，请手动指定: $0 create <nic>"
        exit 1
    fi
    if ip link show "$BRIDGE" >/dev/null 2>&1; then
        echo "网桥 $BRIDGE 已存在，跳过创建（查看: $0 status）"
        exit 0
    fi

    echo ">> 创建网桥 $BRIDGE（管理地址 $SUBNET）"
    ip link add name "$BRIDGE" type bridge
    ip link set "$BRIDGE" up
    ip addr add "$SUBNET" dev "$BRIDGE"

    echo ">> 把物理网卡 $nic 挂到 $BRIDGE（会短暂断网）"
    ip addr flush dev "$nic"            # 清掉原地址，避免地址留在物理口
    ip link set "$nic" master "$BRIDGE"
    ip link set "$nic" up

    # 开机自启（NetworkManager 环境用 nmcli 更稳，这里给两种方式）
    if command -v nmcli >/dev/null 2>&1 \
       && nmcli -t -f NAME connection show --active 2>/dev/null | grep -q .; then
        echo ">> 检测到 NetworkManager，建议改用 nmcli 持久化（见 lab05「常见失败」）"
    fi

    echo
    echo "完成。验证："
    ip -br addr show "$BRIDGE"
    echo
    echo "下一步（QEMU 用法）："
    echo "  qemu-system-x86_64 -netdev bridge,id=n0,br=$BRIDGE \\"
    echo "      -device virtio-net-pci,netdev=n0 ..."
    echo
    echo "还原: sudo $0 delete"
}

status() {
    echo ">> 网桥列表"
    ip -br link show type bridge || true
    echo
    if ip link show "$BRIDGE" >/dev/null 2>&1; then
        echo ">> $BRIDGE 详情"
        ip addr show "$BRIDGE"
        echo
        bridge link show master "$BRIDGE" || true
    else
        echo ">> $BRIDGE 不存在"
    fi
}

delete() {
    if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
        echo "$BRIDGE 不存在，无需删除"
        exit 0
    fi
    # 先把物理网卡摘下来并恢复 DHCP（如适用）
    for port in $(bridge link show master "$BRIDGE" 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}'); do
        echo ">> 把 $port 从 $BRIDGE 摘下"
        ip link set "$port" nomaster
        if command -v nmcli >/dev/null 2>&1; then
            nmcli device connect "$port" >/dev/null 2>&1 || true
        fi
    done
    ip link delete "$BRIDGE"
    echo ">> $BRIDGE 已删除"
}

case "$cmd" in
    create)  shift || true; create "${1:-}" ;;
    status)  status ;;
    delete)  delete ;;
    *)       grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
esac
