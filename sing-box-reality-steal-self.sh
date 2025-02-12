#!/usr/bin/env bash
#
# 一键式可交互脚本：安装 Nginx、sing-box、acme.sh 并自动申请证书 & 配置 Reality
# 适用于 Debian 11/12，Ubuntu 20.04/22.04/24.04/24.10
#

set -e

# ------ 若用户不是 root，则提示并退出 ------
if [[ $EUID -ne 0 ]]; then
    echo -e "\n[错误] 请使用 root 权限执行此脚本。\n"
    exit 1
fi

# ------ 若系统未安装 lsb_release，则自动安装 ------
if ! command -v lsb_release &>/dev/null; then
    echo -e "\n[信息] 系统未安装 lsb_release，现自动安装中...\n"
    apt update
    apt install -y lsb-release
fi

# ------ 检测当前系统发行版 & 版本 ------
dist_name=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
dist_codename=$(lsb_release -cs)

echo -e "\n[信息] 检测到系统：$dist_name ($dist_codename)\n"

# ------ 根据系统发行版设置并安装 Nginx ------
function install_nginx_repo_debian() {
    # 安装 Nginx 依赖
    apt update
    apt install -y curl gnupg2 ca-certificates debian-archive-keyring
    # 导入官方签名 key
    curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
        | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
    # 验证指纹
    finger=$(gpg --dry-run --quiet --no-keyring --import --import-options import-show /usr/share/keyrings/nginx-archive-keyring.gpg | grep -o '573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62')
    if [ "$finger" != "573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62" ]; then
        echo -e "\n[错误] Nginx 签名密钥指纹验证失败！"
        exit 1
    fi
    # 设置稳定版仓库
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian $dist_codename nginx" \
        | tee /etc/apt/sources.list.d/nginx.list
    # 设置优先级
    echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
        | tee /etc/apt/preferences.d/99nginx
}

function install_nginx_repo_ubuntu() {
    # 安装 Nginx 依赖
    apt update
    apt install -y curl gnupg2 ca-certificates ubuntu-keyring
    # 导入官方签名 key
    curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
        | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
    # 验证指纹
    finger=$(gpg --dry-run --quiet --no-keyring --import --import-options import-show /usr/share/keyrings/nginx-archive-keyring.gpg | grep -o '573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62')
    if [ "$finger" != "573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62" ]; then
        echo -e "\n[错误] Nginx 签名密钥指纹验证失败！"
        exit 1
    fi
    # 设置稳定版仓库
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $dist_codename nginx" \
        | tee /etc/apt/sources.list.d/nginx.list
    # 设置优先级
    echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
        | tee /etc/apt/preferences.d/99nginx
}

case "$dist_name" in
    debian)
        # 仅支持 bullseye/bookworm，但也允许继续尝试
        if [[ "$dist_codename" != "bullseye" && "$dist_codename" != "bookworm" ]]; then
            echo -e "[警告] 当前 Debian 版本 ($dist_codename) 不在官方支持列表 (bullseye/bookworm) 中，仍将尝试继续。"
        fi
        install_nginx_repo_debian
        ;;
    ubuntu)
        # 仅支持 focal/jammy/noble/oracular，但也允许继续尝试
        if [[ "$dist_codename" != "focal" && "$dist_codename" != "jammy" && "$dist_codename" != "noble" && "$dist_codename" != "oracular" ]]; then
            echo -e "[警告] 当前 Ubuntu 版本 ($dist_codename) 不在官方支持列表 (focal/jammy/noble/oracular) 中，仍将尝试继续。"
        fi
        install_nginx_repo_ubuntu
        ;;
    *)
        echo -e "\n[错误] 暂不支持此发行版：$dist_name\n"
        exit 1
        ;;
esac

echo -e "\n[信息] 开始安装 (或更新) Nginx...\n"
apt update
apt install -y nginx

# ------ 安装 sing-box (正式版) ------
echo -e "\n[信息] 开始安装 sing-box...\n"
mkdir -p /etc/apt/keyrings
curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
chmod a+r /etc/apt/keyrings/sagernet.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" \
    | tee /etc/apt/sources.list.d/sagernet.list >/dev/null

apt-get update
apt-get install -y sing-box

# ------ 安装 acme.sh ------
echo -e "\n[交互] 请输入用于申请证书的邮箱地址 (例如: admin@example.com)："
read -rp "Email: " ACME_EMAIL
if [ -z "$ACME_EMAIL" ]; then
    echo -e "\n[错误] 邮箱地址不能为空，脚本中止。\n"
    exit 1
fi

echo -e "\n[信息] 开始安装 acme.sh...\n"
curl https://get.acme.sh | sh -s email="$ACME_EMAIL"

# 让当前 Shell 会话识别 acme.sh
. ~/.acme.sh/acme.sh.env

# ------ 获取 Cloudflare API Token、Zone ID、域名 ------
echo -e "\n[交互] 请输入 Cloudflare API Token (仅需对单一 DNS zone 具有编辑权限)："
read -rp "CF_Token: " CF_Token
if [ -z "$CF_Token" ]; then
    echo -e "\n[错误] CF_Token 不能为空，脚本中止。\n"
    exit 1
fi

echo -e "\n[交互] 请输入 Cloudflare Zone ID (与上面 Token 对应的单一 DNS 区域)："
read -rp "CF_Zone_ID: " CF_Zone_ID
if [ -z "$CF_Zone_ID" ]; then
    echo -e "\n[错误] CF_Zone_ID 不能为空，脚本中止。\n"
    exit 1
fi

export CF_Token
export CF_Zone_ID

echo -e "\n[交互] 请输入需要申请证书的域名 (例如: example.com)："
read -rp "Domain: " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "\n[错误] 域名不能为空，脚本中止。\n"
    exit 1
fi

# ------ 申请证书：仅精确域名 ------
echo -e "\n[信息] 开始使用 acme.sh 申请证书...\n"
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN"

# ------ 证书安装位置交互 ------
echo -e "\n[交互] 请输入保存私钥 (key) 文件的路径 (默认: /etc/ssl/private/key.pem)："
read -rp "Key Path: " KEY_PATH
[ -z "$KEY_PATH" ] && KEY_PATH="/etc/ssl/private/key.pem"
mkdir -p "$(dirname "$KEY_PATH")"

echo -e "\n[交互] 请输入保存证书 (cert) 文件的路径 (默认: /etc/ssl/private/cert.pem)："
read -rp "Cert Path: " CERT_PATH
[ -z "$CERT_PATH" ] && CERT_PATH="/etc/ssl/private/cert.pem"
mkdir -p "$(dirname "$CERT_PATH")"

echo -e "\n[信息] 安装证书并配置自动续期...\n"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file "$KEY_PATH" \
  --fullchain-file "$CERT_PATH" \
  --reloadcmd "systemctl force-reload nginx"

# ------ 替换 /etc/nginx/nginx.conf ------
echo -e "\n[信息] 更新 /etc/nginx/nginx.conf 配置...\n"
NGINX_CONF="/etc/nginx/nginx.conf"

cat > "$NGINX_CONF" <<EOF
user nginx;
worker_processes auto;

error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format main '[\$time_local] \$proxy_protocol_addr "\$http_referer" "\$http_user_agent"';
    access_log /var/log/nginx/access.log main;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ""      close;
    }

    map \$proxy_protocol_addr \$proxy_forwarded_elem {
        ~^[0-9.]+\$        "for=\$proxy_protocol_addr";
        ~^[0-9A-Fa-f:.]+\$ "for=\"[\$proxy_protocol_addr]\"";
        default           "for=unknown";
    }

    map \$http_forwarded \$proxy_add_forwarded {
        "~^(,[ \\t]*)*([!#\$%&'*+.^_\`|~0-9A-Za-z-]+=([!#\$%&'*+.^_\`|~0-9A-Za-z-]+|\"([\\t \\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\t \\x21-\\x7E\\x80-\\xFF])*\"))?(;([!#\$%&'*+.^_\`|~0-9A-Za-z-]+=([!#\$%&'*+.^_\`|~0-9A-Za-z-]+|\"([\\t \\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\t \\x21-\\x7E\\x80-\\xFF])*\"))?)*([ \\t]*,([ \\t]*([!#\$%&'*+.^_\`|~0-9A-Za-z-]+=([!#\$%&'*+.^_\`|~0-9A-Za-z-]+|\"([\\t \\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\t \\x21-\\x7E\\x80-\\xFF])*\"))?(;([!#\$%&'*+.^_\`|~0-9A-Za-z-]+=([!#\$%&'*+.^_\`|~0-9A-Za-z-]+|\"([\\t \\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\t \\x21-\\x7E\\x80-\\xFF])*\"))?)*)?)*\$" "\$http_forwarded, \$proxy_forwarded_elem";
        default "\$proxy_forwarded_elem";
    }

    server {
        listen 80;
        listen [::]:80;
        return 301 https://\$host\$request_uri;
    }

    server {
        listen                  127.0.0.1:8601 ssl default_server;

        ssl_reject_handshake    on;
        ssl_protocols           TLSv1.2 TLSv1.3;

        ssl_session_timeout     1h;
        ssl_session_cache       shared:SSL:10m;
    }

    server {
        listen                     127.0.0.1:8601 ssl;
        http2                      on;

        set_real_ip_from           127.0.0.1;
        real_ip_header             proxy_protocol;

        server_name                $DOMAIN;

        ssl_certificate            $CERT_PATH;
        ssl_certificate_key        $KEY_PATH;

        ssl_protocols              TLSv1.2 TLSv1.3;
        ssl_ciphers                TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers  on;

        ssl_stapling               on;
        ssl_stapling_verify        on;
        resolver                   1.1.1.1 valid=60s;
        resolver_timeout           2s;

        location / {
            sub_filter              \$proxy_host \$host;
            sub_filter_once         off;

            set \$website           www.bing.com;
            proxy_pass             https://\$website;
            resolver               1.1.1.1;

            proxy_set_header Host  \$proxy_host;

            proxy_http_version     1.1;
            proxy_cache_bypass     \$http_upgrade;
            proxy_ssl_server_name  on;

            proxy_set_header Upgrade           \$http_upgrade;
            proxy_set_header Connection        \$connection_upgrade;
            proxy_set_header X-Real-IP         \$proxy_protocol_addr;
            proxy_set_header Forwarded         \$proxy_add_forwarded;
            proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host  \$host;
            proxy_set_header X-Forwarded-Port  \$server_port;

            proxy_connect_timeout   60s;
            proxy_send_timeout      60s;
            proxy_read_timeout      60s;
        }
    }
}
EOF

systemctl restart nginx

# ------ 配置 sing-box ------
echo -e "\n[信息] 配置 /etc/sing-box/config.json...\n"
SING_CONF="/etc/sing-box/config.json"
rm -f "$SING_CONF"

# 生成 UUID
echo -e "[信息] 生成 sing-box UUID..."
UUID=$(sing-box generate uuid)
echo "UUID: $UUID"

# 生成 Reality Keypair
echo -e "\n[信息] 生成 Reality Keypair..."
REALITY_KEY=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$REALITY_KEY" | grep 'PrivateKey:' | awk '{print $2}')
PUBLIC_KEY=$(echo  "$REALITY_KEY" | grep 'PublicKey:'  | awk '{print $2}')
echo "PrivateKey: $PRIVATE_KEY"
echo "PublicKey:  $PUBLIC_KEY"

# 生成 short_id
echo -e "\n[信息] 生成 short_id..."
SHORT_ID=$(sing-box generate rand 8 --hex)
echo "short_id: $SHORT_ID"

mkdir -p /etc/sing-box
cat > "$SING_CONF" <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "127.0.0.1",
            "server_port": 8601
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

systemctl enable sing-box
systemctl restart sing-box

# ------ 获取本机公网 IPv4 & 地理位置 ------
echo -e "\n[信息] 获取本机公网 IPv4 和地理信息...\n"
GEO_INFO=$(curl -4 -s ping0.cc/geo || echo "")
# GEO_INFO 应该包含 4 行，例如：
#   1) 45.150.xxx.xxx
#   2) 美国 华盛顿州 西雅圖 — xxx
#   3) ASxxxxx
#   4) ProviderName

PUBLIC_IP=$(echo "$GEO_INFO" | sed -n '1p')
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="0.0.0.0"
fi

LOCATION_LINE=$(echo "$GEO_INFO" | sed -n '2p')
LOCATION_LABEL="其他"
if [[ "$LOCATION_LINE" == *"香港"* ]]; then
    LOCATION_LABEL="香港"
elif [[ "$LOCATION_LINE" == *"台湾"* ]]; then
    LOCATION_LABEL="台湾"
elif [[ "$LOCATION_LINE" == *"日本"* ]]; then
    LOCATION_LABEL="日本"
elif [[ "$LOCATION_LINE" == *"新加坡"* ]]; then
    LOCATION_LABEL="新加坡"
elif [[ "$LOCATION_LINE" == *"美国"* ]]; then
    LOCATION_LABEL="美国"
fi

# ------ 输出最终配置信息 ------
echo -e "\n===================="
echo -e "sing-box 已启动完成！\n"
echo "配置参数回顾："
echo "  - DOMAIN:       $DOMAIN"
echo "  - UUID:         $UUID"
echo "  - PrivateKey:   $PRIVATE_KEY"
echo "  - PublicKey:    $PUBLIC_KEY"
echo "  - short_id:     $SHORT_ID"
echo "  - Key Path:     $KEY_PATH"
echo "  - Cert Path:    $CERT_PATH"
echo -e "====================\n"

# 生成 VLESS Reality 链接，节点名称使用「地区-UUID」
VLESS_LINK="vless://${UUID}@${PUBLIC_IP}:443?encryption=none&security=reality&type=tcp&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision#${LOCATION_LABEL}-${UUID}"

echo -e "[信息] 复制以下链接到客户端使用：\n"
echo -e "  ${VLESS_LINK}\n"
echo -e "[完成] 脚本执行结束。\n"
