#!/bin/bash

# 颜色定义
red='\e[91m'
green='\e[92m'
yellow='\e[93m'
cyan='\e[96m'
none='\e[0m'

# 帮助函数
usage() {
    echo -e "
${yellow}使用方法:${none}
  bash cf_kv_manager.sh --account <ID> --token <Token> --kv <KV_ID> --list-key <KeyName> [选项]

${yellow}必要参数:${none}
  --account    Cloudflare Account ID
  --token      Cloudflare API Token (需有 KV Write 权限)
  --kv         KV Namespace ID
  --list-key   KV 中存储订阅列表的键名 (例如: my_subscribe_list)

${yellow}可选参数:${none}
  --file       指定 VLESS 节点文件 (默认: ~/_vless_reality_url_)
  --alias      节点备注名 (如果不传，脚本运行时会要求输入)
"
}

# 默认值
file_path=~/_vless_reality_url_
account_id=""
api_token=""
kv_id=""
list_key=""
node_alias=""

# 解析参数
ARGS=$(getopt -o '' --long account:,token:,kv:,list-key:,file:,alias:,help -n "$0" -- "$@")
if [ $? != 0 ]; then usage; exit 1; fi
eval set -- "${ARGS}"

while true; do
    case "$1" in
        --account) account_id="$2"; shift 2 ;;
        --token) api_token="$2"; shift 2 ;;
        --kv) kv_id="$2"; shift 2 ;;
        --list-key) list_key="$2"; shift 2 ;;
        --file) file_path="$2"; shift 2 ;;
        --alias) node_alias="$2"; shift 2 ;;
        --help) usage; exit 0 ;;
        --) shift; break ;;
        *) usage; exit 1 ;;
    esac
done

# 1. 检查必要参数
if [[ -z "$account_id" || -z "$api_token" || -z "$kv_id" || -z "$list_key" ]]; then
    echo -e "${red}错误：缺少 Cloudflare API 相关参数！${none}"
    usage
    exit 1
fi

# 2. 读取本地节点文件
if [[ ! -f "$file_path" ]]; then
    echo -e "${red}错误：找不到节点文件 $file_path${none}"
    exit 1
fi
raw_url=$(cat "$file_path")
if [[ -z "$raw_url" ]]; then
    echo -e "${red}错误：节点文件为空${none}"
    exit 1
fi

# 3. 获取并修改备注
# 如果没有通过命令行传入别名，则请求用户输入
if [[ -z "$node_alias" ]]; then
    echo -e "${cyan}当前节点: $raw_url${none}"
    read -p "请输入该节点的备注名 (将作为 #后的内容): " node_alias
fi

if [[ -z "$node_alias" ]]; then
    echo -e "${red}错误：备注名不能为空${none}"
    exit 1
fi

# 替换 # 后面的内容
# ${raw_url%#*} 删除最后一个 # 及其右边的内容
final_url="${raw_url%#*}#${node_alias}"
echo -e "${green}预处理 URL: $final_url${none}"

# 4. 获取 Cloudflare KV 当前列表
echo -e "${yellow}正在获取远程 KV 列表...${none}"
remote_content=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/storage/kv/namespaces/${kv_id}/values/${list_key}" \
     -H "Authorization: Bearer ${api_token}")

# 检查是否获取成功 (如果 key 不存在，CF 会返回错误代码，curl 获取到的可能不是纯文本)
# 这里做一个简单的判断：如果返回内容包含 "errors":，说明可能出错了或者是第一次创建
if [[ "$remote_content" == *"\"errors\":["* ]]; then
    echo -e "${yellow}远程列表不存在，将初始化为新列表。${none}"
    remote_content=""
fi

# 5. 对比查重
# 检查备注名是否已存在于远程列表中
if echo "$remote_content" | grep -q "#${node_alias}$"; then
    echo -e "${red}❌ 错误：列表中已存在备注为 [#${node_alias}] 的节点！${none}"
    echo "跳过上传操作。"
    exit 0
fi

# 6. 合并与排序
echo -e "${yellow}正在合并并排序...${none}"
# 将旧内容和新内容合并，去除空行
combined_content="${remote_content}
${final_url}"

# 核心排序逻辑：
# grep "vless://" 确保只处理有效行
# sort -t'#' -k 2 : 指定 # 为分隔符，根据第 2 列（即备注）进行排序
sorted_content=$(echo -e "$combined_content" | grep "vless://" | sort -t'#' -k 2)

# ... (前面的代码不变)

# 7. 上传回 Cloudflare
echo -e "${yellow}正在上传更新后的列表...${none}"

response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${account_id}/storage/kv/namespaces/${kv_id}/values/${list_key}" \
     -H "Authorization: Bearer ${api_token}" \
     -H "Content-Type: text/plain" \
     --data "$sorted_content")

# === 修改点开始 ===
# 使用正则匹配，允许冒号后面有空格
if [[ "$response" =~ \"success\":[[:space:]]*true ]]; then
    echo -e "${green}✅ 成功！节点已添加并重新排序。${none}"
    echo -e "列表 Key: $list_key"
    # 统计行数时排除空行
    count=$(echo "$sorted_content" | grep -v '^\s*$' | wc -l)
    echo -e "当前节点数: $count"
else
    echo -e "${red}❌ 上传失败！${none}"
    echo "API 返回: $response"
    exit 1
fi
# === 修改点结束 ===
