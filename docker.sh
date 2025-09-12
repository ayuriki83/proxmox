#!/bin/bash

# 10:23
# 자동화 스크립트 (커스텀 INI 스타일 NFO: CMD/EOFS/EOF/FINAL 대응)
# - 서비스별 명령/파일 블록 파싱, 환경변수 치환
# - CMD는 직접 실행, EOFS/EOF는 파일생성
# - FINAL은 경로 지정하여 생성
# - 주요 로그 및 단계별 디버그출력

set -e

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

# NFO 내 환경변수 키 목록 추출 및 입력 받음
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
DOCKER_BLOCKS=()

# 서비스 목록 및 각 블록의 시작라인 기록
block_start=0
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ $line =~ ^__DOCKER_START__\ name=([^[:space:]]+)\ req=([^[:space:]]+) ]]; then
    DOCKER_NAMES+=("${BASH_REMATCH[1]}")
    DOCKER_REQ+=("${BASH_REMATCH[2]}")
    block_start=$((block_start+1))
    DOCKER_BLOCKS+=($block_start)
  fi
  block_start=$((block_start+1))
done < "$NFO_FILE"

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

  # 서비스 블록 시작/끝번호 추출, 빈값/문자열 오류 방지
  line_start=$(awk '/^__DOCKER_START__ name='"$svc"' /{print NR}' "$NFO_FILE" | head -n1)
  line_end=$(awk 'NR>'$line_start' && /^__DOCKER_END__/{print NR; exit}' "$NFO_FILE")
  if [[ -z "$line_start" || -z "$line_end" ]]; then
    echo "[ERROR] 블록 라인 찾기 실패: line_start=$line_start, line_end=$line_end"
    exit 1
  fi
  block_lines=$(sed -n "${line_start},${line_end}p" "$NFO_FILE")

  # CMD 파싱 및 실행
  cmd_block=$(echo "$block_lines" | awk '
    $0 ~ /^__CMD_START__$/ {in_cmd=1; next}
    $0 ~ /^__CMD_END__$/ {in_cmd=0; next}
    in_cmd {print}
  ')
  if [[ -n "$cmd_block" ]]; then
    echo "-- 단일명령(DEBUG $svc) --"
    echo "$cmd_block"
    eval "$cmd_block"
    echo "-- 명령 실행 완료 --"
  fi

  # EOFS/EOF 파싱 및 파일 생성
  eofs_blocks=$(echo "$block_lines" | awk '
    $0 ~ /^__EOFS_START__$/ {in_eofs=1; next}
    $0 ~ /^__EOFS_END__$/ {in_eofs=0; next}
    in_eofs {print}
  ')
  if [[ -n "$eofs_blocks" ]]; then
    while read -r eof_start_line; do
      [[ -z "$eof_start_line" ]] && continue
      # 파일명 추출 (__EOF_START__ /docker/caddy/docker-compose.yml)
      if [[ $eof_start_line =~ ^__EOF_START__\ (.+) ]]; then
        eof_path="${BASH_REMATCH[1]}"
        eof_content=$(echo "$eofs_blocks" | awk '
          $0 ~ /^__EOF_START__ '"$eof_path"'$/ {in_eof=1; next}
          $0 ~ /^__EOF_END__$/ {in_eof=0; exit}
          in_eof {print}
        ')
        # 환경변수 치환
        for k in "${!ENV_VALUES[@]}"; do
          eof_content=$(echo "$eof_content" | sed "s/##$k##/${ENV_VALUES[$k]}/g")
        done
        mkdir -p "$(dirname "$eof_path")"
        echo "$eof_content" > "$eof_path"
        echo "--- 파일 생성됨: $eof_path"
      fi
    done < <(echo "$eofs_blocks" | grep "^__EOF_START__")
  fi
}

for svc in "${ALL_SERVICES[@]}"; do
  run_commands "$svc"
done

# FINAL 블록 처리
final_filename=$(awk '
  BEGIN{fn=""}
  /^\s*__FINAL_START__/ {getline; fn=$1; print fn; exit}
' "$NFO_FILE")
final_content=$(awk '
  BEGIN{in_f=0}
  /^\s*__FINAL_START__/ {in_f=1; getline; next}
  /^\s*__FINAL_END__/ {in_f=0; exit}
  in_f {print}
' "$NFO_FILE")

# 환경변수 치환
for k in "${!ENV_VALUES[@]}"; do
  final_content=$(echo "$final_content" | sed "s/##$k##/${ENV_VALUES[$k]}/g")
done
mkdir -p "$(dirname "$final_filename")"
echo "$final_content" > "$final_filename"
echo "[완료] 최종 파일 생성됨: $final_filename"
log

# 필요시 추가처리 (예: caddy reload)
# docker exec caddy caddy reload || echo "caddy reload 실패"
