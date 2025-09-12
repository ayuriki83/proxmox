#!/bin/bash

# 9:49
# Docker 환경 자동화 스크립트 v2.0
# - NFO 파일 기반 Docker 컨테이너 배포 자동화
# - 환경변수 치환 및 heredoc 처리 개선
# - 에러 처리 및 로깅 강화

set -e  # 에러 발생시 스크립트 중단

# 색상 정의 (로그 가독성 향상)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
            log "  - $key 로드됨"
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
            printf "│ %3s │ ${GREEN}%-15s${NC} │ %-10s │\n" "$no" "$name" "Yes"
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
        # 특수 문자 이스케이프 처리
        escaped_value=$(printf '%s\n' "$value" | sed 's/[[\.*^$()+?{|]/\\&/g')
        content="${content//##${key}##/$escaped_value}"
    done
    
    echo "$content"
}

# 명령어 실행 함수
execute_command() {
    local cmd="$1"
    local service="$2"
    local cmd_type="$3"
    local idx="$4"
    
    # 환경변수 치환
    cmd=$(replace_env_vars "$cmd")
    
    # 로그 파일 경로
    local log_file="${LOG_DIR}/${service}_${cmd_type}_${idx}.log"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "실행: $service - $cmd_type #$idx"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 명령어 내용 표시 (디버그용)
    if [[ "$cmd_type" == "CMD" ]]; then
        echo "명령어: $cmd"
    else
        echo "다중라인 명령어:"
        echo "$cmd" | head -n 5
        echo "..."
    fi
    
    # 실제 실행
    if bash -c "$cmd" 2>&1 | tee "$log_file"; then
        log "✓ 성공: $service - $cmd_type #$idx"
    else
        error "✗ 실패: $service - $cmd_type #$idx (로그: $log_file)"
        return 1
    fi
}

# 서비스별 명령어 실행
run_service_commands() {
    local svc="$1"
    
    echo
    echo "════════════════════════════════════════"
    echo " 서비스 처리: $svc"
    echo "════════════════════════════════════════"
    
    # CMD 블록 추출 및 실행
    log "CMD 블록 처리 중..."
    local cmd_idx=0
    while IFS= read -r cmd_block; do
        if [[ -n "$cmd_block" ]]; then
            execute_command "$cmd_block" "$svc" "CMD" "$cmd_idx"
            ((cmd_idx++))
        fi
    done < <(awk -v svc="$svc" '
        BEGIN { in_docker=0; in_cmd=0; cmd="" }
        $0 ~ "__DOCKER_START__.*name="svc".*req=" { in_docker=1; next }
        in_docker && /^__CMD_START__$/ { in_cmd=1; cmd=""; next }
        in_docker && /^__CMD_END__$/ { 
            if (in_cmd && length(cmd)>0) print cmd
            cmd=""; in_cmd=0; next 
        }
        in_docker && in_cmd && !/^__/ { 
            if (length(cmd)>0) cmd=cmd"\n"
            cmd=cmd$0
            next 
        }
        /^__DOCKER_END__$/ { in_docker=0; exit }
    ' "$NFO_FILE")
    
    # EOF 블록 추출 및 실행
    log "EOF 블록 처리 중..."
    local eof_idx=0
    local in_eof=0
    local eof_content=""
    
    while IFS= read -r line; do
        if [[ "$line" == "__EOF_START__" ]]; then
            in_eof=1
            eof_content=""
        elif [[ "$line" == "__EOF_END__" ]]; then
            if [[ -n "$eof_content" ]]; then
                # heredoc 실행을 위한 임시 스크립트 생성
                local tmp_script=$(mktemp)
                echo "$eof_content" > "$tmp_script"
                
                # 환경변수 치환 적용
                local replaced_content=$(replace_env_vars "$eof_content")
                echo "$replaced_content" > "$tmp_script"
                
                # 스크립트 실행
                if bash "$tmp_script" 2>&1 | tee "${LOG_DIR}/${svc}_EOF_${eof_idx}.log"; then
                    log "✓ EOF 블록 #$eof_idx 성공"
                else
                    error "✗ EOF 블록 #$eof_idx 실패"
                fi
                
                rm -f "$tmp_script"
                ((eof_idx++))
            fi
            in_eof=0
            eof_content=""
        elif [[ $in_eof -eq 1 ]]; then
            if [[ -n "$eof_content" ]]; then
                eof_content="${eof_content}"$'\n'"${line}"
            else
                eof_content="${line}"
            fi
        fi
    done < <(awk -v svc="$svc" '
        BEGIN { in_docker=0; in_eofs=0; in_eof=0 }
        $0 ~ "__DOCKER_START__.*name="svc".*req=" { in_docker=1; next }
        in_docker && /^__EOFS_START__$/ { in_eofs=1; next }
        in_docker && /^__EOFS_END__$/ { in_eofs=0; next }
        in_docker && in_eofs { print }
        /^__DOCKER_END__$/ { in_docker=0; exit }
    ' "$NFO_FILE")
}

# Caddy 설정 생성
generate_caddy_config() {
    log "Caddy 설정 생성 중..."
    
    # CADDY 블록 수집
    local caddy_blocks=""
    for svc in "${ALL_SERVICES[@]}"; do
        local block=$(awk -v svc="$svc" '
            BEGIN { in_docker=0; in_caddys=0; in_caddy=0; content="" }
            $0 ~ "__DOCKER_START__.*name="svc".*req=" { in_docker=1; next }
            in_docker && /^__CADDYS_START__$/ { in_caddys=1; next }
            in_docker && /^__CADDYS_END__$/ { in_caddys=0; next }
            in_docker && in_caddys && /^__CADDY_START__$/ { in_caddy=1; next }
            in_docker && in_caddys && /^__CADDY_END__$/ { 
                if (in_caddy && length(content)>0) print content
                content=""; in_caddy=0; next 
            }
            in_docker && in_caddys && in_caddy { 
                if (length(content)>0) content=content"\n"
                content=content$0
                next 
            }
            /^__DOCKER_END__$/ { in_docker=0; exit }
        ' "$NFO_FILE")
        
        if [[ -n "$block" ]]; then
            caddy_blocks="${caddy_blocks}"$'\n'"${block}"
        fi
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
