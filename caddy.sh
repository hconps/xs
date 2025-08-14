#!/bin/bash
# 一键部署 Caddy + Cloudflare 反代
# 适用：Debian/Ubuntu 系统

set -e

# 颜色
green='\e[92m'; red='\e[31m'; none='\e[0m'
ok() { echo -e "${green}[OK]${none} $1"; }
err() { echo -e "${red}[ERR]${none} $1" && exit 1; }

# 检查 root
[[ $EUID -ne 0 ]] && err "请使用 root 运行此脚本"

# 输入信息
read -p "请输入你的域名（如 mydomain.com）: " DOMAIN
read -p "请输入后端端口（如 3002）: " PORT
read -p "请输入 Cloudflare API Token: " CF_TOKEN

[[ -z "$DOMAIN" || -z "$PORT" || -z "$CF_TOKEN" ]] && err "输入不能为空"

# 安装依赖
ok "安装依赖..."
apt update -y
apt install -y curl debian-keyring debian-archive-keyring apt-transport-https

# 安装 xcaddy
ok "安装 xcaddy..."
apt install -y xcaddy

# 构建带 Cloudflare 插件的 Caddy
ok "构建带 Cloudflare 插件的 Caddy..."
xcaddy build --with github.com/caddy-dns/cloudflare
mv caddy /usr/bin/caddy
chmod +x /usr/bin/caddy

# 创建 Caddy 用户和目录
id -u caddy &>/dev/null || useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
mkdir -p /etc/caddy /var/lib/caddy
chown -R caddy:caddy /etc/caddy /var/lib/caddy

# 配置环境变量（Cloudflare Token）
echo "CLOUDFLARE_API_TOKEN=${CF_TOKEN}" > /etc/caddy/env
chmod 600 /etc/caddy/env

# 创建 Caddyfile
cat >/etc/caddy/Caddyfile <<EOF
{
    email admin@${DOMAIN}
}

${DOMAIN} {
    encode gzip
    reverse_proxy 127.0.0.1:${PORT}

    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
}
EOF

# 创建 systemd 服务
cat >/etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy web server
After=network.target

[Service]
EnvironmentFile=/etc/caddy/env
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
User=caddy
Group=caddy
Restart=on-abnormal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# 启动 Caddy
ok "启动 Caddy..."
systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy

ok "Caddy 部署完成！"
echo -e "${green}请确保你的域名 ${DOMAIN} 已正确解析到本机 IP，并在 Cloudflare 启用 Full SSL。${none}"
echo -e "${green}现在可以通过 https://${DOMAIN} 访问你的服务（反代 127.0.0.1:${PORT}）。${none}"
