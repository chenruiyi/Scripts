#!/usr/bin/env bash
#
# 一键式可交互脚本：安装 Nginx、sing-box、acme.sh 并自动申请证书 & 配置 Reality
# 功能菜单：
#   1) 重新安装
#   2) 更新VLESS
#   3) 更新域名
#   4) 更新Socks
#   5) 查看订阅链接
#
# 支持：Debian 11/12，Ubuntu 20.04/22.04/24.04/24.10
# ---------------------------------------------------------------------------------

set -e

# ====================【 全局变量定义 】====================
SINGBOX_CONF_DIR="/etc/sing-box"
SINGBOX_CONF_FILE="$SINGBOX_CONF_DIR/config.json"
SINGBOX_DNS_ID_FILE="$SINGBOX_CONF_DIR/dns_record_id"
ACCOUNT_INFO_FILE="$SINGBOX_CONF_DIR/account_info"
PUBLIC_KEY_FILE="$SINGBOX_CONF_DIR/reality_public_key"

NGINX_CONF="/etc/nginx/nginx.conf"

KEY_DEFAULT_PATH="/etc/ssl/private/key.pem"
CERT_DEFAULT_PATH="/etc/ssl/private/cert.pem"

SUPPORTED_DEBIAN=("bullseye" "bookworm")
SUPPORTED_UBUNTU=("focal" "jammy" "noble" "oracular")

# 存储于 $ACCOUNT_INFO_FILE
ACME_EMAIL=""
CF_Token=""
CF_Zone_ID=""

DOMAIN=""
PUBLIC_IP=""
LOCATION_LABEL="其他"    # 地理位置标签（如 香港/日本 等）
SSL_KEY_PATH=""
SSL_CERT_PATH=""

# ==============【 输出函数：统一格式 】=============
function echo_info()  { echo -e "\n\e[36m[信息]\e[0m $1\n"; }
function echo_warn()  { echo -e "\n\e[33m[警告]\e[0m $1\n"; }
function echo_err()   { echo -e "\n\e[31m[错误]\e[0m $1\n"; exit 1; }

# ==============【 检测是否 root 】=============
if [[ $EUID -ne 0 ]]; then
    echo_err "请使用 root 权限执行此脚本。"
fi

# 安装 lsb_release（如未安装）
if ! command -v lsb_release &>/dev/null; then
    echo_info "系统未安装 lsb_release，自动安装..."
    apt update
    apt install -y lsb-release
fi

dist_name=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
dist_codename=$(lsb_release -cs)
echo_info "检测到系统：$dist_name ($dist_codename)"


# ==============【 日常安装函数：Nginx/ sing-box / acme.sh 】=============
function install_nginx_repo_debian() {
    apt update
    apt install -y curl gnupg2 ca-certificates debian-archive-keyring
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
        | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

    local finger
    finger=$(gpg --dry-run --quiet --no-keyring --import --import-options import-show \
             /usr/share/keyrings/nginx-archive-keyring.gpg \
             | grep -o '573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62')
    if [ "$finger" != "573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62" ]; then
        echo_err "Nginx 签名密钥指纹验证失败！"
    fi

    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
          http://nginx.org/packages/debian $dist_codename nginx" \
        | tee /etc/apt/sources.list.d/nginx.list
    echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
        | tee /etc/apt/preferences.d/99nginx
}

function install_nginx_repo_ubuntu() {
    apt update
    apt install -y curl gnupg2 ca-certificates ubuntu-keyring
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
        | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

    local finger
    finger=$(gpg --dry-run --quiet --no-keyring --import --import-options import-show \
             /usr/share/keyrings/nginx-archive-keyring.gpg \
             | grep -o '573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62')
    if [ "$finger" != "573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62" ]; then
        echo_err "Nginx 签名密钥指纹验证失败！"
    fi

    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
          http://nginx.org/packages/ubuntu $dist_codename nginx" \
        | tee /etc/apt/sources.list.d/nginx.list
    echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
        | tee /etc/apt/preferences.d/99nginx
}

function ensure_nginx_installed() {
    if ! command -v nginx &>/dev/null; then
        echo_info "Nginx 未安装，开始添加官方仓库并安装..."
        if [[ "$dist_name" == "debian" ]]; then
            if [[ ! " ${SUPPORTED_DEBIAN[*]} " =~ " $dist_codename " ]]; then
                echo_warn "当前 Debian ($dist_codename) 不在官方支持列表 (${SUPPORTED_DEBIAN[*]}) 中，仍尝试继续。"
            fi
            install_nginx_repo_debian
        elif [[ "$dist_name" == "ubuntu" ]]; then
            if [[ ! " ${SUPPORTED_UBUNTU[*]} " =~ " $dist_codename " ]]; then
                echo_warn "当前 Ubuntu ($dist_codename) 不在官方支持列表 (${SUPPORTED_UBUNTU[*]}) 中，仍尝试继续。"
            fi
            install_nginx_repo_ubuntu
        else
            echo_err "暂不支持此发行版：$dist_name"
        fi
        apt update
        apt install -y nginx
    else
        echo_info "检测到 Nginx 已安装，跳过安装。"
    fi
}

function ensure_sing_box_installed() {
    if ! command -v sing-box &>/dev/null; then
        echo_info "开始安装 sing-box..."
        mkdir -p /etc/apt/keyrings
        if [ ! -f /etc/apt/keyrings/sagernet.asc ]; then
            curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
            chmod a+r /etc/apt/keyrings/sagernet.asc
        fi
        if [ ! -f /etc/apt/sources.list.d/sagernet.list ]; then
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/sagernet.asc] \
                  https://deb.sagernet.org/ * *" \
                | tee /etc/apt/sources.list.d/sagernet.list >/dev/null
        fi
        apt-get update
        apt-get install -y sing-box
    else
        echo_info "检测到 sing-box 已安装，跳过安装。"
    fi
}

function ensure_acme_installed() {
    # 若本地记录已有邮箱，先读取
    if [ -f "$ACCOUNT_INFO_FILE" ]; then
        source "$ACCOUNT_INFO_FILE"
    fi

    if [ -z "$ACME_EMAIL" ]; then
        echo_info "请输入用于申请证书的邮箱地址 (例如: admin@example.com)："
        read -rp "Email: " ACME_EMAIL
        if [ -z "$ACME_EMAIL" ]; then
            echo_err "邮箱地址不能为空。"
        fi
    else
        echo_info "检测到已保存的邮箱地址: $ACME_EMAIL"
        echo -e "[交互] 是否继续使用此邮箱？(y/N)"
        read -rp "请输入 (y/n) [默认 y]: " reuse_email
        reuse_email=${reuse_email:-y}
        reuse_email=${reuse_email,,}
        if [[ "$reuse_email" != "y" ]]; then
            echo_info "请输入新的邮箱地址："
            read -rp "Email: " new_email
            [ -z "$new_email" ] && echo_err "邮箱地址不能为空。"
            ACME_EMAIL="$new_email"
        fi
    fi

    if [ ! -d ~/.acme.sh ]; then
        echo_info "安装 acme.sh..."
        curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
        . ~/.acme.sh/acme.sh.env
    else
        echo_info "检测到 acme.sh 已安装，跳过安装。"
        . ~/.acme.sh/acme.sh.env
    fi
    save_account_info
}


# ==============【 账号信息保存/读取 】=============
function save_account_info() {
    mkdir -p "$SINGBOX_CONF_DIR"
    cat > "$ACCOUNT_INFO_FILE" <<EOF
export ACME_EMAIL="$ACME_EMAIL"
export CF_Token="$CF_Token"
export CF_Zone_ID="$CF_Zone_ID"
EOF
    chmod 600 "$ACCOUNT_INFO_FILE"
}

function ensure_cf_token_zone() {
    if [ -f "$ACCOUNT_INFO_FILE" ]; then
        source "$ACCOUNT_INFO_FILE"
    fi

    if [ -n "$CF_Token" ] && [ -n "$CF_Zone_ID" ]; then
        echo_info "检测到已保存的 Cloudflare Token & ZoneID：\n  CF_Token: $CF_Token\n  CF_Zone_ID: $CF_Zone_ID"
        echo -e "[交互] 是否继续使用？(y/N)"
        read -rp "请输入 (y/n) [默认 y]: " reuse_cf
        reuse_cf=${reuse_cf:-y}
        reuse_cf=${reuse_cf,,}
        if [[ "$reuse_cf" != "y" ]]; then
            CF_Token=""
            CF_Zone_ID=""
        fi
    fi

    if [ -z "$CF_Token" ]; then
        echo_info "请输入 Cloudflare API Token（需对单一 DNS zone 具有编辑权限）："
        read -rp "CF_Token: " CF_Token
        [ -z "$CF_Token" ] && echo_err "CF_Token 不能为空。"
    fi
    if [ -z "$CF_Zone_ID" ]; then
        echo_info "请输入 Cloudflare Zone ID："
        read -rp "CF_Zone_ID: " CF_Zone_ID
        [ -z "$CF_Zone_ID" ] && echo_err "CF_Zone_ID 不能为空。"
    fi
    save_account_info
}


# ==============【 获取本机公网 IP / 地理位置 】=============
function get_geo_info() {
    [ -n "$PUBLIC_IP" ] && return  # 若已获取过则不重复
    echo_info "正在获取本机公网 IP 和地理信息..."
    [ ! -x "$(command -v curl)" ] && apt update && apt install -y curl
    local try_count=0
    local max_retries=3
    local geo

    while [ $try_count -lt $max_retries ]; do
        geo=$(curl -4 -s ping0.cc/geo || echo "")
        PUBLIC_IP=$(echo "$geo" | sed -n '1p')
        if [ -n "$PUBLIC_IP" ]; then
            break
        fi
        try_count=$((try_count+1))
        echo_warn "获取公网 IP 失败，重试第 $try_count/$max_retries 次..."
        sleep 2
    done

    [ -z "$PUBLIC_IP" ] && echo_err "多次尝试后仍无法获取公网 IP。"

    local location_line
    location_line=$(echo "$geo" | sed -n '2p')
    LOCATION_LABEL="其他"
    if   [[ "$location_line" == *"香港"* ]];   then LOCATION_LABEL="香港"
    elif [[ "$location_line" == *"台湾"* ]];   then LOCATION_LABEL="台湾"
    elif [[ "$location_line" == *"日本"* ]];   then LOCATION_LABEL="日本"
    elif [[ "$location_line" == *"新加坡"* ]]; then LOCATION_LABEL="新加坡"
    elif [[ "$location_line" == *"美国"* ]];   then LOCATION_LABEL="美国"
    fi
}


# ==============【 Cloudflare DNS 记录操作 】=============
function delete_old_dns_record_if_exists() {
    if [ -f "$SINGBOX_DNS_ID_FILE" ]; then
        local old_record_id
        old_record_id=$(cat "$SINGBOX_DNS_ID_FILE" 2>/dev/null || echo "")
        if [ -n "$old_record_id" ]; then
            echo_info "检测到旧的 DNS 记录 ID：$old_record_id，尝试删除..."
            local delete_resp
            delete_resp=$(curl --silent --location \
                "https://api.cloudflare.com/client/v4/zones/${CF_Zone_ID}/dns_records/${old_record_id}" \
                -X DELETE -H "Authorization: Bearer ${CF_Token}")
            local success
            success=$(echo "$delete_resp" | grep -Po '"success":\s*\K[^,}]*')
            if [[ "$success" == "true" ]]; then
                echo_info "旧的 DNS 记录已删除。"
                rm -f "$SINGBOX_DNS_ID_FILE"

                local old_domain
                old_domain=$(jq -r '.inbounds[0].tls.server_name' "$SINGBOX_CONF_FILE" 2>/dev/null || echo "")
                [ -z "$old_domain" ] && echo_err "无法从配置中获取原域名。"
                if [ -n "$old_domain" ]; then
                    echo_info "停止对旧域名 (${old_domain}) 的证书续期，并删除本地证书目录..."
                    ~/.acme.sh/acme.sh --remove -d "$old_domain" || echo_warn "acme.sh --remove 操作可能未成功，请手动检查。"

                    # 递归删除 ~/.acme.sh/ 下以旧域名为前缀的目录
                    local old_cert_dirs
                    old_cert_dirs=$(find ~/.acme.sh -maxdepth 1 -type d -name "${old_domain}*")
                    for f in $old_cert_dirs; do
                        rm -rf "$f"
                        echo_info "已删除目录：$f"
                    done
                fi
            else
                echo_warn "旧的 DNS 记录删除失败，返回：$delete_resp"
            fi
        fi
    fi
}

function create_dns_record() {
    delete_old_dns_record_if_exists
    local AUTO_SUBDOMAIN
    AUTO_SUBDOMAIN=$(sing-box generate rand 8 --hex)
    echo_info "自动生成子域名前缀：$AUTO_SUBDOMAIN，指向公网 IP：$PUBLIC_IP"

    local create_dns
    create_dns=$(curl --silent --location \
      "https://api.cloudflare.com/client/v4/zones/${CF_Zone_ID}/dns_records" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${CF_Token}" \
      --data "{
        \"content\": \"${PUBLIC_IP}\",
        \"name\": \"${AUTO_SUBDOMAIN}\",
        \"proxied\": false,
        \"ttl\": 1,
        \"type\": \"A\"
      }")

    local success
    success=$(echo "$create_dns" | grep -Po '"success":\s*\K[^,}]*')
    [[ "$success" != "true" ]] && echo_err "Cloudflare API 创建 DNS 记录失败：\n$create_dns"

    DOMAIN=$(echo "$create_dns" | grep -Po '"name":\s*"\K[^"]+')
    [ -z "$DOMAIN" ] && echo_err "未能从 Cloudflare API 响应中解析出域名。"

    local record_id
    record_id=$(echo "$create_dns" | grep -Po '"id":\s*"\K[^"]+')
    if [ -n "$record_id" ]; then
        mkdir -p "$SINGBOX_CONF_DIR"
        echo "$record_id" > "$SINGBOX_DNS_ID_FILE"
    fi

    echo_info "成功添加 DNS 记录：$DOMAIN -> $PUBLIC_IP"
}


# ==============【 申请并安装证书 】=============
function apply_certificate() {
    echo_info "开始使用 acme.sh 申请证书：$DOMAIN"
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN"

    echo_info "请输入私钥保存路径（默认: $KEY_DEFAULT_PATH）："
    read -rp "Key Path: " KEY_PATH
    [ -z "$KEY_PATH" ] && KEY_PATH="$KEY_DEFAULT_PATH"
    mkdir -p "$(dirname "$KEY_PATH")"

    echo_info "请输入证书保存路径（默认: $CERT_DEFAULT_PATH）："
    read -rp "Cert Path: " CERT_PATH
    [ -z "$CERT_PATH" ] && CERT_PATH="$CERT_DEFAULT_PATH"
    mkdir -p "$(dirname "$CERT_PATH")"

    echo_info "安装证书并配置自动续期..."
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
      --key-file "$KEY_PATH" \
      --fullchain-file "$CERT_PATH" \
      --reloadcmd "systemctl force-reload nginx"

    SSL_KEY_PATH="$KEY_PATH"
    SSL_CERT_PATH="$CERT_PATH"
}


# ==============【 更新 Nginx 配置 】=============
function update_nginx_conf() {
    echo_info "更新 Nginx 配置：$NGINX_CONF"
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

    # 仅握手用途，不做实际业务
    server {
        listen 127.0.0.1:8601 ssl default_server;
        ssl_reject_handshake on;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_timeout 1h;
        ssl_session_cache shared:SSL:10m;
    }

    # 回源到同端口做真实代理
    server {
        listen                     127.0.0.1:8601 ssl;
        http2                      on;
        set_real_ip_from           127.0.0.1;
        real_ip_header             proxy_protocol;
        server_name                $DOMAIN;

        ssl_certificate            $SSL_CERT_PATH;
        ssl_certificate_key        $SSL_KEY_PATH;
        ssl_protocols              TLSv1.2 TLSv1.3;
        ssl_ciphers                TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers  on;

        ssl_stapling               on;
        ssl_stapling_verify        on;
        resolver                   1.1.1.1 valid=60s;
        resolver_timeout           2s;

        location / {
            sub_filter \$proxy_host \$host;
            sub_filter_once off;

            set \$website www.bing.com;
            proxy_pass https://\$website;
            resolver 1.1.1.1;

            proxy_set_header Host \$proxy_host;
            proxy_http_version 1.1;
            proxy_cache_bypass \$http_upgrade;
            proxy_ssl_server_name on;

            proxy_set_header Upgrade           \$http_upgrade;
            proxy_set_header Connection        \$connection_upgrade;
            proxy_set_header X-Real-IP         \$proxy_protocol_addr;
            proxy_set_header Forwarded         \$proxy_add_forwarded;
            proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host  \$host;
            proxy_set_header X-Forwarded-Port  \$server_port;

            proxy_connect_timeout 60s;
            proxy_send_timeout    60s;
            proxy_read_timeout    60s;
        }
    }
}
EOF

    systemctl restart nginx
}


# ==============【 生成 sing-box 配置 】=============
#   根据是否需要 Socks 中转，写入不同配置结构
function generate_singbox_config() {
    local uuid="$1"
    local private_key="$2"
    local public_key="$3"
    local short_id="$4"
    local need_socks="$5"

    # 如需 SOCKS，中转信息放在全局临时变量
    if [[ "$need_socks" == "true" ]]; then
        cat > "$SINGBOX_CONF_FILE" <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-direct",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "uuid": "${uuid}",
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
          "private_key": "${private_key}",
          "short_id": ["${short_id}"]
        }
      }
    },
    {
      "type": "vless",
      "tag": "vless-socks",
      "listen": "::",
      "listen_port": ${SOCKS_LOCAL_PORT},
      "users": [
        {
          "uuid": "${uuid}",
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
          "private_key": "${private_key}",
          "short_id": ["${short_id}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "socks",
      "tag": "socks_out",
      "server": "${SOCKS_IP}",
      "server_port": ${SOCKS_PORT},
      "version": "5",
      "username": "${SOCKS_USER}",
      "password": "${SOCKS_PASS}"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["vless-direct"],
        "outbound": "direct"
      },
      {
        "inbound": ["vless-socks"],
        "outbound": "socks_out"
      }
    ]
  }
}
EOF
    else
        cat > "$SINGBOX_CONF_FILE" <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-direct",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "uuid": "${uuid}",
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
          "private_key": "${private_key}",
          "short_id": ["${short_id}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": [
          "vless-direct"
        ],
        "outbound": "direct"
      }
    ]
  }
}
EOF
    fi
}


# ==============【 sing-box 启动配置过程 】=============
function config_singbox() {
    local uuid
    local keypair
    local private_key
    local public_key
    local short_id

    uuid=$(sing-box generate uuid)
    keypair=$(sing-box generate reality-keypair)
    private_key=$(echo "$keypair" | grep 'PrivateKey:' | awk '{print $2}')
    public_key=$( echo "$keypair" | grep 'PublicKey:'  | awk '{print $2}')
    short_id=$(sing-box generate rand 8 --hex)
    echo "$public_key" > "$PUBLIC_KEY_FILE"

    echo_info "配置 sing-box：\n  UUID: $uuid\n  PrivateKey: $private_key\n  PublicKey: $public_key\n  short_id: $short_id"

    echo_info "[交互] 是否需要添加 Socks 中转？(y/N)"
    read -rp "请输入 (y/n) [默认 n]: " ADD_SOCKS
    ADD_SOCKS=${ADD_SOCKS,,}

    if [[ "$ADD_SOCKS" == "y" ]]; then
        SOCKS_LOCAL_PORT=$(( 10000 + ( $RANDOM % 55536 ) ))

        echo_info "请输入 Socks 中转服务器 IP："
        read -rp "Socks IP: " SOCKS_IP
        [ -z "$SOCKS_IP" ] && echo_err "Socks IP 不能为空。"

        echo_info "请输入 Socks 中转端口号："
        read -rp "Socks 端口: " SOCKS_PORT
        [ -z "$SOCKS_PORT" ] && echo_err "Socks 端口不能为空。"

        echo_info "请输入 Socks 用户名（可留空）："
        read -rp "Socks 用户: " SOCKS_USER

        echo_info "请输入 Socks 密码（可留空）："
        read -rp "Socks 密码: " SOCKS_PASS

        generate_singbox_config "$uuid" "$private_key" "$public_key" "$short_id" "true"
    else
        generate_singbox_config "$uuid" "$private_key" "$public_key" "$short_id" "false"
    fi

    systemctl enable sing-box
    systemctl restart sing-box

    echo -e "\n---------------------------"
    echo_info "sing-box 已启动！"
    echo "配置参数："
    echo "  - DOMAIN:      $DOMAIN"
    echo "  - UUID:        $uuid"
    echo "  - PrivateKey:  $private_key"
    echo "  - PublicKey:   $public_key"
    echo "  - short_id:    $short_id"
    echo "  - Key Path:    $SSL_KEY_PATH"
    echo "  - Cert Path:   $SSL_CERT_PATH"
    echo "---------------------------"
}


# ==============【 脚本主要功能函数 】=============
# (1) 全新安装
function full_install() {
    get_geo_info
    ensure_nginx_installed
    ensure_sing_box_installed
    ensure_acme_installed
    ensure_cf_token_zone

    echo_info "[交互] 是否已在 Cloudflare DNS 手动添加记录？(y/N)"
    read -rp "请输入 (y/n) [默认 n]: " DNS_MANUAL
    DNS_MANUAL=${DNS_MANUAL,,}

    if [[ "$DNS_MANUAL" == "y" ]]; then
        echo_info "请输入需要申请证书的域名 (如: example.com)："
        read -rp "Domain: " DOMAIN
        [ -z "$DOMAIN" ] && echo_err "域名不能为空。"
        delete_old_dns_record_if_exists   # 手动情况下也尝试删除旧记录
    else
        create_dns_record
    fi

    apply_certificate
    update_nginx_conf
    config_singbox
}

# (2) 更新VLESS
function reinstall_vless() {
    if [ ! -f "$SINGBOX_CONF_FILE" ]; then
        echo_err "未检测到 $SINGBOX_CONF_FILE，无法更新VLESS。请先执行全新安装。"
    fi
    [ ! -x "$(command -v jq)" ] && apt update && apt install -y jq

    local old_domain
    old_domain=$(jq -r '.inbounds[0].tls.server_name' "$SINGBOX_CONF_FILE" 2>/dev/null || echo "")
    [ -z "$old_domain" ] && echo_err "无法从配置中获取原域名。"

    echo_info "重新生成 VLESS + Reality 关键字段..."
    local new_uuid
    local keypair
    local new_private_key
    local new_public_key
    local new_short_id

    new_uuid=$(sing-box generate uuid)
    keypair=$(sing-box generate reality-keypair)
    new_private_key=$(echo "$keypair" | grep 'PrivateKey:' | awk '{print $2}')
    new_public_key=$( echo "$keypair" | grep 'PublicKey:'  | awk '{print $2}')
    new_short_id=$(sing-box generate rand 8 --hex)
    echo "$new_public_key" > "$PUBLIC_KEY_FILE"

    local updated_json
    updated_json=$(jq -r \
        --arg new_uuid "$new_uuid" \
        --arg new_pkey "$new_private_key" \
        --arg new_sid  "$new_short_id"   \
        '
        .inbounds |= map(
            if .type == "vless" then
                .users[0].uuid = $new_uuid
                | .users[0].flow = "xtls-rprx-vision"
                | .tls.reality.private_key = $new_pkey
                | .tls.reality.short_id = [$new_sid]
            else
                .
            end
        )
        ' "$SINGBOX_CONF_FILE") || echo_err "更新 Reality 参数时发生错误。"

    echo "$updated_json" > "$SINGBOX_CONF_FILE"
    systemctl restart sing-box
    
    echo_info "更新VLESS 完毕。"
}

# (3) 更新域名
function update_domain() {
    if [ ! -f "$SINGBOX_CONF_FILE" ]; then
        echo_err "未找到 $SINGBOX_CONF_FILE，无法更新域名。"
    fi
    [ ! -x "$(command -v jq)" ] && apt update && apt install -y jq

    ensure_cf_token_zone
    delete_old_dns_record_if_exists
    get_geo_info
    create_dns_record
    local NEW_DOMAIN="$DOMAIN"
    [ -z "$NEW_DOMAIN" ] && echo_err "获取新域名失败。"

    echo_info "更新 Nginx 配置 server_name => $NEW_DOMAIN"
    sed -i -r "s|^(\s*server_name\s+)([^;]+);|\1$NEW_DOMAIN;|g" "$NGINX_CONF"

    echo_info "更新 sing-box 中的域名 => $NEW_DOMAIN"
    local updated_json
    updated_json=$(jq --arg d "$NEW_DOMAIN" '
        .inbounds |= map(
            if .type == "vless" then
                .tls.server_name = $d
            else
                .
            end
        )
    ' "$SINGBOX_CONF_FILE") || echo_err "更新域名时发生错误。"

    echo "$updated_json" > "$SINGBOX_CONF_FILE"

    apply_certificate
    systemctl force-reload nginx
    systemctl restart sing-box

    echo_info "域名更新完成，已使用新域名：$NEW_DOMAIN"
}

# (4) 更新 Socks
function update_socks() {
    # 确保配置文件存在、jq可用
    if [ ! -f "$SINGBOX_CONF_FILE" ]; then
        echo_err "未找到 $SINGBOX_CONF_FILE，无法更新/删除 Socks。"
    fi
    [ ! -x "$(command -v jq)" ] && apt update && apt install -y jq

    # 从当前配置中解析出主要的 VLESS inbound，用来复用 Reality 配置
    # 你也可以改成固定查询 "vless-direct" 之类的 tag
    local main_vless_inbound_json
    main_vless_inbound_json=$(jq -c '[.inbounds[] | select(.type=="vless") | select(has("tls"))][0]' "$SINGBOX_CONF_FILE")
    if [ -z "$main_vless_inbound_json" ]; then
        echo_err "当前配置中找不到任何 VLESS inbound（含 Reality 配置），无法复用 Reality。"
    fi

    # 提取关键字段：domain、uuid、flow、private_key、short_id
    local domain uuid flow private_key short_id
    domain=$(echo "$main_vless_inbound_json"     | jq -r '.tls.server_name // ""')
    uuid=$(echo "$main_vless_inbound_json"       | jq -r '.users[0].uuid // ""')
    flow=$(echo "$main_vless_inbound_json"       | jq -r '.users[0].flow // ""')
    private_key=$(echo "$main_vless_inbound_json"| jq -r '.tls.reality.private_key // ""')
    short_id=$(echo "$main_vless_inbound_json"   | jq -r '.tls.reality.short_id[0] // ""')

    if [ -z "$domain" ] || [ -z "$uuid" ] || [ -z "$private_key" ] || [ -z "$short_id" ]; then
        echo_err "无法解析 VLESS inbound 的域名/UUID/Reality字段，请检查配置。"
    fi

    # 让用户选择：1)更新 2)删除
    echo_info "请选择操作：\n  1) 更新 Socks 配置\n  2) 删除 Socks 配置"
    read -rp "输入选项 (1/2): " socks_opt

    if [[ "$socks_opt" == "2" ]]; then
        # ========================【 删除配置 】========================
        # 彻底移除 inbounds中 tag="vless-socks"，outbounds中 tag="socks_out"，以及 route中引用它们的规则
        local updated_json
        updated_json=$(jq '
          .inbounds |= map(select(.tag != "vless-socks")) 
          |
          .outbounds |= map(select(.tag != "socks_out"))
          |
          if .route then
            .route.rules |= map(
              select(
                (.inbound|index("vless-socks")|not)
                and
                (.outbound != "socks_out")
              )
            )
          else
            .
          end
        ' "$SINGBOX_CONF_FILE") || echo_err "删除 Socks 配置时出错。"

        echo "$updated_json" > "$SINGBOX_CONF_FILE"
        systemctl restart sing-box
        echo_info "Socks 配置已删除。"
        return
    fi

    # ========================【 更新配置 】========================
    # 1) 询问用户新的 Socks 参数
    echo_info "请输入 Socks 中转服务器 IP："
    read -rp "Socks IP: " new_ip
    [ -z "$new_ip" ] && echo_err "Socks IP 不能为空。"

    echo_info "请输入 Socks 中转端口号："
    read -rp "Socks 端口: " new_port
    [ -z "$new_port" ] && echo_err "Socks 端口不能为空。"

    echo_info "请输入 Socks 用户名 (可留空)："
    read -rp "Socks 用户: " new_user

    echo_info "请输入 Socks 密码 (可留空)："
    read -rp "Socks 密码: " new_pass

    # 2) 检查当前是否已有 vless-socks、socks_out
    local exist_inbound_socks inbound_socks_port
    local exist_outbound_socks
    exist_inbound_socks=$(jq -r '
      [ .inbounds[] | select(.tag=="vless-socks") ] | length
    ' "$SINGBOX_CONF_FILE")
    exist_outbound_socks=$(jq -r '
      [ .outbounds[] | select(.tag=="socks_out") ] | length
    ' "$SINGBOX_CONF_FILE")

    # 如果 inbound 已存在，就获取它的 listen_port，稍后保持不变
    if [ "$exist_inbound_socks" -gt 0 ]; then
      inbound_socks_port=$(jq -r '
        .inbounds[] | select(.tag=="vless-socks") | .listen_port
      ' "$SINGBOX_CONF_FILE")
      [ -z "$inbound_socks_port" -o "$inbound_socks_port" == "null" ] && inbound_socks_port=443
    else
      # 如果 inbound 不存在，随机生成一个新端口
      inbound_socks_port=$((10000 + (RANDOM % 55536)))
    fi

    # 3) 分两步用 jq 修改：  
    #    (a) 先移除所有 tag="vless-socks"/"socks_out" 的旧配置（包括 route 中引用），  
    #    (b) 如果 inbound_socks 原本就存在，则只添加/更新 outbound；如果没有，则连 inbound + route 一并添加。  
    local remove_socks_jq='
      .inbounds |= map(select(.tag != "vless-socks"))
      |
      .outbounds |= map(select(.tag != "socks_out"))
      |
      if .route then
        .route.rules |= map(
          select(
            (.inbound|index("vless-socks")|not)
            and
            (.outbound != "socks_out")
          )
        )
      else
        .
      end
    '

    # 新的 socks_out JSON
    local outbound_socks_json
    outbound_socks_json=$(
      jq -n \
         --arg ip "$new_ip" \
         --argjson pt "$new_port" \
         --arg us "$new_user" \
         --arg pw "$new_pass" \
      '{
        "type": "socks",
        "tag": "socks_out",
        "server": $ip,
        "server_port": $pt,
        "version": "5",
        "username": $us,
        "password": $pw
      }'
    )

    # 新的 inbound_socks JSON（仅当原先不存在时才插入）
    local inbound_socks_json
    inbound_socks_json=$(
      jq -n \
         --arg dm "$domain" \
         --arg pk "$private_key" \
         --arg sid "$short_id" \
         --arg ud "$uuid" \
         --arg fl "$flow" \
         --argjson lp "$inbound_socks_port" \
      '{
        "type": "vless",
        "tag": "vless-socks",
        "listen": "::",
        "listen_port": $lp,
        "users": [
          {
            "uuid": $ud,
            "flow": $fl
          }
        ],
        "tls": {
          "enabled": true,
          "server_name": $dm,
          "reality": {
            "enabled": true,
            "handshake": {
              "server": "127.0.0.1",
              "server_port": 8601
            },
            "private_key": $pk,
            "short_id": [
              $sid
            ]
          }
        }
      }'
    )

    # 可能需要的 route 规则
    local route_socks_json='{"inbound":["vless-socks"],"outbound":"socks_out"}'

    # 第一步：先移除旧 socks 配置
    local tmp_json
    tmp_json=$(jq "$remove_socks_jq" "$SINGBOX_CONF_FILE") || echo_err "移除旧 socks 配置时出错。"

    # 第二步：根据是否已经存在 inbound_socks 来决定是否插入 inbound_socks + route
    local updated_json
    if [ "$exist_inbound_socks" -gt 0 ]; then
        # 原先就有 vless-socks，只需插入新的 socks_out，并保证 route 中 inbound= vless-socks -> outbound= socks_out
        updated_json=$(echo "$tmp_json" | \
            jq --argjson outObj "$outbound_socks_json" \
               --argjson routeObj "$route_socks_json" '
              # 加回新的 socks_out
              .outbounds += [ $outObj ]

              # 检查 route 是否存在；若 .route 不存在则添加
              | if .route then
                  # 追加一条 rule: inbound=["vless-socks"] -> outbound="socks_out"
                  .route.rules += [ $routeObj ] | .
                else
                  . + { "route": { "rules": [ $routeObj ] } }
                end
            ')
    else
        # 原先没有 vless-socks，需要插入 inbound_socks + outbound_socks + route
        updated_json=$(echo "$tmp_json" | \
            jq --argjson inObj "$inbound_socks_json" \
               --argjson outObj "$outbound_socks_json" \
               --argjson routeObj "$route_socks_json" '
              .inbounds += [ $inObj ]
              | .outbounds += [ $outObj ]
              | if .route then
                  .route.rules += [ $routeObj ] | .
                else
                  . + { "route": { "rules": [ $routeObj ] } }
                end
            ')
    fi

    # 写回文件 & 重启
    echo "$updated_json" > "$SINGBOX_CONF_FILE"
    systemctl restart sing-box

    if [ "$exist_inbound_socks" -gt 0 ]; then
        echo_info "已更新 Socks 配置。"
    else
        echo_info "已新增 Socks 配置。"
    fi
}

# (5) 查看当前订阅
function show_vless_links() {
    if [ ! -f "$SINGBOX_CONF_FILE" ]; then
        echo_warn "未找到 $SINGBOX_CONF_FILE，无法查看订阅。"
        return
    fi
    [ ! -x "$(command -v jq)" ] && apt update && apt install -y jq

    if [ -f "$PUBLIC_KEY_FILE" ]; then
        local public_key
        public_key=$(cat "$PUBLIC_KEY_FILE" || echo "")
        if [ -z "$public_key" ]; then
            echo_warn "reality_public_key 文件内容为空。"
        fi
    else
        echo_warn "未找到 reality_public_key 文件，无法生成完整链接。"
        public_key=""
    fi

    get_geo_info
    echo_info "========== VLESS 订阅列表 =========="
    local inbounds=()
    IFS=$'\n' read -r -d '' -a inbounds < <(jq -c '.inbounds[] | select(.type=="vless")' "$SINGBOX_CONF_FILE" && printf '\0')
    for inbound in "${inbounds[@]}"; do
        local port domain uuid sid
        port=$(echo "$inbound" | jq -r '.listen_port // empty')
        domain=$(echo "$inbound" | jq -r '.tls.server_name // empty')
        uuid=$(echo "$inbound" | jq -r '.users[0].uuid // empty')
        sid=$(echo "$inbound" | jq -r '.tls.reality.short_id[0] // empty')

        [ -z "$uuid" ] && continue
        [ -z "$port" ] && continue
        [ -z "$domain" ] && continue
        [ -z "$public_key" ] && continue

        local link="vless://${uuid}@${PUBLIC_IP}:${port}?encryption=none&security=reality&type=tcp&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${sid}&flow=xtls-rprx-vision#${LOCATION_LABEL}-${uuid}-${port}"
        echo "$link"
    done
    echo -e "====================================\n"
}


# ==============【 脚本入口菜单 】=============
function main_menu() {
    echo -e "======================================="
    echo -e "  请选择操作（输入对应数字）："
    echo -e "---------------------------------------"
    echo -e "  1) 重新安装"
    echo -e "  2) 更新VLESS"
    echo -e "  3) 更新域名"
    echo -e "  4) 更新Socks"
    echo -e "  5) 查看订阅"
    echo -e "---------------------------------------"
    read -rp "请输入选项(1-5): " opt
    case "$opt" in
        1)  full_install;     show_vless_links ;;
        2)  reinstall_vless;  show_vless_links ;;
        3)  update_domain;    show_vless_links ;;
        4)  update_socks;     show_vless_links ;;
        5)  show_vless_links ;;
        *)  echo_err "无效选项：$opt" ;;
    esac
}

main_menu
