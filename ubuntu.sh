#!/bin/bash
set -e

# --- [환경변수] ---
CONFIG_FILE="./proxmox.conf"
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
else
  echo "설정 파일 $CONFIG_FILE 이(가) 없습니다. 기본값 사용."
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
BASIC_APT=${BASIC_APT:-"curl wget htop tree neofetch git vim net-tools nfs-common"}
ALLOW_PORTS=${ALLOW_PORTS:-"80/tcp 443/tcp 443/udp 45876 5574 9999 32400"}
INTERNAL_NET=${INTERNAL_NET:-"192.168.0.0/24"}

error_exit() { echo "[오류] $1"; exit 1; }
step() { echo "==> STEP $1: $2"; }

# --- [STEP1. Ubuntu 템플릿 준비] ---
step 1 "Ubuntu 템플릿 준비"
LATEST_TEMPLATE=$(pveam available --section system | awk '/ubuntu-22.04-standard/ {print $2}' | sort -V | tail -1)
TEMPLATE="local:vztmpl/${LATEST_TEMPLATE}"
TEMPLATE_FILE="/var/lib/vz/template/cache/${LATEST_TEMPLATE}"
if [ ! -f "$TEMPLATE_FILE" ]; then
  pveam update > /dev/null 2>&1 || error_exit "pveam update 실패"
  pveam download local "$LATEST_TEMPLATE" > /dev/null 2>&1 || error_exit "템플릿 다운로드 실패"
fi

# --- [STEP2. 네트워크 입력] ---
read -rp "컨테이너에 할당할 IP 주소를 입력하세요 (예: 192.168.0.235): " USER_IP
IP="${USER_IP}/24"
GATEWAY=$(ip route | awk '/default/ {print $3}')

# --- [STEP3. LXC 컨테이너 생성] ---
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

# --- [STEP4. LVC 생성 및 conf 설정] ---
step 3 "RCLONE LV생성(ext4) 및 LXC Conf 설정 적용"
lv_path="/dev/${VG_NAME}/${LV_RCLONE}"
if ! lvs $lv_path > /dev/null 2>&1; then
  lvcreate -V $RCLONE_SIZE -T ${VG_NAME}/${LV_NAME} -n $LV_RCLONE || error_exit "LV 생성 실패"
  mkfs.ext4 $lv_path || error_exit "ext4 생성 실패"
fi
LXC_CONF="/etc/pve/lxc/${CT_ID}.conf"
cat >> $LXC_CONF <<EOF
mp0: $lv_path,mp=$MOUNT_POINT
lxc.cgroup2.devices.allow: c 10:229 rwm
lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
EOF

# --- [STEP5. GPU 선택 및 conf 적용] ---
step 4 "LXC Conf GPU 설정 적용"
echo "GPU 종류를 선택하세요:"
echo "  1) AMD(내장/외장)  2) Intel(내장/외장)  3) NVIDIA"
read -p "선택 (1/2/3): " GPU_CHOICE
case "$GPU_CHOICE" in
  1|2)
    cat >> $LXC_CONF <<EOF
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
    ;;
  3)
    cat >> $LXC_CONF <<EOF
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
EOF
    ;;
  *)
    ;;
esac

# --- [STEP6. 컨테이너 시작] ---
step 5 "LXC 컨테이너 시작"
pct start $CT_ID || error_exit "컨테이너 시작 실패"
sleep 2

# --- [STEP7. 컨테이너 내부 기본세팅] ---
step 6 "LXC 컨테이너 내부 환경구성 및 소프트웨어 설치"
pct exec $CT_ID -- bash -c "
set -e
echo '[CT] STEP 1: 시스템/패키지 업데이트'; apt-get update -qq > /dev/null 2>&1 && apt-get upgrade -y > /dev/null 2>&1
echo '[CT] STEP 2: 필수 패키지 설치'; apt-get install $BASIC_APT dnsutils -y > /dev/null 2>&1
echo '[CT] STEP 3: AppArmor/한글/로케일/폰트'; 
systemctl stop apparmor || true; systemctl disable apparmor || true
apt-get remove apparmor man-db -y > /dev/null 2>&1
apt-get install language-pack-ko fonts-nanum locales -y > /dev/null 2>&1
locale-gen $LOCALE_LANG > /dev/null 2>&1
update-locale LANG=$LOCALE_LANG > /dev/null 2>&1
echo -e 'export LANG=$LOCALE_LANG\nexport LANGUAGE=$LOCALE_LANG\nexport LC_ALL=$LOCALE_LANG' >> /root/.bashrc
timedatectl set-timezone $TIMEZONE > /dev/null 2>&1
"

# --- [STEP8. 컨테이너 내부 Docker, 네트워크, 방화벽 등] ---
step 7 "Docker 설치 및 브릿지 네트워크 등록"
pct exec $CT_ID -- bash -c "
set -e
echo '[CT] STEP 4: GPU 설정 및 드라이버'
case \"$GPU_CHOICE\" in
  1)
    apt-get install vainfo -y > /dev/null 2>&1 ; vainfo > /dev/null 2>&1 || echo '[CT] vainfo 동작 경고'
    ;;
  2)
    apt-get install vainfo intel-media-va-driver-non-free intel-gpu-tools -y > /dev/null 2>&1 ; vainfo > /dev/null 2>&1
    ;;
  3)
    apt-get install nvidia-driver nvidia-utils-525 -y > /dev/null 2>&1 ; nvidia-smi > /dev/null 2>&1 || echo '[CT] nvidia-smi 실행 경고'
    ;;
  *)
    ;;
esac

echo '[CT] STEP 5: Docker 및 Daemon 세팅'
apt-get install docker.io docker-compose-v2 -y > /dev/null 2>&1
systemctl enable docker
systemctl start docker
mkdir -p $(dirname $DOCKER_DATA_ROOT) /etc/docker
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

echo '[CT] STEP 6: Docker 네트워크/방화벽'
docker network create --subnet=$DOCKER_BRIDGE_NET --gateway=$DOCKER_BRIDGE_GW ProxyNet > /dev/null 2>&1 || true
apt-get install ufw -y > /dev/null 2>&1
for PORT in $ALLOW_PORTS; do ufw allow \$PORT > /dev/null 2>&1; done
ufw allow from $INTERNAL_NET > /dev/null 2>&1
ufw allow from $DOCKER_BRIDGE_NET > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1
dig @8.8.8.8 google.com +short | grep -qE '([0-9]{1,3}\\.){3}[0-9]{1,3}' || echo '[CT] DNS 쿼리 실패'
"

# --- [STEP9. 호스트 NAT/UFW after.rules 조정] ---
step 8 "호스트 NAT/UFW after.rules 변경"
NAT_IFACE=$(ip route | awk '/default/ {print $5; exit}')
if ! iptables -t nat -C POSTROUTING -s $DOCKER_BRIDGE_NET -o $NAT_IFACE -j MASQUERADE 2>/dev/null
then
  iptables -t nat -A POSTROUTING -s $DOCKER_BRIDGE_NET -o $NAT_IFACE -j MASQUERADE || error_exit "MASQUERADE 생성 실패"
fi

UFW_AFTER_RULES="/etc/ufw/after.rules"
if ! grep -q "^:DOCKER-USER" $UFW_AFTER_RULES
then
  cp $UFW_AFTER_RULES ${UFW_AFTER_RULES}.bak
  sed -i '/^COMMIT/i :DOCKER-USER - [0:0]\n-A DOCKER-USER -j RETURN' $UFW_AFTER_RULES || error_exit "after.rules 수정 실패"
  ufw reload > /dev/null 2>&1
fi

echo "==> 전체 LXC 자동화 완료!"
