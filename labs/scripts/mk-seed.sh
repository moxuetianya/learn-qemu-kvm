#!/usr/bin/env bash
# 生成 cloud-init NoCloud seed ISO（lab13 配套）
# 用法:
#   bash labs/scripts/mk-seed.sh <输出.iso> <目录>
# 目录里放 user-data(必需) meta-data(建议) network-config(可选)
# 依赖: cloud-image-utils(cloud-localds) 或 genisoimage/xorriso 任一
set -euo pipefail

ISO=${1:?用法: mk-seed.sh <输出.iso> <seed目录>}
DIR=${2:?用法: mk-seed.sh <输出.iso> <seed目录>}

[ -f "$DIR/user-data" ] || { echo "❌ 缺少 $DIR/user-data（首行应为 #cloud-config）"; exit 1; }
[ -f "$DIR/meta-data" ] || { echo "⚠️  没有 meta-data，instance-id 将为空（cloud-init 可能不重跑）"; }

# ISO 若是相对路径，输出位置相对调用者 CWD（脚本内部会 cd 进 seed 目录）
case "$ISO" in /*) OUT=$ISO ;; *) OUT=$PWD/$ISO ;; esac

cd "$DIR"

if command -v cloud-localds >/dev/null 2>&1; then
    # cloud-localds 会把目录里三个标准文件打进卷标 cidata 的 ISO
    if [ -f network-config ]; then
        cloud-localds -N network-config "$OUT" user-data meta-data
    else
        cloud-localds "$OUT" user-data meta-data
    fi
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -output "$OUT" -volid cidata -joliet -rock \
        user-data meta-data $([ -f network-config ] && echo network-config)
elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -output "$OUT" -volid cidata -joliet -rock \
        user-data meta-data $([ -f network-config ] && echo network-config)
else
    echo "❌ 需要 cloud-localds / genisoimage / xorriso 之一（如: sudo apt install cloud-image-utils）"
    exit 1
fi

echo "✅ 生成 $ISO"
echo "   验证: isoinfo -i $ISO -J -f   （应看到 user-data/meta-data[/network-config]）"
echo "   卷标: $(file "$OUT" | grep -o 'cidata' || echo '检查失败!')"
