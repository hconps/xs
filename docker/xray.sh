#!/bin/bash

# ==============================================================
# 功能：Docker Compose 部署 Xray VLESS-Reality (Host模式)
# 特性：临时文件处理密钥 (高稳定性)、支持参数化、自动配置
# ==============================================================

# --- 1. 定义默认变量 ---
DEFAULT_PORT=28888
DEFAULT_SNI="www.microsoft.com"
CUSTOM_UUID=""
CUSTOM_PRIVATE_KEY=""
WORK_DIR="/root/xray"
IMAGE_NAME="ghcr.io/xtls/xray-core:latest"
TEMP_KEY_FILE="/tmp/xray_keys.txt"

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

# --- 4. 密钥与 UUID 处理逻辑 (文件缓冲模式) ---

# 4.1 UUID
if [ -z "$CUSTOM_UUID" ]; then
    UUID=$(docker run --rm "$IMAGE_NAME" uuid | tr -d '\r')
    echo "已随机生成 UUID: $UUID"
else
    UUID=$CUSTOM_UUID
    echo "使用自定义 UUID: $UUID"
fi

# 4.2 密钥 (使用临时文件方案)
echo -e "\033[36m>>> 处理密钥对...\033[0m"

if [ -z "$CUSTOM_PRIVATE_KEY" ]; then
    echo "未提供私钥，正在随机生成新的密钥对..."
    # 将输出同时写入文件，包含标准输出和标准错误
    docker run --rm "$IMAGE_NAME" x25519 > "$TEMP_KEY_FILE" 2>&1
    
    # 从文件读取，awk $3 代表第三列 (Private Key: xxxx)
    PRIVATE_KEY=$(grep "Private Key:" "$TEMP_KEY_FILE" | awk '{print $3}' | tr -d '\r')
    PUBLIC_KEY=$(grep "Public Key:" "$TEMP_KEY_FILE" | awk '{print $3}' | tr -d '\r')
else
    echo "检测到自定义私钥，正在推导公钥..."
    PRIVATE_KEY=$CUSTOM_PRIVATE_KEY
    
    # 验证私钥并输出到文件
    echo "$PRIVATE_KEY" | docker run --rm -i "$IMAGE_NAME" x25519 -i > "$TEMP_KEY_FILE" 2>&1
    
    # 检查命令是否执行成功（文件是否包含 Public Key）
    if ! grep -q "Public Key:" "$TEMP_KEY_FILE"; then
        echo -e "\033[31m错误：提供的私钥无效或无法推导！\033[0m"
        cat "$TEMP_KEY_FILE"
        exit 1
    fi
    PUBLIC_KEY=$(grep "Public Key:" "$TEMP_KEY_FILE" | awk '{print $3}' | tr -d '\r')
fi

# 4.3 强力检查
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo -e "\033[31m严重错误：无法获取密钥对！\033[0m"
    echo ">>> 调试信息 (Docker 原始输出):"
    cat "$TEMP_KEY_FILE"
    echo "----------------------------"
    rm -f "$TEMP_KEY_FILE"
    exit 1
fi

# 清理临时文件
rm -f "$TEMP_KEY_FILE"

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
