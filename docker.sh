#!/bin/bash

# 자동화 스크립트: 외부 nfo 파일에서 Docker, Caddy 설정 읽기 및 환경변수 적용해서 도커 컴포즈 실행 + Caddyfile 생성

NFO_FILE="./docker.nfo"
ENV_FILE="./.env"

if [ ! -f "$NFO_FILE" ]; then
  echo "오류: $NFO_FILE 파일을 찾을 수 없습니다."
  exit 1
fi

# 1. nfo파일에서 [] 변수명 자동 수집 및 환경변수 로드/입력
mapfile -t ENV_KEYS < <(grep -oP '\[\K[^\]]+' "$NFO_FILE" | sort -u)
declare -A ENV_VALUES

load_or_prompt_env() {
  local key="$1"
  local value=""
  if [ -f "$ENV_FILE" ]; then
    value=$(grep -E "^${key}=" "$ENV_FILE" | cut -d '=' -f2-)
  fi
  if [ -z "$value" ]; then
    read -rp "환경 변수 '$key' 값을 입력하세요: " value
    grep -v "^${key}=" "$ENV_FILE" 2>/dev/null > "${ENV_FILE}.tmp" || true
    echo "${key}=${value}" >> "${ENV_FILE}.tmp"
    mv "${ENV_FILE}.tmp" "$ENV_FILE"
  fi
  echo "$value"
}

for key in "${ENV_KEYS[@]}"; do
  ENV_VALUES[$key]=$(load_or_prompt_env "$key")
done

# 2. nfo에서 <docker> 태그 name, required 리스트 추출
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

# compose 실행 함수
run_compose_for_service() {
  local svc="$1"
  echo
  echo ">>> Setting up service: $svc"

  # <docker name="$svc" ...> ~ </compose> 영역 추출
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

  # [] 변수 치환
  for key in "${!ENV_VALUES[@]}"; do
    compose_block=$(echo "$compose_block" | sed "s/\[$key\]/${ENV_VALUES[$key]//\//\\/}/g")
  done

  # 쉘 명령 실행
  bash -c "$compose_block"
}

for svc in "${ALL_SERVICES[@]}"; do
  run_compose_for_service "$svc"
done

# 3. 선택한 서비스의 <caddys> 내 <caddy> 태그 반복추출 및 Caddyfile에 반영

# 3-1. 전체 final 태그에서 내용 추출
FINAL_BLOCK=$(awk '
  BEGIN {in_final=0;}
  /<final>/ {in_final=1; next;}
  /<\/final>/ {in_final=0;}
  in_final {print;}
' "$NFO_FILE")

# 3-2. 선택 서비스별 <caddys> ... </caddys> 반복 내 <caddy> ... </caddy> 추출 함수
extract_caddy_blocks() {
  local svc="$1"
  awk -v svc="$svc" '
    BEGIN {in_docker=0; in_caddys=0; in_caddy=0; block=""}
    # docker명에 맞는 docker 시작 확인
    /<docker name="'"$svc"'"/ {in_docker=1;}
    in_docker && /<caddys>/ {in_caddys=1; next;}
    in_caddys && /<\/caddys>/ {in_caddys=0;}
    in_caddys && /<caddy>/ {
      in_caddy=1;
      block=""
      next
    }
    in_caddy && /<\/caddy>/ {
      in_caddy=0;
      print block
      next
    }
    in_caddy {
      block = block $0 "\n"
    }
    in_docker && /<\/docker>/ && !in_caddys {in_docker=0}
  ' "$NFO_FILE"
}

# 3-3. Caddyfile 내 [DOCKER SERVICE] 부분에 삽입할 문자열 생성
DOCKER_CADDY_CONFIGS=""

for svc in "${ALL_SERVICES[@]}"; do
  caddy_blocks=$(extract_caddy_blocks "$svc")

  if [ -n "$caddy_blocks" ]; then
    # [domain] 치환
    caddy_blocks=$(echo "$caddy_blocks" | sed "s/\[domain\]/${ENV_VALUES[domain]}/g")
    DOCKER_CADDY_CONFIGS+=$'\n'"$caddy_blocks"$'\n'
  fi
done

# 3-4. final 블록 내 [DOCKER SERVICE] 치환
FINAL_BLOCK=$(echo "$FINAL_BLOCK" | sed "/\[DOCKER SERVICE\]/{
  s/\[DOCKER SERVICE\]/$(echo "$DOCKER_CADDY_CONFIGS" | sed 's/[\/&]/\\&/g')
}")

# 3-5. 나머지 [] 변수 치환
for key in "${!ENV_VALUES[@]}"; do
  FINAL_BLOCK=$(echo "$FINAL_BLOCK" | sed "s/\[$key\]/${ENV_VALUES[$key]//\//\\/}/g")
done

# 3-6. Caddyfile 쓰기
mkdir -p /docker/caddy/conf
echo "$FINAL_BLOCK" > /docker/caddy/conf/Caddyfile

# 4. caddy reload 시도 (실패해도 무시)
#docker exec -it caddy caddy reload || echo "경고: Caddy 재시작 실패"

echo ">>> 자동화 완료! Caddyfile이 생성되었고, 서비스가 실행 중입니다."
