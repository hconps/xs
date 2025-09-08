#!/bin/bash

# 颜色
red='\e[91m'
green='\e[92m'
yellow='\e[93m'
cyan='\e[96m'
none='\e[0m'

warn() { echo -e "\n$yellow $1 $none\n"; }

# 获取公网 IPv4 / IPv6
InFaces=($(ls /sys/class/net/ | grep -E '^(eth|ens|eno|esp|enp|venet|vif)'))
for i in "${InFaces[@]}"; do
    IPv4=$(curl -4s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")
    IPv6=$(curl -6s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")
    [[ -n "$IPv4" ]] && break
done

# 参数默认值
port=443
domain="learn.microsoft.com"
uuid=""
fingerprint="random"
private_key=""
shortid=""

# 解析参数
ARGS=$(getopt -o '' --long uuid:,port:,domain:,privatekey:,shortid:,fingerprint: -n "$0" -- "$@")
eval set -- "${ARGS}"
while true; do
    case "$1" in
        --uuid) uuid="$2"; shift 2 ;;
        --port) port="$2"; shift 2 ;;
        --domain) domain="$2"; shift 2 ;;
        --privatekey) private_key="$2"; shift 2 ;;
        --shortid) shortid="$2"; shift 2 ;;
        --fingerprint) fingerprint="$2"; shift 2 ;;
        --) shift; break ;;
        *) echo "参数错误" && exit 1 ;;
    esac
done

# UUID 自动生成
if [[ -z $uuid ]]; then
    uuidSeed="${IPv4}${IPv6}$(cat /proc/sys/kernel/hostname)$(cat /etc/timezone)"
    uuid=$(curl -sL "https://www.uuidtools.com/api/generate/v3/namespace/ns:dns/name/${uuidSeed}" \
        | grep -oP '[^-]{8}-[^-]{4}-[^-]{4}-[^-]{4}-[^-]{12}')
fi

# 私钥和公钥处理
if [[ -z "$private_key" ]]; then
    # 没传参 → 生成一对新的
    tmp_key=$(xray x25519)
else
    # 传了私钥 → 根据它生成公钥
    tmp_key=$(echo "$private_key" | xray x25519 -i)
fi

private_key=$(echo "$tmp_key" | grep 'Private key' | awk '{print $3}')
public_key=$(echo "$tmp_key" | grep 'Public key' | awk '{print $3}')

# ShortID 自动生成
if [[ -z "$shortid" ]]; then
    shortid=$(echo -n ${uuid} | sha1sum | head -c 16)
fi

# 如果只有 IPv6 没有 IPv4，自动装 WARP
if [[ -z "$IPv4" && -n "$IPv6" ]]; then
    warn "只检测到 IPv6，安装 WARP 获取 IPv4 出口"
    bash <(curl -L git.io/warp.sh) 4
    service xray restart
    IPv4=$(curl -4s https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")
fi

# 开启 BBR (for debian13)
modprobe tcp_bbr
cat >/etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system >/dev/null 2>&1

# 安装 xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata

# 写入 xray 配置
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${port},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}],
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
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}, "tag": "force-ipv4"},
    {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv6"}, "tag": "force-ipv6"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "dns": {"servers": ["8.8.8.8", "1.1.1.1", "localhost"]},
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}]}
}
EOF

service xray restart

# 输出信息
echo -e "$green ✅ 配置完成 VLESS Reality$none"
ip=${IPv4}
[[ "$ip" == *:* ]] && ip="[$ip]"
vless_url="vless://${uuid}@${ip}:${port}?encryption=none&security=reality&type=tcp&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}&flow=xtls-rprx-vision&#VLESS_R_${ip}"
echo -e "$cyan$vless_url$none"
echo "$vless_url" > ~/_vless_reality_url_
