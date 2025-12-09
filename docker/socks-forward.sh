#!/bin/bash

# ==============================================================================
# 功能：强制 SOCKS5 + 强制 IPv4 (解决 IPv6 路由不稳导致的断流)
# 核心修改：将 domainStrategy 设为 UseIPv4
# ==============================================================================

WORK_DIR="/root/xray"
CONFIG_FILE="$WORK_DIR/config.json"
BACKUP_PATTERN="config.json.bk_*"

# --- 1. 参数解析 ---
ADDRESS=""
PORT=""
USERNAME=""
PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --address) ADDRESS="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --username) USERNAME="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# --- 2. 恢复检测 (可选) ---
cd "$WORK_DIR" || exit 1
if ls $BACKUP_PATTERN 1> /dev/null 2>&1; then
    OLDEST_BACKUP=$(ls -1 $BACKUP_PATTERN | sort | head -n 1)
    read -p "❓ 是否恢复最早备份？[y/N]: " RESTORE_CHOICE
    if [[ "$RESTORE_CHOICE" =~ ^[yY]$ ]]; then
        cat "$OLDEST_BACKUP" > "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        docker compose restart
        exit 0
    fi
fi

# --- 3. 交互输入 ---
[ -z "$ADDRESS" ] && read -p "请输入 SOCKS5 地址: " ADDRESS
[ -z "$PORT" ] && read -p "请输入 SOCKS5 端口: " PORT
if [ -z "$USERNAME" ] && [ -z "$PASSWORD" ]; then
    read -p "用户名 (回车跳过): " USERNAME
    read -p "密码 (回车跳过): " PASSWORD
fi

# --- 4. 备份 ---
cp "$CONFIG_FILE" "${CONFIG_FILE}.bk_$(date +%Y%m%d_%H%M%S)"

# --- 5. 写入配置 (强制 UseIPv4) ---
echo ">>> 正在应用 IPv4 优先策略..."

TMP_FILE=$(mktemp)

jq --arg addr "$ADDRESS" \
   --arg port "$PORT" \
   --arg user "$USERNAME" \
   --arg pass "$PASSWORD" \
   '
   # 1. 构建 SOCKS 节点
   (
     if $user != "" and $pass != "" then
       {
         tag: "proxy-landing",
         protocol: "socks",
         settings: {
           servers: [{ address: $addr, port: ($port | tonumber), users: [{user: $user, pass: $pass}] }]
         }
       }
     else
       {
         tag: "proxy-landing",
         protocol: "socks",
         settings: {
           servers: [{ address: $addr, port: ($port | tonumber) }]
         }
       }
     end
   ) as $proxy |
   
   # 2. 默认出站
   [
     {"protocol": "freedom", "tag": "direct"},
     {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}, "tag": "force-ipv4"},
     {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv6"}, "tag": "force-ipv6"},
     {"protocol": "blackhole", "tag": "block"}
   ] as $defaults |

   # 3. 覆盖 outbounds
   .outbounds = [$proxy] + $defaults |

   # 4. 路由规则：核心修改在这里！
   # domainStrategy: "UseIPv4" -> 强制将 google.com 解析为 1.2.3.4 (IPv4)
   # 这样 SOCKS5 就只会建立 IPv4 连接，避开不稳定的 IPv6
   .routing = {
     "domainStrategy": "UseIPv4",
     "rules": [
       {
         "type": "field",
         "outboundTag": "block",
         "ip": ["geoip:private"]
       },
       {
         "type": "field",
         "outboundTag": "proxy-landing",
         "network": "tcp,udp"
       }
     ]
   }
   ' "$CONFIG_FILE" > "$TMP_FILE"

# --- 6. 应用 ---
if [ -s "$TMP_FILE" ]; then
    cat "$TMP_FILE" > "$CONFIG_FILE"
    rm -f "$TMP_FILE"
    chmod 644 "$CONFIG_FILE"
    
    echo "✅ 配置已更新：强制使用 IPv4 路由。"
    docker compose restart
    echo "🎉 Xray 已重启。请再次尝试连接。"
else
    echo "❌ 失败。"
    exit 1
fi
