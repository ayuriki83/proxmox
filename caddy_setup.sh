#!/bin/bash

##################################################
# Docker Caddy 자동화
# bash caddy-setup.sh init     # 최초 전체 파일 생성
# bash caddy-setup.sh add      # 서비스 블록 추가
##################################################

set -e

for LINE in \
  "alias ls='ls --color=auto --show-control-chars'" \
  "alias ll='ls -al --color=auto --show-control-chars'" \
  "log() { echo \"[\$(date '+%T')] \$*\"; }" \
  "info() { echo \"[INFO][\$(date '+%T')] \$*\"; }" \
  "err() { echo \"[ERROR][\$(date '+%T')] \$*\"; }"
do
  grep -q "${LINE}" /root/.bashrc || echo "${LINE}" >> /root/.bashrc
done
source /root/.bashrc

# 설정 파일 위치 지정 (스크립트와 같은 디렉토리 등)
CONFIG_FILE="./proxmox.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    info "설정 파일 $CONFIG_FILE 이(가) 없습니다. 기본값 사용."
fi

DOCKER_BRIDGE_NM=${DOCKER_BRIDGE_NM:-ProxyNet}
ADMIN_EMAIL=${DOCKER_BRIDGE_NM:-}
BASE_DOMAIN=${DOCKER_BRIDGE_NM:-ProxyNet}
CADDYFILE="/docker/caddy/conf/Caddyfile"


usage() {
    echo "사용법: $0 [init|add]"
    exit 1
}

init() {
    mkdir -p /docker/caddy/{conf,log}

    read -p "Cloudflare API TOKEN: " CF_TOKEN
    read -p "Caddy 관리자 이메일: " ADMIN_EMAIL
    read -p "기본 도메인 (예: seani.pe.kr): " BASE_DOMAIN
    read -p "Proxmox 내부IP:PORT (예: 192.168.0.3:8006_: " PROXMOX_IP_PORT

    # 서비스 정보 반복 입력
    SERVICES=()
    while true; do
        read -p "추가할 서브도메인(호스트명, 예: ap), 그만하려면 엔터: " SUB
        [ -z "$SUB" ] && break
        read -p "reverse_proxy IP:포트 (예: 192.168.0.1:22222): " RP_ADDR
        SERVICES+=("$SUB $RP_ADDR")
    done

    # docker-compose.yaml 생성
    cat > /docker/caddy/docker-compose.yml <<EOF
services:
  caddy:
    container_name: caddy
    image: ghcr.io/caddybuilds/caddy-cloudflare:latest
    restart: always
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    cap_add:
      - NET_ADMIN
    volumes:
      - ./conf:/etc/caddy
      - ./log:/var/log
      - data:/data
      - config:/config
    environment:
      - CLOUDFLARE_API_TOKEN=${CF_TOKEN}
volumes:
  data:
  config:
networks:
  default:
    external: true
    name: ${DOCKER_BRIDGE_NM}
EOF

    # Caddyfile 생성
    cat > "$CADDYFILE" <<EOF
{
    email ${ADMIN_EMAIL}
}
# 와일드카드 인증서로 모든 서브도메인 처리
*.${BASE_DOMAIN} {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
    # Proxmox (별도 서비스 이니 IP체크)
    @proxmox host pve.seani.pe.kr
    handle @proxmox {
        reverse_proxy https://${PROXMOX_IP_PORT} {
            transport http {
                tls_insecure_skip_verify
            }
        }
    }
EOF

    # 서비스 핸들 추가
    for SVC in "${SERVICES[@]}"; do
        HN=\$(echo \$SVC | awk '{print \$1}')
        ADDR=\$(echo \$SVC | awk '{print \$2}')
        cat >> "$CADDYFILE" <<SVCF
    @$HN host $HN.$BASE_DOMAIN
    handle @$HN {
        reverse_proxy http://$ADDR {
            header_up X-Forwarded-For {remote_host}
            header_up X-Real-IP {remote_host}
        }
    }
SVCF
    done

    # 기본 응답/로그/메인 도메인 추가
    cat >> "$CADDYFILE" <<EOF
    handle {
        respond "🏠  Homelab Server - Service not found" 404
    }
    log {
        output file /var/log/access.log {
            roll_size 50mb
            roll_keep 7
            roll_keep_for 720h
        }
        format json
        level INFO
    }
}
${BASE_DOMAIN} {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
    respond "🏠  Homelab Main Page - All services running!"
}
EOF
    echo ">> docker-compose.yml, conf/Caddyfile 생성 완료"
}

add() {
    [ ! -f "$CADDYFILE" ] && { echo "$CADDYFILE 파일이 없습니다. 먼저 init을 실행하세요."; exit 2; }
    read -p "추가할 서브도메인(호스트명, 예: ap): " SUB
    read -p "reverse_proxy IP:포트 (예: 192.168.0.1:22222): " RP_ADDR
    read -p "기본 도메인 (예: seani.pe.kr): " BASE_DOMAIN

    # 와일드카드 블록 끝나는 '}' 전에 삽입 (awk 활용)
    TMP_FILE=$(mktemp)
    awk -v HN="$SUB" -v ADDR="$RP_ADDR" -v BASE="$BASE_DOMAIN" '
        /^\*\./ && $0 ~ BASE " {" {inblock=1}
        inblock && /^}/ { 
            printf("    @%s host %s.%s\n",HN,HN,BASE);
            printf("    handle @%s {\n        reverse_proxy http://%s\n    }\n",HN,ADDR);
            inblock=0 
        }
        {print}
    ' "$CADDYFILE" > "$TMP_FILE"
    mv "$TMP_FILE" "$CADDYFILE"

    echo ">> $SUB.$BASE_DOMAIN → $RP_ADDR 추가 완료"
}

# Main logic
[[ $# -lt 1 ]] && usage
case "$1" in
    init) init ;;
    add)  add ;;
    *) usage ;;
esac
