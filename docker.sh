#!/bin/bash

# 2:45
# 자동화 스크립트 (INI 스타일 NFO 대응)
# - NFO 사용자정의 마커(__DOCKER__, __COMMAND__, etc) 직접 파싱
# - 환경변수 ##KEY## 형식 치환
# - 명령어 임시파일 실행 (heredoc 문제 없음)
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

  mapfile -t commands < <(
    awk -v svc="$svc" '
      index($0, "__DOCKER__ name=\""svc"\"") > 0 {in_docker=1; next}
      in_docker && $0 ~ /^__COMMANDS_START__$/ {in_cmds=1; next}
      in_docker && $0 ~ /^__COMMANDS_END__$/ {in_cmds=0; next}
      in_docker && in_cmds && $0 ~ /^__COMMAND_START__$/ {in_cmd=1; cmd=""; next}
      in_docker && in_cmds && $0 ~ /^__COMMAND_END__$/ {if(cmd){print cmd}; cmd=""; in_cmd=0; next}
      in_docker && in_cmds && in_cmd && $0 !~ /^__/ {cmd=cmd $0 "\n"}
      $0 ~ /^__DOCKER_END__$/ {in_docker=0}
      END{if(cmd!="") print cmd}
    ' "$NFO_FILE"
  )

  for cmd in "${commands[@]}"; do
    tmpf=$(mktemp)
    printf "%s" "$cmd" > "$tmpf"
    echo "==== 임시파일 DEBUG: 실행할 명령어 내용 ===="
    cat -A "$tmpf"
    echo "==== 임시파일 END ===="
    echo "==== 명령어 실행 시작 ===="
    # 실행 명령어를 쉘에 전달해 바로 실행
    bash "$tmpf"
    echo "==== 명령어 실행 종료 ===="
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
    BEGIN {in_docker=0; in_caddys=0; in_caddy=0; caddyblock=""}
    $0 ~ "^__DOCKER__ name=\""svc"\"" {in_docker=1; next}
    in_docker && $0 ~ /^__CADDYS_START__$/ {in_caddys=1; next}
    in_docker && in_caddys && $0 ~ /^__CADDY_START__$/ {in_caddy=1; caddyblock=""; next}
    in_docker && in_caddys && in_caddy && $0 ~ /^__CADDY_END__$/ {if(in_caddy){print caddyblock}; caddyblock=""; in_caddy=0; next}
    in_docker && in_caddys && in_caddy {caddyblock=caddyblock $0 "\n"}
    # CADDYS 종료
    in_docker && $0 ~ /^__CADDYS_END__$/ {in_caddys=0}
    # DOCKER 블록 탈출
    $0 ~ /^__DOCKER_END__$/ {in_docker=0}
    END{if(caddyblock!="") print caddyblock}
  ' "$NFO_FILE"
}

DOCKER_CADDY=""
for svc in "${ALL_SERVICES[@]}"; do
  caddy_block=$(extract_caddy "$svc")
  caddy_block=${caddy_block//"##DOMAIN##"/${ENV_VALUES[DOMAIN]}}
  DOCKER_CADDY+=$'\n'"$caddy_block"$'\n'
done

caddy_escaped=$(printf '%s' "$DOCKER_CADDY" | sed 's/[\/&;]/\\&/g')
final_block=${final_block//_DOCKER_/$caddy_escaped}
for key in "${!ENV_VALUES[@]}"; do
  final_block=${final_block//"##$key##"/"${ENV_VALUES[$key]}"}
done

mkdir -p docker/caddy/conf
echo "$final_block" > /docker/caddy/conf/Caddyfile

echo "모든 작업 완료. Caddyfile 생성됨."
log

# 필요시 caddy 재시작:
# docker exec caddy caddy reload || echo "caddy reload 실패"
