#!/bin/bash

# ==============================================================
# 功能：Docker Compose 部署 Xray VLESS-Reality (Host模式)
# 特性：支持参数化运行、自动生成/推导密钥、输出分享链接
# ==============================================================

# --- 1. 定义默认变量 (Default Values) ---
DEFAULT_PORT=28888
DEFAULT_SNI="www.microsoft.com"
# 默认不预设 UUID 和 Key，为空时自动生成
CUSTOM_UUID=""
CUSTOM_PRIVATE_KEY=""

# 工作目录
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

# 应用默认值
PORT=${PORT:-$DEFAULT_PORT
}
DOMAIN=${SNI:-$DEFAULT_SNI
}

# --- 3. 环境检查与准备 ---
echo -e "\033[36m>>> 正在检查 Docker 环境...\033[0m"
if ! command -v docker &> /dev/null; then
    echo "Docker 未安装，正在安装..."
    curl -fsSL https: //get.docker.com | bash
    systemctl enable docker
    systemctl start docker
fi

# 确保目录存在
mkdir -p "$WORK_DIR"

# 拉取镜像用于生成/验证密钥
echo -e "\033[36m>>> 拉取 Xray 官方镜像...\033[0m"
docker pull "$IMAGE_NAME"

# --- 4. 密钥与 UUID 处理逻辑 ---

# 4.1 UUID 处理
if [ -z "$CUSTOM_UUID"
]; then
    UUID=$(docker run --rm "$IMAGE_NAME" xray uuid)
    echo "已随机生成 UUID: $UUID"
else
    UUID=$CUSTOM_UUID
    echo "使用自定义 UUID: $UUID"
fi

# 4.2 密钥处理 (核心逻辑)
echo -e "\033[36m>>> 处理密钥对...\033[0m"

if [ -z "$CUSTOM_PRIVATE_KEY"
]; then
    # 情况 A: 无输入，全自动生成
    echo "未提供私钥，正在随机生成新的密钥对..."
    KEYS=$(docker run --rm "$IMAGE_NAME" xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3
}')
    PUBLIC_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3
}')
else
    # 情况 B: 有输入私钥，推导公钥
    echo "检测到自定义私钥，正在推导公钥..."
    PRIVATE_KEY=$CUSTOM_PRIVATE_KEY
    # 利用 xray 容器验证私钥并推导公钥 (通过管道符传入私钥)
    KEYS=$(echo "$PRIVATE_KEY" | docker run --rm -i "$IMAGE_NAME" xray x25519 -i)
    # 检查上一条命令是否执行成功
    if [ $? -ne 0
]; then
        echo -e "\033[31m错误：提供的私钥无效！\033[0m"
        exit 1
    fi
    PUBLIC_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3
}')
fi

# 生成 ShortID
SHORT_ID=$(openssl rand -hex 4)

echo "------------------------------------------------"
echo "UUID:        $UUID"
echo "Private Key: $PRIVATE_KEY"
echo "Public Key:  $PUBLIC_KEY"
echo "Short ID:    $SHORT_ID"
echo "Port:        $PORT"
echo "Domain:      $DOMAIN"
echo "------------------------------------------------"

# --- 5. 获取本机 IP ---
IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me || curl -s ipinfo.io/ip)

# --- 6. 生成 docker-compose.yaml ---
# 注意：你使用了 network_mode: host，所以 ports 映射在 compose 中是不生效的，端口由 config.json 控制
cat > "$WORK_DIR/compose.yaml" << EOF
services:
  xray:
    image: $IMAGE_NAME
    container_name: xray
    restart: always
    network_mode: host
    command: [
  "run",
  "-c",
  "/etc/xray/config.json"
]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
EOF

# --- 7. 生成 config.json ---
cat > "$WORK_DIR/config.json" << EOF
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DOMAIN:443",
          "xver": 0,
          "serverNames": [
            "$DOMAIN"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "tag": "force-ipv4"
    },
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv6"
      },
      "tag": "force-ipv6"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "dns": {
    "servers": [
      "8.8.8.8",
      "1.1.1.1",
      "localhost"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

# --- 8. 启动容器 ---
echo -e "\033[36m>>> 启动 Xray 服务...\033[0m"
cd "$WORK_DIR"
# 先停止旧的（防止端口冲突）
docker compose down >/dev/null 2>&1
docker compose up -d

# --- 9. 生成分享链接 ---
VLESS_URL="vless://$UUID@${IP}:${PORT}?encryption=none&security=reality&type=tcp&sni=$DOMAIN&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision#Xray_Reality_${IP}"

echo "$VLESS_URL" > ~/url.txt

echo ""
echo "======================================================="
echo -e "\033[32m部署完成！\033[0m"
echo "======================================================="
echo "地址 (Address): $IP"
echo "端口 (Port):    $PORT"
echo "SNI (Domain):   $DOMAIN"
echo "UUID:           $UUID"
echo "Public Key:     $PUBLIC_KEY"
echo "Private Key:    $PRIVATE_KEY (请妥善保存)"
echo "-------------------------------------------------------"
echo -e "分享链接 (已保存至 ~/url.txt): \n"
echo -e "\033[33m$VLESS_URL\033[0m"
echo ""
echo "======================================================="
