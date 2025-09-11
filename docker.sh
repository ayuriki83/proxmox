#!/bin/bash

# 12:27
# 자동화 스크립트 (최신 수정판)
# - docker.nfo에서 docker 서비스, commands, caddy 설정 추출
# - docker.env에서 환경변수 읽기 및 부족시 입력
# - 선택 서비스 명령 실행 (commands 내 command 단위)
# - 선택형 서비스 인덱스 번호 입력 지원
# - 환경변수 치환 방식 ##KEY## 활용
# - NFO 내 _DOCKER_ 마커 치환하여 Caddyfile 생성

NFO_FILE="./docker.nfo"
ENV_FILE="./docker.env"

if [ ! -f "$NFO_FILE" ]; then
  echo "오류: $NFO_FILE 파일이 없습니다."
  exit 1
fi

# -- NFO 파일 HTML entity 리턴 (필요시)
NFO_LITERAL="/tmp/docker_nfo_literal"

sed 's/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g' "$NFO_FILE" > "$NFO_LITERAL"

# 환경변수 초기화 및 불러오기
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

# 환경변수 리스트 추출 및 입력
mapfile -t ENV_KEYS < <(grep -Po '##\K[^#]+(?=##)' "$NFO_LITERAL" | sort -u)

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

# docker 서비스명과 필수여부 파싱
DOCKER_NAMES=()
DOCKER_REQUIRED=()
while IFS= read -r line; do
  if [[ $line =~ \<docker[[:space:]]+name=\"([^\"]+)\"[[:space:]]+required=\"([^\"]+)\" ]]; then
    DOCKER_NAMES+=("${BASH_REMATCH[1]}")
    DOCKER_REQUIRED+=("${BASH_REMATCH[2]}")
  fi
done < "$NFO_LITERAL"

# 도커 서비스 표 출력 및 선택지 번호 부여 (필수 아닌 것만 번호)
echo
printf "========== Docker Services ==========\n"
printf "| %3s | %-15s | %-9s |\n" "No." "Name" "Required"
printf "|-----|-----------------|-----------|\n"
opt_seq=1
OPTIONAL_INDEX_MAP=()
for i in "${!DOCKER_NAMES[@]}"; do
  local name="${DOCKER_NAMES[i]}"
  local required="${DOCKER_REQUIRED[i]}"
  local no=""
  if [[ "$required" == "false" ]]; then
    no=$opt_seq
    OPTIONAL_INDEX_MAP+=("${i}:${no}:${name}")
    ((opt_seq++))
  fi
  printf "| %3s | %-15s | %-9s |\n" "$no" "$name" "$required"
done
printf "|-----|-----------------|-----------|\n"
echo

# 옵션 서비스 선택 안내
if (( ${#OPTIONAL_INDEX_MAP[@]} > 0 )); then
  for item in "${OPTIONAL_INDEX_MAP[@]}"; do
    idx=${item%%:*}
    rest=${item#*:}
    num=${rest%%:*}
    svc=${rest#*:}
  done
else
  echo "선택 가능한 서비스가 없습니다."
fi

read -rp "실행할 서비스 번호를 ','로 구분하여 입력하세요 (예: 1,3,5): " input_indices
IFS=',' read -r -a selected_indices <<< "$input_indices"

declare -A SELECTED_SERVICES
for idx in "${selected_indices[@]}"; do
  idx_trimmed=$(echo "$idx" | xargs)
  for entry in "${OPTIONAL_INDEX_MAP[@]}"; do
    entry_idx=${entry%%:*}
    rest=${entry#*:}
    num=${rest%%:*}
    svc=${rest#*:}
    if [[ $idx_trimmed == "$num" ]]; then
      SELECTED_SERVICES["$svc"]=1
    fi
  done
done

# 필수 서비스와 선택된 옵션 서비스 합침
REQUIRED_SERVICES=()
OPTIONAL_SERVICES=()
for i in "${!DOCKER_NAMES[@]}"; do
  name="${DOCKER_NAMES[i]}"
  required="${DOCKER_REQUIRED[i]}"
  if [[ "$required" == "true" ]]; then
    REQUIRED_SERVICES+=("$name")
  elif [[ -n "${SELECTED_SERVICES[$name]}" ]]; then
    OPTIONAL_SERVICES+=("$name")
  fi
done
ALL_SERVICES=("${REQUIRED_SERVICES[@]}" "${OPTIONAL_SERVICES[@]}")

echo
echo "실행 대상 서비스: ${ALL_SERVICES[*]}"

# compose 실행 함수 (commands 내 개별 command 실행)
run_compose() {
  local svc="$1"
  echo
  echo ">>> Setting up service: $svc"

  local commands_block
  commands_block=$(awk -v svc="$svc" '
    BEGIN {in_docker=0; in_commands=0;}
    /<docker[[:space:]]+name="'$svc'"/ {in_docker=1;}
    in_docker && /<commands>/ {in_commands=1; next;}
    in_commands && /<\/commands>/ {in_commands=0;}
    in_commands {print;}
  ' "$NFO_LITERAL")

  if [[ -z "$commands_block" ]]; then
    echo "명령어 블록을 찾지 못했습니다: $svc"
    return 1
  fi

  # 여러 command별 분리
  mapfile -t commands < <(awk '
    /<command>/,/<\/command>/ {
      if ($0 ~ /<command>/) {flag=1; next}
      if ($0 ~ /<\/command>/) {flag=0; print c; c=""; next}
      if (flag) c = (c ? c "\n" : "") $0
    }
  ' "$NFO_LITERAL")
  
  for cmd in "${commands[@]}"; do
    for key in "${!ENV_VALUES[@]}"; do
      cmd="${cmd//"##$key##"/${ENV_VALUES[$key]}}"
    done
    tmpfile=$(mktemp)
    printf "%s\n" "$cmd" > "$tmpfile"
    bash "$tmpfile"
    rm -f "$tmpfile"
  done
}

for svc in "${ALL_SERVICES[@]}"; do
  run_compose "$svc"
done

# caddy 구성 템플릿 추출
FINAL_BLOCK=$(awk '
  BEGIN {in_final=0;}
  /<final>/ {in_final=1; next;}
  /<\/final>/ {in_final=0;}
  in_final {print;}
' "$NFO_LITERAL")

# caddy 설정들 추출
extract_caddy_blocks() {
  local svc="$1"
  awk -v svc="$svc" '
    BEGIN {in_docker=0; in_caddys=0; in_caddy=0; block=""}
    /<docker[[:space:]]+name="'$svc'"/ {in_docker=1;}
    in_docker && /<caddys>/ {in_caddys=1; next;}
    in_caddys && /<\/caddys>/ {in_caddys=0;}
    in_caddys && /<caddy>/ {in_caddy=1; block=""; next;}
    in_caddy && /<\/caddy>/ {in_caddy=0; print block; next;}
    in_caddy {block=block $0 "\n";}
    in_docker && /<\/docker>/ && !in_caddys {in_docker=0;}
  ' "$NFO_LITERAL"
}

DOCKER_CADDY_CONFIGS=""
for svc in "${ALL_SERVICES[@]}"; do
  caddy_conf=$(extract_caddy_blocks "$svc")
  if [[ -n "$caddy_conf" ]]; then
    caddy_conf=${caddy_conf//"##DOMAIN##"/${ENV_VALUES[DOMAIN]}}
    DOCKER_CADDY_CONFIGS+=$'\n'"$caddy_conf"$'\n'
  fi
done

# 치환 (중간에 치환 용 마커 _DOCKER_)
escaped_caddy_conf=$(printf '%s' "$DOCKER_CADDY_CONFIGS" | sed 's/[\/&]/\\&/g')
FINAL_BLOCK=$(echo "$FINAL_BLOCK" | sed "s/_DOCKER_/$escaped_caddy_conf/")

# 나머지 변수 치환
for key in "${!ENV_VALUES[@]}"; do
  FINAL_BLOCK=$(echo "$FINAL_BLOCK" | sed "s/##$key##/${ENV_VALUES[$key]//\//\\/}/g")
done

mkdir -p ./docker/caddy/conf
echo "$FINAL_BLOCK" > ./docker/caddy/conf/Caddyfile

# 실제 caddy 새로고침 필요시 활성화
# docker exec -it caddy caddy reload || echo "caddy reload 실패"

echo "모든 작업 완료: 선택 서비스 실행 및 Caddyfile 갱신됨."
