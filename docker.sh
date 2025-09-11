#!/bin/bash

# 12:44
# 자동화 스크립트 (최신, INI 스타일 NFO 대응)
# - NFO를 사용자정의 마커(__DOCKER__, __COMMAND__, etc)로 변경하여 직접 파싱
# - 환경변수도 ##KEY## 형식으로 치환
# - 각 명령어를 임시파일에 저장해 실행하여 heredoc 문제 회피

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

# NFO 내부 변환 필요없으므로 그대로 NFO_FILE 읽음
# 환경변수 추출
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

# 도커 서비스 명과 필수 여부 읽기
DOCKER_NAMES=()
DOCKER_REQUIRED=()
while IFS= read -r line; do
  if [[ $line =~ ^__DOCKER__\ name=\"([^\"]+)\"\ +required=\"([^\"]+)\" ]]; then
    DOCKER_NAMES+=("${BASH_REMATCH[1]}")
    DOCKER_REQUIRED+=("${BASH_REMATCH[2]}")
  fi
done < "$NFO_FILE"

# 서비스 출력 및 번호 매기기 (선택 가능 항목만 번호)
echo
printf "========== Docker Services ==========\n"
printf "| %3s | %-15s | %-9s |\n" "No." "Name" "Required"
printf "|-----|----------------|----------|\n"
opt_idx=1
OPTIONAL_INDEX=()
for i in "${!DOCKER_NAMES[@]}"; do
  local name="${DOCKER_NAMES[i]}"
  local required="${DOCKER_REQUIRED[i]}"
  local no=""
  if [[ "$required" == "false" ]]; then
    no=$opt_idx
    OPTIONAL_INDEX+=("${i}:${no}:${name}")
    ((opt_idx++))
  fi
  printf "| %3s | %-15s | %-9s |\n" "$no" "$name" "$required"
done
printf "|-----|----------------|----------|\n\n"

# 선택 안내
if (( ${#OPTIONAL_INDEX[@]} > 0 )); then
  echo "선택 가능한 서비스:"
  for item in "${OPTIONAL_INDEX[@]}"; do
    local idx=${item%%:*}
    local rest=${item#*:}
    local num=${rest%%:*}
    local svc=${rest#*:}
    echo "  $num) $svc"
  done
else
  echo "선택 가능한 서비스가 없습니다."
fi

read -rp "실행할 서비스 번호를 ','로 구분하여 입력하세요 (예: 1,3,5): " input_line
IFS=',' read -r -a selected_nums <<< "$input_line"

declare -A SELECTED_SERVICES=()
for num in "${selected_nums[@]}"; do
  num_trimmed=$(echo "$num" | xargs)
  for item in "${OPTIONAL_INDEX[@]}"; do
    local idx=${item%%:*}
    local rest=${item#*:}
    local n=${rest%%:*}
    local s=${rest#*:}
    if [[ "$num_trimmed" == "$n" ]]; then
      SELECTED_SERVICES["$s"]=1
    fi
  done
done

# 실행 대상 합치기
REQUIRED=()
OPTIONAL=()
for i in "${!DOCKER_NAMES[@]}"; do
  local name="${DOCKER_NAMES[i]}"
  local required="${DOCKER_REQUIRED[i]}"
  if [[ "$required" == "true" ]]; then
    REQUIRED+=("$name")
  elif [[ -n "${SELECTED_SERVICES[$name]}" ]]; then
    OPTIONAL+=("$name")
  fi
done

ALL_SERVICES=("${REQUIRED[@]}" "${OPTIONAL[@]}")

echo
echo "실행 대상: ${ALL_SERVICES[*]}"

# 명령 실행 함수
run_commands() {
  local svc="$1"
  echo
  echo "=== 실행: $svc ==="

  local cmds_block
  cmds_block=$(awk -v svc="$svc" '
    BEGIN {in_d=0; in_c=0}
    /^\s*__DOCKER__\ name="'$svc'"/ {in_d=1; next}
    /^\s*__DOCKER__/ {if (in_d) exit}
    in_d && /^\s*__COMMANDS__/ {in_c=1; next}
    in_c && /^\s*__COMMANDS__/ {next}
    in_c && /^\s*__C\w+__/ {in_c=0; exit}
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
    # 직접 파일에 기록하고 실행
    tmpf=$(mktemp)
    printf "%s\n" "$cmd" > "$tmpf"
    bash "$tmpf"
    rm -f "$tmpf"
  done
}

# 서비스 실행
for svc in "${ALL_SERVICES[@]}"; do
  run_commands "$svc"
done

# Caddy 필드 취합
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
    /^\s*__DOCKER__\ name="'$svc'"/ {in_d=1; next}
    /^\s*__DOCKER__/ {if(in_d) exit}
    in_d && /^\s*__CADDYS__/ {in_c=1; next}
    in_c && /^\s*__CADDYS__/ {in_c=0; exit}
    in_c && !/^\s*__\w+__/ {buf=buf $0 "\n"}
    END {print buf}
  ' "$NFO_FILE")
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

echo "모든 작업 완료. Caddyfile 생성됨."

# 필요시 caddy 재시작:
# docker exec caddy caddy reload || echo "caddy reload 실패"
