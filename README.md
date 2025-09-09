# For Proxmox with AMD 5825u

개인 서버 환경 구성을 위한 스크립트 모음입니다.

## 스크립트 목록 및 설명

| 스크립트 파일 | 설명 |
| --- | --- |
| `init.sh` | Proxmox 설치 후 초기 설정 값 대응 |



### 스크립트 실행
각 스크립트는 저장소를 클론한 후 직접 실행하거나, curl로 바로 다운로드하여 사용할 수 있습니다.

#### 방법 1: 저장소 클론 후 실행
```bash
git clone https://github.com/ayuriki83/proxmox.git
cd proxmox
chmod +x *.sh
# 원하는 스크립트 실행
./init.sh
```

#### 방법 2: 스크립트 직접 다운로드 및 실행
```bash
# Xpenology VM 자동 설치
curl -o pve_xpenol_install.sh https://raw.githubusercontent.com/ayuriki83/proxmox/main/pve_xpenol_install.sh
chmod +x pve_xpenol_install.sh
./pve_xpenol_install.sh
```
