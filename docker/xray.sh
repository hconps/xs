#!/bin/bash

# ==============================================================
# 功能：Docker Compose 部署 Xray VLESS-Reality (Host模式)
# 特性：支持参数化运行、强制去除回车符、更强的容错性
# ==============================================================

# --- 1. 定义默认变量 ---
DEFAULT_PORT=28888
DEFAULT_SNI="www.microsoft.com"
CUSTOM_UUID=""
CUSTOM_PRIVATE_KEY=""
WORK_DIR="/root/xray"
IMAGE_NAME="ghcr.io/xtls/xray-core:latest"

# --- 2. 解析命令行参数 ---
usage() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -p <port>    监听端口 (默认: 28888)"
    echo "  -s <domain>  伪装域名/SNI (默认: www.microsoft.com)"
    echo "  -u <uuid>    自定义 UUID (默认: 随机生成)"
    echo "  -k <key>     自定义私钥 PrivateKey (默认: 随机生成，自动推导公钥)"
    echo "  -h           显示帮助"
    exit 1
}

while getopts "p:s:u:k:h" opt; do
    case "$opt" in
        p) PORT=$OPTARG ;;
        s) SNI=$OPTARG ;;
        u) CUSTOM_UUID=$OPTARG ;;
        k) CUSTOM_PRIVATE_KEY=$OPTARG ;;
        h) usage ;;
        *) usage ;;
    esac
done

PORT=${PORT:-$DEFAULT_PORT}
DOMAIN=${SNI:-$DEFAULT_SNI}

# --- 3. 环境检查与准备 ---
echo -e "\033[36m>>> 正在检查 Docker 环境...\033[0m"

if ! command -v curl &> /dev/null; then
    echo "正在安装 curl..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y curl
    elif [ -f /etc/redhat-release ]; then
        yum install -y curl
    fi
fi

if ! command -v docker &> /dev/null; then
    echo "Docker 未安装，正在安装..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
fi

if ! command -v docker &> /dev/null; then
    echo -e "\033[31mDocker 安装失败，请手动检查环境。\033[0m"
    exit 1
fi

mkdir -p "$WORK_DIR"
echo -e "\033[36m>>> 拉取 Xray 官方镜像...\033[0m"
docker pull "$IMAGE_NAME"

# --- 4. 密钥与 UUID 处理逻辑 (修复版) ---

# 4.1 UUID
if [ -z "$CUSTOM_UUID" ]; then
    # 增加 tr -d '\r' 去除可能存在的 Windows 回车符
    UUID=$(docker run --rm "$IMAGE_NAME" uuid | tr -d '\r')
    echo "已随机生成 UUID: $UUID"
else
    UUID=$CUSTOM_UUID
    echo "使用自定义 UUID: $UUID"
fi

# 4.2 密钥 (关键修复部分)
echo -e "\033[36m>>> 处理密钥对...\033[0m"

if [ -z "$CUSTOM_PRIVATE_KEY" ]; then
    echo "未提供私钥，正在随机生成新的密钥对..."
    # 获取原始输出
    KEYS_RAW=$(docker run --rm "$IMAGE_NAME" x25519)
    
    # 使用 awk '{print $NF}' 获取最后一个字段，并强力去除回车符
    PRIVATE_KEY=$(echo "$KEYS_RAW" | grep "Private" | awk '{print $NF}' | tr -d '\r')
    PUBLIC_KEY=$(echo "$KEYS_RAW" | grep "Public" | awk '{print $NF}' | tr -d '\r')
else
    echo "检测到自定义私钥，正在推导公钥..."
    PRIVATE_KEY=$CUSTOM_PRIVATE_KEY
    
    # 验证私钥
    KEYS_RAW=$(echo "$PRIVATE_KEY" | docker run --rm -i "$IMAGE_NAME" x25519 -i)
    if [ $? -ne 0 ]; then
        echo -e "\033[31m错误：提供的私钥无效！\033[0m"
        exit 1
    fi
    PUBLIC_KEY=$(echo "$KEYS_RAW" | grep "Public" | awk '{print $NF}' | tr -d '\r')
fi

# 4.3 最后的空值检查 (防止生成空链接)
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo -e "\033[31m严重错误：无法获取密钥对！\033[0m"
    echo "调试信息 (Raw Output):"
    echo "$KEYS_RAW"
    exit 1
fi

SHORT_ID=$(openssl rand -hex 4)

echo "------------------------------------------------"
echo "UUID:        $UUID"
echo "Public Key:  $PUBLIC_KEY"
echo "Short ID:    $SHORT_ID"
echo "------------------------------------------------"

# --- 5. 获取本机 IP ---
IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me || curl -s ipinfo.io/ip)

# --- 6. 生成配置 ---
cat > "$WORK_DIR/compose.yaml" << EOF
services:
  xray:
    image: $IMAGE_NAME
    container_name: xray
    restart: always
    network_mode: host
    command: ["run", "-c", "/etc/xray/config.json"]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
EOF

cat > "$WORK_DIR/config.json" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$DOMAIN:443",
        "xver": 0,
        "serverNames": ["$DOMAIN"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}, "tag": "force-ipv4"},
    {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv6"}, "tag": "force-ipv6"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "dns": {"servers": ["8.8.8.8", "1.1.1.1", "localhost"]},
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}]}
}
EOF

# --- 7. 启动服务 ---
echo -e "\033[36m>>> 启动 Xray 服务...\033[0m"
cd "$WORK_DIR"
if docker compose version &>/dev/null; then
    docker compose down >/dev/null 2>&1
    docker compose up -d
else
    docker-compose down >/dev/null 2>&1
    docker-compose up -d
fi

# --- 8. 输出结果 ---
VLESS_URL="vless://$UUID@${IP}:${PORT}?encryption=none&security=reality&type=tcp&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision#Xray_Reality_${IP}"
echo "$VLESS_URL" > ~/url.txt

echo ""
echo "======================================================="
echo -e "\033[32m部署完成！\033[0m"
echo "======================================================="
echo "地址: $IP"
echo "端口: $PORT"
echo "UUID: $UUID"
echo "Public Key: $PUBLIC_KEY"
echo "Private Key: $PRIVATE_KEY"
echo "-------------------------------------------------------"
echo -e "分享链接: \n\033[33m$VLESS_URL\033[0m"
echo ""
echo "======================================================="
