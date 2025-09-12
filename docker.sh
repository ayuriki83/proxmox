#!/bin/bash

# Perplexity
# 10:34
# 자동화 스크립트 (커스텀 INI 스타일 NFO 대응: CMD/EOFS/EOF/FINAL)
# - NFO 사용자정의 마커(__DOCKER_START__, __CMD_START__, __EOFS_START__, __EOF_START__, __FINAL_START__ 등) 직접 파싱
# - 환경변수 ##KEY## 형식 치환
# - 커맨드 블록 실행 및 다중라인 파일 생성
# - 함수 외부에서는 local 제거, 변수만 선언
# - 함수 내부만 local 사용
# - 메인 구간 전체 bash 루프·판정 위주(awk는 line번호 추출에만 사용, 정규식 없음)
# - 주요 단계별 디버깅/로그 안내

set -e

NFO_FILE="./docker.nfo"
ENV_FILE="./docker.env"

if [ ! -f "$NFO_FILE" ]; then
  echo "오류: NFO 파일이 없습니다: $NFO_FILE"
  exit 1
fi

# 환경변수 초기화 및 로드
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

# NFO 내 환경변수 리스트 추출
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

# 도커 서비스 정보 파싱(마커 따옴표·공백 호환, 정규식 최소화)
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
  # 블록 범위(라인번호) 탐색 (정수로만)
  line_start=$(awk '/^__DOCKER_START__ name='"$svc"' /{print NR}' "$NFO_FILE" | head -n1)
  line_end=$(awk 'NR>'$line_start' && /^__DOCKER_END__/{print NR; exit}' "$NFO_FILE")
  if [[ -z "$line_start" || -z "$line_end" ]]; then
    echo "[ERROR] 블록 라인 찾기 실패: line_start=$line_start, line_end=$line_end"
    exit 1
  fi
  mapfile -t block_lines < <(sed -n "${line_start},${line_end}p" "$NFO_FILE")

  # CMD 처리
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

  # EOFS/EOF 처리 (bash 루프로 안전하게)
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

for svc in "${ALL_SERVICES[@]}"; do
  run_commands "$svc"
done

# FINAL 블록 처리
final_filename=""
final_content=""
in_final=0
while IFS= read -r line; do
  if [[ "$line" =~ ^__FINAL_START__\ (.+) ]]; then
    in_final=1
    final_filename="${BASH_REMATCH[1]}"
    continue
  fi
  if [[ "$line" == "__FINAL_END__" ]]; then
    in_final=0
    continue
  fi
  if ((in_final)); then
    final_content+="$line"$'\n'
  fi
done < "$NFO_FILE"

if [[ -n "$final_filename" ]]; then
  for k in "${!ENV_VALUES[@]}"; do
    final_content=$(echo "$final_content" | sed "s/##$k##/${ENV_VALUES[$k]}/g")
  done
  mkdir -p "$(dirname "$final_filename")"
  echo -n "$final_content" > "$final_filename"
  echo "[완료] 최종 파일 생성됨: $final_filename"
fi

echo "모든 작업 완료."
log

# 필요시 추가 액션(예: caddy reload)
# docker exec caddy caddy reload || echo "caddy reload 실패"
