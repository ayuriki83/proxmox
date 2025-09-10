#!/bin/bash

##################################################
# Proxmox Ubuntu 설치 자동화
##################################################

set -e

# alias 추가 및 중복 제거
for LINE in \
  "alias ls='ls --color=auto --show-control-chars'" \
  "alias ll='ls -al --color=auto --show-control-chars'"
do
  grep -q "${LINE}" /root/.bashrc || echo "${LINE}" >> /root/.bashrc
done
source /root/.bashrc

log() { echo "[$(date '+%T')] $*"; }
info() { echo "[INFO][$(date '+%T')] $*"; }
err() { echo "[ERROR][$(date '+%T')] $*"; }


# 설정 파일 위치 지정 (스크립트와 같은 디렉토리 등)
CONFIG_FILE="./proxmox.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    info "설정 파일 $CONFIG_FILE 이(가) 없습니다. 기본값 사용."
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
LOCALE_LANG=${LOCALE_LANG:-ko_KR.UTF-8}
TIMEZONE=${TIMEZONE:-Asia/Seoul}
DOCKER_DATA_ROOT=${DOCKER_DATA_ROOT:-/docker/core}
DOCKER_DNS1=${DOCKER_DNS1:-8.8.8.8}
DOCKER_DNS2=${DOCKER_DNS2:-1.1.1.1}
DOCKER_BRIDGE_NET=${DOCKER_BRIDGE_NET:-172.18.0.0/16}
DOCKER_BRIDGE_GW=${DOCKER_BRIDGE_GW:-172.18.0.1}
DOCKER_BRIDGE_NM=${DOCKER_BRIDGE_NM:-ProxyNet}
BASIC_APT=${BASIC_APT:-"curl wget htop tree neofetch git vim net-tools nfs-common"}
ALLOW_PORTS=${ALLOW_PORTS:-"80/tcp 443/tcp 443/udp 45876 5574 9999 32400"}

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

step 6 "LXC 컨테이너 시스템/패키지 업데이트 및 필수 구성요소 설치"
SCRIPT_STEP_6="
set -e
apt-get update -qq > /dev/null 2>&1 && apt-get upgrade -y > /dev/null 2>&1
apt-get install $BASIC_APT dnsutils -y > /dev/null 2>&1
"
pct exec $CT_ID -- bash -c "$SCRIPT_STEP_6"

step 7 "LXC 컨테이너 AppArmor비활성화/한글폰트 및 로케일/시간설정"
SCRIPT_STEP_7="
set -e
(
  systemctl stop apparmor || true
  systemctl disable apparmor || true
  apt-get remove apparmor man-db -y || true
) &> /dev/null
apt-get install language-pack-ko fonts-nanum locales -y > /dev/null 2>&1
locale-gen $LOCALE_LANG > /dev/null 2>&1
update-locale LANG=$LOCALE_LANG > /dev/null 2>&1
echo -e 'export LANG=$LOCALE_LANG\nexport LANGUAGE=$LOCALE_LANG\nexport LC_ALL=$LOCALE_LANG' >> /root/.bashrc
echo -e 'export LANG=$LOCALE_LANG\nexport LANGUAGE=$LOCALE_LANG\nexport LC_ALL=$LOCALE_LANG' >> /root/.bashrc
for LINE in \
  \"alias ls='ls --color=auto --show-control-chars'\" \
  \"alias ll='ls -al --color=auto --show-control-chars'\" \
  \"log() { echo \\\"[\\\$(date '+%T')] \\\$*\\\"; }\" \
  \"info() { echo \\\"[INFO][\\\$(date '+%T')] \\\$*\\\"; }\" \
  \"err() { echo \\\"[ERROR][\\\$(date '+%T')] \\\$*\\\"; }\"
do
  grep -q \"\${LINE}\" /root/.bashrc || echo \"\${LINE}\" >> /root/.bashrc
done
source /root/.bashrc
timedatectl set-timezone $TIMEZONE > /dev/null 2>&1
"
pct exec $CT_ID -- bash -c "$SCRIPT_STEP_7"

step 8 "LXC 컨테이너 GPU 설정 및 드라이버"
SCRIPT_STEP_8="
set -e
case \"$GPU_CHOICE\" in
  1)
    apt-get install vainfo -y > /dev/null 2>&1 ; vainfo > /dev/null 2>&1 || info '[CT] vainfo 동작 경고'
    ;;
  2)
    apt-get install vainfo intel-media-va-driver-non-free intel-gpu-tools -y > /dev/null 2>&1 ; vainfo > /dev/null 2>&1
    ;;
  3)
    apt-get install nvidia-driver nvidia-utils-525 -y > /dev/null 2>&1 ; nvidia-smi > /dev/null 2>&1 || info '[CT] nvidia-smi 실행 경고'
    ;;
  *)
    ;;
esac
"
pct exec $CT_ID -- bash -c "$SCRIPT_STEP_8"

step 9 "LXC 컨테이너 Docker 및 Daemon 세팅, 브릿지 네트워크 생성"
SCRIPT_STEP_9="
set -e
apt-get install docker.io docker-compose-v2 -y > /dev/null 2>&1
systemctl enable docker
systemctl start docker
mkdir -p $(dirname "$DOCKER_DATA_ROOT") /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  \"data-root\": \"$DOCKER_DATA_ROOT\",
  \"log-driver\": \"json-file\",
  \"log-opts\": { \"max-size\": \"10m\", \"max-file\": \"3\" },
  \"storage-driver\": \"overlay2\",
  \"default-shm-size\": \"1g\",
  \"default-ulimits\": {\"nofile\":{\"name\":\"nofile\",\"hard\":65536,\"soft\":65536}},
  \"dns\": [\"$DOCKER_DNS1\", \"$DOCKER_DNS2\"]
}
EOF
systemctl restart docker
docker network create --subnet=$DOCKER_BRIDGE_NET --gateway=$DOCKER_BRIDGE_GW $DOCKER_BRIDGE_NM > /dev/null 2>&1 || true
"
pct exec $CT_ID -- bash -c "$SCRIPT_STEP_9"

step 10 "LXC 컨테이너 방화벽(UFW) 설정"
SCRIPT_STEP_10="
set -e
apt-get install ufw -y > /dev/null 2>&1
for PORT in $ALLOW_PORTS; do ufw allow \$PORT > /dev/null 2>&1; done
ufw allow from $INTERNAL_NET > /dev/null 2>&1
ufw allow from $DOCKER_BRIDGE_NET > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1
dig @8.8.8.8 google.com +short | grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}' || err '[CT] DNS 쿼리 실패'
"
pct exec $CT_ID -- bash -c "$SCRIPT_STEP_10"

step 11 "LXC 컨테이너 NAT/UFW rule적용 (DOCKER)"
SCRIPT_STEP_11="
set -e
NAT_IFACE=\$(ip route | awk '/default/ {print \$5; exit}')
if ! iptables -t nat -C POSTROUTING -s $DOCKER_BRIDGE_NET -o \$NAT_IFACE -j MASQUERADE 2>/dev/null
then
  iptables -t nat -A POSTROUTING -s $DOCKER_BRIDGE_NET -o \$NAT_IFACE -j MASQUERADE
fi

UFW_AFTER_RULES=\"/etc/ufw/after.rules\"
if ! grep -q \"^:DOCKER-USER\" \$UFW_AFTER_RULES
then
  cp \$UFW_AFTER_RULES \${UFW_AFTER_RULES}.bak
  sed -i '/^COMMIT/i :DOCKER-USER - [0:0]\n-A DOCKER-USER -j RETURN' \$UFW_AFTER_RULES
  ufw reload > /dev/null 2>&1
fi
"
pct exec $CT_ID -- bash -c "$SCRIPT_STEP_11"

log "==> 전체 LXC 자동화 완료!"
