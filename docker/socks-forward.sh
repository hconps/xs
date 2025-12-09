#!/bin/bash

# ==============================================================================
# 功能：强制重置 Xray Outbounds 为：SOCKS5 + 默认规则
# 修复：解决 mv 命令导致 Docker 挂载失效的问题
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

# --- 2. 恢复模式检测 ---
cd "$WORK_DIR" || exit 1
if ls $BACKUP_PATTERN 1> /dev/null 2>&1; then
    OLDEST_BACKUP=$(ls -1 $BACKUP_PATTERN | sort | head -n 1)
    echo "--------------------------------------------------------"
    echo "📅 发现最早备份: $OLDEST_BACKUP"
    read -p "❓ 是否放弃修改，直接恢复纯净配置并重启？[y/N]: " RESTORE_CHOICE
    if [[ "$RESTORE_CHOICE" =~ ^[yY]$ ]]; then
        echo ">>> 恢复中 (使用 cat 保持 inode)..."
        cat "$OLDEST_BACKUP" > "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        docker compose restart
        echo "✅ 已恢复并重启。脚本退出。"
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

# --- 5. 使用 jq 覆盖 Outbounds (核心逻辑) ---
echo ">>> 正在重写配置文件..."

TMP_FILE=$(mktemp)

# jq 逻辑说明：
# 1. 构造新的 proxy 对象 ($proxy)
# 2. 构造固定的默认规则列表 ($defaults)
# 3. 将 .outbounds 直接赋值为 [$proxy] + $defaults (彻底替换旧列表)
jq --arg addr "$ADDRESS" \
   --arg port "$PORT" \
   --arg user "$USERNAME" \
   --arg pass "$PASSWORD" \
   '
   # 1. 构建 SOCKS 节点
   (
     if $user != "" and $pass != "" then
       {
         protocol: "socks",
         settings: {
           servers: [{ address: $addr, port: ($port | tonumber), users: [{user: $user, pass: $pass}] }]
         }
       }
     else
       {
         protocol: "socks",
         settings: {
           servers: [{ address: $addr, port: ($port | tonumber) }]
         }
       }
     end
   ) as $proxy |
   
   # 2. 定义你要求的固定后置规则
   [
     {"protocol": "freedom", "tag": "direct"},
     {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}, "tag": "force-ipv4"},
     {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv6"}, "tag": "force-ipv6"},
     {"protocol": "blackhole", "tag": "block"}
   ] as $defaults |

   # 3. 覆盖 outbounds (保持其他配置不变)
   .outbounds = [$proxy] + $defaults
   ' "$CONFIG_FILE" > "$TMP_FILE"

# --- 6. 写入与重启 ---
if [ -s "$TMP_FILE" ]; then
    # 【关键修复】使用 cat 覆盖，保持文件 inode 不变，确保 Docker 能立刻读到
    cat "$TMP_FILE" > "$CONFIG_FILE"
    rm -f "$TMP_FILE"
    
    chmod 644 "$CONFIG_FILE"
    echo "✅ 配置文件修改成功 (格式已重置为 SOCKS + 默认规则)。"
    
    echo ">>> 重启 Xray..."
    docker compose restart
    echo "🎉 完成。"
else
    echo "❌ 修改失败，文件为空。"
    rm -f "$TMP_FILE"
    exit 1
fi
