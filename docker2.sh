#!/bin/bash

# 10:07
# 수정된 Docker 환경 자동화 스크립트 v3.2
# - 바로 종료 문제 해결
# - 에러 핸들링 강화
# - 디버깅 모드 추가

# 디버깅 모드 설정 (필요시 uncomment)
# set -x

# 에러 발생시 스크립트 중단하지 않고 계속 진행
set +e

# 색상 정의 (로그 가독성 향상)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로깅 함수
log() { echo -e "${GREEN}[$(date '+%F %T')]${NC} $*" }
error() { echo -e "${RED}[$(date '+%F %T')][ERROR]${NC} $*" >&2 }
warn() { echo -e "${YELLOW}[$(date '+%F %T')][WARN]${NC} $*" }
debug() { echo -e "${BLUE}[$(date '+%F %T')][DEBUG]${NC} $*" }

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
    log "환경변수 파일 로드 함수 시작"
    
    if [ -f "$ENV_FILE" ]; then
        log "환경변수 파일 로드 중: $ENV_FILE"
        
        # 안전한 파일 읽기
        while IFS='=' read -r key val || [[ -n "$key" ]]; do
            # 빈 줄이나 주석 건너뛰기
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            
            # 공백 제거 및 따옴표 제거
            key=${key//[[:space:]]/}
            val=${val#\"}
            val=${val%\"}
            
            if [[ -n "$key" && -n "$val" ]]; then
                ENV_VALUES[$key]=$val
                debug "  - $key = $val"
            fi
        done < "$ENV_FILE"
        
        log "환경변수 로드 완료: ${#ENV_VALUES[@]}개"
    else
        warn "환경변수 파일이 없습니다. 새로 생성합니다: $ENV_FILE"
        touch "$ENV_FILE"
    fi
}

# NFO 파일에서 필요한 환경변수 추출
extract_required_env() {
    log "NFO 파일에서 필요한 환경변수 추출 함수 시작"
    
    if ! command -v grep &> /dev/null; then
        error "grep 명령어를 찾을 수 없습니다"
        return 1
    fi
    
    # grep으로 환경변수 패턴 추출
    mapfile -t ENV_KEYS < <(grep -oP '##\K[^#]+(?=##)' "$NFO_FILE" 2>/dev/null | sort -u)
    
    log "필요한 환경변수: ${ENV_KEYS[*]}"
    log "환경변수 추출 완료: ${#ENV_KEYS[@]}개"
}

# 환경변수 입력 받기
prompt_for_env() {
    local key="$1"
    
    debug "환경변수 확인: $key"
    
    if [[ -z "${ENV_VALUES[$key]}" ]]; then
        echo -n "환경변수 '$key' 값을 입력하세요: "
        read -r val
        
        if [[ -n "$val" ]]; then
            ENV_VALUES[$key]=$val
            echo "$key=\"$val\"" >> "$ENV_FILE"
            log "환경변수 저장됨: $key = $val"
        else
            warn "빈 값이 입력되었습니다: $key"
        fi
    else
        debug "기존 환경변수 사용: $key = ${ENV_VALUES[$key]}"
    fi
}

# 도커 서비스 파싱
parse_docker_services() {
    log "Docker 서비스 정보 파싱 함수 시작"
    
    DOCKER_NAMES=()
    DOCKER_REQ=()
    
    local service_count=0
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $line =~ ^__DOCKER_START__[[:space:]]+name=([^[:space:]]+)[[:space:]]+req=([^[:space:]]+) ]]; then
            local name="${BASH_REMATCH[1]}"
            local req="${BASH_REMATCH[2]}"
            DOCKER_NAMES+=("$name")
            DOCKER_REQ+=("$req")
            ((service_count++))
            log "  - 서비스 발견: $name (필수: $req)"
        fi
    done < "$NFO_FILE"
    
    log "서비스 파싱 완료: $service_count개 서비스"
    
    if [[ $service_count -eq 0 ]]; then
        error "서비스를 찾을 수 없습니다"
        return 1
    fi
}

# 서비스 목록 출력
display_services() {
    log "서비스 목록 출력 함수 시작"
    
    echo
    echo "╔════════════════════════════════════════╗"
    echo "║         Docker Services Menu           ║"
    echo "╚════════════════════════════════════════╝"
    printf "│ %3s │ %-15s │ %-10s │\n" "No." "Service Name" "Required"
    printf "├─────┼─────────────────┼────────────┤\n"
    
    OPTIONAL_INDEX=()
    local opt_idx=1
    
    for i in "${!DOCKER_NAMES[@]}"; do
        local name="${DOCKER_NAMES[i]}"
        local req="${DOCKER_REQ[i]}"
        local no=""
        
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
    
    log "서비스 목록 출력 완료"
}

# 서비스 선택 처리
select_services() {
    log "서비스 선택 함수 시작"
    
    declare -g -A SELECTED_SERVICES=()
    
    if (( ${#OPTIONAL_INDEX[@]} == 0 )); then
        warn "선택 가능한 선택적 서비스가 없습니다."
        return 0
    fi
    
    echo
    echo -n "실행할 선택적 서비스 번호를 입력하세요 (예: 1,3,5 또는 all): "
    
    # 타임아웃 없이 입력 받기
    local input_line
    read -r input_line
    
    debug "사용자 입력: '$input_line'"
    
    # 'all' 입력 처리
    if [[ "$input_line" == "all" ]]; then
        log "모든 선택적 서비스 선택"
        for item in "${OPTIONAL_INDEX[@]}"; do
            local service_name=${item##*:}
            SELECTED_SERVICES["$service_name"]=1
            debug "선택됨: $service_name"
        done
    else
        # 개별 번호 처리
        IFS=',' read -r -a selected_nums <<< "$input_line"
        for num in "${selected_nums[@]}"; do
            local num_trimmed=$(echo "$num" | xargs)
            debug "처리 중인 번호: '$num_trimmed'"
            
            for item in "${OPTIONAL_INDEX[@]}"; do
                local idx=${item%%:*}
                local rest=${item#*:}
                local n=${rest%%:*}
                local s=${rest#*:}
                
                if [[ "$num_trimmed" == "$n" ]]; then
                    SELECTED_SERVICES["$s"]=1
                    log "서비스 선택됨: $s"
                fi
            done
        done
    fi
    
    log "서비스 선택 완료: ${#SELECTED_SERVICES[@]}개"
}

# 환경변수 치환 함수
replace_env_vars() {
    local content="$1"
    
    for key in "${!ENV_VALUES[@]}"; do
        local value="${ENV_VALUES[$key]}"
        content="${content//##${key}##/$value}"
    done
    
    echo "$content"
}

# 서비스별 명령어 실행 (안전성 강화)
run_service_commands() {
    local svc="$1"
    
    log "서비스 처리 시작: $svc"
    
    echo
    echo "════════════════════════════════════════"
    echo " 서비스 처리: $svc"
    echo "════════════════════════════════════════"
    
    # 임시 파일로 서비스 블록 추출
    local temp_service_file=$(mktemp)
    
    # 에러 처리를 위한 체크
    if [[ ! -f "$temp_service_file" ]]; then
        error "임시 파일 생성 실패"
        return 1
    fi
    
    # awk를 사용해서 서비스 블록 추출
    awk -v svc="$svc" '
        BEGIN { found=0; capture=0 }
        $0 ~ "__DOCKER_START__.*name="svc".*req=" { 
            found=1; capture=1; next 
        }
        capture && /^__DOCKER_END__$/ { 
            capture=0; exit 
        }
        capture { print }
    ' "$NFO_FILE" > "$temp_service_file"
    
    local block_lines=$(wc -l < "$temp_service_file")
    debug "서비스 블록 크기: $block_lines 줄"
    
    if [[ $block_lines -eq 0 ]]; then
        warn "서비스 블록을 찾을 수 없습니다: $svc"
        rm -f "$temp_service_file"
        return 0
    fi
    
    # CMD 블록 처리
    log "CMD 블록 처리 중..."
    local cmd_count=0
    local in_cmd=0
    local cmd_content=""
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        debug "처리 중인 라인: $line"
        
        if [[ "$line" == "__CMD_START__" ]]; then
            in_cmd=1
            cmd_content=""
            debug "CMD 블록 시작"
        elif [[ "$line" == "__CMD_END__" ]]; then
            if [[ $in_cmd -eq 1 && -n "$cmd_content" ]]; then
                ((cmd_count++))
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "실행: $svc - CMD #$cmd_count"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                debug "명령어: $cmd_content"
                
                # 환경변수 치환 후 실행
                local cmd_final=$(replace_env_vars "$cmd_content")
                debug "치환된 명령어: $cmd_final"
                
                # 명령어 실행
                echo "실행할 명령어: $cmd_final"
                eval "$cmd_final" 2>&1 | tee "${LOG_DIR}/${svc}_CMD_${cmd_count}.log"
                local cmd_result=$?
                
                if [[ $cmd_result -eq 0 ]]; then
                    log "✓ 성공: $svc - CMD #$cmd_count"
                else
                    error "✗ 실패: $svc - CMD #$cmd_count (exit code: $cmd_result)"
                    # 에러가 발생해도 계속 진행
                fi
            fi
            in_cmd=0
            cmd_content=""
            debug "CMD 블록 종료"
        elif [[ $in_cmd -eq 1 ]]; then
            if [[ -n "$cmd_content" ]]; then
                cmd_content="${cmd_content}${line}"$'\n'
            else
                cmd_content="${line}"$'\n'
            fi
        fi
    done < "$temp_service_file"
    
    # EOF 블록 처리
    log "EOF 블록 처리 중..."
    local eof_count=0
    local in_eofs=0
    local in_eof=0
    local eof_content=""
    
    # 파일을 다시 읽기
    while IFS= read -r line || [[ -n "$line" ]]; do
        debug "EOF 처리 - 라인: $line"
        
        # EOFS 블록 시작/종료
        if [[ "$line" == "__EOFS_START__" ]]; then
            in_eofs=1
            debug "EOFS 블록 시작"
        elif [[ "$line" == "__EOFS_END__" ]]; then
            in_eofs=0
            debug "EOFS 블록 종료"
        elif [[ $in_eofs -eq 1 ]]; then
            # EOFS 블록 내부에서만 EOF 처리
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
                    local eof_final=$(replace_env_vars "$eof_content")
                    
                    # 임시 스크립트 파일 생성 및 실행
                    local tmp_script=$(mktemp)
                    echo "$eof_final" > "$tmp_script"
                    
                    debug "임시 스크립트: $tmp_script"
                    echo "스크립트 내용 미리보기:"
                    head -n 5 "$tmp_script"
                    echo "..."
                    
                    # 스크립트 실행
                    echo "EOF 스크립트 실행 중..."
                    bash "$tmp_script" 2>&1 | tee "${LOG_DIR}/${svc}_EOF_${eof_count}.log"
                    local eof_result=$?
                    
                    rm -f "$tmp_script"
                    
                    if [[ $eof_result -eq 0 ]]; then
                        log "✓ 성공: $svc - EOF #$eof_count"
                    else
                        error "✗ 실패: $svc - EOF #$eof_count (exit code: $eof_result)"
                        # 에러가 발생해도 계속 진행
                    fi
                fi
                in_eof=0
                eof_content=""
                debug "EOF 블록 종료"
            elif [[ $in_eof -eq 1 ]]; then
                # EOF 블록 내용 수집
                if [[ -n "$eof_content" ]]; then
                    eof_content="${eof_content}${line}"$'\n'
                else
                    eof_content="${line}"$'\n'
                fi
            fi
        fi
    done < "$temp_service_file"
    
    # 임시 파일 정리
    rm -f "$temp_service_file"
    
    log "서비스 $svc 처리 완료 (CMD: $cmd_count개, EOF: $eof_count개)"
    
    # 서비스 처리 완료 후 잠깐 대기
    echo "서비스 $svc 처리 완료. 계속하려면 Enter를 누르세요..."
    read -r
}

# Caddy 설정 생성
generate_caddy_config() {
    log "Caddy 설정 생성 시작"
    
    # CADDY 블록 수집
    local caddy_blocks=""
    for svc in "${ALL_SERVICES[@]}"; do
        debug "Caddy 블록 수집: $svc"
        
        # 임시 파일로 서비스 블록 추출
        local temp_service_file=$(mktemp)
        awk -v svc="$svc" '
            BEGIN { found=0; capture=0 }
            $0 ~ "__DOCKER_START__.*name="svc".*req=" { 
                found=1; capture=1; next 
            }
            capture && /^__DOCKER_END__$/ { 
                capture=0; exit 
            }
            capture { print }
        ' "$NFO_FILE" > "$temp_service_file"
        
        # CADDYS 블록 내의 CADDY 내용 추출
        local in_caddys=0
        local in_caddy=0
        local caddy_content=""
        
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "__CADDYS_START__" ]]; then
                in_caddys=1
                debug "CADDYS 블록 시작: $svc"
            elif [[ "$line" == "__CADDYS_END__" ]]; then
                in_caddys=0
                debug "CADDYS 블록 종료: $svc"
            elif [[ $in_caddys -eq 1 ]]; then
                if [[ "$line" == "__CADDY_START__" ]]; then
                    in_caddy=1
                    caddy_content=""
                    debug "CADDY 블록 시작"
                elif [[ "$line" == "__CADDY_END__" ]]; then
                    if [[ $in_caddy -eq 1 && -n "$caddy_content" ]]; then
                        caddy_blocks="${caddy_blocks}${caddy_content}"$'\n'
                        debug "CADDY 블록 추가됨 (길이: ${#caddy_content})"
                    fi
                    in_caddy=0
                    debug "CADDY 블록 종료"
                elif [[ $in_caddy -eq 1 ]]; then
                    if [[ -n "$caddy_content" ]]; then
                        caddy_content="${caddy_content}${line}"$'\n'
                    else
                        caddy_content="${line}"$'\n'
                    fi
                fi
            fi
        done < "$temp_service_file"
        
        # 임시 파일 정리
        rm -f "$temp_service_file"
    done
    
    debug "수집된 Caddy 블록 크기: ${#caddy_blocks}"
    
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
    debug "Caddyfile 크기: $(wc -l < /docker/caddy/conf/Caddyfile) 줄"
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
        docker network create "$network_name" 2>&1 | tee "${LOG_DIR}/network_create.log"
        local result=$?
        
        if [[ $result -eq 0 ]]; then
            log "Docker 네트워크 생성 완료: $network_name"
        else
            error "Docker 네트워크 생성 실패 (exit code: $result)"
            return 1
        fi
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
        (cd "/docker/${service}" && docker-compose up -d 2>&1 | tee "${LOG_DIR}/${service}_compose.log")
        local result=$?
        
        if [[ $result -eq 0 ]]; then
            log "Docker Compose 실행 완료: $service"
        else
            error "Docker Compose 실행 실패: $service (exit code: $result)"
        fi
    else
        warn "Docker Compose 파일이 없습니다: $compose_file"
    fi
}

# 메인 실행 함수
main() {
    log "=== Docker 자동화 스크립트 시작 ==="
    
    # 1. 환경변수 로드
    log "단계 1: 환경변수 로드"
    load_env_file
    
    # 2. 필요한 환경변수 추출
    log "단계 2: 필요한 환경변수 추출"
    extract_required_env
    
    # 3. 환경변수 입력
    log "단계 3: 환경변수 입력"
    for key in "${ENV_KEYS[@]}"; do
        prompt_for_env "$key"
    done
    
    # 4. Docker 서비스 파싱
    log "단계 4: Docker 서비스 파싱"
    parse_docker_services
    
    # 5. 서비스 목록 표시
    log "단계 5: 서비스 목록 표시"
    display_services
    
    # 6. 서비스 선택
    log "단계 6: 서비스 선택"
    select_services
    
    # 7. 실행할 서비스 목록 구성
    log "단계 7: 실행할 서비스 목록 구성"
    REQS=()
    OPTS=()
    
    for i in "${!DOCKER_NAMES[@]}"; do
        local name="${DOCKER_NAMES[i]}"
        local req="${DOCKER_REQ[i]}"
        
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
    log "단계 8: Docker 네트워크 생성"
    create_docker_network
    
    # 9. 각 서비스 처리
    log "단계 9: 각 서비스 처리"
    for svc in "${ALL_SERVICES[@]}"; do
        run_service_commands "$svc"
    done
    
    # 10. Caddy 설정 생성
    log "단계 10: Caddy 설정 생성"
    generate_caddy_config
    
    # 11. Docker Compose 실행 (선택적)
    log "단계 11: Docker Compose 실행 여부 선택"
    echo
    echo -n "Docker 컨테이너를 지금 시작하시겠습니까? (y/n): "
    read -r start_now
    
    if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
        log "Docker 컨테이너 시작 중..."
        for svc in "${ALL_SERVICES[@]}"; do
            run_docker_compose "$svc"
        done
        
        # Caddy reload
        if docker ps | grep -q caddy; then
            log "Caddy 설정 리로드 중..."
            docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>&1 | tee "${LOG_DIR}/caddy_reload.log"
            local result=$?
            
            if [[ $result -eq 0 ]]; then
                log "Caddy 리로드 완료"
            else
                warn "Caddy 리로드 실패. 수동으로 재시작이 필요할 수 있습니다."
            fi
        fi
    else
        log "Docker 컨테이너 시작을 건너뜁니다."
    fi
    
    echo
    echo "════════════════════════════════════════"
    log "🎉 모든 작업이 완료되었습니다!"
    log "📁 로그 위치: $LOG_DIR"
    echo "════════════════════════════════════════"
}

# 신호 핸들러 (Ctrl+C 등)
trap 'echo; error "스크립트가 중단되었습니다"; exit 1' INT TERM

# 스크립트 실행
main "$@"
