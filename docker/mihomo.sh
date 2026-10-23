#!/bin/bash

# ==============================================================
# 功能：Docker Mihomo (Clash.Meta) VLESS-Reality & SS-2022 自动部署脚本
# 包含：Docker 自动检查与更新
# ==============================================================

# --- 1. 默认变量 ---
DEFAULT_PORT_VLESS=443
DEFAULT_PORT_CHACHA=444
DEFAULT_PORT_AES=445
DEFAULT_SNI="learn.microsoft.com"
WORK_DIR="/root/mihomo"
IMAGE_NAME="metacubex/mihomo:latest"

MODE_SPECIFIED=0
ENABLE_VLESS=0
ENABLE_SS_CHACHA=0
ENABLE_SS_AES=0

# --- 2. 解析长参数 ---
usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "VLESS Reality 选项:"
    echo "  --vless               启用 VLESS-Reality"
    echo "  --port-vless <port>   指定 VLESS 监听端口 (默认: 443)"
    echo "  --domain <domain>     指定伪装域名 (默认: learn.microsoft.com)"
    echo "  --uuid <uuid>         自定义 UUID"
    echo "  --private-key <key>   自定义私钥 (需配合公钥使用)"
    echo "  --public-key <key>    自定义公钥 (需配合私钥使用)"
    echo "  --short-id <id>       自定义 ShortID"
    echo ""
    echo "Shadowsocks (Chacha20) 选项:"
    echo "  --ss-chacha           启用 2022-blake3-chacha20-poly1305"
    echo "  --port-chacha <port>  指定 SS-Chacha20 监听端口 (默认: 444)"
    echo "  --pwd-chacha <pwd>    指定 SS-Chacha 密码 (需 32-byte Base64)"
    echo ""
    echo "Shadowsocks (AES-128) 选项:"
    echo "  --ss-aes              启用 2022-blake3-aes-128-gcm"
    echo "  --port-aes <port>     指定 SS-AES 监听端口 (默认: 445)"
    echo "  --pwd-aes <pwd>       指定 SS-AES 密码 (需 16-byte Base64)"
    echo ""
    echo "  --help                显示帮助"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --vless) ENABLE_VLESS=1; MODE_SPECIFIED=1; shift ;;
        --port-vless) PORT_VLESS="$2"; ENABLE_VLESS=1; MODE_SPECIFIED=1; shift 2 ;;
        --domain) SNI="$2"; ENABLE_VLESS=1; MODE_SPECIFIED=1; shift 2 ;;
        --uuid) CUSTOM_UUID="$2"; ENABLE_VLESS=1; MODE_SPECIFIED=1; shift 2 ;;
        --private-key) CUSTOM_PRIVATE_KEY="$2"; ENABLE_VLESS=1; MODE_SPECIFIED=1; shift 2 ;;
        --public-key) CUSTOM_PUBLIC_KEY="$2"; ENABLE_VLESS=1; MODE_SPECIFIED=1; shift 2 ;;
        --short-id) CUSTOM_SHORT_ID="$2"; ENABLE_VLESS=1; MODE_SPECIFIED=1; shift 2 ;;
        
        --ss-chacha) ENABLE_SS_CHACHA=1; MODE_SPECIFIED=1; shift ;;
        --port-chacha) PORT_CHACHA="$2"; ENABLE_SS_CHACHA=1; MODE_SPECIFIED=1; shift 2 ;;
        --pwd-chacha) SS_CHACHA_PWD="$2"; ENABLE_SS_CHACHA=1; MODE_SPECIFIED=1; shift 2 ;;
        
        --ss-aes) ENABLE_SS_AES=1; MODE_SPECIFIED=1; shift ;;
        --port-aes) PORT_AES="$2"; ENABLE_SS_AES=1; MODE_SPECIFIED=1; shift 2 ;;
        --pwd-aes) SS_AES_PWD="$2"; ENABLE_SS_AES=1; MODE_SPECIFIED=1; shift 2 ;;

        --help) usage ;;
        *) echo -e "\033[31m未知参数: $1\033[0m"; usage ;;
    esac
done

# 如果未指定任何协议开启参数，默认全开
if [ "$MODE_SPECIFIED" -eq 0 ]; then
    ENABLE_VLESS=1
    ENABLE_SS_CHACHA=1
    ENABLE_SS_AES=1
fi

# 赋默认值
PORT_VLESS=${PORT_VLESS:-$DEFAULT_PORT_VLESS}
PORT_CHACHA=${PORT_CHACHA:-$DEFAULT_PORT_CHACHA}
PORT_AES=${PORT_AES:-$DEFAULT_PORT_AES}
DOMAIN=${SNI:-$DEFAULT_SNI}

# --- 3. 环境准备与 Docker 更新检查 ---
echo -e "\033[36m>>> 检查环境与 Docker 版本...\033[0m"
if ! echo "test" | grep -P "test" &>/dev/null; then
    echo "正在安装 grep..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y grep curl
    elif [ -f /etc/redhat-release ]; then
        yum install -y grep curl
    fi
fi

if ! command -v docker &> /dev/null; then
    echo "未检测到 Docker，正在安装全新 Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
else
    # 检查 Docker 更新
    LOCAL_VERSION=$(docker -v | awk '{print $3}' | tr -d ',')
    LATEST_VERSION=$(curl -sI https://github.com/docker/cli/releases/latest | grep -i "^location:" | awk -F'/v' '{print $2}' | tr -d '\r')

    if [ -n "$LATEST_VERSION" ] && [ "$LOCAL_VERSION" != "$LATEST_VERSION" ]; then
        # 比较版本号，判断本地是否低于最新版
        if [ "$(printf '%s\n' "$LOCAL_VERSION" "$LATEST_VERSION" | sort -V | head -n1)" = "$LOCAL_VERSION" ]; then
            echo -e "\033[33m发现 Docker 新版本: $LATEST_VERSION (当前版本: $LOCAL_VERSION)，正在自动更新...\033[0m"
            curl -fsSL https://get.docker.com | bash
            systemctl restart docker
            echo -e "\033[32mDocker 已更新至 $LATEST_VERSION\033[0m"
        else
            echo "Docker 当前版本 ($LOCAL_VERSION) 已是最新或更高。"
        fi
    else
        echo "Docker 已是最新版本 ($LOCAL_VERSION)。"
    fi
fi

mkdir -p "$WORK_DIR"
echo -e "\033[36m>>> 拉取镜像 ($IMAGE_NAME)...\033[0m"
docker pull "$IMAGE_NAME"

clean() { echo "$1" | tr -d ' \r\n\t'; }

# --- 4. 生成对应协议的参数 ---
echo -e "\033[36m>>> 处理凭证和密钥...\033[0m"

# VLESS 配置
if [ "$ENABLE_VLESS" -eq 1 ]; then
    if [ -z "$CUSTOM_UUID" ]; then
        UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
        UUID=$(clean "$UUID")
    else
        UUID=$(clean "$CUSTOM_UUID")
    fi

    if [ -z "$CUSTOM_SHORT_ID" ]; then
        SHORT_ID=$(openssl rand -hex 4)
        SHORT_ID=$(clean "$SHORT_ID")
    else
        SHORT_ID=$(clean "$CUSTOM_SHORT_ID")
    fi

    if [ -n "$CUSTOM_PRIVATE_KEY" ]; then
        if [ -z "$CUSTOM_PUBLIC_KEY" ]; then
            echo -e "\033[31m错误：mihomo 不支持从私钥推导公钥，使用自定义私钥时必须同时提供公钥 (--public-key)！\033[0m"
            exit 1
        fi
        PRIVATE_KEY=$(clean "$CUSTOM_PRIVATE_KEY")
        PUBLIC_KEY=$(clean "$CUSTOM_PUBLIC_KEY")
    else
        OUTPUT=$(docker run --rm "$IMAGE_NAME" generate reality-keypair 2>&1)
        PRIVATE_KEY=$(echo "$OUTPUT" | grep -oP 'PrivateKey: \K.*')
        PUBLIC_KEY=$(echo "$OUTPUT" | grep -oP 'PublicKey: \K.*')
    fi
    PRIVATE_KEY=$(clean "$PRIVATE_KEY")
    PUBLIC_KEY=$(clean "$PUBLIC_KEY")
fi

# SS Chacha20 配置
if [ "$ENABLE_SS_CHACHA" -eq 1 ]; then
    if [ -z "$SS_CHACHA_PWD" ]; then
        SS_CHACHA_PWD=$(openssl rand -base64 32)
    fi
    SS_CHACHA_PWD=$(clean "$SS_CHACHA_PWD")
fi

# SS AES-128 配置
if [ "$ENABLE_SS_AES" -eq 1 ]; then
    if [ -z "$SS_AES_PWD" ]; then
        SS_AES_PWD=$(openssl rand -base64 16)
    fi
    SS_AES_PWD=$(clean "$SS_AES_PWD")
fi

# --- 5. 获取 IP ---
IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)

# --- 6. 生成配置文件 ---
echo -e "\033[36m>>> 生成配置文件...\033[0m"

cat > "$WORK_DIR/compose.yaml" << EOF
services:
  mihomo:
    image: $IMAGE_NAME
    container_name: mihomo
    restart: always
    network_mode: host
    volumes:
      - ./config.yaml:/root/.config/mihomo/config.yaml:ro
EOF

# 初始化 config.yaml
cat > "$WORK_DIR/config.yaml" << EOF
log-level: info
mode: direct
ipv6: true

listeners:
EOF

# 追加 VLESS
if [ "$ENABLE_VLESS" -eq 1 ]; then
cat >> "$WORK_DIR/config.yaml" << EOF
  - name: vless-reality-in
    type: vless
    port: $PORT_VLESS
    listen: "::"
    users:
      - username: user1
        uuid: "$UUID"
        flow: xtls-rprx-vision
    reality-config:
      dest: $DOMAIN:443
      private-key: "$PRIVATE_KEY"
      short-id:
        - "$SHORT_ID"
      server-names:
        - "$DOMAIN"
EOF
fi

# 追加 SS-Chacha20
if [ "$ENABLE_SS_CHACHA" -eq 1 ]; then
cat >> "$WORK_DIR/config.yaml" << EOF
  - name: ss-chacha20-in
    type: shadowsocks
    port: $PORT_CHACHA
    listen: "::"
    cipher: 2022-blake3-chacha20-poly1305
    password: "$SS_CHACHA_PWD"
    udp: true
EOF
fi

# 追加 SS-AES
if [ "$ENABLE_SS_AES" -eq 1 ]; then
cat >> "$WORK_DIR/config.yaml" << EOF
  - name: ss-aes-128-in
    type: shadowsocks
    port: $PORT_AES
    listen: "::"
    cipher: 2022-blake3-aes-128-gcm
    password: "$SS_AES_PWD"
    udp: true
EOF
fi

# --- 7. 启动 ---
cd "$WORK_DIR"
docker compose down >/dev/null 2>&1
docker compose up -d

# --- 8. 输出链接 ---
echo -e "\n\033[32m✅ Mihomo 部署完成！\033[0m"
echo "------------------------------------------------"
> "$WORK_DIR/url"

if [ "$ENABLE_VLESS" -eq 1 ]; then
    FINGERPRINT="ios"
    VLESS_URL="vless://$UUID@${IP}:${PORT_VLESS}?encryption=none&security=reality&type=tcp&sni=$DOMAIN&fp=$FINGERPRINT&pbk=$PUBLIC_KEY&sid=$SHORT_ID&flow=xtls-rprx-vision#Mihomo_Reality"
    echo "$VLESS_URL" >> "$WORK_DIR/url"
    echo -e "VLESS-Reality 端口: $PORT_VLESS"
    echo -e "VLESS 链接:\n\033[33m$VLESS_URL\033[0m\n"
fi

if [ "$ENABLE_SS_CHACHA" -eq 1 ]; then
    SS_METHOD="2022-blake3-chacha20-poly1305"
    SS_USERINFO=$(echo -n "${SS_METHOD}:${SS_CHACHA_PWD}" | base64 | tr -d '\n')
    SS_CHACHA_URL="ss://${SS_USERINFO}@${IP}:${PORT_CHACHA}#Mihomo_SS_Chacha20"
    echo "$SS_CHACHA_URL" >> "$WORK_DIR/url"
    echo -e "SS-Chacha20 端口: $PORT_CHACHA"
    echo -e "SS-Chacha20 链接:\n\033[33m$SS_CHACHA_URL\033[0m\n"
fi

if [ "$ENABLE_SS_AES" -eq 1 ]; then
    SS_METHOD="2022-blake3-aes-128-gcm"
    SS_USERINFO=$(echo -n "${SS_METHOD}:${SS_AES_PWD}" | base64 | tr -d '\n')
    SS_AES_URL="ss://${SS_USERINFO}@${IP}:${PORT_AES}#Mihomo_SS_AES128"
    echo "$SS_AES_URL" >> "$WORK_DIR/url"
    echo -e "SS-AES128 端口: $PORT_AES"
    echo -e "SS-AES128 链接:\n\033[33m$SS_AES_URL\033[0m\n"
fi

echo "所有节点链接已保存至: $WORK_DIR/url"
echo "------------------------------------------------"
