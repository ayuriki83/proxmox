#!/bin/bash

##################################################
# Docker Caddy 자동화
##################################################

set -e

log() { echo "[$(date '+%T')] $*"; }
info() { echo "[$(date '+%T')][INFO] $*"; }
err() { echo "[$(date '+%T')][ERROR]" "$@" >&2 }

CADDY_DIR="/docker/caddy"
CONFIG_DIR="${CADDY_DIR}/conf"
CADDYFILE="${CONFIG_DIR}/Caddyfile"
DOCKER_COMPOSE_FILE="/docker/caddy/docker-compose.yml"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROXMOX_CONF="${SCRIPT_DIR}/proxmox.conf"

# 설정 파일 로드
load_config() {
    if [ -f "$PROXMOX_CONF" ]; then
        source "$PROXMOX_CONF"
        return 0
    else
        return 1
    fi
}

usage() {
    log "사용법: $0 [init|add|remove] 또는 $0 (메뉴 선택)"
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
    log "Caddy 초기 설정 파일을 생성합니다."

    mkdir -p "${CADDY_DIR}"/{conf,log}

    read -p "1. Cloudflare API TOKEN 입력 : " CF_TOKEN
    validate_input "$CF_TOKEN" "Cloudflare API TOKEN"

    read -p "2. Caddy 관리자 이메일 입력 : " ADMIN_EMAIL
    validate_input "$ADMIN_EMAIL" "Caddy 관리자 이메일"

    # proxmox.conf 파일이 있고 BASE_DOMAIN이 이미 설정되어 있는지 확인
    if load_config; then
        log "기존 설정 파일(${PROXMOX_CONF})에서 BASE_DOMAIN을(를) 사용합니다."
    else
        log "기존 설정된 BASE_DOMAIN이 없습니다. 새로 입력합니다."
        read -p "3. 기본 도메인 (예: seani.pe.kr) 입력 : " BASE_DOMAIN
        validate_input "$BASE_DOMAIN" "기본 도메인"
        
        # BASE_DOMAIN 값만 업데이트 (sed 사용)
        echo "BASE_DOMAIN=${BASE_DOMAIN}" > "$PROXMOX_CONF"
        log "BASE_DOMAIN '${BASE_DOMAIN}'을(를) ${PROXMOX_CONF} 파일에 업데이트했습니다."
    fi
    
    # proxmox.conf 파일을 다시 소싱하여 BASE_DOMAIN 변수 적용
    load_config

    # 브릿지 네트워크 명칭
    DOCKER_BRIDGE_NM=${DOCKER_BRIDGE_NM:-ProxyNet}

    read -p "4. Proxmox 내부IP:PORT (예: 192.168.0.3:8006) 입력 : " PROXMOX_IP_PORT
    validate_input "$PROXMOX_IP_PORT" "Proxmox 내부IP:PORT"

    log "서브도메인을 추가합니다."

    # 서비스 정보 반복 입력
    SERVICES=()
    while true; do
        read -p "1. 추가할 서브도메인(호스트명, 예: ap)입력하세요. 그만하려면 엔터 : " SUB
        [ -z "$SUB" ] && break

        read -p "2. 리버스 프록시(서버IP:포트 또는 도커명:포트) (예: 192.168.0.1:22222 또는 my-app:80)입력하세요 : " RP_ADDR
        validate_input "$RP_ADDR" "리버스 프록시"
        
        # IP 패턴일 경우에만 http:// 추가
        if [[ "$RP_ADDR" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+$ ]]; then
            RP_ADDR="http://${RP_ADDR}"
        fi

        SERVICES+=("$SUB $RP_ADDR")
    done

    # docker-compose.yml 생성
    log "docker-compose.yml 파일을 생성합니다."
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
volumes:
  data:
  config:
networks:
  default:
    external: true
    name: ${DOCKER_BRIDGE_NM}
EOF

    # Caddyfile 생성
    log "Caddyfile 파일을 생성합니다."
    SERVICE_BLOCKS=""
    for SVC in "${SERVICES[@]}"; do
        HN=$(echo "$SVC" | awk '{print $1}')
        ADDR=$(echo "$SVC" | awk '{print $2}')
        SERVICE_BLOCKS+=$(cat <<SVCF

    @${HN} host ${HN}.${BASE_DOMAIN}
    handle @${HN} {
        reverse_proxy ${ADDR} {
            header_up X-Forwarded-For {remote_host}
            header_up X-Real-IP {remote_host}
        }
    }
SVCF
)
    done

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
            tls_insecure_skip_verify
        }
    }
${SERVICE_BLOCKS}

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

    log "docker-compose.yml, conf/Caddyfile 생성 완료"
    log 
    log "Caddy 컨테이너를 시작하세요."
    log "  - 시작: cd /docker/caddy && docker-compose up -d --force-recreate"
}

add() {
    log "Caddyfile에 서비스 블록을 추가합니다."

    [ ! -f "$CADDYFILE" ] && { err "$CADDYFILE 파일이 없습니다. 먼저 init을 실행하세요."; exit 2; }
    
    if ! load_config; then
        err "설정 파일(${PROXMOX_CONF})에 BASE_DOMAIN이 없거나 파일을 읽지 못했습니다. 먼저 'init'을 실행하세요."; exit 3;
    fi
    
    # 현재 서비스 목록 출력 로직 추가
    local services_list=()
    local tmp_list=$(grep '^[[:space:]]*@.* host' "$CADDYFILE" | awk '{print $1}' | sed 's/@//g' | sort -u)
    while IFS= read -r line; do
        if [[ "$line" != "proxmox" ]]; then
            services_list+=("$line")
        fi
    done <<< "$tmp_list"

    if [[ ${#services_list[@]} -eq 0 ]]; then
        log "현재 등록된 서비스가 없습니다."
    else
        printf "\n%s\t%-20s\t%s\n" "순번" "서브도메인" "리버스 프록시"
        printf "%s\n" "--------------------------------------------------------"
        local count=1
        for item in "${services_list[@]}"; do
            local rp_addr=$(awk "/@${item} host/ {
                found_rp = 0;
                for(i=1; i<=10; ++i) {
                    getline;
                    if (\$1 ~ /reverse_proxy/) {
                        print \$2;
                        found_rp = 1;
                        break;
                    }
                }
                if (found_rp == 0) {
                    print \"N/A\"
                }
            }" "$CADDYFILE")

            printf "%d\t%-20s\t%s\n" "$count" "${item}.${BASE_DOMAIN}" "$rp_addr"
            count=$((count+1))
        done
        log "" # 목록과 추가 메시지 사이에 빈 줄 추가
    fi


    # 서비스 정보 반복 입력
    SERVICES=()
    while true; do
        read -p "1. 추가할 서브도메인(호스트명, 예: ap)입력하세요. 그만하려면 엔터 : " SUB
        [ -z "$SUB" ] && break

        read -p "2. 리버스 프록시(서버IP:포트 또는 도커명:포트) (예: 192.168.0.1:22222 또는 my-app:80)입력하세요 : " RP_ADDR
        validate_input "$RP_ADDR" "reverse_proxy IP:포트"

        # IP 패턴일 경우에만 http:// 추가
        if [[ "$RP_ADDR" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]+$ ]]; then
            RP_ADDR="http://${RP_ADDR}"
        fi
        
        SERVICES+=("$SUB $RP_ADDR")
    done

    # 서비스 블록 내용을 하나의 변수에 저장
    NEW_BLOCKS=""
    for SVC in "${SERVICES[@]}"; do
        HN=$(echo "$SVC" | awk '{print $1}')
        ADDR=$(echo "$SVC" | awk '{print $2}')
        NEW_BLOCKS+=$(cat <<SVCF

    @${HN} host ${HN}.${BASE_DOMAIN}
    handle @${HN} {
        reverse_proxy ${ADDR} {
            header_up X-Forwarded-For {remote_host}
            header_up X-Real-IP {remote_host}
        }
    }
SVCF
)
    done

    # Caddyfile의 'handle {' 블록 바로 위에 새 블록 삽입
    # awk를 사용하여 이식성 및 오류 해결
    awk -v new_blocks="$NEW_BLOCKS" '/^[[:space:]]*handle {/ {print new_blocks"\n\n    handle {"} !/^[[:space:]]*handle {/ {print}' "$CADDYFILE" > "${CADDYFILE}.tmp"
    mv "${CADDYFILE}.tmp" "$CADDYFILE"
    
    # 블록 삭제 후 남을 수 있는 연속된 빈 줄을 하나로 합침
    sed -i'' -e '/^$/N;/^\n$/D' "$CADDYFILE"

    log "Caddy 서비스 블럭 추가를 완료하였습니다."
    log 
    log "Caddy 설정을 리로드하거나 컨테이너를 다시 시작하세요."
    log "  - 리로드: docker restart caddy"
    log "  - 재시작: cd /docker/caddy && docker-compose up -d --force-recreate"
}

remove() {
    log "Caddyfile에서 서비스 블록을 삭제합니다."

    [ ! -f "$CADDYFILE" ] && { err "$CADDYFILE 파일이 없습니다. 초기화 (init)를 먼저 실행하세요."; exit 2; }
    
    if ! load_config; then
        err "설정 파일(${PROXMOX_CONF})에 BASE_DOMAIN이 없거나 파일을 읽지 못했습니다."; exit 3;
    fi

    # 삭제 루프 시작
    while true; do
        local services_list=()
        
        # Caddyfile에서 서비스 목록을 추출하는 더 견고한 로직으로 수정
        local tmp_list=$(grep '^[[:space:]]*@.* host' "$CADDYFILE" | awk '{print $1}' | sed 's/@//g' | sort -u)

        # 목록을 한 줄씩 읽어서 배열에 저장
        while IFS= read -r line; do
            # 'pve'는 프록스목스 서비스이므로 삭제 목록에서 제외
            if [[ "$line" != "proxmox" ]]; then
                services_list+=("$line")
            fi
        done <<< "$tmp_list"

        # 추출된 목록이 없을 경우 종료
        if [[ ${#services_list[@]} -eq 0 ]]; then
            log "삭제할 서비스가 없습니다."
            return 0
        fi

        # 서비스 목록을 순번과 함께 출력
        printf "\n%s\t%-20s\t%s\n" "순번" "서브도메인" "리버스 프록시"
        printf "%s\n" "--------------------------------------------------------"
        local count=1
        for item in "${services_list[@]}"; do
            local rp_addr=$(awk "/@${item} host/ {
                # 다음 줄부터 reverse_proxy 줄을 찾음
                found_rp = 0;
                for(i=1; i<=10; ++i) {
                    getline;
                    if (\$1 ~ /reverse_proxy/) {
                        print \$2;
                        found_rp = 1;
                        break;
                    }
                }
                if (found_rp == 0) {
                    print \"N/A\"
                }
            }" "$CADDYFILE")

            printf "%d\t%-20s\t%s\n" "$count" "${item}.${BASE_DOMAIN}" "$rp_addr"
            count=$((count+1))
        done

        read -p "삭제할 서비스의 순번을 입력하세요 (예: 1,3,5 또는 'q'로 종료) : " SELECTION
        
        # 엔터 또는 'q' 입력 시 종료
        if [[ -z "$SELECTION" ]] || [[ "$SELECTION" == "q" ]]; then
            log "삭제를 취소하고 이전 메뉴로 돌아갑니다."
            return
        fi

        # 입력된 순번 문자열을 쉼표로 구분하여 배열에 저장
        IFS=',' read -ra selections <<< "$SELECTION"
        
        # 삭제할 서브도메인 목록을 담을 배열
        local sub_to_delete_list=()
        local invalid_selection=0

        for sel in "${selections[@]}"; do
            sel=$(echo "$sel" | xargs) # 앞뒤 공백 제거
            if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt ${#services_list[@]} ]; then
                err "오류: 올바르지 않은 순번(${sel})이 포함되어 있습니다. 1부터 ${#services_list[@]} 사이의 숫자를 입력해주세요."
                invalid_selection=1
                break
            fi
            sub_to_delete_list+=("${services_list[$((sel-1))]}")
        done

        # 잘못된 입력이 있었으면 루프 재시작
        if [ "$invalid_selection" -eq 1 ]; then
            continue
        fi

        # 삭제할 항목들을 순회하며 삭제 작업 수행
        for SUB_TO_DELETE in "${sub_to_delete_list[@]}"; do
            awk -v sub_to_delete="$SUB_TO_DELETE" '
            BEGIN { in_block=0; brace_level=0 }
            
            $0 ~ ("@" sub_to_delete " host") {
                in_block=1;
                next
            }
            
            in_block == 1 && $0 ~ /{/ {
                brace_level++
            }
            
            in_block == 1 && $0 ~ /}/ {
                brace_level--
            }
            
            in_block == 0 {
                print
            }
            
            in_block == 1 && brace_level == 0 {
                in_block=0
            }
            ' "$CADDYFILE" > "${CADDYFILE}.tmp" && mv "${CADDYFILE}.tmp" "$CADDYFILE"
        done
        
        # 모든 삭제 작업 후 연속된 빈 줄을 하나로 합침
        sed -i'' -e '/^$/N;/^\n$/D' "$CADDYFILE"

        log "Caddy 서비스 블럭 삭제를 완료하였습니다."
        log 
        log "Caddy 설정을 리로드하거나 컨테이너를 다시 시작하세요."
        log "  - 리로드: docker exec -w /etc/caddy caddy caddy reload"
        log "  - 재시작: cd /docker/caddy && docker-compose up -d --force-recreate"
        
        # 한 번 삭제 후 루프를 종료
        break
    done
}


# 메인 로직
if [[ $# -lt 1 ]]; then
    log "========================================"
    log "           Caddy 자동화 스크립트"
    log "========================================"
    log "원하는 작업을 선택하세요:"
    log "1. 초기화 (init) - 최초 전체 파일 생성"
    log "2. 추가 (add) - 서비스 블록 추가"
    log "3. 삭제 (remove) - 서비스 블록 삭제"
    log "4. 종료 (exit)"
    
    read -p "선택: " SELECTION
    
    case "$SELECTION" in
        1) init ;;
        2) add ;;
        3) remove ;;
        4|exit) echo "스크립트를 종료합니다."; exit 0 ;;
        *) err "잘못된 선택입니다. 1, 2, 3, 4 중 하나를 입력하세요."; exit 1 ;;
    esac
else
    case "$1" in
        init) init ;;
        add)  add ;;
        remove) remove ;;
        *)    usage ;;
    esac
fi
