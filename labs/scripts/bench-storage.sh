#!/usr/bin/env bash
# 磁盘镜像格式对比（对应 lab04 宿主侧部分）
# 自动完成：四种格式创建 → 稀疏占用对比 → qcow2 特性演示 → fio 性能对比
# 用法: bash labs/scripts/bench-storage.sh [工作目录]
#   可用环境变量: SIZE=1G  FIO_RUNTIME=10  SKIP_FIO=1
set -euo pipefail

DIR="${1:-/tmp/lab04}"
SIZE="${SIZE:-1G}"
FIO_RUNTIME="${FIO_RUNTIME:-10}"

mkdir -p "$DIR"
cd "$DIR"
echo "工作目录: $DIR（镜像大小 $SIZE）"

##############################################
echo
echo "========== [1] 创建四种格式 =========="
for fmt in raw qcow2 vmdk vdi; do
    echo "--- qemu-img create -f $fmt test-$fmt.img $SIZE"
    qemu-img create -f "$fmt" "test-$fmt.img" "$SIZE"
done

##############################################
echo
echo "========== [2] 稀疏占用对比（逻辑大小 vs 实际占用） =========="
printf "%-20s %-12s %-12s\n" "文件" "逻辑大小" "实际占用"
for fmt in raw qcow2 vmdk vdi; do
    f="test-$fmt.img"
    logical=$(stat -c '%s' "$f")
    actual=$(du -b "$f" | cut -f1)
    printf "%-20s %-12s %-12s\n" "$f" "$(numfmt --to=iec $logical)" "$(numfmt --to=iec $actual)"
done
echo
echo "结论：qcow2/vmdk/vdi 初始只有元数据；raw 立即占用全部空间（除非文件系统支持稀疏文件）"

##############################################
echo
echo "========== [3] qcow2 特性演示 =========="
echo "--- 3.1 qemu-img info（看 format specific 字段）"
qemu-img info test-qcow2.img

echo
echo "--- 3.2 backing file 差分镜像"
qemu-img create -f qcow2 -b test-qcow2.img -F qcow2 delta.qcow2 "$SIZE"
qemu-img info delta.qcow2 | grep -E 'backing|virtual size'

echo
echo "--- 3.3 写入数据后看占用增长（COW）"
# ⚠️ 正确姿势：用 qemu-io 把数据写进镜像。不要用 dd 直接写 qcow2 文件——
#    那会从头覆盖 qcow2 头部元数据，直接把镜像写坏！
if command -v qemu-io >/dev/null 2>&1; then
    qemu-io -c 'write -P 0xaa 0 64M' test-qcow2.img >/dev/null
    echo "写入 64M 后 qcow2 实际占用: $(du -h test-qcow2.img | cut -f1)"
else
    echo "（qemu-io 不可用，跳过本演示）"
fi

echo
echo "--- 3.4 压缩（可压缩数据效果最直观）"
if command -v qemu-io >/dev/null 2>&1; then
    qemu-img create -f qcow2 zerofill.qcow2 "$SIZE" >/dev/null
    qemu-io -c 'write -P 0x00 0 64M' zerofill.qcow2 >/dev/null
    before=$(du -h zerofill.qcow2 | cut -f1)
    qemu-img convert -O qcow2 -c zerofill.qcow2 compressed.qcow2
    echo "写入 64M 全零后: $before  →  压缩后: $(du -h compressed.qcow2 | cut -f1)"
    echo "（全零簇被压缩算法几乎压没；真实系统盘通常省 30-70%）"
fi

##############################################
if [ "${SKIP_FIO:-0}" = "1" ] || ! command -v fio >/dev/null 2>&1; then
    echo
    echo "========== [4] fio 跳过 =========="
    echo "跳过原因: ${SKIP_FIO:+SKIP_FIO=1}${SKIP_FIO:-fio 未安装（sudo apt install -y fio）}"
else
    echo
    echo "========== [4] fio 4K 随机写对比（runtime=${FIO_RUNTIME}s） =========="
    printf "%-10s %-14s %-14s\n" "格式" "IOPS" "带宽"
    for fmt in raw qcow2 vmdk vdi; do
        out=$(fio --name=bench --filename="test-$fmt.img" \
                --size="$SIZE" --bs=4k --rw=randwrite \
                --ioengine=psync --iodepth=1 \
                --runtime="$FIO_RUNTIME" --time_based --direct=1 \
                --output-format=json 2>/dev/null || true)
        iops=$(echo "$out" | python3 -c 'import json,sys; print(f"{json.load(sys.stdin)["jobs"][0]["write"]["iops"]:.0f}")' 2>/dev/null || echo "n/a")
        bw=$(echo "$out" | python3 -c 'import json,sys; print(f"{json.load(sys.stdin)["jobs"][0]["write"]["bw"] / 1024:.1f} MiB/s")' 2>/dev/null || echo "n/a")
        printf "%-10s %-14s %-14s\n" "$fmt" "$iops" "$bw"
    done
    echo
    echo "期望：raw >= qcow2 ≈ vmdk ≈ vdi（qcow2 通常折损 5-15%）"
    echo "注意：宿主侧测的是镜像文件格式开销，VM 内 virtio-blk 的数据要另测（见 lab06）"
fi

echo
echo "========== 清理 =========="
echo "保留 $DIR 下的文件供检查，手动清理: rm -rf $DIR"
