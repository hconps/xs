#!/bin/bash
# 使用 getopts 解析参数，自动备份并修改 /root/xray/config.json

CONFIG_FILE="/root/xray/config.json"
BACKUP_FILE="/root/xray/config.json.bk_$(date +%Y%m%d_%H%M%S)"

usage() {
    echo "用法: $0 [-a address] [-p port] [-m username] [-k password]"
    echo "  -a    socks5 服务器地址"
    echo "  -p    端口号"
    echo "  -m    用户名（可选）"
    echo "  -k    密码（可选）"
    echo "  -h    显示帮助"
    exit 1
}

ADDRESS=""
PORT=""
USERNAME=""
PASSWORD=""

while getopts "a:p:m:k:h" opt; do
  case $opt in
    a) ADDRESS="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    m) USERNAME="$OPTARG" ;;
    k) PASSWORD="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

[ -z "$ADDRESS" ] && read -p "请输入 address: " ADDRESS
[ -z "$PORT" ] && read -p "请输入 port: " PORT
# 用户名密码可选
[ -z "$USERNAME" ] && read -p "请输入 username(可空): " USERNAME
[ -z "$PASSWORD" ] && read -p "请输入 password(可空): " PASSWORD

docker compose stop

# 备份
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo "已备份到: $BACKUP_FILE"

# ============================
# 插入 SOCKS 客户端 outbound
# ============================
if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
    # 有用户名密码
    sed -i "26i\\
    {\"protocol\": \"socks\",\"settings\": {\"servers\": [{\"address\": \"$ADDRESS\", \"port\": $PORT, \"users\": [{\"user\": \"$USERNAME\", \"pass\": \"$PASSWORD\"}]}]}}, 
" "$CONFIG_FILE"
else
    # 无用户名密码（匿名 socks）
    sed -i "26i\\
    {\"protocol\": \"socks\",\"settings\": {\"servers\": [{\"address\": \"$ADDRESS\", \"port\": $PORT}]}}, 
" "$CONFIG_FILE"
fi

echo "已插入 SOCKS 客户端配置到: $CONFIG_FILE"

docker compose up -d
echo "xray 服务已重启"
