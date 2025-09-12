#!/usr/bin/env bash

# 10:28
# docker.sh - NFO 마커 파싱 기반 자동 구성/생성 스크립트
# - 입력: docker.nfo, docker.env
# - 출력:
#   * /tmp/docker_<svc>_cmd_N.sh : 서비스별 CMD 스크립트 (치환 후, 실행됨)
#   * /tmp/docker_<svc>_eof_N.sh : 서비스별 EOF 파일 내용 백업본 (치환 후)
#   * 각 EOF 타깃 경로로 실제 파일 생성 (치환 후)
#   * __FINAL_START__ 경로에 최종 Caddyfile 생성 (_DOCKER_ 자리엔 선택 서비스 Caddy 스니펫 삽입)
#
# 주요 파싱 규칙(변경된 NFO 기준):
#   __DOCKERS_START__ ... __DOCKER_LIST_END__
#   __DOCKER_START__ name=<svc> req=<true|false>
#     __CMD_START__          ... __CMD_END__
#     __EOFS_START__         ... __EOFS_END__
#       __EOF_START__ <path> ... __EOF_END__
#     __CADDYS_START__       ... __CADDYS_END__
#       __CADDY_START__      ... __CADDY_END__
#   __DOCKER_END__
#   __FINAL_START__ <path>   ... __FINAL_END__
#
# 주의:
# - 함수/변수명은 기존 유지(요청사항).
# - heredoc(<<EOF)을 쓰지 않습니다. 모든 파일 생성은 __EOF_START__ <경로> 사용.

set -euo pipefail

NFO_FILE="./docker.nfo"
ENV_FILE="./docker.env"

log() {
  echo "[$(date '+%F %T')] $*"
}

# --- 안전한 sed 치환용 이스케이프 ---
_escape_sed_repl() {
  local s="$1"
  s="${s//\\/\\\\}"   # \
  s="${s//&/\\&}"     # &
  s="${s//\//\\/}"    # /
  printf '%s' "$s"
}

# --- 자리표시자 ##KEY## 치환 ---
_replace_placeholders() {
  local content
  content="$(cat)"
  for k in "${!ENV_VALUES[@]}"; do
    local v="$(_escape_sed_repl "${ENV_VALUES[$k]}")"
    content="$(printf '%s' "$content" | sed -E "s/##${k}##/${v}/g")"
  done
  printf '%s' "$content"
}

# --- docker.env 로드: 한 줄에 여러 토큰 KEY="VALUE" 지원 ---
declare -A ENV_VALUES
if [[ -f "$ENV_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    # KEY="VALUE" 패턴 모두 추출
    while read -r token; do
      [[ -z "$token" ]] && continue
      local key="${token%%=*}"
      local val="${token#*=}"
      val="${val%\"}"
      val="${val#\"}"
      key="${key//[[:space:]]/}"
      [[ -n "$key" ]] && ENV_VALUES["$key"]="$val"
    done < <(grep -oE '[A-Za-z_][A-Za-z0-9_]*="[^"]*"' <<< "$line" || true)
  done < "$ENV_FILE"
else
  : > "$ENV_FILE"
fi

# --- NFO에서 ##PLACEHOLDER## 목록 수집 후 없으면 입력 받기 ---
if [[ -f "$NFO_FILE" ]]; then
  mapfile -t ENV_KEYS < <(grep -oP '##\K[^#]+(?=##)' "$NFO_FILE" | sort -u || true)
else
  echo "오류: $NFO_FILE 파일이 없습니다."; exit 1
fi

load_env() {
  local key="$1"
  if [[ -z "${ENV_VALUES[$key]+_}" || -z "${ENV_VALUES[$key]}" ]]; then
    read -rp "환경변수 '$key' 값을 입력하세요: " val
    ENV_VALUES["$key"]="$val"
    printf '%s="%s"\n' "$key" "$val" >> "$ENV_FILE"
  fi
}
for key in "${ENV_KEYS[@]}"; do
  load_env "$key"
done

# --- 서비스 목록 파싱 (name/req 추출) ---
DOCKER_NAMES=()
DOCKER_REQ=()

# __DOCKER_START__ name=<x> req=<y> 한 줄에서 name/req 뽑기
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^__DOCKER_START__ ]]; then
    # name=..., req=... 추출(공백/따옴표 허용)
    name="$(sed -E 's/.*name[[:space:]]*=[[:space:]]*"?([^"[:space:]]+)"?.*/\1/;t;d' <<< "$line" || true)"
    req="$( sed -E 's/.*req[[:space:]]*=[[:space:]]*"?([^"[:space:]]+)"?.*/\1/;t;d'  <<< "$line" || true)"
    if [[ -n "$name" && -n "$req" ]]; then
      DOCKER_NAMES+=("$name")
      DOCKER_REQ+=("$req")
    fi
  fi
done < "$NFO_FILE"

log "[DEBUG] 파싱 완료: 총 ${#DOCKER_NAMES[@]}개 서비스 발견"
echo "========== Docker Services =========="
printf "| %-3s | %-18s | %-9s |\n" "No." "Name" "ReqYn"
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

# --- 서비스 블록 추출(전체를 통으로) : awk/mawk 의존 제거, Bash 상태머신 ---
_get_service_block() {
  local svc="$1"
  local in=0 buf="" found=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^__DOCKER_START__ ]]; then
      # 시작 → 초기화
      in=1; buf="$line"$'\n'; found=0
      # 시작줄에서 name=svc 확인
      [[ "$line" =~ name[[:space:]]*=[[:space:]]*\"?$svc\"? ]] && found=1
      continue
    fi
    if (( in )); then
      buf+="$line"$'\n'
      # 블록 중간줄에서 name=svc 나와도 인정
      [[ "$line" =~ name[[:space:]]*=[[:space:]]*\"?$svc\"? ]] && found=1
      if [[ "$line" =~ ^__DOCKER_END__ ]]; then
        if (( found )); then
          printf '%s' "$buf"
          return 0
        fi
        in=0; buf=""; found=0
      fi
    fi
  done < "$NFO_FILE"
  return 1
}

# --- 선택 서비스들의 Caddy 스니펫(원문) 누적용 ---
CADDY_SNIPPETS_RAW=""

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

  # 디버그 미리보기
  log "[DEBUG] [$svc] 블록 미리보기 ↓"
  printf '%s\n' "$block" | head -n 8

  # 1) CMD 처리
  local in_cmd=0 cmd_content="" cmd_index=0
  while IFS= read -r line; do
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
  done <<< "$block"

  # 2) EOF 처리 (__EOFS_START__ ~ __EOFS_END__ 내부의 여러 __EOF_START__ <path> ~ __EOF_END__)
  local in_eofs=0 in_eof=0 eof_content="" eof_path="" eof_index=0
  while IFS= read -r line; do
    # EOFS 범위 on/off
    if [[ "$line" == *"__EOFS_START__"* ]]; then in_eofs=1; continue; fi
    if [[ "$line" == *"__EOFS_END__"* ]]; then   in_eofs=0; in_eof=0; eof_content=""; eof_path=""; continue; fi
    (( in_eofs==0 )) && continue

    # EOF 시작: "__EOF_START__ <path>" 또는 "__EOF_START__<path>" 모두 허용
    if [[ "$line" == *"__EOF_START__"* ]]; then
      in_eof=1; eof_content=""
      # 경로 뽑기
      eof_path="${line#*__EOF_START__}"
      eof_path="${eof_path/# /}"              # 앞 공백 제거
      # 혹시 슬래시 바로 붙은 케이스 "__EOF_START__/path"
      [[ "${eof_path:0:1}" == "/" ]] || eof_path="${eof_path# }"
      continue
    fi

    # EOF 끝: 파일 생성(치환 후), /tmp 백업도 생성
    if [[ "$line" == *"__EOF_END__"* ]] && (( in_eof )); then
      in_eof=0; ((eof_index++))
      if [[ -z "$eof_path" ]]; then
        log "[WARN] [$svc] EOF 경로가 비었습니다. 해당 EOF는 건너뜁니다."
      else
        mkdir -p "$(dirname "$eof_path")"
        # 타깃 파일 기록(치환 후)
        printf '%s\n' "$eof_content" | _replace_placeholders > "$eof_path"
        # /tmp 백업본
        local tmpf="/tmp/docker_${svc}_eof_${eof_index}.sh"
        printf '%s\n' "$eof_content" | _replace_placeholders > "$tmpf"
        log "[INFO] EOF 저장: $eof_path  (백업: $tmpf)"
      fi
      eof_content=""
      eof_path=""
      continue
    fi

    (( in_eof )) && eof_content+="$line"$'\n'
  done <<< "$block"

  # 3) CADDY 스니펫 수집 (__CADDYS_START__ ~ __CADDYS_END__ / 내부 다수 __CADDY_START__ ~ __CADDY_END__)
  local in_caddys=0 in_caddy=0 caddy_chunk=""
  while IFS= read -r line; do
    if [[ "$line" == *"__CADDYS_START__"* ]]; then in_caddys=1; continue; fi
    if [[ "$line" == *"__CADDYS_END__"* ]];   then
      in_caddys=0; in_caddy=0; caddy_chunk=""; continue
    fi
    (( in_caddys==0 )) && continue

    if [[ "$line" == *"__CADDY_START__"* ]]; then
      in_caddy=1; caddy_chunk=""; continue
    fi
    if [[ "$line" == *"__CADDY_END__"* ]] && (( in_caddy )); then
      in_caddy=0
      # 서비스별로 누적
      CADDY_SNIPPETS_RAW+="${caddy_chunk}"$'\n'
      caddy_chunk=""
      continue
    fi
    (( in_caddy )) && caddy_chunk+="$line"$'\n'
  done <<< "$block"

  # 4) /tmp 생성물 확인
  echo
  log "[CHECK] /tmp 내 [$svc] 관련 파일 목록"
  ls -1 "/tmp/docker_${svc}_cmd_"* "/tmp/docker_${svc}_eof_"* 2>/dev/null || echo "(생성된 파일 없음)"
}

# --- 선택된 서비스 실행 ---
for svc in "${ALL_SERVICES[@]}"; do
  run_commands "$svc"
done

# --- FINAL 블록 처리: __FINAL_START__ <path> ... __FINAL_END__ ---
FINAL_PATH=""
FINAL_BODY=""
{
  in_f=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^__FINAL_START__ ]]; then
      in_f=1
      FINAL_PATH="${line#*__FINAL_START__}"
      FINAL_PATH="${FINAL_PATH/# /}"
      continue
    fi
    if [[ "$line" =~ ^__FINAL_END__ ]] && (( in_f )); then
      in_f=0
      break
    fi
    (( in_f )) && FINAL_BODY+="$line"$'\n'
  done
} < "$NFO_FILE"

if [[ -n "$FINAL_BODY" && -n "$FINAL_PATH" ]]; then
  # Caddy 스니펫 치환 → _DOCKER_ 자리 대체
  DOCKER_SNIPPETS_FILL="$(printf '%s' "$CADDY_SNIPPETS_RAW" | _replace_placeholders)"
  FINAL_MERGED="$(printf '%s' "$FINAL_BODY" | sed "s|_DOCKER_|$(_escape_sed_repl "$DOCKER_SNIPPETS_FILL")|g")"
  mkdir -p "$(dirname "$FINAL_PATH")"
  printf '%s' "$FINAL_MERGED" | _replace_placeholders > "$FINAL_PATH"
  log "Caddyfile 생성됨: $FINAL_PATH"
else
  log "FINAL 블록이 없어 Caddyfile을 생성하지 않았습니다."
fi

log "모든 작업 완료"
