#!/bin/bash

# ===========================
# Docker Xray SOCKS5 代理安装
# 参数：端口、用户名、密码
# ===========================

# 默认变量
DEFAULT_PORT=1080
DEFAULT_USER="user"
DEFAULT_PASS="pass"
WORK_DIR="/root/xray"
IMAGE_NAME="ghcr.io/xtls/xray-core:latest"

# ===========================
# 参数解析
# ===========================
usage() {
    echo "用法: $0 [选项]"
    echo "  -p <port>     监听端口 (默认: 1080)"
    echo "  -u <user>     SOCKS5 用户名 (默认: user)"
    echo "  -w <pass>     SOCKS5 密码 (默认: pass)"
    echo "  -h            帮助"
    exit 1
}

while getopts "p:u:w:h" opt; do
    case "$opt" in
        p) PORT=$OPTARG ;;
        u) SOCKS_USER=$OPTARG ;;
        w) SOCKS_PASS=$OPTARG ;;
        h) usage ;;
        *) usage ;;
    esac
done

# 应用默认值
PORT=${PORT:-$DEFAULT_PORT}
SOCKS_USER=${SOCKS_USER:-$DEFAULT_USER}
SOCKS_PASS=${SOCKS_PASS:-$DEFAULT_PASS}

# ===========================
# 准备环境
# ===========================
echo ">>> 检查 Docker..."
if ! command -v docker &>/dev/null; then
    echo "安装 Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
fi

mkdir -p "$WORK_DIR"

echo ">>> 拉取镜像：$IMAGE_NAME"
docker pull "$IMAGE_NAME"

# ===========================
# 写入 Docker Compose
# ===========================
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

# ===========================
# 写入 SOCKS5 配置文件
# ===========================
cat > "$WORK_DIR/config.json" << EOF
{
  "log": { "loglevel": "warning" },

  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "$SOCKS_USER",
            "pass": "$SOCKS_PASS"
          }
        ],
        "udp": true
      }
    }
  ],

  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF

# ===========================
# 启动服务
# ===========================
cd "$WORK_DIR"
docker compose down >/dev/null 2>&1
docker compose up -d

# ===========================
# 展示信息
# ===========================
echo "====================================="
echo " SOCKS5 代理已部署（Docker Xray）"
echo "-------------------------------------"
echo " 地址: 服务器IP:$PORT"
echo " 用户名: $SOCKS_USER"
echo " 密码:   $SOCKS_PASS"
echo "====================================="
