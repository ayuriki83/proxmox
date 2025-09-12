#!/bin/bash

##################################################
# Proxmox Ubuntu 설치 자동화
##################################################

set -e

# 색상 정의 (로그 가독성 향상)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로깅 함수
log() { echo -e "${GREEN}[$(date '+%F %T')]${NC} $*" }
error() { echo -e "${RED}[$(date '+%F %T')][ERROR]${NC} $*" >&2 }
warn() { echo -e "${YELLOW}[$(date '+%F %T')][WARN]${NC} $*" }
debug() { echo -e "${BLUE}[$(date '+%F %T')][DEBUG]${NC} $*" }

# 설정 파일 위치 지정 (스크립트와 같은 디렉토리 등)
ENV_FILE="./lxc.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    info "설정 파일 $ENV_FILE 이(가) 없습니다. 기본값 사용."
fi

MAIN=${MAIN:-main}
VG_NAME="vg-$MAIN"
LV_NAME="lv-$MAIN"
LVM_NAME="lvm-$MAIN"
CT_ID=${CT_ID:-101}
HOSTNAME=${HOSTNAME:-Ubuntu}
STORAGE=${LVM_NAME:-lvm-main}
ROOTFS=${ROOTFS:-128}
MEMORY_GB=${MEMORY_GB:-18}
MEMORY=$((MEMORY_GB * 1024))
CORES=${CORES:-6}
CPU_LIMIT=${CPU_LIMIT:-6}
UNPRIVILEGED=${UNPRIVILEGED:-0}
RCLONE_GB=${RCLONE_GB:-256}
RCLONE_SIZE="${RCLONE_GB}G"
LV_RCLONE=${LV_RCLONE:-lv-rclone}
MOUNT_POINT=${MOUNT_POINT:-/mnt/rclone}

step() { log "==> STEP $1: $2"; }
error_exit() { err "$1"; exit 1; }

step 1 "Ubuntu 템플릿 준비"
LATEST_TEMPLATE=$(pveam available --section system | awk '/ubuntu-22.04-standard/ {print $2}' | sort -V | tail -1)
TEMPLATE="local:vztmpl/${LATEST_TEMPLATE}"
TEMPLATE_FILE="/var/lib/vz/template/cache/${LATEST_TEMPLATE}"
if [ ! -f "$TEMPLATE_FILE" ]; then
  pveam update > /dev/null 2>&1 || error_exit "pveam update 실패"
  pveam download local "$LATEST_TEMPLATE" > /dev/null 2>&1 || error_exit "템플릿 다운로드 실패"
fi

read -rp "컨테이너에 할당할 IP 주소를 입력하세요 (예: 192.168.0.235): " USER_IP
IP="${USER_IP}/24"
GATEWAY=$(ip route | awk '/default/ {print $3}')
INTERNAL_NET=$(ip route | awk '/default/ {print $3}' | awk -F. '{print $1"."$2"."$3".0/24"}')

step 2 "LXC 컨테이너 생성"
pct create $CT_ID $TEMPLATE \
  --hostname $HOSTNAME \
  --storage $STORAGE \
  --rootfs $ROOTFS \
  --memory $MEMORY \
  --cores $CORES \
  --cpulimit $CPU_LIMIT \
  --net0 name=eth0,bridge=vmbr0,ip=$IP,gw=$GATEWAY \
  --features nesting=1,keyctl=1 \
  --unprivileged $UNPRIVILEGED \
  --description "Docker LXC ${ROOTFS}GB rootfs with Docker" \
  > /dev/null 2>&1 || error_exit "컨테이너 생성 실패"

step 3 "RCLONE LV생성(ext4) 및 LXC 설정 적용"
lv_path="/dev/${VG_NAME}/${LV_RCLONE}"
if ! lvs "$lv_path" > /dev/null 2>&1; then
  lvcreate -V "$RCLONE_SIZE" -T "${VG_NAME}/${LV_NAME}" -n "$LV_RCLONE" || error_exit "LV 생성 실패"
  mkfs.ext4 "$lv_path" || error_exit "ext4 생성 실패"
fi
LXC_CONF="/etc/pve/lxc/${CT_ID}.conf"
cat >> "$LXC_CONF" <<EOF
mp0: $lv_path,mp=$MOUNT_POINT
lxc.cgroup2.devices.allow: c 10:229 rwm
lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
EOF

step 4 "LXC GPU 설정 적용"
info "GPU 종류를 선택하세요: 1) AMD(내장/외장)   2) Intel(내장/외장)   3) NVIDIA"
read -p "선택 (1/2/3): " GPU_CHOICE
case "$GPU_CHOICE" in
  1|2)
    cat >> "$LXC_CONF" <<EOF
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
    ;;
  3)
    cat >> "$LXC_CONF" <<EOF
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
EOF
    ;;
  *)
    ;;
esac

step 5 "LXC 컨테이너 시작"
pct start $CT_ID > /dev/null 2>&1 || error_exit "컨테이너 시작 실패"
sleep 5


pct exec $CT_ID -- mkdir -p /tmp/scripts
pct push $CT_ID lxc_init.sh /tmp/scripts/lxc_init.sh
pct push $CT_ID lxc.env /tmp/scripts/lxc.env
pct push $CT_ID docker.nfo /tmp/scripts/docker.nfo
pct push $CT_ID docker.sh /tmp/scripts/docker.sh
pct push $CT_ID caddy_setup.sh /tmp/scripts/caddy_setup.sh
pct exec $CT_ID -- bash /tmp/scripts/lxc_init.sh


log "==> 전체 LXC 자동화 완료!"
