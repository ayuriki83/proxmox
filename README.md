# For Proxmox with Ubuntu, Synology

홈서버 구성을 위한 가이드!
- Proxmox
  - Ubuntu (with docker)
    - Docker Caddy (Required)
    - Docker Portainer (Required)
    - Docker Rclone (Required)
    - Docker FF_Plex (Required)
    - Docker jellyfin (Optional)
    - Docker kavita (Optional)
    - Docker beszel (Optional)
    - Docker uptime-kuma (Optional)
    - Docker vaultwarden (Optional)
  - Synology
    - 컨테이너 (beszel agent, naverpaper)

## 파일목록 및 설명

| 파일 | 설명 |
| --- | --- |
| `proxmox.env` | 환경설정 값 관리 |
| `proxmox_init.sh` | Proxmox 설치 후 초기 설정 값 대응 |
| `proxmox_partition.sh` | Proxmox 파티셔닝 |
| `ubuntu_init.sh` | Ubuntu 컨테이너 생성 및 기본 설정 |
| --- | --- |
| `docker.env` | Docker 관련 환경설정 |
| `docker.nfo` | Docker compose 및 caddy 적용 템플릿 |
| `docker.sh` | Docker 서비스 생성 및 caddy 환경설정 생성 |
| `caddy_setup.sh` | Docker Caddy 서브도메인 추가/삭제기능  |

### Step0. 사전작업
```
echo "alias ls='ls --color=auto --show-control-chars'" >> /root/.bashrc
echo "alias ll='ls -al --color=auto --show-control-chars'" >> /root/.bashrc
source /root/.bashrc

cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak && \
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" | tee /etc/apt/sources.list.d/pve-enterprise.list

cp /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.list.bak && \
echo "deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription" | tee /etc/apt/sources.list.d/ceph.list

apt update && apt upgrade -y
apt install curl wget htop tree rsync neofetch git vim parted nfs-common net-tools -y

mkdir -p /tmp/scripts && cd /tmp/scripts
curl -L -o pve.env https://raw.githubusercontent.com/ayuriki83/proxmox/main/pve.env
curl -L -o pve_init.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/pve_init.sh
curl -L -o pve_partition.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/pve_partition.sh
curl -L -o lxc_create.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/lxc_create.sh
curl -L -o lxc_init.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/lxc_init.sh
curl -L -o docker.env https://raw.githubusercontent.com/ayuriki83/proxmox/main/docker.env
curl -L -o docker.nfo https://raw.githubusercontent.com/ayuriki83/proxmox/main/docker.nfo
curl -L -o docker.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/docker.sh
curl -L -o caddy_setup.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/caddy_setup.sh
chmod +x pve_init.sh && chmod +x pve_partition.sh && chmod +x lxc_create.sh
```

### Step2. Proxmox 설치 후 초기 설정 값 대응
- root 사이즈 최대치 설정
- AppArmor 비활성화
- pve-filrewall 비활성화 및 ufw 활성화
- USB장치를 통한 백업 이용시 자동 마운트 (옵션)
- GPU 활성화
```
mkdir -p /tmp/scripts && cd /tmp/scripts
curl -L -o proxmox.conf https://raw.githubusercontent.com/ayuriki83/proxmox/main/proxmox.conf
curl -L -o init.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/init.sh
chmod +x *.sh
./init.sh
```

### Step3. Proxmox 파티셔닝
- 메인디스크 잔여용량 lvm-thin 모드로 생성
- 보조/백업 디스크 생성유형에 따른 처리 (보조모드로 헤놀로지 통 운영시 : lvm-thin, 백업모드로 운영시 : directory)
- parted 처리 및 pv/vg/lv/lvm 생성까지 처리
- 디렉토리 구성시 마운트 구성으로 대응
```
mkdir -p /tmp/proxmox && cd /tmp/proxmox
curl -L -o proxmox.conf https://raw.githubusercontent.com/ayuriki83/proxmox/main/proxmox.conf
curl -L -o init.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/partition.sh
chmod +x *.sh
./partition.sh
```

#### 메인디스크에 Proxmox를 제외한 나머지 삭제하는 방법
| 순번 | 설명 |
| --- | --- |
| A | pvesm -> vg -> pv 순으로 삭제해야함 |
| B | `cat /etc/pve/storage.cfg` 명령어를 통해 나오는 pvesm 목록에서 명칭(1)과 vgname(2)을 확인 |
| C | `pvs` 명령어를 통해 pv(3) 확인 |
| D | pvesm remove (1) |
| E | vgremove (2)    # vg삭제시 lv도 같이 삭제됨 |
| F | pvremove (3) |
| G | fdisk 에서 삭제 |

### Step4. Ubuntu 컨테이너 생성 및 기본 설정
- LXC Container (Ubunutu) 생성 (마운트 및 GPU연결 설정)
- 마운트 공간 초기설정
- LXC 시스템/패키지 업데이트 및 필수 구성요소 설치
- LXC AppArmor 제거
- LXC 한글 폰트 및 로케일 적용
- LXC 시간설정
- LXC GPU 설정
- LXC Docker 설치 및 Daemon 세팅, 브릿지 네트워크 설치
- LXC 방화벽 UFW 설정 (DOKCER 체인포함)
- LXC NAT/UFW rule적용 (DOCKER)
```
mkdir -p /tmp/proxmox && cd /tmp/proxmox
curl -L -o proxmox.conf https://raw.githubusercontent.com/ayuriki83/proxmox/main/proxmox.conf
curl -L -o ubuntu.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/ubuntu.sh
chmod +x *.sh
./ubuntu.sh
```

### Step5. Docker Caddy 세팅 및 서브도메인 관리기능
- docker compose 자동생성
- caddyfile 초기 설정
- 서비스 블럭 (서브도메인) 추가
- 서비스 블럭 (서브도메인) 삭제
```
pct enter 101    # 우분투 접속 (ID 101 인 경우)
mkdir -p /tmp/proxmox && cd /tmp/proxmox
curl -L -o proxmox.conf https://raw.githubusercontent.com/ayuriki83/proxmox/main/proxmox.conf
curl -L -o caddy_setup.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/caddy_setup.sh
chmod +x *.sh
./caddy_setup.sh
```
