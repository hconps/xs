#!/usr/bin/env bash

set -e

# 参数校验
UUID="$1"
PORT="$2"
PRIVATEKEY="$3"
SHORTID="$4"
DOMAIN="$5"

if [[ -z $UUID || -z $PORT || -z $PRIVATEKEY || -z $SHORTID || -z $DOMAIN ]]; then
  echo -e "用法: $0 <uuid> <port> <privatekey> <shortid> <domain>"
  exit 1
fi

# 检查root权限
[[ $EUID -ne 0 ]] && { echo "请使用 root 权限运行"; exit 1; }

# 安装依赖
apt-get update -y || yum update -y
apt-get install -y wget tar || yum install -y wget tar

# 下载最新版 sing-box
ARCH=$(uname -m)
[[ $ARCH == "x86_64" || $ARCH == "amd64" ]] && ARCH="amd64"
[[ $ARCH == "aarch64" ]] && ARCH="arm64"

VERSION=$(wget -qO- https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f4)
URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION:1}-linux-${ARCH}.tar.gz"

mkdir -p /etc/sing-box
cd /etc/sing-box
wget -qO sing-box.tar.gz "$URL"
tar -xzf sing-box.tar.gz --strip-components=1
rm -f sing-box.tar.gz

# 生成配置文件
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": $PORT,
    "users": [{
      "uuid": "$UUID",
      "flow": ""
    }],
    "tls": {
      "enabled": true,
      "server_name": "$DOMAIN",
      "reality": {
        "enabled": true,
        "handshake": {
          "server": "$DOMAIN",
          "server_port": 443
        },
        "private_key": "$PRIVATEKEY",
        "short_id": ["$SHORTID"]
      }
    }
  }],
  "outbounds": [{
    "type": "direct"
  }]
}
EOF

# 写入 systemd 服务
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/etc/sing-box/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

echo "✅ sing-box 安装完成，使用 VLESS + REALITY，端口 $PORT"
