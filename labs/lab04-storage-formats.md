# Lab 04 · 磁盘镜像格式对比

> **难度**：★★  
> **前置**：Lab 03  
> **预计时间**：30 分钟

## 目标

- 创建 raw / qcow2 / vmdk / vdi 四种格式
- 跑 fio 测性能差异
- 验证 qcow2 的快照、稀疏、压缩特性

## 实验步骤

### 1. 创建四种镜像

```bash
cd /tmp
mkdir -p lab04 && cd lab04

for fmt in raw qcow2 vmdk vdi; do
    qemu-img create -f $fmt test-$fmt.img 1G
done

ls -lh *.img
```

### 2. 看实际占用（稀疏特性）

```bash
du -h *.img
# qcow2/vmdk/vdi 实际占用远小于 1G（仅元数据）
# raw 立刻占用 1G
```

### 3. 性能对比：fio

#### 3.1 用 libguestfs 直接测镜像

```bash
sudo apt install -y fio libguestfs-tools

# 写性能（裸盘 IOPS）
for fmt in raw qcow2 vmdk vdi; do
    echo "=== $fmt ==="
    sudo fio --name=randwrite \
        --filename=/tmp/lab04/test-$fmt.img \
        --size=512M --bs=4k --rw=randwrite \
        --ioengine=psync --iodepth=1 \
        --runtime=10 --time_based --direct=1 \
        --output-format=normal 2>/dev/null \
        | grep -E '^(write|IOPS|BW)'
done
```

#### 3.2 期望结果

- raw 性能最好（无额外开销）
- qcow2 写损耗约 5-15%
- vmdk / vdi 与 qcow2 类似，差异不大

### 4. qcow2 独有特性

#### 4.1 快照

```bash
# 在跑着的 VM 上做快照
virsh snapshot-create lab03 --name "before-upgrade"

# 查
virsh snapshot-list lab03

# 回滚
virsh snapshot-revert lab03 --snapshotname "before-upgrade"

# 删
virsh snapshot-delete lab03 --snapshotname "before-upgrade"
```

> ⚠️ 生产中更多用 external snapshot（基于 backing file），方便做镜像分层。

#### 4.2 backing file（差分镜像）

```bash
# base 镜像
qemu-img create -f qcow2 -o backing_file=base.qcow2 \
    -F qcow2 delta.qcow2

# delta 改动不影响 base
# 配合云镜像：base 不动，每个 VM 一个 delta
```

#### 4.3 压缩

```bash
qemu-img convert -O qcow2 -c input.qcow2 output-compressed.qcow2
# 通常能省 30-70% 空间
```

#### 4.4 加密

```bash
qemu-img create -f qcow2 -o encryption=on secret.qcow2 1G
# 会要求输入密码
```

## 优劣对比：什么时候用什么格式

| 场景 | 推荐格式 |
| --- | --- |
| 高性能（数据库） | raw / qcow2 with preallocation=falloc |
| 通用 VM | qcow2 |
| 多 VM 共用 base | qcow2 backing file |
| 跨平台（VMware） | vmdk |
| 跨平台（VBox） | vdi |

## 输出记录

1. 四种镜像实际占用各是多少？
2. fio 测得的 IOPS 排序？
3. qcow2 压缩前后文件大小对比？

## 下一步

[Lab 05 - 网络模式](lab05-network-modes.md)
