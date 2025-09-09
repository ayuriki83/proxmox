#!/bin/bash

set -e

# 1. 영구 alias 설정
echo "alias ll='ls -lah --color=auto'" >> ~/.bashrc
source ~/.bashrc
echo "alias 'll' set in ~/.bashrc and applied immediately."

# 2. AppArmor 비활성화
echo "Disabling AppArmor..."
sudo systemctl stop apparmor
sudo systemctl disable apparmor
sudo systemctl mask apparmor
echo "AppArmor disabled."

# 3. 방화벽 설정
echo "기존 pve-firewall 비활성화..."
sudo systemctl stop pve-firewall
sudo systemctl disable pve-firewall

echo "ufw 설치 및 구성 시작..."
sudo apt update
sudo apt install -y ufw

read -p "내부망 IP 대역을 입력하세요 (예: 192.168.0.0/24): " INTERNAL_NETWORK

sudo ufw allow 22       # SSH
sudo ufw allow 8006     # Proxmox Web UI
sudo ufw allow 45876    # Beszel agent
sudo ufw allow from "$INTERNAL_NETWORK"
sudo ufw --force enable

echo "방화벽 설정이 완료되었습니다."
sudo ufw status verbose

# 4. USB 사용 여부 선택
read -p "USB 장치를 사용하시겠습니까? (Y/N): " USE_USB
USE_USB=$(echo "$USE_USB" | tr '[:upper:]' '[:lower:]')

if [[ "$USE_USB" == "y" ]]; then
  echo "현재 시스템의 블럭 장치 목록:"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -E 'disk|part'
  echo

  read -p "USB 장치 이름을 입력하세요 (예: sda1): " USB_DEVICE

  MOUNT_POINT="/mnt/usb-backup"
  sudo mkdir -p "${MOUNT_POINT}"

  echo "USB 장치 /dev/${USB_DEVICE} 을(를) ${MOUNT_POINT}에 마운트하도록 설정합니다."
  # fstab 중복 추가 방지
  if grep -q "/dev/${USB_DEVICE}" /etc/fstab; then
    echo "/dev/${USB_DEVICE} 에 대한 fstab 항목이 이미 존재합니다."
  else
    echo "/dev/${USB_DEVICE} ${MOUNT_POINT} ext4 defaults 0 0" | sudo tee -a /etc/fstab
  fi

  sudo systemctl daemon-reload
  sudo mount -a

  echo "USB 장치 마운트 완료."

  echo "Proxmox 저장소 usb-backup 등록..."
  sudo pvesm add dir usb-backup --path "${MOUNT_POINT}" --content images,iso,vztmpl,backup,rootdir
  echo "Proxmox usb-backup 저장소 등록 완료."
else
  echo "USB 장치 사용을 건너뜁니다."
fi
