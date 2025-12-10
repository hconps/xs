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
  --kv         KV Namespace ID (不是名称)
  --list-key   KV 存储列表的文件名 (例如: LINK.txt)

${yellow}可选参数:${none}
  --file       指定 VLESS 节点文件 (默认: ~/_vless_reality_url_)
  --alias      节点备注名 (如果不传，脚本运行时会要求输入)
"
}

# 默认值
file_path=~/xray/url
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

# 3. 获取并处理备注 (核心修改部分)
if [[ -z "$node_alias" ]]; then
    echo -e "${cyan}当前节点: $raw_url${none}"
    echo -e "输入提示: 数字后加 o=€, y=¥, p=£, d=$ (例: 34o -> €34)"
    read -p "请输入节点备注: " node_alias
fi

if [[ -z "$node_alias" ]]; then
    echo -e "${red}错误：备注名不能为空${none}"
    exit 1
fi

# === 货币符号自动替换逻辑 ===
# sed -E 's/([0-9.]+)[字母]/符号\1/g'
# \1 代表正则里第一个括号匹配到的数字

# o -> Euro (€)
node_alias=$(echo "$node_alias" | sed -E 's/([0-9.]+)o/€\1/g')
# y -> Yuan/Yen (¥)
node_alias=$(echo "$node_alias" | sed -E 's/([0-9.]+)y/¥\1/g')
# p -> Pound (£)
node_alias=$(echo "$node_alias" | sed -E 's/([0-9.]+)p/£\1/g')
# d -> Dollar ($) (顺手加上，方便统一)
node_alias=$(echo "$node_alias" | sed -E 's/([0-9.]+)d/$\1/g')

echo -e "${cyan}转换后备注: $node_alias${none}"
# ===========================

# 替换 URL 中 # 后面的内容
final_url="${raw_url%#*}#${node_alias}"

# 4. 获取 Cloudflare KV 当前列表
echo -e "${yellow}正在获取远程 KV 列表...${none}"
remote_content=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/storage/kv/namespaces/${kv_id}/values/${list_key}" \
     -H "Authorization: Bearer ${api_token}")

if [[ "$remote_content" == *"\"errors\":["* ]]; then
    echo -e "${yellow}远程列表为空或新建，初始化中...${none}"
    remote_content=""
fi

# 5. 对比查重与覆盖询问
# 注意：这里查重用的是转换后的符号
if echo "$remote_content" | grep -q "#${node_alias}$"; then
    echo -e "${yellow}⚠️  发现重复：列表中已存在备注为 [#${node_alias}] 的节点！${none}"
    read -p "是否覆盖旧节点？(输入 y 覆盖，回车或其它键跳过): " overwrite_choice
    
    case "$overwrite_choice" in
        [yY]|[yY][eE][sS])
            echo -e "${green}>>> 正在删除旧节点，准备写入新配置...${none}"
            # 核心逻辑：使用 grep -v 反选，将旧的这一行从变量中删除
            # 这样后续追加新链接时，就相当于实现了"覆盖"
            remote_content=$(echo "$remote_content" | grep -v "#${node_alias}$")
            ;;
        *)
            echo "已取消覆盖，跳过上传操作。"
            exit 0
            ;;
    esac
fi

# 6. 合并与排序
#echo -e "${yellow}正在合并并排序...${none}"
#combined_content="${remote_content}
#${final_url}"

# 过滤空行并排序
#sorted_content=$(echo -e "$combined_content" | grep "vless://" | sort -t'#' -k 2)

# 6. 合并与排序
echo -e "${yellow}正在合并并排序...${none}"
combined_content="${remote_content}
${final_url}"

# 使用 awk + sort 实现多列排序 (无需 Python)
# 逻辑：
# 1. awk: 拆分出【前缀】(HK_Wawo) 和【数字价格】(22.5)，拼接到行首
# 2. sort: 第一列按文本排序(保证组名顺序)，第二列按数字排序(解决 7.99 < 22.5)
# 3. cut:  删掉行首的辅助信息，只保留原始链接

sorted_content=$(echo -e "$combined_content" | grep "vless://" | awk -F'#' '
{
    # $NF 代表以 # 分割的最后一段，即备注
    remark=$NF;
    
    # 寻找最后一个下划线 "_" 的位置
    last_us = 0;
    for(i=1; i<=length(remark); i++) {
        if(substr(remark, i, 1) == "_") last_us = i;
    }

    # 根据下划线拆分前缀 (prefix) 和后缀 (suffix)
    if (last_us > 0) {
        prefix = substr(remark, 1, last_us-1);
        suffix = substr(remark, last_us+1);
    } else {
        prefix = remark;
        suffix = "";
    }

    # 从后缀中提取纯数字 (把所有非数字和非小数点的字符删掉)
    # 例如 "¥22.5" -> "22.5", "Free" -> ""
    price = suffix;
    gsub(/[^0-9.]/, "", price);

    # 如果没有数字 (比如 Free)，设为一个超大数 999999 让它排在最后
    if (price == "") price = 999999;

    # 打印格式: 前缀 <TAB> 价格 <TAB> 原始整行
    # 使用 Tab 分隔是为了防止和 URL 里的字符冲突
    print prefix "\t" price "\t" $0;
}' | sort -t$'\t' -k1,1 -k2,2n | cut -f3-)


# 7. 上传回 Cloudflare
echo -e "${yellow}正在上传...${none}"

response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${account_id}/storage/kv/namespaces/${kv_id}/values/${list_key}" \
     -H "Authorization: Bearer ${api_token}" \
     -H "Content-Type: text/plain" \
     --data "$sorted_content")

# 使用正则匹配 success，兼容空格
if [[ "$response" =~ \"success\":[[:space:]]*true ]]; then
    echo -e "${green}✅ 成功！节点已添加并重新排序。${none}"
    echo -e "列表 Key: $list_key"
    count=$(echo "$sorted_content" | grep -v '^\s*$' | wc -l)
    echo -e "当前节点数: $count"
else
    echo -e "${red}❌ 上传失败！${none}"
    echo "API 返回: $response"
    exit 1
fi
