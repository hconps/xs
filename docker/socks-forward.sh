#!/bin/bash

# ==============================================================================
# 功能：自动安装 jq，支持 SOCKS5 添加，或一键恢复最早备份并重启
# 逻辑变更：若用户选择恢复备份，则恢复后立即重启并退出脚本，不进行后续修改。
# ==============================================================================

WORK_DIR="/root/xray"
CONFIG_FILE="$WORK_DIR/config.json"
BACKUP_PATTERN="config.json.bk_*"

# --- 1. 帮助信息 ---
usage() {
    echo "用法: $0 [选项]"
    echo "  --address   <ip>      SOCKS5 服务器地址"
    echo "  --port      <num>     端口号"
    echo "  --username  <str>     用户名（可选）"
    echo "  --password  <str>     密码（可选）"
    echo "  --help                显示帮助"
    exit 1
}

ADDRESS=""
PORT=""
USERNAME=""
PASSWORD=""

# --- 2. 解析长参数 ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --address) ADDRESS="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --username) USERNAME="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --help) usage ;;
        *) echo "❌ 未知参数: $1"; usage ;;
    esac
done

# --- 3. 智能回滚/恢复检测 (逻辑已修改) ---
cd "$WORK_DIR" || { echo "❌ 目录 $WORK_DIR 不存在"; exit 1; }

# 检查是否存在备份文件
if ls $BACKUP_PATTERN 1> /dev/null 2>&1; then
    # 获取最早的一个备份文件 (sort 默认按字符排序，时间戳文件名可以直接排序)
    OLDEST_BACKUP=$(ls -1 $BACKUP_PATTERN | sort | head -n 1)
    
    echo "--------------------------------------------------------"
    echo "🔍 检测到历史备份文件。"
    echo "📅 最早的备份是: $OLDEST_BACKUP"
    echo "--------------------------------------------------------"
    
    read -p "❓ 是否放弃当前修改，直接恢复到该最早备份？[y/N]: " RESTORE_CHOICE
    
    if [[ "$RESTORE_CHOICE" == "y" || "$RESTORE_CHOICE" == "Y" ]]; then
        echo ">>> 正在从 $OLDEST_BACKUP 恢复配置..."
        
        # 1. 覆盖配置
        cp "$OLDEST_BACKUP" "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        
        # 2. 重启服务
        echo ">>> 正在重启 Xray 服务以应用旧配置..."
        if docker compose version &>/dev/null; then
            docker compose restart
        else
            docker-compose restart
        fi
        
        echo "✅ 已恢复到最早备份并重启成功。脚本退出。"
        echo "--------------------------------------------------------"
        
        # 3. 【关键修改】恢复后直接退出，不执行后面代码
        exit 0
    else
        echo ">>> 跳过恢复，将在当前配置基础上添加新代理..."
    fi
    echo "--------------------------------------------------------"
fi

# ==========================================================
# 下面的代码只有在“没有备份”或者“用户选择不恢复(N)”时才会执行
# ==========================================================

# --- 4. 交互式输入补全 ---
[ -z "$ADDRESS" ] && read -p "请输入 SOCKS5 地址 (--address): " ADDRESS
[ -z "$PORT" ] && read -p "请输入 SOCKS5 端口 (--port): " PORT
if [ -z "$USERNAME" ] && [ -z "$PASSWORD" ]; then
    read -p "请输入用户名 (回车跳过): " USERNAME
    read -p "请输入密码 (回车跳过): " PASSWORD
fi

# --- 5. jq 环境检测 ---
if ! command -v jq &> /dev/null; then
    echo ">>> 未检测到 jq，正在安装..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y jq
    else
        echo "❌ 本脚本仅自动支持 Debian/Ubuntu 安装 jq。"
        echo "请手动运行安装命令 (如: apk add jq) 后重试。"
        exit 1
    fi
fi

# --- 6. 创建本次操作的新备份 ---
NEW_BACKUP_FILE="${CONFIG_FILE}.bk_$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG_FILE" "$NEW_BACKUP_FILE"
echo ">>> 已为本次修改创建备份: $NEW_BACKUP_FILE"

# --- 7. 使用 jq 修改 JSON ---
echo ">>> 正在写入配置..."

TMP_FILE=$(mktemp)

# jq 逻辑
jq --arg addr "$ADDRESS" \
   --arg port "$PORT" \
   --arg user "$USERNAME" \
   --arg pass "$PASSWORD" \
   '
   (
     if $user != "" and $pass != "" then
       {
         protocol: "socks",
         tag: "proxy-socks-jq",
         settings: {
           servers: [{ address: $addr, port: ($port | tonumber), users: [{user: $user, pass: $pass}] }]
         }
       }
     else
       {
         protocol: "socks",
         tag: "proxy-socks-jq",
         settings: {
           servers: [{ address: $addr, port: ($port | tonumber) }]
         }
       }
     end
   ) as $new_proxy | 
   .outbounds = [$new_proxy] + .outbounds
   ' "$CONFIG_FILE" > "$TMP_FILE"

# --- 8. 验证与重启 ---
if [ -s "$TMP_FILE" ]; then
    mv "$TMP_FILE" "$CONFIG_FILE"
    chmod 644 "$CONFIG_FILE"
    echo "✅ 配置文件修改成功！"
    
    echo ">>> 重启 Xray 服务..."
    if docker compose version &>/dev/null; then
        docker compose restart
    else
        docker-compose restart
    fi
    echo "🎉 服务已重启。"
else
    echo "❌ jq 处理失败，文件未修改。"
    rm -f "$TMP_FILE"
    exit 1
fi
