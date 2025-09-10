#!/bin/bash

##################################################
# Proxmox Disk Partition 자동화
# 요구: parted 기반 (GPT, Linux LVM 또는 Directory 타입 자동 생성)
##################################################

set -e

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
MAIN=${MAIN:-main} 
DATA=${DATA:-data}
DIR_NAME=${DIR_NAME:-directory}
VG_MAIN="vg-$MAIN"
LV_MAIN="lv-$MAIN"
LVM_MAIN="lvm-$MAIN"
VG_DATA="vg-$DATA"
LV_DATA="lv-$DATA"
LVM_DATA="lvm-$DATA"

log "===== 파티션 생성 자동화 스크립트 ====="
log "===== 현재 파티션 정보 ====="
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

log
log "===== 메인 디스크(Linux LVM 잔여 공간) 선택 (미선택시 Enter) ====="
read -p "메인 디스크명 입력(ex: nvme0n1, sda, skip=Enter): " MAIN_DISK
if [ -n "$MAIN_DISK" ]; then 
  # 마지막 파티션 번호 자동 추출 (예: p3)
  LAST_PART_NUM=$(lsblk /dev/$MAIN_DISK | awk '/part/ {print $1}' | tail -n1 | grep -oP "${MAIN_DISK}p\K[0-9]+")
  if [ -z "$LAST_PART_NUM" ]; then
    echo "파티션 번호를 찾을 수 없습니다."
    exit 1
  fi
  PART_NUM=$(($LAST_PART_NUM+1))
  PARTITION="/dev/${MAIN_DISK}p${PART_NUM}"
  START_POS=$(parted /dev/$MAIN_DISK unit MiB print free | awk '/Free Space/ {print $1}' | tail -1 | sed 's/MiB//')
  START_POS=$(expr $START_POS + 1)
  END_POS=$(parted /dev/$MAIN_DISK unit MiB print free | awk '/Free Space/ {print $2}' | tail -1 | sed 's/MiB//')
  END_POS=$(expr $END_POS - 1)
  log "새 파티션 $PARTITION => 시작 위치: $START_POS MiB, 종료 위치: $END_POS MiB"
  
  # 실제 parted 파티션 생성 및 LVM 설정
  parted /dev/$MAIN_DISK --script unit MiB mkpart primary "${START_POS}MiB" "${END_POS}MiB"
  parted /dev/$MAIN_DISK --script set $PART_NUM lvm on
  partprobe /dev/$MAIN_DISK
  udevadm trigger
  log "새 파티션 $PARTITION 생성 및 LVM 플래그 적용 완료."
  
  # pv, vg, lv 자동 생성
  pvcreate "$PARTITION"
  vgcreate $VG_MAIN "$PARTITION"
  lvcreate -l 100%FREE -T $VG_MAIN/$LV_MAIN
  pvesm add lvmthin $LVM_MAIN --vgname $VG_MAIN --thinpool $LV_MAIN --content images,rootdir
  log "pv/vg/lv까지 자동 생성 완료: pv($PARTITION), vg($VG_MAIN), lv($VG_MAIN/$LV_MAIN)"
fi

log
log "==== 보조/백업 디스크 선택 (미선택시 Enter) ===="
lsblk -o NAME,SIZE,TYPE
read -p "보조/백업 디스크명 입력(ex: nvme1n1, sdb, skip=Enter): " SECOND_DISK
if [ -n "$SECOND_DISK" ]; then
  read -p "보조/백업 디스크 파티션 유형 선택 1:LinuxLVM 2:Directory [1/2]: " SECOND_TYPE
  # 모든 시그니처 먼저 제거
  wipefs -a /dev/$SECOND_DISK >/dev/null 2>&1
  # 파티션 테이블 생성(초기화) 및 LVM 설정
  parted /dev/$SECOND_DISK --script mklabel gpt
  if [[ "$SECOND_TYPE" == "1" ]]; then
    parted /dev/$SECOND_DISK --script mkpart primary 0% 100%
    parted /dev/$SECOND_DISK --script set 1 lvm on
    partprobe /dev/$SECOND_DISK
    udevadm trigger
    log "보조/백업 디스크( $SECOND_DISK )를 Linux LVM 파티션으로 전체 할당 완료."

    # 보조 디스크 새 파티션 이름 자동 탐색
    PARTITION=$(lsblk -nr -o NAME /dev/$SECOND_DISK | grep -v "^$SECOND_DISK$" | tail -n1)
    PARTITION="/dev/$PARTITION"

    # pv, vg, lv 생성(보조 디스크)
    pvcreate --yes "$PARTITION"
    vgcreate $VG_DATA "$PARTITION"
    lvcreate -l 100%FREE -T $VG_DATA/$LV_DATA
    pvesm add lvmthin $LVM_DATA --vgname $VG_DATA --thinpool $LV_DATA --content images,rootdir
    log "pv/vg/lv까지 자동 생성 완료: pv($PARTITION), vg($VG_DATA), lv($VG_DATA/$LV_DATA)"
  elif [[ "$SECOND_TYPE" == "2" ]]; then
    parted /dev/$SECOND_DISK --script mkpart primary ext4 0% 100%
    partprobe /dev/$SECOND_DISK
    udevadm trigger
    log "보조/백업 디스크( $SECOND_DISK )를 Directory(ext4) 파티션으로 전체 할당 완료."

    # 보조 디스크 새 파티션 이름 자동 탐색
    PARTITION=$(lsblk -nr -o NAME /dev/$SECOND_DISK | grep -v "^$SECOND_DISK$" | tail -n1)
    PARTITION="/dev/$PARTITION"
    MOUNT_PATH="/mnt/$DIR_NAME"
    
    # 마운트경로 생성 및 파티션 ext4로 초기화
    mkdir -p "$MOUNT_PATH" >/dev/null 2>&1
    mkfs.ext4 "$PARTITION" >/dev/null 2>&1
    
    # 실제 UUID 값 조회
    UUID=$(blkid -s UUID -o value "$PARTITION")
    if [ -z "$UUID" ]; then
      err "UUID를 찾을 수 없습니다: $PARTITION"
      exit 1
    fi
    
    # 이미 /etc/fstab에 같은 UUID가 등록되어있는지 체크
    if ! grep -qs "UUID=$UUID $MOUNT_PATH" /etc/fstab; then
      echo "UUID=$UUID $MOUNT_PATH ext4 defaults 0 2" | tee -a /etc/fstab
    fi
    systemctl daemon-reload
    mount -a
    log "$PARTITION (UUID=$UUID)를 $MOUNT_PATH로 마운트 완료"
    
    # Proxmox 디렉터리 스토리지 등록
    pvesm add dir "$DIR_NAME" --path "$MOUNT_PATH" --content images,backup,rootdir
    log "Proxmox에서 디렉터리 스토리지 ($DIR_NAME)로 등록됨"    
  else
    err "올바른 선택이 아닙니다."
    exit 1
  fi
else
  info "보조/백업 디스크 없이 진행합니다."
fi

log
log "===== 최종 파티션 상태 확인 ====="
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
