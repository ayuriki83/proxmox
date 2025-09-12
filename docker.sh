#!/bin/bash

# 9:52
# 자동화 스크립트 (커스텀 NFO 마커 파싱 & EOF 안전 실행)
# - 문제 원인: docker.nfo에 마커(__EOFS_START__, __EOF_START__ 등)가 한 줄에 이어붙어 있어
#   '^__EOFS_START__$' 같은 라인 매칭이 실패 → EOF 블록 추출 불가.
# - 해결: NFO를 전처리하여 모든 마커를 개행으로 분리한 임시 파일을 만든 뒤, 라인 단위 파싱.
# - 추가: docker.env가 한 줄에 공백으로 나열된 key="value" 형식 → 토큰 단위 파싱 지원.
# - 자리표시자(##KEY##)는 EOF/FINAL 블록에 대해 사전 치환 후 bash 실행.
# - 변수명, 함수명은 기존 것을 유지.

set -euo pipefail

log() {
  echo "[$(date '+%F %T')] $*"
}

NFO_FILE="./docker.nfo"
ENV_FILE="./docker.env"

if [ ! -f "$NFO_FILE" ]; then
  echo "오류: $NFO_FILE 파일이 없습니다."
  exit 1
fi

# ------------------------------------------------------------------------------
# 0) docker.nfo 전처리: 모든 마커 토큰을 개행으로 분리해 라인 매칭 가능하게 변환
#    (예: "__EOFS_START__ __EOF_START__ ..." → 각 토큰이 자기 라인에 위치)
# ------------------------------------------------------------------------------
TMP_NFO="$(mktemp)"
# 마커 패턴: __UPPERCASE_WITH_UNDERSCORE__
# 양 옆에 항상 개행을 삽입하고, 연속 개행은 1개로 축소
sed -E 's/(__[A-Z]+(_[A-Z]+)*__)/\n\1\n/g' "$NFO_FILE" | sed -E ':a;N;$!ba;s/\n{2,}/\n/g' > "$TMP_NFO"

# ------------------------------------------------------------------------------
# 1) 환경변수 로드: docker.env의 한 줄 공백 구분 key="value" 포맷 지원
# ------------------------------------------------------------------------------
declare -A ENV_VALUES

if [ -f "$ENV_FILE" ]; then
  # 예) DOCKER_BRIDGE_NM="ProxyNet" API_TOKEN="AAAA" ...
  # 토큰 단위로 끊어 각 key/value 추출
  while read -r line; do
    # 라인 내에서 key="value" 패턴을 모두 뽑아 반복
    # 안전하게 따옴표만 제거
    while read -r token; do
      [ -z "$token" ] && continue
      key="${token%%=*}"
      val="${token#*=}"
      # val에서 앞뒤 큰따옴표만 제거
      val="${val%\"}"
      val="${val#\"}"
      key="${key//[[:space:]]/}"
      [ -n "$key" ] && ENV_VALUES["$key"]="$val"
    done < <(grep -oE '[A-Za-z_][A-Za-z0-9_]*="[^"]*"' <<< "$line" || true)
  done < "$ENV_FILE"
else
  touch "$ENV_FILE"
fi

# ------------------------------------------------------------------------------
# 2) NFO에서 자리표시자 키 목록 수집 → 값 없으면 입력 받아 ENV_FILE에 라인 단위로 append
# ------------------------------------------------------------------------------
mapfile -t ENV_KEYS < <(grep -oP '##\K[^#]+(?=##)' "$TMP_NFO" | sort -u || true)

load_env() {
  local key="$1"
  if [ -z "${ENV_VALUES[$key]+_}" ] || [ -z "${ENV_VALUES[$key]}" ]; then
    read -rp "환경변수 '$key' 값을 입력하세요: " val
    ENV_VALUES[$key]="$val"
    # docker.env에 라인 단위로 안전 추가
    printf '%s="%s"\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

for key in "${ENV_KEYS[@]}"; do
  load_env "$key"
done

# ------------------------------------------------------------------------------
# 3) 서비스 목록 파싱: __DOCKER_START__ name=xxx req=true|false
#    (이제 마커가 각 라인에 분리되어 있으므로 라인 단위 정규식으로 안정 파싱 가능)
# ------------------------------------------------------------------------------
DOCKER_NAMES=()
DOCKER_REQ=()

# in_block 변수를 명시적으로 초기화
in_block=0

while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ ^__DOCKER_START__ ]]; then
    in_block=1
    continue
  fi

  if [[ $in_block -eq 1 ]]; then
    if [[ "$line" =~ name=([^[:space:]]+)[[:space:]]+req=([^[:space:]]+) ]]; then
      name="${BASH_REMATCH[1]//\"/}"
      req="${BASH_REMATCH[2]//\"/}"
      DOCKER_NAMES+=("$name")
      DOCKER_REQ+=("$req")
    else
      echo "[DEBUG] name/req 패턴 매칭 실패: $line"
    fi
    in_block=0
  fi
done < "$TMP_NFO"

echo "[DEBUG] 파싱 완료: 총 ${#DOCKER_NAMES[@]}개 서비스 발견"

# 보기 표 출력
printf "========== Docker Services ==========|\n"
printf "| %3s | %-18s | %-9s |\n" "No." "Name" "ReqYn"
printf "|-----|--------------------|-----------|\n"
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
  printf "| %3s | %-18s | %-9s |\n" "$no" "$name" "$req"
done
printf "|-----|--------------------|-----------|\n\n"

if (( ${#OPTIONAL_INDEX[@]} == 0 )); then
  echo "[WARN] 선택 가능한(선택 설치) 서비스가 없습니다."
fi

read -rp "실행할 서비스 번호를 ','로 구분하여 입력하세요 (예: 1,3,5): " input_line
IFS=',' read -r -a selected_nums <<< "$input_line"
declare -A SELECTED_SERVICES=()
for num in "${selected_nums[@]}"; do
  num_trimmed="$(echo "$num" | xargs)"
  for item in "${OPTIONAL_INDEX[@]}"; do
    idx="${item%%:*}"
    rest="${item#*:}"
    n="${rest%%:*}"
    s="${rest#*:}"
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
  elif [[ -n "${SELECTED_SERVICES[$name]+_}" ]]; then
    OPTS+=("$name")
  fi
done
ALL_SERVICES=("${REQS[@]}" "${OPTS[@]}")

echo
echo "실행 대상: ${ALL_SERVICES[*]}"

# ------------------------------------------------------------------------------
# 4) 치환 유틸: ##KEY## → ENV_VALUES[KEY]
#    sed 안전 치환을 위해 슬래시/역슬래시 등 이스케이프 처리
# ------------------------------------------------------------------------------
_escape_sed_repl() {
  # sed replacement 영역에 들어갈 문자열 이스케이프
  local s="$1"
  s="${s//\\/\\\\}"   # backslash
  s="${s//&/\\&}"     # &
  s="${s//\//\\/}"    # /
  printf '%s' "$s"
}

# 지정한 서비스 이름을 가진 DOCKER 블록 전체를 그대로 반환
_get_service_block() {
  local svc="$1"
  local capture=0 buf="" name_ok=0

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ __DOCKER_START__ ]]; then
      capture=1; buf="$line"$'\n'; name_ok=0; continue
    fi
    if (( capture )); then
      buf+="$line"$'\n'
      [[ "$line" =~ name[[:space:]]*=[[:space:]]*\"?$svc\"? ]] && name_ok=1
      if [[ "$line" =~ __DOCKER_END__ ]]; then
        if (( name_ok )); then
          printf '%s' "$buf"; return 0
        fi
        capture=0; buf=""; name_ok=0
      fi
    fi
  done < "$TMP_NFO"

  return 1
}

_replace_placeholders() {
  # stdin → stdout
  local content
  content="$(cat)"
  for k in "${!ENV_VALUES[@]}"; do
    v="$(_escape_sed_repl "${ENV_VALUES[$k]}")"
    content="$(printf '%s' "$content" | sed -E "s/##${k}##/${v}/g")"
  done
  printf '%s' "$content"
}

# ------------------------------------------------------------------------------
# 5) 실행기: 선택 서비스 내 __CMD_START__/__CMD_END__ 와 __EOFS_START__/__EOF_START__/__EOF_END__/__EOFS_END__ 처리
# ------------------------------------------------------------------------------
run_commands() {
  local svc="$1"
  echo
  echo "=== 실행: $svc ==="

  local block
  block="$(_get_service_block "$svc")"
  if [[ -z "$block" ]]; then
    log "[WARN] 서비스 [$svc] 블록을 찾지 못했습니다."
    return
  fi

  # CMD
  local cmd_index=0 cmd_content="" in_cmd=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == *"__CMD_START__"* ]]; then
      in_cmd=1; cmd_content=""; continue
    fi
    if [[ "$line" == *"__CMD_END__"* ]] && (( in_cmd )); then
      ((cmd_index++))
      local tmpf="/tmp/docker_${svc}_cmd_${cmd_index}.sh"
      printf '%s\n' "$cmd_content" | _replace_placeholders > "$tmpf"
      chmod +x "$tmpf"
      log "[INFO] CMD 저장: $tmpf"
      bash "$tmpf"
      in_cmd=0; cmd_content=""; continue
    fi
    (( in_cmd )) && cmd_content+="$line"$'\n'
  done < <(printf '%s' "$block")

  # EOF
  local eof_index=0 eof_content="" in_eofs=0 in_eof=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == *"__EOFS_START__"* ]]; then in_eofs=1; continue; fi
    if [[ "$line" == *"__EOFS_END__"* ]]; then in_eofs=0; in_eof=0; eof_content=""; continue; fi
    (( in_eofs==0 )) && continue

    if [[ "$line" == *"__EOF_START__"* ]]; then in_eof=1; eof_content=""; continue; fi
    if [[ "$line" == *"__EOF_END__"* ]] && (( in_eof )); then
      in_eof=0; ((eof_index++))
      local tmpf="/tmp/docker_${svc}_eof_${eof_index}.sh"
      printf '%s\n' "$eof_content" | _replace_placeholders > "$tmpf"
      chmod +x "$tmpf"
      log "[INFO] EOF 저장: $tmpf"
      bash "$tmpf"
      eof_content=""; continue
    fi
    (( in_eof )) && eof_content+="$line"$'\n'
  done < <(printf '%s' "$block")

  if ((cmd_index==0 && eof_index==0)); then
    log "[WARN] 서비스 [$svc]에서 CMD/EOF 블록을 찾지 못했습니다."
  else
    log "[INFO] 서비스 [$svc] 처리 완료 (CMD:$cmd_index, EOF:$eof_index)"
  fi
}

# ------------------------------------------------------------------------------
# 6) 선택된 모든 서비스 실행
# ------------------------------------------------------------------------------
for svc in "${ALL_SERVICES[@]}"; do
  run_commands "$svc"
done

# ------------------------------------------------------------------------------
# 7) FINAL 블록(Caddyfile)도 치환 적용하여 생성
# ------------------------------------------------------------------------------
final_block="$(
  awk '
    BEGIN{in_f=0}
    /^\s*__FINAL_START__/ {in_f=1; next}
    /^\s*__FINAL_END__/   {in_f=0; exit}
    in_f {print}
  ' "$TMP_NFO"
)"

mkdir -p /docker/caddy/conf
if [[ -n "$final_block" ]]; then
  if [[ "${#ENV_KEYS[@]}" -gt 0 ]]; then
    printf '%s' "$final_block" | _replace_placeholders > /docker/caddy/conf/Caddyfile
  else
    printf '%s' "$final_block" > /docker/caddy/conf/Caddyfile
  fi
  log "Caddyfile 생성됨: /docker/caddy/conf/Caddyfile"
else
  log "FINAL 블록이 없어 Caddyfile을 생성하지 않았습니다."
fi

# 마무리
rm -f "$TMP_NFO"
log "모든 작업 완료"
# 필요시: docker exec caddy caddy reload || echo "caddy reload 실패"
