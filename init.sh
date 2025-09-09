echo "Root resizing..."
lvresize -l +100%FREE /dev/pve/root
resize2fs /dev/mapper/pve-root
echo "Root resized"

# 기존 저장소 파일 백업 및 신규 추가
cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak && \
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" | tee /etc/apt/sources.list.d/pve-enterprise.list

cp /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.list.bak && \
echo "deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription" | tee /etc/apt/sources.list.d/ceph.list

# 시스템 업데이트
apt update && apt upgrade -y

# 필수 도구 설치
apt install curl wget htop tree rsync neofetch git vim parted nfs-common net-tools -y

# 영구 alias 설정 (.bashrc에 입력)
vi ~/.bashrc
alias ll='ls -lah --color=auto'           # ll 적용
source ~/.bashrc                          # 즉시 적용

# ApprArmor 오류 방지
systemctl stop apparmor
systemctl disable apparmor
systemctl mask apparmor

# USB 마운트
mkdir /mnt/usb-backup
echo "/dev/sda1 /mnt/usb-backup ext4 defaults 0 0" >> /etc/fstab
systemctl daemon-reload
# CLI 명령어
pvesm add dir usb-backup --path /mnt/usb-backup --content images,iso,vztmpl,backup,rootdir
# Proxmox 화면 처리
Datacenter 클릭 > Storage 클릭 > Add 클릭 > Directory 클릭
- ID : 표기되는 명칭 (usb-backup)
- Directory : 마운트 된 경로 (/mnt/usb-backup)
- Content : 전부 다 체크 (Snippets,Import 제외하고)

# 방화벽 설정
# iptable 사용안하고 ufw로만 관리하도록 함
systemctl stop pve-firewall
systemctl disable pve-firewall

apt install ufw
ufw allow 22                    # SSH
ufw allow 8006                  # Proxmox Web UI
ufw allow 45876                 # beszel agent
ufw allow from 192.168.0.0/16   # 내부망
ufw enable                      # ufw 활성화
ufw status
