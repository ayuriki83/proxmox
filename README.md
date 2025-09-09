# For Proxmox with AMD 5825u

개인 서버 환경 구성을 위한 스크립트 모음입니다.

## 스크립트 목록 및 설명

| 스크립트 파일 | 설명 |
| --- | --- |
| `init.sh` | Proxmox 설치 후 초기 설정 값 대응 |

### Step1. Proxmox Repository 변경 및 업데이트
```
cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak && \
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" | tee /etc/apt/sources.list.d/pve-enterprise.list

cp /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.list.bak && \
echo "deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription" | tee /etc/apt/sources.list.d/ceph.list

apt update && apt upgrade -y
```

### Step2. apt update 및 필수 도구 설치
```
apt install curl wget htop tree rsync neofetch git vim parted nfs-common net-tools -y
```

### Step3. proxmox 기본 설정파일 실행
```bash
# 
mkdir -p /opt/proxmox & cd /opt/proxmox
curl -o init.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/init.sh
chmod +x init.sh
./init.sh
```
