#!/bin/bash

# 11:31
# 자동화 스크립트 (docker.sh 수정판)
# - docker.nfo 읽어서 docker 서비스 리스트 및 compose, caddy 설정 추출 및 실행
# - docker.env 읽어 환경변수 불러오고, 없으면 입력받음
# - [ ] 변수 치환 자동 처리
# - 선택 서비스 compose 실행 및 Caddyfile 생성
# - NFO내 <DOCKER> 대신 _DOCKER_ 마커로 변경 대응

NFO_FILE="./docker.nfo"
ENV_FILE="./docker.env"

if [ ! -f "$NFO_FILE" ]; then
  echo "오류: $NFO_FILE 파일이 없습니다."
  exit 1
fi

# 1. env 파일 읽기 또는 생성
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
mapfile -t ENV_KEYS < <(grep -oP '##\K[^#]+(?=##)' "$NFO_FILE" | sort -u)

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

# 2. nfo에서 docker name, required 추출 및 표 출력
DOCKER_NAMES=()
DOCKER_REQUIRED=()

printf "\n===== Docker Services =====\n"
printf "| %3s | %-15s | %-9s |\n" "No." "Name" "Required"
printf "|-----|-----------------|----------|\n"
OPTIONAL_INDEX_MAP=() # required=false 인덱스를 위한 배열

opt_seq=1
for i in "${!DOCKER_NAMES[@]}"; do
  name="${DOCKER_NAMES[i]}"
  req="${DOCKER_REQUIRED[i]}"
  printf "| %3s | %-15s | %-9s |\n" "$((i+1))" "$name" "$req"

  # required=false만 선택 인덱스 매핑
  if [[ "$req" == "false" ]]; then
    OPTIONAL_INDEX_MAP+=("${i}:${opt_seq}:${name}")
    opt_seq=$((opt_seq + 1))
  fi
done
printf "\n"

# 표 출력 후 required=false 서비스에 순번 매핑해서 별도 보여줌
echo "선택 가능한 선택형(옵션) 서비스 목록:"
for v in "${OPTIONAL_INDEX_MAP[@]}"; do
  idx="${v%%:*}"
  tmp="${v#*:}"
  num="${tmp%%:*}"
  svc="${tmp#*:}"
  echo "  $num) $svc"
done

echo
echo "실행할 선택형 서비스의 순번을 쉼표(,)로 골라주세요 (예: 2,5) :"
read -rp "선택: " selected_optional

IFS=',' read -r -a selected_arr <<< "$selected_optional"
declare -A OPTIONAL_SELECTIONS
for sel in "${selected_arr[@]}"; do
  sel=$(echo "$sel" | xargs)
  for v in "${OPTIONAL_INDEX_MAP[@]}"; do
    idx="${v%%:*}"
    tmp="${v#*:}"
    num="${tmp%%:*}"
    svc="${tmp#*:}"

    if [[ "$sel" == "$num" ]]; then
      OPTIONAL_SELECTIONS["$svc"]=true
    fi
  done
done

REQUIRED_SERVICES=()
OPTIONAL_SERVICES=()

for i in "${!DOCKER_NAMES[@]}"; do
  name="${DOCKER_NAMES[i]}"
  req="${DOCKER_REQUIRED[i]}"
  if [[ "$req" == "true" ]]; then
    REQUIRED_SERVICES+=("$name")
  elif [[ ${OPTIONAL_SELECTIONS[$name]} == "true" ]]; then
    OPTIONAL_SERVICES+=("$name")
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

  # ##키## 치환
  for key in "${!ENV_VALUES[@]}"; do
    compose_block=$(echo "$compose_block" | sed "s/##${key}##/${ENV_VALUES[$key]//\//\\/}/g")
  done


  bash -c "$compose_block"
}

for svc in "${ALL_SERVICES[@]}"; do
  run_compose_for_service "$svc"
done

# 4. 선택 서비스의 <caddys> 내 <caddy> 반복 추출 및 Caddyfile 반영
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

# 변경: _DOCKER_ 마커 치환 처리
FINAL_BLOCK=$(echo "$FINAL_BLOCK" | sed "/_DOCKER_/{
  s|_DOCKER_|$(echo "$DOCKER_CADDY_CONFIGS" | sed 's/[\/&]/\\&/g')|
}")

for key in "${!ENV_VALUES[@]}"; do
  FINAL_BLOCK=$(echo "$FINAL_BLOCK" | sed "s/##${key}##/${ENV_VALUES[$key]//\//\\/}/g")
done

mkdir -p /docker/caddy/conf
echo "$FINAL_BLOCK" > /docker/caddy/conf/Caddyfile

# caddy reload (실제 환경에 맞게 활성화)
#docker exec -it caddy caddy reload || echo "경고: Caddy 재시작 실패"

echo "자동화 완료! 모든 서비스 실행 및 Caddyfile 갱신됨."
