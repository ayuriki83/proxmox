#!/bin/bash

# Perplexity
# 11:33
# 자동화 스크립트 (CMD/EOFS/EOF/CADDYFILE+CADDYS 완전 대응)
# - NFO 사용자정의 마커 직접 파싱
# - 환경변수 치환
# - 도커 서비스별 명령 및 compose 파일 생성 완성
# - CADDYS 블록 병합 및 _CADDYS_ 치환하여 Caddyfile 제작
# - 단계별 로그 및 디버깅 메시지 포함

set -e

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

NFO_FILE="./docker.nfo"
ENV_FILE="./docker.env"

if [ ! -f "$NFO_FILE" ]; then
  echo "오류: NFO 파일이 없습니다: $NFO_FILE"
  exit 1
fi

declare -A ENV_VALUES
if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r key val; do
    key=${key//[[:space:]]/}
    val=$(echo "$val" | sed -e 's/^"//' -e 's/"$//')
    ENV_VALUES[$key]=$val
  done < "$ENV_FILE"
else
  touch "$ENV_FILE"
fi

mapfile -t ENV_KEYS < <(grep -oP '##\K[^#]+(?=##)' "$NFO_FILE" | sort -u)
for key in "${ENV_KEYS[@]}"; do
  if [ -z "${ENV_VALUES[$key]}" ]; then
    read -rp "환경변수 '$key' 값을 입력하세요: " val
    ENV_VALUES[$key]=$val
    echo "$key=\"$val\"" >> "$ENV_FILE"
  fi
done

DOCKER_NAMES=()
DOCKER_REQ=()

while IFS= read -r line; do
  if [[ $line =~ ^__DOCKER_START__\ name=([^[:space:]]+)\ req=([^[:space:]]+) ]]; then
    DOCKER_NAMES+=("${BASH_REMATCH[1]}")
    DOCKER_REQ+=("${BASH_REMATCH[2]}")
  fi
done < "$NFO_FILE"

log() { echo "[$(date '+%F %T')] $*"; }

printf "========== Docker Services ==========\n"
printf "| %3s | %-15s | %-9s |\n" "No." "Name" "ReqYn"
printf "|-----|-----------------|-----------|\n"
opt_idx=1
OPTIONAL_INDEX=()
for i in "${!DOCKER_NAMES[@]}"; do
  name="${DOCKER_NAMES[i]}"
  req="${DOCKER_REQ[i]}"
  no=""
  if [[ "$req" == "false" ]]; then
    no=$opt_idx
    OPTIONAL_INDEX+=("${i}:${no}:${name}")
    ((opt_idx++))
  fi
  printf "| %3s | %-15s | %-9s |\n" "$no" "$name" "$req"
done
printf "|-----|-----------------|-----------|\n\n"
if (( ${#OPTIONAL_INDEX[@]} == 0 )); then
  echo "[WARN] 선택 가능한 서비스가 없습니다."
fi

read -rp "실행할 서비스 번호를 ','로 구분하여 입력하세요 (예: 1,3,5): " input_line
IFS=',' read -r -a selected_nums <<< "$input_line"

declare -A SELECTED_SERVICES=()
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
echo "실행 대상: ${ALL_SERVICES[*]}"

run_commands() {
  local svc="$1"
  echo -e "\n=== 실행: $svc ==="
  line_start=$(awk '/^__DOCKER_START__ name='"$svc"' /{print NR}' "$NFO_FILE" | head -n1)
  line_end=$(awk 'NR>'$line_start' && /^__DOCKER_END__/{print NR; exit}' "$NFO_FILE")
  if [[ -z "$line_start" || -z "$line_end" ]]; then
    echo "[ERROR] 블록 라인 찾기 실패: line_start=$line_start, line_end=$line_end"
    exit 1
  fi
  mapfile -t block_lines < <(sed -n "${line_start},${line_end}p" "$NFO_FILE")

  # 단일 CMD 실행
  in_cmd=0
  cmd_lines=()
  for line in "${block_lines[@]}"; do
    if [[ "$line" == "__CMD_START__" ]]; then in_cmd=1; continue; fi
    if [[ "$line" == "__CMD_END__" ]]; then in_cmd=0; continue; fi
    if ((in_cmd)); then cmd_lines+=("$line"); fi
  done
  if [ ${#cmd_lines[@]} -gt 0 ]; then
    echo "-- 단일명령(DEBUG $svc) --"
    printf "%s\n" "${cmd_lines[@]}"
    eval "$(printf "%s\n" "${cmd_lines[@]}")"
    echo "-- 명령 실행 완료 --"
  fi

  # EOFS/EOF 파일 생성
  in_eofs=0
  in_eof=0
  eof_path=""
  eof_content=""
  for line in "${block_lines[@]}"; do
    if [[ "$line" == "__EOFS_START__" ]]; then in_eofs=1; continue; fi
    if [[ "$line" == "__EOFS_END__" ]]; then in_eofs=0; continue; fi
    if ((in_eofs)); then
      if [[ "$line" =~ ^__EOF_START__\ (.+) ]]; then
        in_eof=1; eof_path="${BASH_REMATCH[1]}"; eof_content=""; continue;
      fi
      if [[ "$line" == "__EOF_END__" ]]; then
        in_eof=0
        # 환경변수 치환
        eof_output="$eof_content"
        for k in "${!ENV_VALUES[@]}"; do
          eof_output=$(echo "$eof_output" | sed "s/##$k##/${ENV_VALUES[$k]}/g")
        done
        mkdir -p "$(dirname "$eof_path")"
        echo -n "$eof_output" > "$eof_path"
        echo "--- 파일 생성됨: $eof_path"
        continue
      fi
      if ((in_eof)); then
        eof_content+="$line"$'\n'
      fi
    fi
  done
}

# CADDYS 블록 추출 함수
extract_caddys() {
  local svc=$1
  awk -v svc="$svc" '
    $0 ~ ("^__DOCKER_START__ name=" svc " ") { in_docker=1; next }
    in_docker && /^__CADDYS_START__/ { in_caddys=1; next }
    in_docker && /^__CADDYS_END__/ { in_caddys=0; next }
    in_docker && in_caddys && /^__CADDY_START__/ { in_caddy=1; caddy_block=""; next }
    in_docker && in_caddys && /^__CADDY_END__/ { in_caddy=0; print caddy_block; next }
    in_docker && in_caddys && in_caddy { caddy_block = caddy_block $0 "\n"; next }
    in_docker && /^__DOCKER_END__/ { in_docker=0 }
  ' "$NFO_FILE"
}

generate_caddyfile() {
  combined_caddy=""
  for svc in "${ALL_SERVICES[@]}"; do
    caddy_block=$(extract_caddys "$svc")
    for key in "${!ENV_VALUES[@]}"; do
      caddy_block=${caddy_block//"##$key##"/"${ENV_VALUES[$key]}"}
    done
    if [ -n "$combined_caddy" ]; then
      combined_caddy+=$'\n'
    fi
    combined_caddy+="$caddy_block"
  done

  # CADDYFILE 블록 추출
  caddyfile_block=$(awk '
    BEGIN {in_final=0}
    /^__CADDYFILE_START__/ { in_final=1; next }
    /^__CADDYFILE_END__/ { in_final=0; exit }
    in_final { print }
  ' "$NFO_FILE")

  # 환경변수 치환 및 _CADDYS_ 자리 치환
  for key in "${!ENV_VALUES[@]}"; do
    caddyfile_block=${caddyfile_block//"##$key##"/"${ENV_VALUES[$key]}"}
  done
  caddyfile_block=${caddyfile_block//"_CADDYS_"/"$combined_caddy"}

  echo "$caddyfile_block" > /docker/caddy/conf/Caddyfile
  echo "Caddyfile 생성 완료: /docker/caddy/conf/Caddyfile"
}

# 전체 서비스 실행 및 Caddyfile 생성 호출
for svc in "${ALL_SERVICES[@]}"; do
  run_commands "$svc"
done

# caddyfile에 서비스별 정보 자동 등록
generate_caddyfile

# 추가로 생성한 sh파일에 실행권한 부여
chmod +x /docker/rclone-after-service.sh
chmod +x /docker/docker-all-start.sh
systemctl daemon-reload
systemctl enable rclone-after-service
echo "ff, plex, kavita 등 기 데이터가 있을 경우 데이터를 옮긴 다음 /docker/docker-all-start.sh 를 실행해 주세요."

echo "모든 작업 완료."
log
