#!/bin/bash

set -e

echo "==> 0. root 사이즈 변경"
BEFORE_SIZE_GB=$(lsblk -b /dev/mapper/pve-root -o SIZE -n | awk '{printf "%.2f", $1/1024/1024/1024}')
echo "작업 전 용량: ${BEFORE_SIZE_GB} GB"
lvresize -l +100%FREE /dev/pve/root >/dev/null 2>&1 || true
resize2fs /dev/mapper/pve-root >/dev/null 2>&1 || true
AFTER_SIZE_GB=$(lsblk -b /dev/mapper/pve-root -o SIZE -n | awk '{printf "%.2f", $1/1024/1024/1024}')
echo "작업 후 용량: ${AFTER_SIZE_GB} GB"
echo

echo "==> 1. alias 설정"
echo "alias ls='ls --color=auto --show-control-chars'" >> ~/.bashrc
echo "alias l='ls -al --color=auto --show-control-chars'" >> ~/.bashrc
echo "alias ll='ls -al --color=auto --show-control-chars'" >> ~/.bashrc
source ~/.bashrc
echo "alias 설정 및 즉시 적용"
echo

echo "==> 2. AppArmor 비활성화"
systemctl stop apparmor >/dev/null 2>&1
systemctl disable apparmor >/dev/null 2>&1
systemctl mask apparmor >/dev/null 2>&1
echo "AppArmor disabled."
echo

echo "==> # 3. 방화벽 설정"
systemctl stop pve-firewall >/dev/null 2>&1
systemctl disable pve-firewall >/dev/null 2>&1
echo "기존 pve-firewall 비활성화"

apt update >/dev/null 2>&1
apt install -y ufw >/dev/null 2>&1
echo "ufw 설치완료"

PORTS=(22 8006 45876) # SSH, Proxmox Web UI, Beszel agent
for PORT in "${PORTS[@]}"; do
    ufw allow $PORT >/dev/null 2>&1
done
read -p "내부망 IP 대역을 입력하세요 (예: 192.168.0.0/24): " INTERNAL_NETWORK
ufw allow from "$INTERNAL_NETWORK" >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
echo "방화벽 설정이 완료되었습니다. 적용현황은 다음과 같습니다."
ufw status verbose
echo

echo "==> # 4. USB 사용 여부 선택"
read -p "USB 장치를 사용하시겠습니까? (Y/N): " USE_USB
USE_USB=$(echo "$USE_USB" | tr '[:upper:]' '[:lower:]')

if [[ "$USE_USB" == "y" ]]; then
  echo "현재 시스템의 블럭 장치 목록:"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E 'disk|part'
  echo

  read -p "USB 장치 이름을 입력하세요 (예: sda1): " USB_DEVICE

  MOUNT_POINT="/mnt/usb-backup"
  mkdir -p "${MOUNT_POINT}" >/dev/null 2>&1

  echo "USB 장치 /dev/${USB_DEVICE} 을(를) ${MOUNT_POINT}에 마운트하도록 설정합니다."
  # fstab 중복 추가 방지
  if grep -q "/dev/${USB_DEVICE}" /etc/fstab; then
    echo "/dev/${USB_DEVICE} 에 대한 fstab 항목이 이미 존재합니다."
  else
    echo "/dev/${USB_DEVICE} ${MOUNT_POINT} ext4 defaults 0 0" | tee -a /etc/fstab
  fi

  systemctl daemon-reload >/dev/null 2>&1
  mount -a >/dev/null 2>&1
  echo "USB 장치 마운트 완료."

  pvesm add dir usb-backup --path "${MOUNT_POINT}" --content images,iso,vztmpl,backup,rootdir >/dev/null 2>&1
  "Proxmox usb-backup 저장소 등록 완료."
else
  echo "USB 장치 사용을 건너뜁니다."
fi
echo

echo "==> # 5. GPU 종류 선택 및 설치"
echo "GPU 종류를 선택하세요:"
echo "1) AMD(내장/외장)"
echo "2) Intel(내장/외장)"
echo "3) NVIDIA"
read -p "선택 (1/2/3): " GPU_CHOICE

case $GPU_CHOICE in
  1)  # AMD 내장/외장 GPU
    #echo "AMD GPU 펌웨어 및 드라이버 설치 중..."
    apt install -y pve-firmware >/dev/null 2>&1
    #echo "AMD GPU IOMMU 활성화 설정 중..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="amd_iommu=on iommu=pt /' /etc/default/grub >/dev/null 2>&1
    ;;
  2)  # Intel 내장/외장 GPU
    echo "Intel GPU IOMMU 활성화 설정 중..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on iommu=pt /' /etc/default/grub >/dev/null 2>&1
    ;;
  3)  # NVIDIA 외장 GPU
    echo "NVIDIA GPU IOMMU 활성화 설정 중..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="iommu=pt /' /etc/default/grub >/dev/null 2>&1
    echo "NVIDIA VFIO 모듈 로딩 중..."
    modprobe vfio-pci >/dev/null 2>&1
    echo -e "vfio\nvfio_iommu_type1\nvfio_pci\nvfio_virqfd" | tee /etc/modules-load.d/vfio.conf >/dev/null 2>&1
    echo "NVIDIA PCI 디바이스 ID는 lspci -nn | grep -i nvidia 로 확인 가능하며, vfio 바인딩은 수동 또는 별도 스크립트로 진행하세요."
    ;;
  *)
    echo "잘못된 선택입니다. GPU 설정을 건너뜁니다."
    ;;
esac

echo "grub 업데이트 중..."
update-grub >/dev/null 2>&1

echo "재부팅 후 'ls -la /dev/dri/' 명령으로 GPU 장치를 확인하세요."
