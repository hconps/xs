#!/bin/bash

# ==============================================================
# 功能：Docker Xray VLESS-Reality (融合版)
# 特点：使用 grep -oP 正则匹配，兼容所有版本 Xray 输出格式
# ==============================================================

# --- 1. 默认变量 ---
DEFAULT_PORT=443
DEFAULT_SNI="learn.microsoft.com"
CUSTOM_UUID=""
CUSTOM_PRIVATE_KEY=""
CUSTOM_SHORT_ID=""
WORK_DIR="/root/xray"
IMAGE_NAME="ghcr.io/xtls/xray-core:latest" 

# --- 2. 解析参数 ---
usage() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -p <port>      监听端口 (默认: 443)"
    echo "  -s <domain>    伪装域名 (默认: learn.microsoft.com)"
    echo "  -u <uuid>      自定义 UUID"
    echo "  -k <key>       自定义私钥 (会自动推导公钥)"
    echo "  -i <shortid>   自定义 ShortID"
    echo "  -h             显示帮助"
    exit 1
}

while getopts "p:s:u:k:i:h" opt; do
    case "$opt" in
        p) PORT=$OPTARG ;;
        s) SNI=$OPTARG ;;
        u) CUSTOM_UUID=$OPTARG ;;
        k) CUSTOM_PRIVATE_KEY=$OPTARG ;;
        i) CUSTOM_SHORT_ID=$OPTARG ;;
        h) usage ;;
        *) usage ;;
    esac
done

# 应用默认值
PORT=${PORT:-$DEFAULT_PORT}
DOMAIN=${SNI:-$DEFAULT_SNI}

# --- 3. 环境准备 ---
echo -e "\033[36m>>> 检查环境...\033[0m"
# 确保安装了 grep 且支持 -P (Perl正则)
if ! echo "test" | grep -P "test" &>/dev/null; then
    echo "正在安装 grep (用于正则匹配)..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y grep
    elif [ -f /etc/redhat-release ]; then
        yum install -y grep
    fi
fi

# Docker 检查
if ! command -v docker &> /dev/null; then
    echo "安装 Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
fi

mkdir -p "$WORK_DIR"
echo -e "\033[36m>>> 拉取镜像 ($IMAGE_NAME)...\033[0m"
docker pull "$IMAGE_NAME"

# --- 4. 核心逻辑：UUID 和 ShortID ---

# 4.1 UUID
if [ -z "$CUSTOM_UUID" ]; then
    UUID=$(docker run --rm "$IMAGE_NAME" uuid | tr -d '\r\n ')
    echo "已生成 UUID: $UUID"
else
    UUID=$CUSTOM_UUID
    echo "使用 UUID: $UUID"
fi

# 4.2 ShortID 
if [ -z "$CUSTOM_SHORT_ID" ]; then
    SHORT_ID=$(openssl rand -hex 4)
else
    SHORT_ID=$CUSTOM_SHORT_ID
fi

# --- 5. 核心逻辑：密钥生成 (使用 grep -oP) ---
echo -e "\033[36m>>> 处理密钥对...\033[0m"

# 定义清理函数
clean() { echo "$1" | tr -d ' \r\n\t'; }

if [ -n "$CUSTOM_PRIVATE_KEY" ]; then
    # === 场景 A: 用户提供了私钥 ===
    echo "正在根据私钥推导..."

    PRIVATE_KEY=$(clean "$CUSTOM_PRIVATE_KEY")

    # 直接把私钥作为参数传入 x25519
    OUTPUT=$(docker run --rm "$IMAGE_NAME" x25519 -i "$PRIVATE_KEY" 2>&1)

    PUBLIC_KEY=$(echo "$OUTPUT" | grep -oP '(?<=Public key: |Password: ).*')

else
    # === 场景 B: 自动生成 ===
    echo "正在生成新密钥对..."

    OUTPUT=$(docker run --rm "$IMAGE_NAME" x25519 2>&1)

    PRIVATE_KEY=$(echo "$OUTPUT" | grep -oP '(?<=Private key: |PrivateKey: ).*')
    PUBLIC_KEY=$(echo "$OUTPUT" | grep -oP '(?<=Public key: |Password: ).*')
fi

# 再次清理结果，防止 grep 抓到尾部回车
PRIVATE_KEY=$(clean "$PRIVATE_KEY")
PUBLIC_KEY=$(clean "$PUBLIC_KEY")

# 检查是否成功
if [ -z "$PUBLIC_KEY" ]; then
    echo -e "\033[31m错误：密钥提取失败！\033[0m"
    echo "原始输出如下，请检查："
    echo "$OUTPUT"
    exit 1
fi

echo "------------------------------------------------"
echo "UUID:        $UUID"
echo "Short ID:    $SHORT_ID"
echo "Private Key: $PRIVATE_KEY"
echo "Public Key:  $PUBLIC_KEY"
echo "------------------------------------------------"

# --- 6. 获取 IP ---
IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)

# --- 7. 生成配置文件 ---
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

# --- 8. 启动 ---
cd "$WORK_DIR"
docker compose down >/dev/null 2>&1
docker compose up -d

# --- 9. 输出链接 ---
# 链接中的指纹 fingerprint 建议用 chrome 或 random，这里用 chrome
FINGERPRINT="chrome"
VLESS_URL="vless://$UUID@${IP}:${PORT}?encryption=none&security=reality&type=tcp&sni=$DOMAIN&fp=$FINGERPRINT&pbk=$PUBLIC_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision#Xray_Reality_${IP}"

echo "$VLESS_URL" > ~/xray/url
echo -e "\n\033[32m✅ 部署完成！\033[0m"
echo -e "分享链接:\n\033[33m$VLESS_URL\033[0m\n"
