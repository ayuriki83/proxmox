#!/bin/bash

##########################
# Proxmox Disk Partition 자동화
# 요구: parted 기반 (GPT, Linux LVM 또는 Directory 타입 자동 생성)
##########################

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
start_pos="${last_end}MiB"
end_pos="100%"
echo "새 파티션 시작 위치: $start_pos, 종료 위치: $end_pos"

# 실제 parted 파티션 생성
parted /dev/$MAIN_DISK --script mkpart lvm $start_pos $end_pos
new_part_num=$(($last_part_num+1))
new_part="/dev/${MAIN_DISK}p${new_part_num}"

# LVM 플래그 설정
parted /dev/$MAIN_DISK --script set $new_part_num lvm on
echo "새 파티션 $new_part 생성 및 LVM 플래그 적용 완료."

# pv, vg, lv 자동 생성
pvcreate "$new_part"
vgcreate vg-data "$new_part"
lvcreate -l 100%FREE -T vg-data/lv-data

echo "pv/vg/lv까지 자동 생성 완료: pv($new_part), vg(vg-data), lv(vg-data/lv-data)"

echo "==== 보조/백업 디스크 선택 (미선택시 Enter) ===="
lsblk -o NAME,SIZE,TYPE
read -p "보조/백업 디스크명 입력(ex: nvme1n1, sdb, skip=Enter): " SECOND_DISK

if [ -n "$SECOND_DISK" ]; then
  read -p "보조/백업 디스크 파티션 유형 선택 1:LinuxLVM 2:Directory [1/2]: " SECOND_TYPE

  if [[ "$SECOND_TYPE" == "1" ]]; then
    parted /dev/$SECOND_DISK --script mklabel gpt
    parted /dev/$SECOND_DISK --script mkpart lvm 0% 100%
    parted /dev/$SECOND_DISK --script set 1 lvm on
    echo "보조/백업 디스크( $SECOND_DISK )를 Linux LVM 파티션으로 전체 할당 완료."
  elif [[ "$SECOND_TYPE" == "2" ]]; then
    parted /dev/$SECOND_DISK --script mklabel gpt
    parted /dev/$SECOND_DISK --script mkpart primary ext4 0% 100%
    echo "보조/백업 디스크( $SECOND_DISK )를 Directory(ext4) 파티션으로 전체 할당 완료."
  else
    echo "올바른 선택이 아닙니다."
    exit 1
  fi
else
  echo "보조/백업 디스크 없이 진행합니다."
fi

echo "==== 최종 파티션 상태 확인 ===="
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

echo "필요 시 pvcreate/vgcreate 등의 후속 작업을 진행하세요."
