#!/usr/bin/env bash
set -e

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 root 用户运行此脚本！"
    exit 1
fi

REALM_VERSION="v2.9.3"
REALM_DIR="/etc/realm"
DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/realm-x86_64-unknown-linux-gnu.tar.gz"

echo "==> [1/4] 正在创建目录并下载 Realm ${REALM_VERSION}..."
mkdir -p "${REALM_DIR}"
curl -fL -# -o "${REALM_DIR}/realm.tar.gz" "${DOWNLOAD_URL}"

echo "==> [2/4] 正在解压并赋予执行权限..."
tar -zxvf "${REALM_DIR}/realm.tar.gz" -C "${REALM_DIR}"
chmod +x "${REALM_DIR}/realm"
rm -f "${REALM_DIR}/realm.tar.gz"

echo "==> [3/4] 正在写入配置文件 config.toml..."
cat << 'EOF' > "${REALM_DIR}/config.toml"
[network]
no_tcp = false
use_udp = true

[[endpoints]]
listen = "0.0.0.0:16666"
remote = "1.1.1.1:16666"
EOF

echo "==> [4/4] 正在配置并启动 Systemd 服务..."
cat << 'EOF' > /etc/systemd/system/realm.service
[Unit]
Description=Realm Forward Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=/etc/realm/realm -c /etc/realm/config.toml

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable realm.service
systemctl restart realm.service

echo "==> Realm 安装并启动完成！当前运行状态："
systemctl status realm.service --no-pager
