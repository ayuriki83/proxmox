#!/bin/bash

##########################
# Proxmox Disk Partition 자동화
# 요구: parted 기반 (GPT, Linux LVM 또는 Directory 타입 자동 생성)
##########################

# 설정 파일 위치 지정 (스크립트와 같은 디렉토리 등)
CONFIG_FILE="./disk_env.config"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "설정 파일 $CONFIG_FILE 이(가) 없습니다. 기본값 사용."
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

echo "===== 메인 디스크(Linux LVM 잔여 공간) 파티션 생성 자동화 스크립트 ====="
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
read -p "메인 디스크명 입력(ex: nvme0n1, sda): " MAIN_DISK

if [ -z "$MAIN_DISK" ]; then
  echo "디스크명을 입력하세요."
  exit 1
fi

# 마지막 파티션 번호 자동 추출 (예: p3)
last_part_num=$(lsblk /dev/$MAIN_DISK | awk '/part/ {print $1}' | tail -n1 | grep -oP "${MAIN_DISK}p\K[0-9]+")
if [ -z "$last_part_num" ]; then
  echo "파티션 번호를 찾을 수 없습니다."
  exit 1
fi
echo "마지막 파티션 번호: $last_part_num (새 파티션은 $(($last_part_num+1))번)"

echo "메인 디스크의 현재 파티션 현황 및 빈 공간 확인:"
parted /dev/$MAIN_DISK print free

# 자동으로 마지막 파티션의 끝 위치를 MiB 단위로 가져옴
last_end=$(parted /dev/$MAIN_DISK unit MiB print | \
  awk '/^ / && $1 ~ /^[0-9]+$/ {end=$3} END {print end}' | sed 's/MiB//')
if [ -z "$last_end" ]; then
  echo "파티션 정보를 가져올 수 없습니다. 처음부터 생성한다고 가정하고 시작 위치 1MiB 적용"
  last_end=1
fi
START_POS=$(parted /dev/nvme0n1 print free | awk '/Free Space/ {start=$2; end=$3} END{print start}' | sed 's/GB//')
END_POS=$(parted /dev/nvme0n1 print free | awk '/Free Space/ {start=$2; end=$3} END{print end}' | sed 's/GB//')
#start_pos="${last_end}MiB"
#end_pos="100%"
echo "새 파티션 시작 위치: $START_POS, 종료 위치: $END_POS"

# 실제 parted 파티션 생성
parted /dev/$MAIN_DISK --script mkpart lvm $start_pos $end_pos
new_part_num=$(($last_part_num+1))
new_part="/dev/${MAIN_DISK}p${new_part_num}"
echo "$new_part"
echo "----------------"

# LVM 플래그 설정
parted /dev/$MAIN_DISK --script set $new_part_num lvm on
partprobe /dev/$MAIN_DISK
udevadm trigger
echo "새 파티션 $new_part 생성 및 LVM 플래그 적용 완료."

# pv, vg, lv 자동 생성
pvcreate "$new_part"
vgcreate $VG_MAIN "$new_part"
lvcreate -l 100%FREE -T $VG_MAIN/$LV_MAIN
pvesm add lvmthin $LVM_MAIN --vgname $VG_MAIN --thinpool $LV_MAIN --content images,rootdir
echo "pv/vg/lv까지 자동 생성 완료: pv($new_part), vg($VG_MAIN), lv($VG_MAIN/$LV_MAIN)"

echo "==== 보조/백업 디스크 선택 (미선택시 Enter) ===="
lsblk -o NAME,SIZE,TYPE
read -p "보조/백업 디스크명 입력(ex: nvme1n1, sdb, skip=Enter): " SECOND_DISK

if [ -n "$SECOND_DISK" ]; then
  read -p "보조/백업 디스크 파티션 유형 선택 1:LinuxLVM 2:Directory [1/2]: " SECOND_TYPE

  if [[ "$SECOND_TYPE" == "1" ]]; then
    parted /dev/$SECOND_DISK --script mklabel gpt
    parted /dev/$SECOND_DISK --script mkpart lvm 0% 100%
    parted /dev/$SECOND_DISK --script set 1 lvm on
    partprobe /dev/$SECOND_DISK
    udevadm trigger
    echo "보조/백업 디스크( $SECOND_DISK )를 Linux LVM 파티션으로 전체 할당 완료."

    # 보조 디스크 새 파티션 이름 자동 탐색
    PARTITION=$(lsblk /dev/$SECOND_DISK | awk '/part/ {print $1}' | tail -n1)
    PARTITION="/dev/$PARTITION"

    # pv, vg, lv 생성(보조 디스크)
    pvcreate "$PARTITION"
    vgcreate $VG_DATA "$PARTITION"
    lvcreate -l 100%FREE -T $VG_DATA/$LV_DATA
    pvesm add lvmthin $LVM_DATA --vgname $VG_DATA --thinpool $LV_DATA --content images,rootdir
    echo "pv/vg/lv까지 자동 생성 완료: pv($PARTITION), vg($VG_DATA), lv($VG_DATA/$LV_DATA)"
  elif [[ "$SECOND_TYPE" == "2" ]]; then
    parted /dev/$SECOND_DISK --script mklabel gpt
    parted /dev/$SECOND_DISK --script mkpart primary ext4 0% 100%
    partprobe /dev/$SECOND_DISK
    udevadm trigger
    echo "보조/백업 디스크( $SECOND_DISK )를 Directory(ext4) 파티션으로 전체 할당 완료."

    # 파티션명이 변수로 들어왔다고 가정 (예: /dev/nvme1n1p1)
    PARTITION=$(lsblk /dev/$SECOND_DISK | awk '/part/ {print $1}' | tail -n1)
    PARTITION="/dev/$PARTITION"
    MOUNT_PATH="/mnt/$DIRECTORY"
    
    # 실제 UUID 값 조회
    UUID=$(blkid -s UUID -o value "$PARTITION")
    if [ -z "$UUID" ]; then
      echo "UUID를 찾을 수 없습니다: $PARTITION"
      exit 1
    fi
    
    # 마운트경로 생성
    mkdir -p "$MOUNT_PATH"

    # Directory 지정 시 파티션을 ext4로 초기화
    mkfs.ext4 "$PARTITION"
    
    # 이미 /etc/fstab에 같은 UUID가 등록되어있는지 체크
    if ! grep -qs "UUID=$UUID $MOUNT_PATH" /etc/fstab; then
      echo "UUID=$UUID $MOUNT_PATH ext4 defaults 0 2" >> /etc/fstab
    fi
    systemctl daemon-reload
    mount -a
    echo "$PARTITION (UUID=$UUID)를 $MOUNT_PATH로 마운트 완료"
    
    # Proxmox 디렉터리 스토리지 등록
    pvesm add dir "$DIR_NAME" --path "$MOUNT_PATH" --content images,backup,rootdir
    echo "Proxmox에서 디렉터리 스토리지 ($DIR_NAME)로 등록됨"    
  else
    echo "올바른 선택이 아닙니다."
    exit 1
  fi
else
  echo "보조/백업 디스크 없이 진행합니다."
fi

echo "==== 최종 파티션 상태 확인 ===="
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
