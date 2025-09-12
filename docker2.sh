#!/bin/bash

# 9:54
# Docker 환경 자동화 스크립트 v3.0
# - NFO 파일 기반 Docker 컨테이너 배포 자동화
# - EOF 블록 처리 로직 완전 재작성
# - 디버깅 정보 강화

set -e  # 에러 발생시 스크립트 중단

# 색상 정의 (로그 가독성 향상)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로깅 함수
log() { 
    echo -e "${GREEN}[$(date '+%F %T')]${NC} $*" 
}

error() { 
    echo -e "${RED}[ERROR]${NC} $*" >&2 
}

warn() { 
    echo -e "${YELLOW}[WARN]${NC} $*" 
}

debug() {
    echo -e "${BLUE}[DEBUG]${NC} $*"
}

# 파일 경로 설정
NFO_FILE="./docker.nfo"
ENV_FILE="./docker.env"
LOG_DIR="/tmp/docker_logs"

# 로그 디렉토리 생성
mkdir -p "$LOG_DIR"

# 파일 존재 확인
if [ ! -f "$NFO_FILE" ]; then
    error "NFO 파일이 없습니다: $NFO_FILE"
    exit 1
fi

# 환경변수 저장용 연관 배열
declare -A ENV_VALUES

# 환경변수 파일 로드
load_env_file() {
    if [ -f "$ENV_FILE" ]; then
        log "환경변수 파일 로드 중: $ENV_FILE"
        while IFS='=' read -r key val; do
            # 공백 제거 및 따옴표 제거
            key=${key//[[:space:]]/}
            val=${val#\"}
            val=${val%\"}
            ENV_VALUES[$key]=$val
            debug "  - $key = $val"
        done < "$ENV_FILE"
    else
        warn "환경변수 파일이 없습니다. 새로 생성합니다: $ENV_FILE"
        touch "$ENV_FILE"
    fi
}

# NFO 파일에서 필요한 환경변수 추출
extract_required_env() {
    log "NFO 파일에서 필요한 환경변수 추출 중..."
    mapfile -t ENV_KEYS < <(grep -oP '##\K[^#]+(?=##)' "$NFO_FILE" | sort -u)
    log "필요한 환경변수: ${ENV_KEYS[*]}"
}

# 환경변수 입력 받기
prompt_for_env() {
    local key="$1"
    if [ -z "${ENV_VALUES[$key]}" ]; then
        read -rp "환경변수 '$key' 값을 입력하세요: " val
        ENV_VALUES[$key]=$val
        echo "$key=\"$val\"" >> "$ENV_FILE"
        log "환경변수 저장됨: $key"
    fi
}

# 도커 서비스 파싱
parse_docker_services() {
    log "Docker 서비스 정보 파싱 중..."
    
    DOCKER_NAMES=()
    DOCKER_REQ=()
    
    while IFS= read -r line; do
        if [[ $line =~ ^__DOCKER_START__[[:space:]]+name=([^[:space:]]+)[[:space:]]+req=([^[:space:]]+) ]]; then
            name="${BASH_REMATCH[1]}"
            req="${BASH_REMATCH[2]}"
            DOCKER_NAMES+=("$name")
            DOCKER_REQ+=("$req")
            log "  - 서비스 발견: $name (필수: $req)"
        fi
    done < "$NFO_FILE"
}

# 서비스 목록 출력
display_services() {
    echo
    echo "╔════════════════════════════════════════╗"
    echo "║         Docker Services Menu           ║"
    echo "╚════════════════════════════════════════╝"
    printf "│ %3s │ %-15s │ %-10s │\n" "No." "Service Name" "Required"
    printf "├─────┼─────────────────┼────────────┤\n"
    
    OPTIONAL_INDEX=()
    opt_idx=1
    
    for i in "${!DOCKER_NAMES[@]}"; do
        name="${DOCKER_NAMES[i]}"
        req="${DOCKER_REQ[i]}"
        no=""
        
        if [[ "$req" == "false" ]]; then
            no=$opt_idx
            OPTIONAL_INDEX+=("${i}:${no}:${name}")
            ((opt_idx++))
        fi
        
        if [[ "$req" == "true" ]]; then
            printf "│ %3s │ ${GREEN}%-15s${NC} │ %-10s │\n" "" "$name" "Yes"
        else
            printf "│ %3s │ %-15s │ %-10s │\n" "$no" "$name" "No"
        fi
    done
    printf "└─────┴─────────────────┴────────────┘\n"
}

# 서비스 선택 처리
select_services() {
    declare -g -A SELECTED_SERVICES=()
    
    if (( ${#OPTIONAL_INDEX[@]} == 0 )); then
        warn "선택 가능한 서비스가 없습니다."
        return
    fi
    
    echo
    read -rp "실행할 선택적 서비스 번호를 입력하세요 (예: 1,3,5 또는 all): " input_line
    
    # 'all' 입력 처리
    if [[ "$input_line" == "all" ]]; then
        for item in "${OPTIONAL_INDEX[@]}"; do
            service_name=${item##*:}
            SELECTED_SERVICES["$service_name"]=1
        done
    else
        # 개별 번호 처리
        IFS=',' read -r -a selected_nums <<< "$input_line"
        for num in "${selected_nums[@]}"; do
            num_trimmed=$(echo "$num" | xargs)
            for item in "${OPTIONAL_INDEX[@]}"; do
                idx=${item%%:*}
                rest=${item#*:}
                n=${rest%%:*}
                s=${rest#*:}
                if [[ "$num_trimmed" == "$n" ]]; then
                    SELECTED_SERVICES["$s"]=1
                fi
            done
        done
    fi
}

# 환경변수 치환 함수
replace_env_vars() {
    local content="$1"
    
    for key in "${!ENV_VALUES[@]}"; do
        value="${ENV_VALUES[$key]}"
        content="${content//##${key}##/$value}"
    done
    
    echo "$content"
}

# 서비스별 명령어 실행 (완전 재작성)
run_service_commands() {
    local svc="$1"
    
    echo
    echo "════════════════════════════════════════"
    echo " 서비스 처리: $svc"
    echo "════════════════════════════════════════"
    
    # 서비스 블록 전체 추출
    local service_block=$(awk -v svc="$svc" '
        BEGIN { found=0; capture=0 }
        $0 ~ "__DOCKER_START__.*name="svc".*req=" { 
            found=1; capture=1; next 
        }
        capture && /^__DOCKER_END__$/ { 
            capture=0; exit 
        }
        capture { print }
    ' "$NFO_FILE")
    
    debug "서비스 블록 크기: $(echo "$service_block" | wc -l) 줄"
    
    # CMD 블록 처리
    log "CMD 블록 처리 중..."
    local cmd_count=0
    echo "$service_block" | while IFS= read -r line; do
        if [[ "$line" == "__CMD_START__" ]]; then
            local cmd_content=""
            while IFS= read -r cmd_line; do
                [[ "$cmd_line" == "__CMD_END__" ]] && break
                cmd_content="${cmd_content}${cmd_line}"$'\n'
            done
            
            if [[ -n "$cmd_content" ]]; then
                ((cmd_count++))
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "실행: $svc - CMD #$cmd_count"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "명령어: $cmd_content"
                
                # 환경변수 치환 후 실행
                cmd_content=$(replace_env_vars "$cmd_content")
                eval "$cmd_content" 2>&1 | tee "${LOG_DIR}/${svc}_CMD_${cmd_count}.log"
                log "✓ 성공: $svc - CMD #$cmd_count"
            fi
        fi
    done < <(echo "$service_block")
    
    # EOFS 블록 내의 EOF 처리
    log "EOF 블록 처리 중..."
    local eof_count=0
    local in_eofs=0
    local in_eof=0
    local eof_content=""
    
    echo "$service_block" | while IFS= read -r line; do
        # EOFS 블록 시작/종료
        if [[ "$line" == "__EOFS_START__" ]]; then
            in_eofs=1
            debug "EOFS 블록 시작"
            continue
        elif [[ "$line" == "__EOFS_END__" ]]; then
            in_eofs=0
            debug "EOFS 블록 종료"
            continue
        fi
        
        # EOFS 블록 내부에서만 EOF 처리
        if [[ $in_eofs -eq 1 ]]; then
            if [[ "$line" == "__EOF_START__" ]]; then
                in_eof=1
                eof_content=""
                debug "EOF 블록 시작"
            elif [[ "$line" == "__EOF_END__" ]]; then
                if [[ $in_eof -eq 1 && -n "$eof_content" ]]; then
                    ((eof_count++))
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "실행: $svc - EOF #$eof_count"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    
                    # 환경변수 치환
                    eof_content=$(replace_env_vars "$eof_content")
                    
                    # 임시 스크립트 파일 생성 및 실행
                    local tmp_script=$(mktemp)
                    echo "$eof_content" > "$tmp_script"
                    
                    debug "임시 스크립트: $tmp_script"
                    cat "$tmp_script" | head -n 3
                    echo "..."
                    
                    bash "$tmp_script" 2>&1 | tee "${LOG_DIR}/${svc}_EOF_${eof_count}.log"
                    local exit_code=$?
                    
                    rm -f "$tmp_script"
                    
                    if [[ $exit_code -eq 0 ]]; then
                        log "✓ 성공: $svc - EOF #$eof_count"
                    else
                        error "✗ 실패: $svc - EOF #$eof_count (exit: $exit_code)"
                    fi
                fi
                in_eof=0
                eof_content=""
                debug "EOF 블록 종료"
            elif [[ $in_eof -eq 1 ]]; then
                # EOF 블록 내용 수집
                if [[ -n "$eof_content" ]]; then
                    eof_content="${eof_content}"$'\n'"${line}"
                else
                    eof_content="${line}"
                fi
            fi
        fi
    done
    
    log "서비스 $svc 처리 완료 (CMD: $cmd_count개, EOF: $eof_count개)"
}

# Caddy 설정 생성
generate_caddy_config() {
    log "Caddy 설정 생성 중..."
    
    # CADDY 블록 수집
    local caddy_blocks=""
    for svc in "${ALL_SERVICES[@]}"; do
        debug "Caddy 블록 수집: $svc"
        
        local service_block=$(awk -v svc="$svc" '
            BEGIN { found=0; capture=0 }
            $0 ~ "__DOCKER_START__.*name="svc".*req=" { 
                found=1; capture=1; next 
            }
            capture && /^__DOCKER_END__$/ { 
                capture=0; exit 
            }
            capture { print }
        ' "$NFO_FILE")
        
        # CADDYS 블록 내의 CADDY 내용 추출
        local in_caddys=0
        local in_caddy=0
        local caddy_content=""
        
        echo "$service_block" | while IFS= read -r line; do
            if [[ "$line" == "__CADDYS_START__" ]]; then
                in_caddys=1
            elif [[ "$line" == "__CADDYS_END__" ]]; then
                in_caddys=0
            elif [[ $in_caddys -eq 1 ]]; then
                if [[ "$line" == "__CADDY_START__" ]]; then
                    in_caddy=1
                    caddy_content=""
                elif [[ "$line" == "__CADDY_END__" ]]; then
                    if [[ $in_caddy -eq 1 && -n "$caddy_content" ]]; then
                        caddy_blocks="${caddy_blocks}${caddy_content}"$'\n'
                    fi
                    in_caddy=0
                elif [[ $in_caddy -eq 1 ]]; then
                    if [[ -n "$caddy_content" ]]; then
                        caddy_content="${caddy_content}"$'\n'"${line}"
                    else
                        caddy_content="${line}"
                    fi
                fi
            fi
        done
    done
    
    # FINAL 블록 추출
    local final_block=$(awk '
        BEGIN { in_final=0 }
        /^__FINAL_START__$/ { in_final=1; next }
        /^__FINAL_END__$/ { in_final=0; exit }
        in_final { print }
    ' "$NFO_FILE")
    
    # _DOCKER_ 플레이스홀더 치환
    final_block="${final_block//_DOCKER_/$caddy_blocks}"
    
    # 환경변수 치환
    final_block=$(replace_env_vars "$final_block")
    
    # Caddyfile 생성
    mkdir -p /docker/caddy/conf
    echo "$final_block" > /docker/caddy/conf/Caddyfile
    
    log "Caddyfile 생성 완료: /docker/caddy/conf/Caddyfile"
}

# Docker 네트워크 생성 함수
create_docker_network() {
    local network_name="${ENV_VALUES[DOCKER_BRIDGE_NM]}"
    
    if [[ -z "$network_name" ]]; then
        error "Docker 네트워크 이름이 설정되지 않았습니다"
        return 1
    fi
    
    log "Docker 네트워크 확인: $network_name"
    
    if ! docker network ls | grep -q "$network_name"; then
        log "Docker 네트워크 생성 중: $network_name"
        docker network create "$network_name" || {
            error "Docker 네트워크 생성 실패"
            return 1
        }
    else
        log "Docker 네트워크가 이미 존재합니다: $network_name"
    fi
}

# Docker Compose 실행 함수
run_docker_compose() {
    local service="$1"
    local compose_file="/docker/${service}/docker-compose.yml"
    
    if [[ -f "$compose_file" ]]; then
        log "Docker Compose 시작: $service"
        (cd "/docker/${service}" && docker-compose up -d) || {
            error "Docker Compose 실행 실패: $service"
            return 1
        }
    else
        warn "Docker Compose 파일이 없습니다: $compose_file"
    fi
}

# 메인 실행 함수
main() {
    log "Docker 자동화 스크립트 시작"
    
    # 1. 환경변수 로드
    load_env_file
    
    # 2. 필요한 환경변수 추출
    extract_required_env
    
    # 3. 환경변수 입력
    for key in "${ENV_KEYS[@]}"; do
        prompt_for_env "$key"
    done
    
    # 4. Docker 서비스 파싱
    parse_docker_services
    
    # 5. 서비스 목록 표시
    display_services
    
    # 6. 서비스 선택
    select_services
    
    # 7. 실행할 서비스 목록 구성
    REQS=()
    OPTS=()
    
    for i in "${!DOCKER_NAMES[@]}"; do
        name="${DOCKER_NAMES[i]}"
        req="${DOCKER_REQ[i]}"
        
        if [[ "$req" == "true" ]]; then
            REQS+=("$name")
        elif [[ -n "${SELECTED_SERVICES[$name]}" ]]; then
            OPTS+=("$name")
        fi
    done
    
    ALL_SERVICES=("${REQS[@]}" "${OPTS[@]}")
    
    echo
    log "실행 대상 서비스: ${ALL_SERVICES[*]}"
    echo
    
    # 8. Docker 네트워크 생성
    #create_docker_network
    
    # 9. 각 서비스 처리
    for svc in "${ALL_SERVICES[@]}"; do
        run_service_commands "$svc"
    done
    
    # 10. Caddy 설정 생성
    generate_caddy_config
    
    # 11. Docker Compose 실행 (선택적)
    echo
    read -rp "Docker 컨테이너를 지금 시작하시겠습니까? (y/n): " start_now
    
    if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
        for svc in "${ALL_SERVICES[@]}"; do
            run_docker_compose "$svc"
        done
        
        # Caddy reload
        if docker ps | grep -q caddy; then
            log "Caddy 설정 리로드 중..."
            docker exec caddy caddy reload --config /etc/caddy/Caddyfile || {
                warn "Caddy 리로드 실패. 수동으로 재시작이 필요할 수 있습니다."
            }
        fi
    fi
    
    echo
    echo "════════════════════════════════════════"
    log "모든 작업이 완료되었습니다!"
    log "로그 위치: $LOG_DIR"
    echo "════════════════════════════════════════"
}

# 스크립트 실행
main "$@"
