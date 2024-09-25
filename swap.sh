#!/bin/sh

# 默认Swap大小（GB）
DEFAULT_SWAP_GB=2

# 获取传入参数，如果没有则使用默认值
if [ -n "$1" ]; then
    SWAP_GB="$1"
else
    SWAP_GB="$DEFAULT_SWAP_GB"
fi

# 检查输入是否为有效的数字
if ! echo "$SWAP_GB" | grep -E '^[0-9]+(\.[0-9]+)?$' >/dev/null 2>&1; then
    echo "错误: 参数必须是一个数字（可以是浮点数）。"
    exit 1
fi

# 计算Swap大小（MB），向上取整
SWAP_MB=$(echo "$SWAP_GB * 1024" | bc | awk '{printf "%.0f", $0}')

# Swap文件路径
SWAPFILE="/swapfile"

# 检查是否已有Swap启用
if swapon --show | grep -q "$SWAPFILE"; then
    echo "Swap已启用：$SWAPFILE"
    exit 0
fi

# 创建Swap文件
echo "创建Swap文件：$SWAPFILE，大小：${SWAP_MB}MB"
dd if=/dev/zero of=$SWAPFILE bs=1M count=$SWAP_MB status=progress

# 设置正确的权限
chmod 600 $SWAPFILE

# 设置为Swap
mkswap $SWAPFILE

# 启用Swap
swapon $SWAPFILE

# 备份/etc/fstab
cp /etc/fstab /etc/fstab.bak

# 检查是否已经在/etc/fstab中添加
grep -q "$SWAPFILE" /etc/fstab
if [ $? -ne 0 ]; then
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
    echo "已将Swap添加到/etc/fstab中。"
else
    echo "Swap已在/etc/fstab中配置。"
fi

echo "Swap已成功启用。"
