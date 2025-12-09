#!/bin/bash
# 使用 getopts 解析参数，自动备份并修改 /root/xray/config.json

CONFIG_FILE="/root/xray/config.json"
BACKUP_FILE="/root/xray/config.json.bk_$(date +%Y%m%d_%H%M%S)"

usage() {
    echo "用法: $0 [-a address] [-p port] [-m method] [-k password]"
    echo "  -a    shadowsocks 服务器地址"
    echo "  -p    端口号"
    echo "  -m    加密方式 (如 aes-256-gcm)"
    echo "  -k    密码"
    echo "  -h    显示帮助"
    exit 1
}

# 默认值为空
ADDRESS=""
PORT=""
METHOD=""
PASSWORD=""

# 解析参数
while getopts "a:p:m:k:h" opt; do
  case $opt in
    a) ADDRESS="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    m) METHOD="$OPTARG" ;;
    k) PASSWORD="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

# 如果没传就提示输入
[ -z "$ADDRESS" ] && read -p "请输入 address: " ADDRESS
[ -z "$PORT" ] && read -p "请输入 port: " PORT
[ -z "$METHOD" ] && read -p "请输入 method: " METHOD
[ -z "$PASSWORD" ] && read -p "请输入 password: " PASSWORD

docker compose stop

# 备份
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo "已备份到: $BACKUP_FILE"

# 插入配置到第 26 行
sed -i "26i\\
    {\"protocol\": \"shadowsocks\",\"settings\": {\"servers\": [{\"address\": \"$ADDRESS\", \"port\": $PORT, \"method\": \"$METHOD\", \"password\": \"$PASSWORD\"}]}},
" "$CONFIG_FILE"

echo "已修改配置文件: $CONFIG_FILE"

# 重启 xray 服务
docker compose up -d
echo "xray 服务已重启"
