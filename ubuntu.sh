#!/bin/bash

##########################
# Proxmox Ubuntu + Rclone마운트 생성 자동화
##########################

set -e

# 설정 파일 위치 지정 (스크립트와 같은 디렉토리 등)
CONFIG_FILE="./proxmox.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "설정 파일 $CONFIG_FILE 이(가) 없습니다. 기본값 사용."
fi

# 환경변수 기본값 지정 (설정파일에 없을 경우 대비)
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

# 최신 Ubuntu 22.04 템플릿명 자동 파악 및 다운로드
LATEST_TEMPLATE=$(pveam available --section system | awk '/ubuntu-22.04-standard/ {print $2}' | sort -V | tail -1)
TEMPLATE="local:vztmpl/${LATEST_TEMPLATE}"
TEMPLATE_FILE="/var/lib/vz/template/cache/${LATEST_TEMPLATE}"

if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "Ubuntu 22.04 최신 템플릿 다운로드 중..."
    pveam update
    pveam download local "$LATEST_TEMPLATE"
else
    echo "템플릿이 이미 존재합니다: $TEMPLATE_FILE"
fi

read -rp "컨테이너에 할당할 IP 주소를 입력하세요 (예: 192.168.0.235): " USER_IP
IP="${USER_IP}/24"
GATEWAY=$(ip route | awk '/default/ {print $3}')

# CT생성하는 CLI명령어
# hostname은 띄워쓰기/언더바 안됨
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
    --description "Docker LXC ${ROOTFS}GB rootfs with Docker"

# rclone 마운트 설정
RCLONE_GB=${RCLONE_GB:-256}
RCLONE_SIZE="${RCLONE_GB}G"
LV_RCLONE=${LV_RCLONE:-lv-rclone}
MOUNT_POINT=${MOUNT_POINT:-/mnt/rclone}

# LV 생성 및 파일시스템 생성

echo "LV 생성(${RCLONE_SIZE})..."
lvcreate -V $RCLONE_SIZE -T ${VG_NAME}/${LV_NAME} -n $LV_RCLONE

echo "파일시스템(ext4) 생성..."
lv_path="/dev/${VG_NAME}/${LV_RCLONE}"
mkfs.ext4 $lv_path

# lxc conf 파일 경로
LXC_CONF="/etc/pve/lxc/${CT_ID}.conf"

echo "LXC conf에 마운트, fuse 권한 추가..."
cat >> $LXC_CONF << EOF
mp0: $lv_path,mp=$MOUNT_POINT
lxc.cgroup2.devices.allow: c 10:229 rwm
lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file
EOF

echo "AppArmor, cgroup, cap 권한 확장 설정 추가..."
cat >> $LXC_CONF << EOF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
EOF
