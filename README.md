# For Proxmox with AMD 5825u

홈서버 구성을 위한 가이드!
- Ubuntu (with docker)
- 헤놀로지 VM
- rclone

## 스크립트 목록 및 설명

| 스크립트 파일 | 설명 |
| --- | --- |
| `init.sh` | Proxmox 설치 후 초기 설정 값 대응 |
| `partition.sh` | Proxmox 디스크 파티셔닝 및 PV, VG, LV, LVM 세팅 적용 |

### Step0. alias 적용
```
echo "alias ls='ls --color=auto --show-control-chars'" >> ~/.bashrc
echo "alias l='ls -al --color=auto --show-control-chars'" >> ~/.bashrc
echo "alias ll='ls -al --color=auto --show-control-chars'" >> ~/.bashrc
source ~/.bashrc
```

### Step1. Proxmox Repository 변경 및 APT 업데이트와 필수도구 설치
```
cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak && \
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" | tee /etc/apt/sources.list.d/pve-enterprise.list
```
```
cp /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.list.bak && \
echo "deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription" | tee /etc/apt/sources.list.d/ceph.list
```
```
apt update && apt upgrade -y
```
```
apt install curl wget htop tree rsync neofetch git vim parted nfs-common net-tools -y
```

### Step2. proxmox 기본 설정파일 실행
- root 사이즈 최대치 설정
- AppArmor 비활성화
- pve-filrewall 비활성화 및 ufw 활성화
- USB장치를 통한 백업 이용시 자동 마운트 (옵션)
- GPU 활성화
```
mkdir -p /tmp/proxmox && cd /tmp/proxmox
curl -L -o init.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/init.sh
chmod +x init.sh
./init.sh
```

### Step3. proxmox 파티셔닝
- 메인디스크 잔여용량 lvm-thin 모드로 생성
- 보조/백업 디스크 생성유형에 따른 처리 (보조모드로 헤놀로지 통 운영시 : lvm-thin, 백업모드로 운영시 : directory)
- parted 처리 및 pv/vg/lv/lvm 생성까지 처리
- 디렉토리 구성시 마운트 구성으로 대응
```
mkdir -p /tmp/proxmox && cd /tmp/proxmox
curl -L -o disk_env.config https://raw.githubusercontent.com/ayuriki83/proxmox/main/disk_env.config
curl -L -o init.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/partition.sh
chmod +x partition.sh
./partition.sh
```
