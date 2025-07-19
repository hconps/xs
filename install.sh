# 获取本机的IPv4和IPv6
InFaces=($(ls /sys/class/net/ | grep -E '^(eth|ens|eno|esp|enp|venet|vif)'))
for i in "${InFaces[@]}"; do
    Public_IPv4=$(curl -4s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")
    Public_IPv6=$(curl -6s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")
    if [[ -n "$Public_IPv4" ]]; then
        IPv4="$Public_IPv4"
    fi
    if [[ -n "$Public_IPv6" ]]; then
        IPv6="$Public_IPv6"
    fi
done

# 默认端口、域名和UUID
port=443  # 默认端口
domain="learn.microsoft.com"  # 默认域名
uuidSeed=${IPv4}${IPv6}$(cat /proc/sys/kernel/hostname)$(cat /etc/timezone)
uuid=$(curl -sL https://www.uuidtools.com/api/generate/v3/namespace/ns:dns/name/${uuidSeed} | grep -oP '[^-]{8}-[^-]{4}-[^-]{4}-[^-]{4}-[^-]{12}')

# 默认fingerprint
fingerprint="random"  # 默认fingerprint

# 如果带参数执行，使用传入的私钥、ShortID、fingerprint、端口、域名、uuid
if [ $# -ge 1 ]; then
    private_key=${1}  # 私钥
    shortid=${2}  # ShortID
    fingerprint=${3:-"random"}  # Fingerprint, 如果没有传则使用默认"random"
    port=${4:-443}  # 端口
    domain=${5:-"learn.microsoft.com"}  # 域名
    uuid=${6:-$uuid}  # UUID, 如果没有传则使用默认生成的UUID
fi

# 如果没有IPv4，且有IPv6，使用WARP获取IPv4出口
if [[ -z "$IPv4" && -n "$IPv6" ]]; then
    echo -e "$yellow 只获取到了IPv6地址，将使用WARP创建IPv4出站$none"
    bash <(curl -L git.io/warp.sh) 4
    service xray restart
fi

# 如果没有传入私钥，则通过UUID生成
if [[ -z "$private_key" ]]; then
    private_key=$(echo -n ${uuid} | md5sum | head -c 32 | base64 -w 0 | tr '+/' '-_' | tr -d '=')
fi

# 如果没有传入ShortID，则通过UUID生成
if [[ -z "$shortid" ]]; then
    shortid=$(echo -n ${uuid} | sha1sum | head -c 16)
fi

# 继续Xray配置
echo -e "$yellow 配置 /usr/local/etc/xray/config.json $none"
echo "----------------------------------------------------------------"
cat > /usr/local/etc/xray/config.json <<-EOF
{ 
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
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
          "dest": "${domain}:443",
          "xver": 0,
          "serverNames": ["${domain}"],
          "privateKey": "${private_key}",
          "shortIds": ["${shortid}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
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
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

# 重启 Xray
echo -e "$yellow重启 Xray$none"
echo "----------------------------------------------------------------"
service xray restart

# 输出配置信息
echo -e "$green 配置完毕，以下是VLESS Reality服务器配置信息 $none"
echo -e "$yellow 地址 = ${cyan}${IPv4}${none}"
echo -e "$yellow 端口 = ${cyan}${port}${none}"
echo -e "$yellow UUID = ${cyan}${uuid}${none}"
#echo -e "$yellow 公钥 = ${cyan}${public_key}${none}"
echo -e "$yellow ShortId = ${cyan}${shortid}${none}"
echo -e "$yellow SNI = ${cyan}${domain}${none}"
echo -e "$yellow Fingerprint = ${cyan}${fingerprint}${none}"

# 生成VLESS链接
vless_reality_url="vless://${uuid}@${IPv4}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&sid=${shortid}&#VLESS_R_${IPv4}"
echo -e "${cyan}${vless_reality_url}${none}"
