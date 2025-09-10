#!/bin/bash
##########################
# Proxmox Ubuntu + Rclone마운트 생성 자동화 (에러 메시지 Only)
##########################
set -e

step() { echo "==> STEP $1: $2"; }
error_exit() { echo "[오류] $1"; exit 1; }

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

step 1 "템플릿 체크/다운로드"
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

RCLONE_GB=${RCLONE_GB:-256}
RCLONE_SIZE="${RCLONE_GB}G"
LV_RCLONE=${LV_RCLONE:-lv-rclone}
MOUNT_POINT=${MOUNT_POINT:-/mnt/rclone}

step 3 "RCLONE LV생성(ext4) 및 LXC Conf 설정 적용"
lv_path="/dev/${VG_NAME}/${LV_RCLONE}"
lvs $lv_path > /dev/null 2>&1 || (
    lvcreate -V $RCLONE_SIZE -T ${VG_NAME}/${LV_NAME} -n $LV_RCLONE > /dev/null 2>&1 || error_exit "LV 생성 실패"
    mkfs.ext4 $lv_path > /dev/null 2>&1 || error_exit "LV 포맷 실패"
)

LXC_CONF="/etc/pve/lxc/${CT_ID}.conf"
if ! grep -q "$MOUNT_POINT" $LXC_CONF 2>/dev/null; then
cat >> $LXC_CONF <<EOF
mp0: $lv_path,mp=$MOUNT_POINT
lxc.cgroup2.devices.allow: c 10:229 rwm
lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file
EOF
fi
cat >> $LXC_CONF <<EOF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
EOF

step 4 "LXC Conf GPU 설정 적용"
echo "GPU 종류를 선택하세요:"
echo "1) AMD(내장/외장)"
echo "2) Intel(내장/외장)"
echo "3) NVIDIA"
read -p "선택 (1/2/3): " GPU_CHOICE
case "$GPU_CHOICE" in
    1)
        cat >> $LXC_CONF <<EOF
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
        ;;
    2)
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

step 5 "LXC 컨테이너 시작"
pct start $CT_ID > /dev/null 2>&1 || error_exit "컨테이너 시작 실패"
sleep 5
pct status $CT_ID | grep -qw running || error_exit "컨테이너가 비정상 상태"

step 6 "LXC 컨테이너 내부 환경구성"
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

pct exec $CT_ID -- bash -c '
set -e
step() { echo "[CT] STEP $1: $2"; }
error_exit() { echo "[오류] $1"; exit 1; }

echo "[CT] 내부 설정 시작"
step 1 "업데이트/업그레이드"
apt-get update -qq > /dev/null 2>&1 || error_exit "apt update 실패"
apt-get upgrade -y > /dev/null 2>&1 || error_exit "apt upgrade 실패"

step 2 "기본 패키지 설치"
apt-get install '"$BASIC_APT"' dnsutils -y > /dev/null 2>&1 || error_exit "기본패키지 설치 실패"

step 3 "AppArmor/한글/로케일/폰트"
systemctl stop apparmor > /dev/null 2>&1 || true
systemctl disable apparmor > /dev/null 2>&1 || true
apt-get remove apparmor man-db -y > /dev/null 2>&1
apt-get install language-pack-ko fonts-nanum locales -y > /dev/null 2>&1 || error_exit "한글 관련 패키지 설치 실패"
locale-gen '"$LOCALE_LANG"' > /dev/null 2>&1
update-locale LANG='"$LOCALE_LANG"' > /dev/null 2>&1
echo -e "export LANG='"$LOCALE_LANG"'\nexport LANGUAGE='"$LOCALE_LANG"'\nexport LC_ALL='"$LOCALE_LANG"'" >> /root/.bashrc
source /root/.bashrc

step 4 "타임존 설정"
timedatectl set-timezone '"$TIMEZONE"' > /dev/null 2>&1 || error_exit "타임존 설정 실패"

step 5 "GPU 설정 (하드웨어 가속 및 드라이버)"
case "'$GPU_CHOICE'" in
  1)
    apt-get install vainfo -y > /dev/null 2>&1 || error_exit "vainfo(AMD) 설치 실패"
    vainfo > /dev/null 2>&1 || error_exit "vainfo 동작 실패"
    ;;
  2)
    apt-get install vainfo intel-media-va-driver-non-free intel-gpu-tools -y > /dev/null 2>&1 || error_exit "Intel GPU 패키지 설치 실패"
    vainfo > /dev/null 2>&1 || error_exit "vainfo 동작 실패"
    intel_gpu_top --help > /dev/null 2>&1 || true
    ;;
  3)
    apt-get install nvidia-driver nvidia-utils-525 -y > /dev/null 2>&1 || true
    nvidia-smi > /dev/null 2>&1 || echo "[경고] nvidia-smi 실행 안됨"
    ;;
  *) ;;
esac

step 6 "Docker 설치 및 브릿지 네트워크 등록"
apt-get install docker.io docker-compose-v2 -y > /dev/null 2>&1 || error_exit "Docker/V2 설치 실패"
systemctl enable docker > /dev/null 2>&1
systemctl start docker > /dev/null 2>&1
mkdir -p $(dirname '"$DOCKER_DATA_ROOT"')
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << EOF2
{
  "data-root": "'"$DOCKER_DATA_ROOT"'",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "storage-driver": "overlay2",
  "default-shm-size": "1g",
  "default-ulimits": { "nofile": {"name":"nofile","hard":65536,"soft":65536} },
  "dns": ["'"$DOCKER_DNS1"'","'"$DOCKER_DNS2"'"]
}
EOF2
systemctl restart docker > /dev/null 2>&1
docker network create --subnet='"$DOCKER_BRIDGE_NET"' --gateway='"$DOCKER_BRIDGE_GW"' ProxyNet > /dev/null 2>&1 || true

step 7 "방화벽 설정 및 통신 확인"
apt-get install ufw -y > /dev/null 2>&1
for PORT in '"$ALLOW_PORTS"'; do ufw allow $PORT > /dev/null 2>&1; done
ufw allow from '"$INTERNAL_NET"' > /dev/null 2>&1
ufw allow from '"$DOCKER_BRIDGE_NET"' > /dev/null 2>&1
ufw --force enable > /dev/null 2>&1
dig @8.8.8.8 google.com +short | grep -E "([0-9]{1,3}\.){3}[0-9]{1,3}" > /dev/null 2>&1 || error_exit "DNS 쿼리 실패"

step 8 "호스트 NAT/UFW after.rules 변경"
NAT_IFACE=$(ip route | awk '/default/ {print $5; exit}')
if ! iptables -t nat -C POSTROUTING -s $DOCKER_BRIDGE_NET -o $NAT_IFACE -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s $DOCKER_BRIDGE_NET -o $NAT_IFACE -j MASQUERADE || error_exit "MASQUERADE 생성 실패"
fi
UFW_AFTER_RULES="/etc/ufw/after.rules"
if ! grep -q "^:DOCKER-USER" $UFW_AFTER_RULES; then
  cp $UFW_AFTER_RULES ${UFW_AFTER_RULES}.bak
  sed -i '/^COMMIT/i :DOCKER-USER - [0:0]\n-A DOCKER-USER -j RETURN' $UFW_AFTER_RULES || error_exit "after.rules 수정 실패"
  ufw reload > /dev/null 2>&1
fi
echo "[CT] 내부 설정 전체 완료!"
'

echo "==> [완료] 모든 Proxmox LXC+Docker 자동화(오류 발생시만 메시지 표시)"

