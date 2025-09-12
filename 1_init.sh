#!/bin/bash

##################################################
# Proxmox 초기설정 자동화
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
info() { echo "[$(date '+%T')][INFO] $*"; }
err() { echo "[$(date '+%T')][ERROR]" "$@" >&2 }

# 설정 파일 위치 지정 (스크립트와 같은 디렉토리 등)
CONFIG_FILE="./proxmox.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    info "설정 파일 $CONFIG_FILE 이(가) 없습니다. 기본값 사용."
fi

# 환경변수 기본값 지정 (설정파일에 없을 경우 대비)
USB_MOUNT=${USB_MOUNT:-usb-backup} 

log "==> 0. root 사이즈 변경"
BEFORE_SIZE_GB=$(lsblk -b /dev/mapper/pve-root -o SIZE -n | awk '{printf "%.2f", $1/1024/1024/1024}')
log "작업 전 용량: ${BEFORE_SIZE_GB} GB"
lvresize -l +100%FREE /dev/pve/root >/dev/null 2>&1 || true
resize2fs /dev/mapper/pve-root >/dev/null 2>&1 || true
AFTER_SIZE_GB=$(lsblk -b /dev/mapper/pve-root -o SIZE -n | awk '{printf "%.2f", $1/1024/1024/1024}')
log "작업 후 용량: ${AFTER_SIZE_GB} GB"
echo

log "==> 1. AppArmor 비활성화"
systemctl stop apparmor >/dev/null 2>&1
systemctl disable apparmor >/dev/null 2>&1
systemctl mask apparmor >/dev/null 2>&1
log "AppArmor disabled."
echo

log "==> # 2. 방화벽 설정"
systemctl stop pve-firewall >/dev/null 2>&1
systemctl disable pve-firewall >/dev/null 2>&1
log "기존 pve-firewall 비활성화"

script -q -c "apt-get update -qq" /dev/null
apt install -y ufw >/dev/null 2>&1
log "ufw 설치완료"

PORTS=(22 8006 45876) # SSH, Proxmox Web UI, Beszel agent
for PORT in "${PORTS[@]}"; do
    ufw allow $PORT >/dev/null 2>&1
done
# 서버의 주요 인터페이스에서 현재 IP 추출 (예시: eth0, enp1s0 등 환경에 맞게 수정) 
CURRENT_IP=$(hostname -I | awk '{print $1}')
INTERNAL_NETWORK="$(echo $CURRENT_IP | awk -F. '{print $1"."$2"."$3".0/24"}')"
# 기본값으로 내부대역 CIDR 사용
read -e -i "$INTERNAL_NETWORK" -p "내부망 IP 대역을 입력하세요 (엔터 시 자동: $INTERNAL_NETWORK): " USER_NETWORK
# 입력값이 비었으면 자동으로 내부대역을 할당
if [ -z "$USER_NETWORK" ]; then
  USER_NETWORK="$INTERNAL_NETWORK"
fi
ufw allow from "$USER_NETWORK" >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
log "방화벽 설정이 완료되었습니다. 적용현황은 다음과 같습니다."
ufw status verbose
echo

log "==> # 3. USB 사용 여부 선택"
read -p "USB 장치를 사용하시겠습니까? (Y/N): " USE_USB
USE_USB=$(echo "$USE_USB" | tr '[:upper:]' '[:lower:]')

if [[ "$USE_USB" == "y" ]]; then
  log "현재 시스템의 블럭 장치 목록:"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E 'disk|part'
  echo

  read -p "USB 장치 이름을 입력하세요 (예: sda1): " USB_DEVICE

  MOUNT_POINT="/mnt/$USB_MOUNT"
  mkdir -p "${MOUNT_POINT}" >/dev/null 2>&1
  mkfs.ext4 "/dev/${USB_DEVICE}" >/dev/null 2>&1
  log "USB 장치 /dev/${USB_DEVICE} 을(를) ${MOUNT_POINT}에 마운트하도록 설정합니다."
  # fstab 중복 추가 방지
  if grep -q "/dev/${USB_DEVICE}" /etc/fstab; then
    info "/dev/${USB_DEVICE} 에 대한 fstab 항목이 이미 존재합니다."
  else
    echo "/dev/${USB_DEVICE} ${MOUNT_POINT} ext4 defaults 0 0" | tee -a /etc/fstab
  fi

  systemctl daemon-reload
  mount -a
  log "USB 장치 마운트 완료."

  pvesm add dir usb-backup --path "${MOUNT_POINT}" --content images,iso,vztmpl,backup,rootdir
  log "Proxmox usb-backup 저장소 등록 완료."
else
  info "USB 장치 사용을 건너뜁니다."
fi
echo

log "==> # 4. GPU 종류 선택 및 설치"
log "GPU 종류를 선택하세요: 1) AMD(내장/외장)   2) Intel(내장/외장)   3) NVIDIA"
read -p "선택 (1/2/3): " GPU_CHOICE

case $GPU_CHOICE in
  1)  # AMD 내장/외장 GPU
    log "AMD GPU 적용 중..."
    apt install -y pve-firmware >/dev/null 2>&1
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="amd_iommu=on iommu=pt /' /etc/default/grub >/dev/null 2>&1
    ;;
  2)  # Intel 내장/외장 GPU
    log "Intel GPU 적용 중..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on iommu=pt /' /etc/default/grub >/dev/null 2>&1
    ;;
  3)  # NVIDIA 외장 GPU
    log "NVIDIA GPU 적용 중..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="iommu=pt /' /etc/default/grub >/dev/null 2>&1
    modprobe vfio-pci >/dev/null 2>&1
    echo -e "vfio\nvfio_iommu_type1\nvfio_pci\nvfio_virqfd" | tee /etc/modules-load.d/vfio.conf >/dev/null 2>&1
    log "NVIDIA PCI 디바이스 ID는 lspci -nn | grep -i nvidia 로 확인 가능하며, vfio 바인딩은 수동 또는 별도 스크립트로 진행하세요."
    ;;
  *)
    info "잘못된 선택입니다. GPU 설정을 건너뜁니다."
    ;;
esac

log "grub 업데이트 중..."
update-grub >/dev/null 2>&1
info "재부팅 후 'ls -la /dev/dri/' 명령으로 GPU 장치를 확인하세요."
