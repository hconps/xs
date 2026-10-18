#!/bin/bash

# ==============================================================
# 功能：Docker Sing-box VLESS-Reality 自动部署脚本
# 镜像：ghcr.io/sagernet/sing-box:latest (官方镜像)
# ==============================================================

# --- 1. 默认变量 ---
DEFAULT_PORT=443
DEFAULT_SNI="learn.microsoft.com"
CUSTOM_UUID=""
CUSTOM_PRIVATE_KEY=""
CUSTOM_PUBLIC_KEY=""
CUSTOM_SHORT_ID=""
WORK_DIR="/root/sing-box"
IMAGE_NAME="ghcr.io/sagernet/sing-box:latest"

# --- 2. 解析参数 ---
usage() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  -p <port>      监听端口 (默认: 443)"
    echo "  -s <domain>    伪装域名 (默认: learn.microsoft.com)"
    echo "  -u <uuid>      自定义 UUID"
    echo "  -k <privkey>   自定义私钥 (需配合 -P 使用)"
    echo "  -P <pubkey>    自定义公钥 (配合 -k 使用)"
    echo "  -i <shortid>   自定义 ShortID"
    echo "  -h             显示帮助"
    exit 1
}

while getopts "p:s:u:k:P:i:h" opt; do
    case "$opt" in
        p) PORT=$OPTARG ;;
        s) SNI=$OPTARG ;;
        u) CUSTOM_UUID=$OPTARG ;;
        k) CUSTOM_PRIVATE_KEY=$OPTARG ;;
        P) CUSTOM_PUBLIC_KEY=$OPTARG ;;
        i) CUSTOM_SHORT_ID=$OPTARG ;;
        h) usage ;;
        *) usage ;;
    esac
done

PORT=${PORT:-$DEFAULT_PORT}
DOMAIN=${SNI:-$DEFAULT_SNI}

# --- 3. 环境准备 ---
echo -e "\033[36m>>> 检查环境...\033[0m"
if ! echo "test" | grep -P "test" &>/dev/null; then
    echo "正在安装 grep..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y grep
    elif [ -f /etc/redhat-release ]; then
        yum install -y grep
    fi
fi

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
clean() { echo "$1" | tr -d ' \r\n\t'; }

if [ -z "$CUSTOM_UUID" ]; then
    UUID=$(docker run --rm "$IMAGE_NAME" generate uuid)
    UUID=$(clean "$UUID")
    echo "已生成 UUID: $UUID"
else
    UUID=$(clean "$CUSTOM_UUID")
    echo "使用 UUID: $UUID"
fi

if [ -z "$CUSTOM_SHORT_ID" ]; then
    SHORT_ID=$(docker run --rm "$IMAGE_NAME" generate rand --hex 4)
    SHORT_ID=$(clean "$SHORT_ID")
else
    SHORT_ID=$(clean "$CUSTOM_SHORT_ID")
fi

# --- 5. 核心逻辑：密钥生成 ---
echo -e "\033[36m>>> 处理密钥对...\033[0m"

if [ -n "$CUSTOM_PRIVATE_KEY" ]; then
    if [ -z "$CUSTOM_PUBLIC_KEY" ]; then
        echo -e "\033[31m错误：sing-box 不支持从私钥推导公钥，使用 -k 时必须同时通过 -P 提供公钥！\033[0m"
        exit 1
    fi
    PRIVATE_KEY=$(clean "$CUSTOM_PRIVATE_KEY")
    PUBLIC_KEY=$(clean "$CUSTOM_PUBLIC_KEY")
else
    echo "正在生成新密钥对..."
    OUTPUT=$(docker run --rm "$IMAGE_NAME" generate reality-keypair 2>&1)
    PRIVATE_KEY=$(echo "$OUTPUT" | grep -oP 'PrivateKey: \K.*')
    PUBLIC_KEY=$(echo "$OUTPUT" | grep -oP 'PublicKey: \K.*')
fi

PRIVATE_KEY=$(clean "$PRIVATE_KEY")
PUBLIC_KEY=$(clean "$PUBLIC_KEY")

if [ -z "$PUBLIC_KEY" ] || [ -z "$PRIVATE_KEY" ]; then
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
  sing-box:
    image: $IMAGE_NAME
    container_name: sing-box
    restart: always
    network_mode: host
    command: ["run", "-c", "/etc/sing-box/config.json"]
    volumes:
      - ./config.json:/etc/sing-box/config.json:ro
EOF

cat > "$WORK_DIR/config.json" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $PORT,
      "sniff": true,
      "sniff_override_destination": false,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$DOMAIN",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

# --- 8. 启动 ---
cd "$WORK_DIR"
docker compose down >/dev/null 2>&1
docker compose up -d

# --- 9. 输出链接 ---
FINGERPRINT="ios"
VLESS_URL="vless://$UUID@${IP}:${PORT}?encryption=none&security=reality&type=tcp&sni=$DOMAIN&fp=$FINGERPRINT&pbk=$PUBLIC_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision#SingBox_Reality_${IP}"

echo "$VLESS_URL" > "$WORK_DIR/url"
echo -e "\n\033[32m✅ Sing-box 部署完成！\033[0m"
echo -e "分享链接:\n\033[33m$VLESS_URL\033[0m\n"
