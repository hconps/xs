#!/bin/bash

# ===========================
# Docker Xray Shadowsocks 安装
# 参数：端口、密码、加密方式
# ===========================

# 默认变量
DEFAULT_PORT=8388
DEFAULT_PASS="password"
DEFAULT_METHOD="aes-256-gcm"  # 推荐使用 aes-256-gcm 或 chacha20-poly1305
WORK_DIR="/root/xray-ss"
IMAGE_NAME="ghcr.io/xtls/xray-core:latest"

# ===========================
# 参数解析
# ===========================
usage() {
    echo "用法: $0 [选项]"
    echo "  -p <port>     监听端口 (默认: 8388)"
    echo "  -w <pass>     Shadowsocks 密码 (默认: password)"
    echo "  -m <method>   加密方式 (默认: aes-256-gcm，可选 chacha20-poly1305)"
    echo "  -h            帮助"
    exit 1
}

while getopts "p:w:m:h" opt; do
    case "$opt" in
        p) PORT=$OPTARG ;;
        w) SS_PASS=$OPTARG ;;
        m) SS_METHOD=$OPTARG ;;
        h) usage ;;
        *) usage ;;
    esac
done

# 应用默认值
PORT=${PORT:-$DEFAULT_PORT}
SS_PASS=${SS_PASS:-$DEFAULT_PASS}
SS_METHOD=${SS_METHOD:-$DEFAULT_METHOD}

# ===========================
# 准备环境
# ===========================
echo ">>> 检查 Docker..."
if ! command -v docker &>/dev/null; then
    echo "安装 Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
else
    echo "Docker 已安装"
fi

# 检查 Docker Compose 插件
if ! docker compose version >/dev/null 2>&1; then
    echo ">>> 警告: 未检测到 docker compose 插件，尝试使用旧版 docker-compose..."
    if ! command -v docker-compose &>/dev/null; then
        echo "错误: 未找到 docker compose 或 docker-compose 命令。"
        exit 1
    fi
    DOCKER_COMPOSE_CMD="docker-compose"
else
    DOCKER_COMPOSE_CMD="docker compose"
fi

mkdir -p "$WORK_DIR"

echo ">>> 拉取镜像：$IMAGE_NAME"
docker pull "$IMAGE_NAME"

# ===========================
# 写入 Docker Compose
# ===========================
# 注意：Shadowsocks 也是 TCP/UDP 协议，network_mode: host 依然是最简便的端口映射方式
cat > "$WORK_DIR/compose.yaml" << EOF
services:
  xray:
    image: $IMAGE_NAME
    container_name: xray-ss
    restart: always
    network_mode: host
    command: ["run", "-c", "/etc/xray/config.json"]
    volumes:
      - ./config.json:/etc/xray/config.json:ro
EOF

# ===========================
# 写入 Shadowsocks 配置文件
# ===========================
cat > "$WORK_DIR/config.json" << EOF
{
  "log": { "loglevel": "warning" },

  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "shadowsocks",
      "settings": {
        "method": "$SS_METHOD",
        "password": "$SS_PASS",
        "network": "tcp,udp"
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
echo ">>> 正在启动服务..."
$DOCKER_COMPOSE_CMD down >/dev/null 2>&1
$DOCKER_COMPOSE_CMD up -d

# ===========================
# 获取本机 IP (用于展示)
# ===========================
SERVER_IP=$(curl -s ifconfig.me || echo "你的服务器IP")
BASE64_CODE=$(echo -n "${SS_METHOD}:${SS_PASS}@${SERVER_IP}:${PORT}" | base64 -w 0)
SS_LINK="ss://${BASE64_CODE}#Docker-SS"

# ===========================
# 展示信息
# ===========================
echo ""
echo "====================================="
echo " Shadowsocks 代理已部署（Docker Xray）"
echo "-------------------------------------"
echo " 地址 (IP):  $SERVER_IP"
echo " 端口 (Port): $PORT"
echo " 密码 (Pass): $SS_PASS"
echo " 加密 (Method): $SS_METHOD"
echo "-------------------------------------"
echo " SS 链接 (可复制到客户端):"
echo " $SS_LINK"
echo "====================================="
