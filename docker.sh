#!/bin/bash

# 11:06
# 자동화 스크립트 (docker.sh 재작성)
# - docker.nfo 읽어서 docker 서비스 리스트와 compose, caddy 설정 추출 및 실행
# - docker.env 읽어서 환경변수 할당, 없으면 입력받아 저장
# - [ ] 변수 치환 자동 처리
# - 선택 도커 서비스 실행 및 Caddyfile에 서비스별 리버스프록시 설정 반영

log() { echo "[$(date '+%T')] $*"; }
info() { echo "[$(date '+%T')][INFO] $*"; }
err() { echo "[$(date '+%T')][ERROR]" "$@" >&2 }

NFO_FILE="./docker.nfo"
CONFIG_FILE="./docker.env"

if [ ! -f "$NFO_FILE" ]; then
  echo "오류: $NFO_FILE 파일이 없습니다."
  exit 1
fi

# 설정 파일 위치 지정 (스크립트와 같은 디렉토리 등)
CONFIG_FILE="./proxmox.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    info "설정 파일 $CONFIG_FILE 이(가) 없습니다. 기본값 사용."
fi


# 1. env 파일 읽기 또는 없을 경우 생성
declare -A ENV_VALUES

if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r key val; do
    key=$(echo "$key" | tr -d ' ')
    val=$(echo "$val" | sed 's/^"//;s/"$//')
    ENV_VALUES[$key]=$val
  done < "$ENV_FILE"
else
  touch "$ENV_FILE"
fi

# env 변수 리스트 nfo에서 [] 변수 자동추출 후 로드 또는 사용자 입력
mapfile -t ENV_KEYS < <(grep -oP '\[\K[^\]]+' "$NFO_FILE" | sort -u)

load_or_prompt_env() {
  local key="$1"
  if [ -z "${ENV_VALUES[$key]}" ]; then
    read -rp "환경 변수 '$key' 값을 입력하세요: " val
    ENV_VALUES[$key]=$val
    echo "$key=\"$val\"" >> "$ENV_FILE"
  fi
}

for key in "${ENV_KEYS[@]}"; do
  load_or_prompt_env "$key"
done

# 2. nfo에서 docker name, required 추출
DOCKER_NAMES=()
DOCKER_REQUIRED=()

while IFS= read -r line; do
  if [[ $line =~ \<docker[[:space:]]+name=\"([^\"]+)\"[[:space:]]+required=\"(true|false)\" ]]; then
    DOCKER_NAMES+=("${BASH_REMATCH[1]}")
    DOCKER_REQUIRED+=("${BASH_REMATCH[2]}")
  fi
done < "$NFO_FILE"

echo "===== Docker Services ====="
for i in "${!DOCKER_NAMES[@]}"; do
  echo " - ${DOCKER_NAMES[i]} (required: ${DOCKER_REQUIRED[i]})"
done

echo
echo "선택적으로 설치할 서비스 이름을 쉼표(,)로 구분해 입력하세요 (Enter 시 선택 안함):"
read -rp "선택: " selected_optional

IFS=',' read -r -a selected_arr <<< "$selected_optional"

declare -A OPTIONAL_SELECTIONS
for sel in "${selected_arr[@]}"; do
  sel=$(echo "$sel" | xargs)
  found=false
  for i in "${!DOCKER_NAMES[@]}"; do
    if [[ "$sel" == "${DOCKER_NAMES[i]}" && "${DOCKER_REQUIRED[i]}" == "false" ]]; then
      OPTIONAL_SELECTIONS["$sel"]=true
      found=true
      break
    fi
  done
  if ! $found; then
    echo "주의: '$sel' 는 required=false 서비스가 아니거나 존재하지 않습니다."
  fi
done

REQUIRED_SERVICES=()
OPTIONAL_SERVICES=()

for i in "${!DOCKER_NAMES[@]}"; do
  if [[ "${DOCKER_REQUIRED[i]}" == "true" ]]; then
    REQUIRED_SERVICES+=("${DOCKER_NAMES[i]}")
  elif [[ ${OPTIONAL_SELECTIONS[${DOCKER_NAMES[i]}]} == "true" ]]; then
    OPTIONAL_SERVICES+=("${DOCKER_NAMES[i]}")
  fi
done

ALL_SERVICES=("${REQUIRED_SERVICES[@]}" "${OPTIONAL_SERVICES[@]}")

echo
echo "실행 대상 서비스: ${ALL_SERVICES[*]}"

# 3. compose 실행 함수
run_compose_for_service() {
  local svc="$1"
  echo
  echo ">>> Setting up service: $svc"

  local compose_block
  compose_block=$(awk -v svc="$svc" '
    BEGIN {in_docker=0; in_compose=0;}
    /<docker name="'"$svc"'"/ {in_docker=1;}
    in_docker && /<compose>/ {in_compose=1; next;}
    in_compose && /<\/compose>/ {in_compose=0; exit;}
    in_compose {print;}
  ' "$NFO_FILE")

  if [ -z "$compose_block" ]; then
    echo "오류: $svc 서비스의 compose 블록을 찾을 수 없습니다."
    return 1
  fi

  # [키] 치환
  for key in "${!ENV_VALUES[@]}"; do
    compose_block=$(echo "$compose_block" | sed "s/\[$key\]/${ENV_VALUES[$key]//\//\\/}/g")
  done

  bash -c "$compose_block"
}

for svc in "${ALL_SERVICES[@]}"; do
  run_compose_for_service "$svc"
done

# 4. 선택 도커 서비스의 <caddys> 내 <caddy> 반복 추출 및 Caddyfile 반영

FINAL_BLOCK=$(awk '
  BEGIN {in_final=0;}
  /<final>/ {in_final=1; next;}
  /<\/final>/ {in_final=0;}
  in_final {print;}
' "$NFO_FILE")

extract_caddy_blocks() {
  local svc="$1"
  awk -v svc="$svc" '
    BEGIN {in_docker=0; in_caddys=0; in_caddy=0; block=""}
    /<docker name="'"$svc"'"/ {in_docker=1;}
    in_docker && /<caddys>/ {in_caddys=1; next;}
    in_caddys && /<\/caddys>/ {in_caddys=0;}
    in_caddys && /<caddy>/ {in_caddy=1; block=""; next;}
    in_caddy && /<\/caddy>/ {in_caddy=0; print block; next;}
    in_caddy {block=block $0 "\n";}
    in_docker && /<\/docker>/ && !in_caddys {in_docker=0;}
  ' "$NFO_FILE"
}

DOCKER_CADDY_CONFIGS=""

for svc in "${ALL_SERVICES[@]}"; do
  caddy_blocks=$(extract_caddy_blocks "$svc")
  if [ -n "$caddy_blocks" ]; then
    caddy_blocks=$(echo "$caddy_blocks" | sed "s/\[domain\]/${ENV_VALUES[domain]}/g")
    DOCKER_CADDY_CONFIGS+=$'\n'"$caddy_blocks"$'\n'
  fi
done

# 변경: [DOCKER SERVICE] -> <DOCKER> 로 치환 대상 변경
FINAL_BLOCK=$(echo "$FINAL_BLOCK" | sed "/<DOCKER>/{
  s|<DOCKER>|$(echo "$DOCKER_CADDY_CONFIGS" | sed 's/[\/&]/\\&/g')|
}")

# 나머지 [] 변수 치환
for key in "${!ENV_VALUES[@]}"; do
  FINAL_BLOCK=$(echo "$FINAL_BLOCK" | sed "s/\[$key\]/${ENV_VALUES[$key]//\//\\/}/g")
done

mkdir -p /docker/caddy/conf
echo "$FINAL_BLOCK" > /docker/caddy/conf/Caddyfile

# 5. caddy reload (에러시 메시지만 출력)
#docker exec -it caddy caddy reload || echo "경고: Caddy 재시작 실패"

echo "자동화 완료! 모든 서비스 실행 및 Caddyfile 갱신됨."
