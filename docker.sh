#!/bin/bash

# 1:07
# 자동화 스크립트 (INI 스타일 NFO 대응)
# - NFO 사용자정의 마커(__DOCKER__, __COMMAND__, etc) 직접 파싱
# - 환경변수 ##KEY## 형식 치환
# - 명령어 임시파일 실행 (heredoc 문제 없음)
# - 함수 외부에서는 local 제거, 변수만 선언
# - 함수 내부만 local 사용
# - awk 내 쉘 변수를 안전하게 인용

set -e

log() { echo "[$(date '+%T')] $*"; }
info() { echo "[$(date '+%T')][INFO] $*"; }
warn() { echo "[$(date '+%T')][WARN] $*"; }
err() { echo "[$(date '+%T')][ERROR]" "$@" >&2; }

NFO_FILE="./docker.nfo"
ENV_FILE="./docker.env"

if [ ! -f "$NFO_FILE" ]; then
  echo "오류: $NFO_FILE 파일이 없습니다."
  exit 1
fi

# 환경변수 초기화 및 로드
declare -A ENV_VALUES
if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r key val; do
    key=${key//[[:space:]]/}
    val=$(sed -e 's/^"//' -e 's/"$//' <<< "$val")
    ENV_VALUES[$key]=$val
  done < "$ENV_FILE"
else
  touch "$ENV_FILE"
fi

# 환경변수 리스트 추출
mapfile -t ENV_KEYS < <(grep -oP '##\K[^#]+(?=##)' "$NFO_FILE" | sort -u)

# 환경변수 없는 경우 입력받음 (함수 내 local)
load_env() {
  local key="$1"
  if [ -z "${ENV_VALUES[$key]}" ]; then
    read -rp "환경변수 '$key' 값을 입력하세요: " val
    ENV_VALUES[$key]=$val
    echo "$key=\"$val\"" >> "$ENV_FILE"
  fi
}
for key in "${ENV_KEYS[@]}"; do
  load_env "$key"
done

# 도커 서비스 정보 파싱 (전역 변수 사용, local 제거)
DOCKER_NAMES=()
DOCKER_REQ=()
while IFS= read -r line; do
  if [[ $line =~ ^__DOCKER__\ name=\"([^\"]+)\"\ +req=\"([^\"]+)\" ]]; then
    DOCKER_NAMES+=("${BASH_REMATCH[1]}")
    DOCKER_REQ+=("${BASH_REMATCH[2]}")
  fi
done < "$NFO_FILE"

log
printf "========== Docker Services ==========\n"
printf "| %3s | %-15s | %-9s |\n" "No." "Name" "ReqYn"
printf "|-----|----------------|----------|\n"
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
printf "|-----|----------------|----------|\n\n"

if (( ${#OPTIONAL_INDEX[@]} > 0 )); then
  log "선택 가능한 서비스:"
  for item in "${OPTIONAL_INDEX[@]}"; do
    idx=${item%%:*}
    rest=${item#*:}
    num=${rest%%:*}
    svc=${rest#*:}
    echo "  $num) $svc"
  done
else
  warn "선택 가능한 서비스가 없습니다."
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
  log
  log "=== 실행: $svc ==="

  # awk 내 변수 안전 인용을 위해 변수 전달 방식 보완
  cmds_block=$(awk -v svc="$svc" '
    BEGIN {in_d=0; in_c=0}
    $0 ~ "^__DOCKER__ name=\""svc"\"" {in_d=1; next}
    $0 ~ "^__DOCKER__" && in_d == 1 {exit}
    in_d && $0 ~ "^__COMMANDS__" {in_c=1; next}
    in_c && $0 ~ "^__COMMANDS__" {next}
    in_c && $0 ~ "^__C\\w+__" {in_c=0; exit}
    in_c {print}
  ' "$NFO_FILE")

  mapfile -t commands <<< "$(awk '
    BEGIN {cmd=""; in_cmd=0}
    /^__COMMAND__$/ {if (cmd != "") print cmd; cmd=""; in_cmd=1; next}
    /^__COMMAND__$/ {next}
    /^__\w+__$/ {if (in_cmd) {print cmd; cmd="";} in_cmd=0}
    {if(in_cmd) cmd=cmd $0 "\n"}
    END {if(cmd!="") print cmd}
  ' <<< "$cmds_block")"

  for cmd in "${commands[@]}"; do
    for key in "${!ENV_VALUES[@]}"; do
      cmd=${cmd//"##$key##"/${ENV_VALUES[$key]}}
    done
    tmpf=$(mktemp)
    printf "%s\n" "$cmd" > "$tmpf"
    bash "$tmpf"
    rm -f "$tmpf"
  done
}

for svc in "${ALL_SERVICES[@]}"; do
  run_commands "$svc"
done

final_block=$(awk '
  BEGIN{in_f=0}
  /^\s*__FINAL__START__/ {in_f=1; next}
  /^\s*__FINAL__END__/ {in_f=0; exit}
  in_f {print}
' "$NFO_FILE")

extract_caddy() {
  local svc="$1"
  awk -v svc="$svc" '
    BEGIN {in_d=0; in_c=0; buf=""}
    $0 ~ "^__DOCKER__ name=\""svc"\"" {in_d=1; next}
    $0 ~ "^__DOCKER__" && in_d == 1 {exit}
    in_d && $0 ~ "^__CADDYS__" {in_c=1; next}
    in_c && $0 ~ "^__CADDYS__" {in_c=0; exit}
    in_c && $0 !~ "^__\\w+__" {buf=buf $0 "\n"}
    END {print buf}
  ' "$NFO_FILE"
}

DOCKER_CADDY=""
for svc in "${ALL_SERVICES[@]}"; do
  caddy_block=$(extract_caddy "$svc")
  caddy_block=${caddy_block//"##DOMAIN##"/${ENV_VALUES[DOMAIN]}}
  DOCKER_CADDY+=$'\n'"$caddy_block"$'\n'
done

caddy_escaped=$(printf '%s' "$DOCKER_CADDY" | sed 's/[\/&]/\\&/g')
final_block=${final_block//_DOCKER_/$caddy_escaped}
for key in "${!ENV_VALUES[@]}"; do
  final_block=${final_block//"##$key##"/"${ENV_VALUES[$key]}"}
done

mkdir -p docker/caddy/conf
echo "$final_block" > docker/caddy/conf/Caddyfile

log "모든 작업 완료. Caddyfile 생성됨."

# 필요시 caddy 재시작:
# docker exec caddy caddy reload || echo "caddy reload 실패"
