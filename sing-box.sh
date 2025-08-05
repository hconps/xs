#!/bin/bash

# ========= 默认参数 =========
UUID=""
PORT=443
PRIVATE_KEY=""
SHORT_ID=""
DOMAIN=""

# ========= 参数解析 =========
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uuid) UUID="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --privatekey) PRIVATE_KEY="$2"; shift 2 ;;
    --shortid) SHORT_ID="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --fingerprint) FINGERPRINT="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ========= 安装依赖 =========
apt update
apt install -y curl unzip

# ========= 安装 sing-box（官方脚本） =========
curl -fsSL https://sing-box.app/install.sh | sh

# ========= 创建配置目录 =========
mkdir -p /usr/local/etc/sing-box
mkdir -p /var/log/sing-box

# ========= 自动生成参数 =========
[[ -z "$UUID" ]] && UUID=$(cat /proc/sys/kernel/random/uuid)
[[ -z "$PRIVATE_KEY" ]] && PRIVATE_KEY=$(sing-box generate reality-keypair | grep PrivateKey | awk '{print $2}')
[[ -z "$SHORT_ID" ]] && SHORT_ID=$(head -c 8 /dev/urandom | xxd -p)

# ========= 写入配置文件 =========
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "error",
    "output": "/var/log/sing-box/access.log"
  },
  "inbounds":[
    {
      "type": "vless",
      "tag": "shadowsocks xtls-reality",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": ""
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$DOMAIN",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": [
            "$SHORT_ID"
          ]
        }
      },
      "multiplex": {
        "enabled": true,
        "padding": true,
        "brutal": {
          "enabled": false,
          "up_mbps": 1000,
          "down_mbps": 1000
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct" },
    { "type": "block", "tag": "block" }
  ]
}
EOF


# ========= 配置 systemd 服务 =========
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# ========= 启动服务 =========
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

# ========= 输出信息 =========
echo
echo "✅ Sing-box 安装完成！以下是配置信息："
echo "----------------------------------------"
echo "UUID:        $UUID"
echo "Port:        $PORT"
echo "PrivateKey:  $PRIVATE_KEY"
echo "ShortID:     $SHORT_ID"
echo "Domain:      $DOMAIN"
echo "Fingerprint: $FINGERPRINT"
echo "配置路径:    /etc/sing-box/config.json"
echo "systemd服务: sing-box"
echo
