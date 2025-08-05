#!/bin/bash

# 颜色输出
green='\e[92m'
red='\e[31m'
none='\e[0m'
err() { echo -e "${red}错误: $@${none}" && exit 1; }
ok() { echo -e "${green}$@${none}"; }

# 必须root
[[ $EUID != 0 ]] && err "请用ROOT用户运行"

# 只支持amd64和arm64
arch=$(uname -m)
case $arch in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) err "仅支持amd64和arm64架构" ;;
esac

# 检查依赖
cmd=$(type -P apt-get || type -P yum)
[[ ! $cmd ]] && err "仅支持Ubuntu/Debian/CentOS"
[[ ! $(type -P wget) ]] && $cmd install -y wget
[[ ! $(type -P tar) ]] && $cmd install -y tar

# 解析参数
protocol=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --reality)
            protocol="reality"
            shift
            ;;
        --ss)
            protocol="ss"
            shift
            ;;
        --uuid)
            uuid="$2"
            shift 2
            ;;
        --port)
            port="$2"
            shift 2
            ;;
        --domain)
            domain="$2"
            shift 2
            ;;
        --privatekey)
            privatekey="$2"
            shift 2
            ;;
        --ss-password)
            ss_password="$2"
            shift 2
            ;;
        --ss-port)
            ss_port="$2"
            shift 2
            ;;
        --ss-method)
            ss_method="$2"
            shift 2
            ;;
        *)
            err "未知参数: $1"
            ;;
    esac
done

[[ -z $protocol ]] && err "必须指定协议 --reality 或 --ss"

# 下载sing-box
latest_ver=$(wget -qO- "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep tag_name | grep -o 'v[0-9.]\+')
[[ -z $latest_ver ]] && err "获取版本失败"
url="https://github.com/SagerNet/sing-box/releases/download/${latest_ver}/sing-box-${latest_ver:1}-linux-${arch}.tar.gz"
ok "下载sing-box: $url"
wget -qO /tmp/sing-box.tar.gz "$url" || err "下载失败"
mkdir -p /etc/sing-box/bin
tar -zxf /tmp/sing-box.tar.gz --strip-components 1 -C /etc/sing-box/bin || err "解压失败"
rm -f /tmp/sing-box.tar.gz
chmod +x /etc/sing-box/bin/sing-box

# 生成配置
mkdir -p /etc/sing-box/conf
conf=/etc/sing-box/conf/config.json

if [[ $protocol == "reality" ]]; then
    [[ -z $uuid || -z $port || -z $domain || -z $privatekey ]] && err "reality参数缺失"
    cat > $conf <<EOF
{
  "log": { "level": "info" },
  "inbounds": [{
    "type": "vless",
    "listen": "::",
    "listen_port": $port,
    "users": [{ "uuid": "$uuid","flow": "xtls-rprx-vision" }],
    "tls": {
      "enabled": true,
      "server_name": "$domain",
      "reality": {
        "enabled": true,
        "private_key": "$privatekey",
        "short_id": ["6ba85179e30d4fc2"],
        "handshake": { "server": "$domain", "server_port": 443 }
      }
    }
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF
    ok "Reality配置已生成"
elif [[ $protocol == "ss" ]]; then
    [[ -z $ss_password || -z $ss_port || -z $ss_method ]] && err "ss参数缺失"
    cat > $conf <<EOF
{
  "log": { "level": "info" },
  "inbounds": [{
    "type": "shadowsocks",
    "listen": "::",
    "listen_port": $ss_port,
    "method": "$ss_method",
    "password": "$ss_password"
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF
    ok "Shadowsocks配置已生成"
fi

# systemd服务
cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
Type=simple
ExecStart=/etc/sing-box/bin/sing-box run -c /etc/sing-box/conf/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

ok "sing-box安装完成"

# 输出链接
if [[ $protocol == "reality" ]]; then
    echo -e "\nReality链接："
    echo "vless://$uuid@$domain:$port?encryption=none&security=reality&sni=$domain&fp=chrome&pbk=$privatekey&type=grpc&mode=gun&short_id=0123456789abcdef#Reality"
elif [[ $protocol == "ss" ]]; then
    echo -e "\nSS链接："
    link="ss://$(echo -n "$ss_method:$ss_password" | base64 -w0)@$(curl -s ipv4.ip.sb):$ss_port"
    echo "$link"
fi
