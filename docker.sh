#!/bin/bash

# 3:24
# 자동화 스크립트 (커스텀 INI 스타일 NFO 대응: CMD/EOF 구분)
# - NFO 사용자정의 마커(__DOCKER_START__, __CMD__, __EOFS__, __EOF__, etc) 직접 파싱
# - 환경변수 ##KEY## 형식 치환
# - 명령어 임시파일 실행 (heredoc 문제 없음, 다중라인/단일라인 모두 지원)
# - 함수 외부에서는 local 제거, 변수만 선언
# - 함수 내부만 local 사용
# - awk 내 쉘 변수를 안전하게 인용

set -e

log() { echo "[$(date '+%F %T')] $*"; }

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

# 도커 서비스 정보 파싱 (전역 변수 사용)
DOCKER_NAMES=()
DOCKER_REQ=()
while IFS= read -r line; do
  if [[ $line =~ ^__DOCKER_START__\ name=\"([^\"]+)\"\ +req=\"([^\"]+)\" ]]; then
    DOCKER_NAMES+=("${BASH_REMATCH[1]}")
    DOCKER_REQ+=("${BASH_REMATCH[2]}")
  fi
done < "$NFO_FILE"

log
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
  echo
  echo "=== 실행: $svc ==="

  # 단일명령어 블록 추출
  mapfile -t cmds < <(
    awk -v svc="$svc" '
      $0 ~ "__DOCKER_START__ name[ \t]*=[ \t]*[\"'\'']?"svc"[\"'\'']?[ ]*req" {in_docker=1; next}
      in_docker && $0 ~ /^__CMD_START__$/ {in_cmd=1; cmd=""; next}
      in_docker && $0 ~ /^__CMD_END__$/   {if(in_cmd){print cmd}; cmd=""; in_cmd=0; next}
      in_docker && in_cmd && $0 !~ /^__/  {cmd=cmd $0 "\n"; next}
      $0 ~ /^__DOCKER_END__$/ {in_docker=0}
    ' "$NFO_FILE"
  )

  # 다중라인 명령 파싱 (EOFs)
  mapfile -t eofs < <(
    awk -v svc="$svc" '
      $0 ~ "__DOCKER_START__ name[ \t]*=[ \t]*[\"'\'']?"svc"[\"'\'']?[ ]*req" {in_docker=1; next}
      in_docker && $0 ~ /^__EOFS_START__$/ {in_eofs=1; next}
      in_docker && $0 ~ /^__EOFS_END__$/   {in_eofs=0; next}
      in_docker && in_eofs && $0 ~ /^__EOF_START__$/ {in_eof=1; eofcmd=""; next}
      in_docker && in_eofs && $0 ~ /^__EOF_END__$/   {if(in_eof){print eofcmd}; eofcmd=""; in_eof=0; next}
      in_docker && in_eofs && in_eof && $0 !~ /^__EOF_END__$/ {eofcmd=eofcmd $0 "\n"; next}
      $0 ~ /^__DOCKER_END__$/ {in_docker=0}
    ' "$NFO_FILE"
  )
  
  echo "cmds count=${#cmds[@]}"; for i in "${!cmds[@]}"; do echo "-- CMD[$i] --"; echo "${cmds[$i]}"; done
  echo "eofs count=${#eofs[@]}"; for i in "${!eofs[@]}"; do echo "-- EOF[$i] --"; echo "${eofs[$i]}"; done

  # 단일명령 실행
  for idx in "${!cmds[@]}"; do
    cmd="${cmds[$idx]}"
    [[ -z "$cmd" ]] && { echo "CMD[$idx] is empty"; continue; }
    echo "==== 단일명령(DEBUG $svc #$idx) ===="
    echo "$cmd"
    (echo "$cmd" | bash 2>&1 | tee "/tmp/docker_command_${svc}_cmd${idx}.log")
    echo "==== 명령 실행 종료: 반환값 ${PIPESTATUS} ===="
  done

  # 다중라인명령 실행
  for idx in "${!eofs[@]}"; do
    eofcmd="${eofs[$idx]}"
    [ -z "$eofcmd" ] && continue
    tmpf=$(mktemp)
    printf "%s" "$eofcmd" > "$tmpf"
    echo "==== 다중라인명령(DEBUG $svc #$idx) ===="
    cat "$tmpf"
    bash "$tmpf" 2>&1 | tee "/tmp/docker_command_${svc}_eof${idx}.log"
    echo "==== 명령 실행 종료: 반환값 ${PIPESTATUS} ===="
    rm -f "$tmpf"
  done
}

echo "eofs count=${#eofs[@]}"
for i in "${!eofs[@]}"; do
  echo "----- EOF[$i] 블록 전체 -----"
  echo "${eofs[$i]}"
  echo "-----------------------------"
done


for svc in "${ALL_SERVICES[@]}"; do
  run_commands "$svc"
done

final_block=$(awk '
  BEGIN{in_f=0}
  /^\s*__FINAL_START__/ {in_f=1; next}
  /^\s*__FINAL_END__/ {in_f=0; exit}
  in_f {print}
' "$NFO_FILE")

# Caddy 추출 로직 등 기존과 동일 (생략 가능)

mkdir -p docker/caddy/conf
echo "$final_block" > /docker/caddy/conf/Caddyfile

echo "모든 작업 완료. Caddyfile 생성됨."
log

# 필요시 caddy 재시작:
# docker exec caddy caddy reload || echo "caddy reload 실패"
