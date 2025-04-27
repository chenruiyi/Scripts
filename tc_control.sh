#!/bin/bash
# 用法：./tc_control.sh set|clear
# 参数 set ：更新软件包、安装 ifstat 工具，配置默认网络接口的 HTB 带宽限制，速率为 170Mbps，并显示状态及流量统计。
# 参数 clear ：删除默认网络接口上的流量控制配置，恢复默认设置。

if [ "$#" -ne 1 ]; then
    echo "用法: $0 set|clear"
    exit 1
fi

# 自动检测默认网络接口
DEFAULT_IF=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
if [ -z "$DEFAULT_IF" ]; then
    echo "无法检测到默认网络接口，请手动指定接口名称。"
    exit 1
fi
echo "检测到默认网络接口：$DEFAULT_IF"

MODE=$1

case "$MODE" in
    set)
        echo "==> 更新 apt 缓存并安装 ifstat 工具..."
        apt update && apt install -y ifstat

        echo "==> 删除现有流量控制配置（若存在）..."
        tc qdisc del dev "$DEFAULT_IF" root 2>/dev/null

        echo "==> 添加根队列（HTB）控制器..."
        tc qdisc add dev "$DEFAULT_IF" root handle 1: htb default 12

        echo "==> 添加带宽限制类：设置上传和下载速率均为 170Mbps..."
        tc class add dev "$DEFAULT_IF" parent 1: classid 1:12 htb rate 170Mbit ceil 170Mbit burst 1572b cburst 1572b

        echo "==> 当前流量控制配置状态："
        tc -s qdisc

        echo "==> 查看接口流量统计（netstat）："
        netstat -i

        echo "==> 查看当前网络连接（ss）："
        ss -tuln

        echo "==> 开始实时监控 $DEFAULT_IF 流量 (ifstat，每秒刷新；按 Ctrl+C 退出)..."
        ifstat -i "$DEFAULT_IF" 1
        ;;
    clear)
        echo "==> 清除流量控制配置，恢复默认设置..."
        tc qdisc del dev "$DEFAULT_IF" root 2>/dev/null
        echo "流量控制已清除，接口恢复默认配置。"
        ;;
    *)
        echo "无效参数。用法: $0 set|clear"
        exit 1
        ;;
esac
