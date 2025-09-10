#!/bin/bash

##################################################
# Docker Caddy 자동화
# bash caddy-setup.sh init      # 최초 전체 파일 생성
# bash caddy-setup.sh add       # 서비스 블록 추가
##################################################

set -e

# 초기 환경 설정 및 함수 정의
function_exists() { declare -f -F "$1" > /dev/null; }
: << "END"
source_bashrc() {
    local aliases=(
        "alias ls='ls --color=auto --show-control-chars'"
        "alias ll='ls -al --color=auto --show-control-chars'"
        "log() { echo \"[\$(date '+%T')] \$*\"; }"
        "info() { echo \"[INFO][\$(date '+%T')] \$*\"; }"
        "err() { echo \"[ERROR][\$(date '+%T')] \$*\"; }"
    )
    for line in "${aliases[@]}"; do
        grep -qF "${line}" /root/.bashrc || echo "${line}" >> /root/.bashrc
    done
    source /root/.bashrc
}

source_bashrc
END

log() { echo "[$(date '+%T')] $*"; }
info() { echo "[INFO][$(date '+%T')] $*"; }
err() { echo "[ERROR][$(date '+%T')] $*"; }


# 환경 변수 및 설정 파일 경로
CADDY_DIR="/docker/caddy"
CONFIG_DIR="${CADDY_DIR}/conf"
CADDYFILE="${CONFIG_DIR}/Caddyfile"
DOCKER_COMPOSE_FILE="/docker/caddy/docker-compose.yml"
PROXMOX_CONF="./proxmox.conf"

# 설정 파일 로드
if [ -f "$PROXMOX_CONF" ]; then
    source "$PROXMOX_CONF"
else
    info "설정 파일 $PROXMOX_CONF 이(가) 없습니다. 일부 기능이 제한될 수 있습니다."
fi

usage() {
    echo "사용법: $0 [init|add]"
    exit 1
}

validate_input() {
    local value="$1"
    local name="$2"
    if [[ -z "$value" ]]; then
        err "오류: $name 값이 비어 있습니다. 올바른 값을 입력해주세요."
        exit 1
    fi
}

init() {
    info "Caddy 초기 설정 파일을 생성합니다."
    
    mkdir -p ${CADDY_DIR}/{conf,log}

    read -p "Cloudflare API TOKEN: " CF_TOKEN
    validate_input "$CF_TOKEN" "Cloudflare API TOKEN"
    
    read -p "Caddy 관리자 이메일: " ADMIN_EMAIL
    validate_input "$ADMIN_EMAIL" "Caddy 관리자 이메일"
    
    read -p "기본 도메인 (예: seani.pe.kr): " BASE_DOMAIN
    validate_input "$BASE_DOMAIN" "기본 도메인"
    
    read -p "Proxmox 내부IP:PORT (예: 192.168.0.3:8006): " PROXMOX_IP_PORT
    validate_input "$PROXMOX_IP_PORT" "Proxmox 내부IP:PORT"

    # 서비스 정보 반복 입력
    SERVICES=()
    while true; do
        read -p "추가할 서브도메인(호스트명, 예: ap), 그만하려면 엔터: " SUB
        [ -z "$SUB" ] && break
        read -p "reverse_proxy IP:포트 (예: 192.168.0.1:22222): " RP_ADDR
        SERVICES+=("$SUB $RP_ADDR")
    done

    # docker-compose.yml 생성
    info "docker-compose.yml 파일을 생성합니다."
    cat > "$DOCKER_COMPOSE_FILE" <<EOF
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
      - ADMIN_EMAIL=${ADMIN_EMAIL}
      - BASE_DOMAIN=${BASE_DOMAIN}
      - PROXMOX_IP_PORT=${PROXMOX_IP_PORT}
volumes:
  data:
  config:
networks:
  default:
    external: true
    name: ProxyNet
EOF

    # Caddyfile 생성
    info "Caddyfile 파일을 생성합니다."
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
    @proxmox host pve.${BASE_DOMAIN}
    handle @proxmox {
        reverse_proxy https://${PROXMOX_IP_PORT} {
            transport http {
                tls_insecure_skip_verify
            }
        }
    }

$(
    for SVC in "${SERVICES[@]}"; do
        HN=$(echo "$SVC" | awk '{print $1}')
        ADDR=$(echo "$SVC" | awk '{print $2}')
        cat <<SVCF
    @${HN} host ${HN}.${BASE_DOMAIN}
    handle @${HN} {
        reverse_proxy http://${ADDR} {
            header_up X-Forwarded-For {remote_host}
            header_up X-Real-IP {remote_host}
        }
    }
SVCF
    done
)

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
    info "Caddyfile에 서비스 블록을 추가합니다."
    
    [ ! -f "$CADDYFILE" ] && { err "$CADDYFILE 파일이 없습니다. 먼저 init을 실행하세요."; exit 2; }

    # docker-compose.yml에서 기본 도메인 값 가져오기
    BASE_DOMAIN=$(grep "BASE_DOMAIN" "$DOCKER_COMPOSE_FILE" | cut -d'=' -f2)
    [ -z "$BASE_DOMAIN" ] && { err "docker-compose.yml에서 BASE_DOMAIN을 찾을 수 없습니다."; exit 3; }

    read -p "추가할 서브도메인(호스트명, 예: ap): " SUB
    validate_input "$SUB" "서브도메인"
    
    read -p "reverse_proxy IP:포트 (예: 192.168.0.1:22222): " RP_ADDR
    validate_input "$RP_ADDR" "reverse_proxy IP:포트"

    # Caddyfile 수정 (sed 활용)
    # 와일드카드 블록 끝부분을 찾아 새로운 서비스 블록 삽입
    sed_command=$(cat << SED_EOF
/^\s*handle {/i \

    @${SUB} host ${SUB}.${BASE_DOMAIN}
    handle @${SUB} {
        reverse_proxy http://${RP_ADDR} {
            header_up X-Forwarded-For {remote_host}
            header_up X-Real-IP {remote_host}
        }
    }
SED_EOF
)
    
    if ! sed -i "$sed_command" "$CADDYFILE"; then
        err "Caddyfile 수정에 실패했습니다. 파일 권한을 확인하거나 수동으로 수정해주세요."
        exit 4
    fi

    echo ">> ${SUB}.${BASE_DOMAIN} → ${RP_ADDR} 추가 완료"
    info "Docker 컨테이너를 다시 시작하세요. (cd /docker/caddy && docker-compose up -d)"
}

# 메인 로직
[[ $# -lt 1 ]] && usage
case "$1" in
    init) init ;;
    add) add ;;
    *) usage ;;
esac
