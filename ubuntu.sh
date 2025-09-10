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

echo "==> # 4. GPU 종류 선택 및 LXC conf 추가"
echo "GPU 종류를 선택하세요:"
echo "1) AMD(내장/외장)"
echo "2) Intel(내장/외장)"
echo "3) NVIDIA"
read -p "선택 (1/2/3): " GPU_CHOICE

case "$GPU_CHOICE" in
    1)
        echo "AMD GPU(LXC /dev/dri) 패스스루 conf를 추가합니다."
        cat >> /etc/pve/lxc/${CT_ID}.conf << EOF
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
        ;;
    2)
        echo "Intel GPU(LXC /dev/dri) 패스스루 conf를 추가합니다."
        cat >> /etc/pve/lxc/${CT_ID}.conf << EOF
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
        ;;
    3)
        echo "NVIDIA GPU(LXC /dev/nvidia*) 패스스루 conf를 추가합니다."
        cat >> /etc/pve/lxc/${CT_ID}.conf << EOF
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
EOF
        ;;
    *)
        echo "잘못된 선택입니다. GPU 패스스루를 건너뜁니다."
        ;;
esac

# Ubuntu 내부 작업
# Language/Locale
LOCALE_LANG=${LOCALE_LANG:-ko_KR.UTF-8}
TIMEZONE=${TIMEZONE:-Asia/Seoul}

# Docker 설정 값
DOCKER_DATA_ROOT=${DOCKER_DATA_ROOT:-/docker/core}
DOCKER_DNS1=${DOCKER_DNS1:-8.8.8.8}
DOCKER_DNS2=${DOCKER_DNS2:-1.1.1.1}
DOCKER_BRIDGE_NET=${DOCKER_BRIDGE_NET:-172.18.0.0/16}
DOCKER_BRIDGE_GW=${DOCKER_BRIDGE_GW:-172.18.0.1}

# Core utility package list (원하는 구성에 추가 가능)
BASIC_APT=${BASIC_APT:-"curl wget htop tree neofetch git vim net-tools nfs-common"}

pct exec $CT_ID -- bash -c "
echo '[CT 내부] 시스템/패키지 업데이트'
script -q -c "apt-get update -qq" /dev/null
apt upgrade -y >/dev/null 2>&1

echo '[CT 내부] 필수 패키지 설치: $BASIC_APT'
apt install $BASIC_APT -y >/dev/null 2>&1

echo '[CT 내부] AppArmor 비활성/제거'
systemctl stop apparmor >/dev/null 2>&1
systemctl disable apparmor >/dev/null 2>&1
apt remove apparmor man-db -y >/dev/null 2>&1

echo '[CT 내부] 한글 및 폰트/로케일 설정'
apt install language-pack-ko fonts-nanum locales -y >/dev/null 2>&1
locale-gen $LOCALE_LANG
update-locale LANG=$LOCALE_LANG
echo -e 'export LANG=$LOCALE_LANG\nexport LANGUAGE=$LOCALE_LANG\nexport LC_ALL=$LOCALE_LANG' >> /root/.bashrc
source /root/.bashrc
locale

echo '[CT 내부] 타임존 설정: $TIMEZONE'
timedatectl set-timezone $TIMEZONE

echo "==> # 4. GPU 종류 선택 및 LXC conf 추가"
echo "[CT 내부] GPU 종류를 선택하세요:"
echo "1) AMD(내장/외장)"
echo "2) Intel(내장/외장)"
echo "3) NVIDIA"
read -p "선택 (1/2/3): " GPU_CHOICE
case "$GPU_CHOICE" in
  1)
    echo '[CT 내부] AMD GPU: VA-API(h/w 가속) 패키지(vainfo 등) 설치 및 확인'
    apt install vainfo -y >/dev/null 2>&1
    vainfo
    ;;
  2)
    echo '[CT 내부] Intel GPU: Intel 미디어 드라이버, VA-API(vainfo), intel-gpu-tools 설치 및 확인'
    apt install vainfo intel-media-va-driver-non-free intel-gpu-tools -y >/dev/null 2>&1
    vainfo
    intel_gpu_top --help || true
    ;;
  3)
    echo '[CT 내부] NVIDIA GPU: NVENC/NVDEC 관련 패키지, 드라이버, nvidia-smi 확인'
    apt install nvidia-driver nvidia-utils-525 -y >/dev/null 2>&1 || true
    nvidia-smi || echo "nvidia-smi 명령이 정상적으로 실행되지 않을 수 있음(LXC 특성)"
    ;;
  *)
    echo '[CT 내부] GPU 선택 없음 → 하드웨어 가속 설치, 확인 단계를 건너뜀'
    ;;
esac

echo '[CT 내부] Docker 설치'
apt install docker.io docker-compose-v2 -y >/dev/null 2>&1
systemctl enable docker
systemctl start docker

echo '[CT 내부] Docker 디렉토리 및 설정 파일 생성'
mkdir -p $(dirname $DOCKER_DATA_ROOT)
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << EOF
{
  \"data-root\": \"$DOCKER_DATA_ROOT\",
  \"log-driver\": \"json-file\",
  \"log-opts\": {
    \"max-size\": \"10m\",
    \"max-file\": \"3\"
  },
  \"storage-driver\": \"overlay2\",
  \"default-shm-size\": \"1g\",
  \"default-ulimits\": {
    \"nofile\": {
      \"name\": \"nofile\",
      \"hard\": 65536,
      \"soft\": 65536
    }
  },
  \"dns\": [\"$DOCKER_DNS1\", \"$DOCKER_DNS2\"]
}
EOF

systemctl restart docker

echo '[CT 내부] Docker 네트워크 생성: $DOCKER_NET_SUBNET, $DOCKER_NET_GW'
docker network create --subnet=$DOCKER_BRIDGE_NET --gateway=$DOCKER_BRIDGE_GW ProxyNet

ALLOW_PORTS=${ALLOW_PORTS:-"80/tcp 443/tcp 443/udp 45876 5574 9999 32400"}
INTERNAL_NET=${INTERNAL_NET:-"192.168.0.0/24"}
echo '[CT 내부] UFW 방화벽 설치 및 규칙 추가'
apt install ufw -y

for PORT in $ALLOW_PORTS; do
  echo \"[CT 내부] UFW 허용: \$PORT\"
  ufw allow \$PORT
done

echo \"[CT 내부] 내부망 허용: $INTERNAL_NET\"
ufw allow from $INTERNAL_NET

echo \"[CT 내부] Docker 브릿지 허용: $DOCKER_BRIDGE_NET\"
ufw allow from $DOCKER_BRIDGE_NET

ufw --force enable
echo '[CT 내부] UFW 상태 최종 출력'
ufw status verbose

NAT_IFACE=$(ip route | awk '/default/ {print $5; exit}')
# MASQUERADE 규칙 존재 확인 및 자동 등록
echo "[호스트] iptables MASQUERADE NAT 규칙 확인"
if ! iptables -t nat -C POSTROUTING -s $DOCKER_BRIDGE_NET -o $NAT_IFACE -j MASQUERADE 2>/dev/null; then
  echo "[호스트] MASQUERADE 규칙 없음 → 자동 등록"
  iptables -t nat -A POSTROUTING -s $DOCKER_BRIDGE_NET -o $NAT_IFACE -j MASQUERADE
else
  echo "[호스트] MASQUERADE 규칙 이미 존재"
fi

echo "[호스트] NAT POSTROUTING 테이블"
iptables -t nat -L POSTROUTING -n

echo "[CT 내부] 네트워크 및 외부 DNS(8.8.8.8) 통신 확인..."
if dig @8.8.8.8 google.com +short | grep -E '^([0-9]{1,3}\\.){3}[0-9]{1,3}\$' >/dev/null; then
  echo '[CT 내부] 외부 DNS 쿼리 성공(통신 OK!)'
else
  echo '[CT 내부] 외부 DNS 쿼리 실패: 방화벽/NAT 또는 DNS 설정을 확인하세요!'
fi

# 도커 서비스에서 UFW 변경점 없도록 대응
UFW_AFTER_RULES="/etc/ufw/after.rules"

# 이미 추가되었는지 검사 후 없으면 COMMIT 위에 삽입
if ! grep -q "^:DOCKER-USER" $UFW_AFTER_RULES; then
  echo "[UFW] after.rules에 DOCKER-USER 체인 추가"
  cp $UFW_AFTER_RULES ${UFW_AFTER_RULES}.bak
  sed -i '/^COMMIT/i :DOCKER-USER - [0:0]\n-A DOCKER-USER -j RETURN' $UFW_AFTER_RULES
  echo "[UFW] after.rules 업데이트 완료"
else
  echo "[UFW] DOCKER-USER 체인 이미 존재 (중복 방지)"
fi
ufw reload

echo '[CT 내부] 모든 초기화 완료!'
"
