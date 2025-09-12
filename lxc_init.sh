#!/usr/bin/env bash
set -e

### Step 6: /root/.bashrc 적용
for LINE in \
  "alias ls='ls --color=auto --show-control-chars'" \
  "alias ll='ls -al --color=auto --show-control-chars'"
do
  grep -Fxq "$LINE" /root/.bashrc || echo "$LINE" >> /root/.bashrc
done
source /root/.bashrc


### Step 7: 시스템 업데이트 및 패키지 설치
apt-get update -qq && apt-get upgrade -y
apt-get install -y $BASIC_APT dnsutils


### Step 8: AppArmor 비활성화, 로케일/폰트/시간대
systemctl stop apparmor || true
systemctl disable apparmor || true
apt-get remove -y apparmor man-db || true

apt-get install -y language-pack-ko fonts-nanum locales
locale-gen $LOCALE_LANG
update-locale LANG=$LOCALE_LANG
echo -e "export LANG=$LOCALE_LANG\nexport LANGUAGE=$LOCALE_LANG\nexport LC_ALL=$LOCALE_LANG" >> /root/.bashrc

# 로그 함수/alias 추가
for LINE in \
  "alias ls='ls --color=auto --show-control-chars'" \
  "alias ll='ls -al --color=auto --show-control-chars'" \
  "log() { echo \"[\$(date '+%T')] \$*\"; }" \
  "info() { echo \"[INFO][\$(date '+%T')] \$*\"; }" \
  "err() { echo \"[ERROR][\$(date '+%T')] \$*\"; }"
do
  grep -Fxq "$LINE" /root/.bashrc || echo "$LINE" >> /root/.bashrc
done
source /root/.bashrc

timedatectl set-timezone $TIMEZONE


### Step 9: GPU 설정
case "$GPU_CHOICE" in
  1)
    apt-get install -y vainfo
    vainfo || info "[CT] vainfo 동작 경고"
    ;;
  2)
    apt-get install -y vainfo intel-media-va-driver-non-free intel-gpu-tools
    vainfo
    ;;
  3)
    apt-get install -y nvidia-driver nvidia-utils-525
    nvidia-smi || info "[CT] nvidia-smi 실행 경고"
    ;;
esac


### Step 10: Docker 및 Daemon 세팅
apt-get install -y docker.io docker-compose-v2
systemctl enable docker
systemctl start docker

mkdir -p $(dirname "$DOCKER_DATA_ROOT") /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "$DOCKER_DATA_ROOT",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "storage-driver": "overlay2",
  "default-shm-size": "1g",
  "default-ulimits": {"nofile":{"name":"nofile","hard":65536,"soft":65536}},
  "dns": ["$DOCKER_DNS1", "$DOCKER_DNS2"]
}
EOF
systemctl restart docker
docker network create --subnet=$DOCKER_BRIDGE_NET --gateway=$DOCKER_BRIDGE_GW $DOCKER_BRIDGE_NM || true


### Step 11: UFW 방화벽
apt-get install -y ufw
for PORT in $ALLOW_PORTS; do ufw allow $PORT; done
ufw allow from $INTERNAL_NET
ufw allow from $DOCKER_BRIDGE_NET
ufw --force enable
dig @8.8.8.8 google.com +short | grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}' || err "[CT] DNS 쿼리 실패"


### Step 12: NAT/UFW rule 적용 (DOCKER)
NAT_IFACE=$(ip route | awk '/default/ {print $5; exit}')
if ! iptables -t nat -C POSTROUTING -s $DOCKER_BRIDGE_NET -o $NAT_IFACE -j MASQUERADE 2>/dev/null
then
  iptables -t nat -A POSTROUTING -s $DOCKER_BRIDGE_NET -o $NAT_IFACE -j MASQUERADE
fi

UFW_AFTER_RULES="/etc/ufw/after.rules"
if ! grep -q "^:DOCKER-USER" $UFW_AFTER_RULES
then
  cp $UFW_AFTER_RULES ${UFW_AFTER_RULES}.bak
  sed -i '/^COMMIT/i :DOCKER-USER - [0:0]\n-A DOCKER-USER -j RETURN' $UFW_AFTER_RULES
  ufw reload
fi


echo "==> 전체 LXC 자동화 완료!"
