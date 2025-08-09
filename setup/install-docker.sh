#!/bin/bash
# setup/install-docker.sh
# Docker自動インストールスクリプト

set -euo pipefail

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# グローバル変数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/docker-install.log"
BACKUP_DIR="$SCRIPT_DIR/backup-$(date +%Y%m%d_%H%M%S)"
EXIT_CODE=0

# Docker設定
DOCKER_VERSION="24.0"
DOCKER_COMPOSE_VERSION="2.21.0"

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}Docker Installation Script${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting Docker installation"
}

print_status() {
    local status=$1
    local message=$2
    
    case $status in
        "INFO")
            echo -e "ℹ️  ${BLUE}$message${NC}"
            log "INFO: $message"
            ;;
        "SUCCESS")
            echo -e "✅ ${GREEN}$message${NC}"
            log "SUCCESS: $message"
            ;;
        "WARNING")
            echo -e "⚠️  ${YELLOW}$message${NC}"
            log "WARNING: $message"
            ;;
        "ERROR")
            echo -e "❌ ${RED}$message${NC}"
            log "ERROR: $message"
            EXIT_CODE=1
            ;;
    esac
}

# OS検出
detect_os() {
    print_status "INFO" "Detecting operating system..."
    
    if [[ ! -f /etc/os-release ]]; then
        print_status "ERROR" "Cannot detect OS (missing /etc/os-release)"
        exit 1
    fi
    
    source /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"
    OS_CODENAME="${VERSION_CODENAME:-}"
    
    log "Detected OS: $PRETTY_NAME"
    print_status "SUCCESS" "OS detected: $PRETTY_NAME"
    
    case "$OS_ID" in
        ubuntu|debian)
            if [[ "$OS_ID" == "ubuntu" && ! "$OS_VERSION" =~ ^(20\.04|22\.04)$ ]]; then
                print_status "WARNING" "Ubuntu version $OS_VERSION may not be fully supported"
            fi
            ;;
        centos|rhel|fedora)
            if [[ "$OS_ID" == "centos" && ! "$OS_VERSION" =~ ^[78]$ ]]; then
                print_status "WARNING" "CentOS version $OS_VERSION may not be fully supported"
            fi
            ;;
        *)
            print_status "WARNING" "OS $OS_ID may not be fully supported"
            ;;
    esac
}

# 既存Dockerの確認
check_existing_docker() {
    print_status "INFO" "Checking for existing Docker installation..."
    
    if command -v docker >/dev/null 2>&1; then
        local docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | sed 's/,//')
        print_status "WARNING" "Docker already installed: $docker_version"
        
        echo "Existing Docker installation detected."
        echo "Options:"
        echo "1) Continue and upgrade Docker"
        echo "2) Skip Docker installation"
        echo "3) Backup and clean install"
        echo "4) Exit"
        
        read -p "Choose option [1-4]: " choice
        case $choice in
            1)
                print_status "INFO" "Proceeding with Docker upgrade"
                ;;
            2)
                print_status "INFO" "Skipping Docker installation"
                return 1
                ;;
            3)
                print_status "INFO" "Backing up existing Docker configuration"
                backup_existing_docker
                uninstall_existing_docker
                ;;
            4)
                print_status "INFO" "Installation cancelled by user"
                exit 0
                ;;
            *)
                print_status "WARNING" "Invalid choice, proceeding with upgrade"
                ;;
        esac
    else
        print_status "SUCCESS" "No existing Docker installation found"
    fi
}

# 既存Dockerのバックアップ
backup_existing_docker() {
    print_status "INFO" "Creating backup of existing Docker configuration..."
    mkdir -p "$BACKUP_DIR"
    
    # Docker daemon設定のバックアップ
    if [[ -f /etc/docker/daemon.json ]]; then
        cp /etc/docker/daemon.json "$BACKUP_DIR/" 2>/dev/null || true
        log "Backed up /etc/docker/daemon.json"
    fi
    
    # Docker Composeファイルのバックアップ
    if [[ -d /opt/docker-compose ]]; then
        cp -r /opt/docker-compose "$BACKUP_DIR/" 2>/dev/null || true
        log "Backed up /opt/docker-compose"
    fi
    
    # ユーザーのDocker設定
    if [[ -d "$HOME/.docker" ]]; then
        cp -r "$HOME/.docker" "$BACKUP_DIR/docker-user-config" 2>/dev/null || true
        log "Backed up user Docker configuration"
    fi
    
    print_status "SUCCESS" "Backup created at: $BACKUP_DIR"
}

# 既存Dockerのアンインストール
uninstall_existing_docker() {
    print_status "INFO" "Removing existing Docker installation..."
    
    # Dockerサービス停止
    sudo systemctl stop docker 2>/dev/null || true
    sudo systemctl stop docker.socket 2>/dev/null || true
    sudo systemctl stop containerd 2>/dev/null || true
    
    case "$OS_ID" in
        ubuntu|debian)
            # 古いDockerパッケージの削除
            sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
            ;;
        centos|rhel|fedora)
            # 古いDockerパッケージの削除
            sudo yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
            sudo yum remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
            ;;
    esac
    
    # Docker関連ディレクトリの削除（オプション）
    read -p "Remove Docker data directories? (This will delete all containers and images) [y/N]: " remove_data
    if [[ "$remove_data" =~ ^[Yy]$ ]]; then
        sudo rm -rf /var/lib/docker
        sudo rm -rf /var/lib/containerd
        print_status "WARNING" "Docker data directories removed"
    fi
    
    print_status "SUCCESS" "Existing Docker installation removed"
}

# システムパッケージ更新
update_system_packages() {
    print_status "INFO" "Updating system packages..."
    
    case "$OS_ID" in
        ubuntu|debian)
            sudo apt-get update
            sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
            ;;
        centos|rhel)
            sudo yum update -y
            sudo yum install -y yum-utils device-mapper-persistent-data lvm2 curl
            ;;
        fedora)
            sudo dnf update -y
            sudo dnf install -y dnf-plugins-core curl
            ;;
    esac
    
    print_status "SUCCESS" "System packages updated"
}

# Docker GPGキーとリポジトリの追加
add_docker_repository() {
    print_status "INFO" "Adding Docker repository..."
    
    case "$OS_ID" in
        ubuntu|debian)
            # GPGキーの追加
            curl -fsSL https://download.docker.com/linux/$OS_ID/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            
            # リポジトリの追加
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS_ID $OS_CODENAME stable" | \
                sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # パッケージリスト更新
            sudo apt-get update
            ;;
        centos|rhel)
            # リポジトリの追加
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            ;;
        fedora)
            # リポジトリの追加
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            ;;
    esac
    
    print_status "SUCCESS" "Docker repository added"
}

# Dockerのインストール
install_docker_ubuntu() {
    print_status "INFO" "Installing Docker on Ubuntu/Debian..."
    
    # 利用可能なバージョンを確認
    local available_versions=$(apt-cache madison docker-ce | grep "$DOCKER_VERSION" | awk '{print $3}' | head -5)
    log "Available Docker versions: $available_versions"
    
    # 最新の指定バージョンをインストール
    local docker_version_full=$(apt-cache madison docker-ce | grep "$DOCKER_VERSION" | awk '{print $3}' | head -1)
    
    if [[ -n "$docker_version_full" ]]; then
        sudo apt-get install -y \
            docker-ce="$docker_version_full" \
            docker-ce-cli="$docker_version_full" \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
        print_status "SUCCESS" "Docker $docker_version_full installed"
    else
        print_status "WARNING" "Specific version $DOCKER_VERSION not found, installing latest"
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    
    # バージョン固定
    sudo apt-mark hold docker-ce docker-ce-cli containerd.io
    print_status "INFO" "Docker packages marked as held (auto-update disabled)"
}

install_docker_centos() {
    print_status "INFO" "Installing Docker on CentOS/RHEL..."
    
    # SELinux設定
    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
        sudo setsebool -P container_manage_cgroup on
        print_status "INFO" "SELinux configured for Docker"
    fi
    
    # Dockerインストール
    sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    print_status "SUCCESS" "Docker installed"
}

install_docker_fedora() {
    print_status "INFO" "Installing Docker on Fedora..."
    
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    print_status "SUCCESS" "Docker installed"
}

# Docker Composeスタンドアローンのインストール
install_docker_compose_standalone() {
    print_status "INFO" "Installing Docker Compose standalone..."
    
    local compose_url="https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)"
    
    # Docker Compose バイナリのダウンロード
    sudo curl -L "$compose_url" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    
    # シンボリックリンクの作成
    sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    
    # バージョン確認
    local installed_version
    if installed_version=$(docker-compose --version 2>/dev/null); then
        print_status "SUCCESS" "Docker Compose installed: $installed_version"
    else
        print_status "ERROR" "Docker Compose installation failed"
    fi
}

# Dockerサービスの設定
configure_docker_service() {
    print_status "INFO" "Configuring Docker service..."
    
    # systemd設定
    sudo systemctl enable docker
    sudo systemctl enable containerd
    
    # Dockerデーモン設定
    sudo mkdir -p /etc/docker
    
    cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "registry-mirrors": [],
  "insecure-registries": ["localhost:5000"],
  "live-restore": true
}
EOF
    
    # systemdデーモン再読込み
    sudo systemctl daemon-reload
    
    print_status "SUCCESS" "Docker service configured"
}

# ユーザーをdockerグループに追加
add_user_to_docker_group() {
    print_status "INFO" "Adding current user to docker group..."
    
    # dockerグループが存在するか確認
    if ! getent group docker >/dev/null 2>&1; then
        sudo groupadd docker
        log "Created docker group"
    fi
    
    # 現在のユーザーをdockerグループに追加
    sudo usermod -aG docker "$USER"
    
    print_status "SUCCESS" "User $USER added to docker group"
    print_status "WARNING" "Please log out and log back in for group changes to take effect"
    print_status "INFO" "Or run: newgrp docker"
}

# Dockerサービス開始
start_docker_service() {
    print_status "INFO" "Starting Docker service..."
    
    sudo systemctl start docker
    sudo systemctl start containerd
    
    # サービス状態確認
    if sudo systemctl is-active --quiet docker; then
        print_status "SUCCESS" "Docker service started successfully"
    else
        print_status "ERROR" "Failed to start Docker service"
        sudo systemctl status docker --no-pager
        return 1
    fi
}

# Dockerインストールテスト
test_docker_installation() {
    print_status "INFO" "Testing Docker installation..."
    
    # Docker バージョン確認
    local docker_version
    if docker_version=$(docker --version 2>/dev/null); then
        print_status "SUCCESS" "Docker version: $docker_version"
    else
        print_status "WARNING" "Docker command not accessible (may need to re-login)"
        # rootでテスト
        if sudo docker --version >/dev/null 2>&1; then
            docker_version=$(sudo docker --version)
            print_status "INFO" "Docker accessible with sudo: $docker_version"
        else
            print_status "ERROR" "Docker not accessible even with sudo"
            return 1
        fi
    fi
    
    # Docker Composeバージョン確認
    local compose_version
    if compose_version=$(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null); then
        print_status "SUCCESS" "Docker Compose: $compose_version"
    else
        print_status "WARNING" "Docker Compose not accessible"
    fi
    
    # Hello world テスト
    print_status "INFO" "Running Docker hello-world test..."
    
    local test_cmd="docker"
    if ! docker ps >/dev/null 2>&1; then
        print_status "WARNING" "Using sudo for Docker test (normal for first run)"
        test_cmd="sudo docker"
    fi
    
    if $test_cmd run --rm hello-world >/dev/null 2>&1; then
        print_status "SUCCESS" "Docker hello-world test passed"
    else
        print_status "ERROR" "Docker hello-world test failed"
        $test_cmd run --rm hello-world
        return 1
    fi
    
    # Dockerデーモン情報
    local docker_info
    if docker_info=$($test_cmd info --format '{{.ServerVersion}}' 2>/dev/null); then
        print_status "INFO" "Docker daemon version: $docker_info"
    fi
}

# ロールバック機能
rollback_installation() {
    print_status "WARNING" "Rolling back Docker installation..."
    
    if [[ -d "$BACKUP_DIR" ]]; then
        print_status "INFO" "Restoring from backup: $BACKUP_DIR"
        
        # 設定ファイルの復元
        if [[ -f "$BACKUP_DIR/daemon.json" ]]; then
            sudo cp "$BACKUP_DIR/daemon.json" /etc/docker/ 2>/dev/null || true
        fi
        
        print_status "INFO" "Backup restoration completed"
    fi
    
    print_status "ERROR" "Installation failed. Please check logs: $LOG_FILE"
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # Dockerインストールプロセス
    detect_os
    check_existing_docker || {
        print_status "INFO" "Skipping Docker installation as requested"
        exit 0
    }
    
    # エラーハンドリング設定
    trap 'rollback_installation' ERR
    
    update_system_packages
    add_docker_repository
    
    case "$OS_ID" in
        ubuntu|debian)
            install_docker_ubuntu
            ;;
        centos|rhel)
            install_docker_centos
            ;;
        fedora)
            install_docker_fedora
            ;;
    esac
    
    # Docker Compose スタンドアローン版もインストール
    install_docker_compose_standalone
    
    configure_docker_service
    add_user_to_docker_group
    start_docker_service
    test_docker_installation
    
    echo -e "\n${BLUE}=== Installation Summary ===${NC}"
    print_status "SUCCESS" "Docker installation completed successfully!"
    
    echo ""
    echo "Installed versions:"
    docker --version 2>/dev/null || sudo docker --version
    docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || true
    
    echo ""
    echo "Important notes:"
    echo "1. Please log out and log back in to use Docker without sudo"
    echo "2. Or run: newgrp docker"
    echo "3. Docker daemon configuration: /etc/docker/daemon.json"
    echo "4. Log file: $LOG_FILE"
    
    if [[ -d "$BACKUP_DIR" ]]; then
        echo "5. Backup directory: $BACKUP_DIR"
    fi
    
    echo ""
    echo "Next step: Run ./install-kubernetes.sh"
    
    exit 0
}

# 引数処理
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  -h, --help        Show this help message"
        echo "  --uninstall       Uninstall existing Docker"
        echo "  --version VERSION Specify Docker version (default: $DOCKER_VERSION)"
        exit 0
        ;;
    --uninstall)
        detect_os
        backup_existing_docker
        uninstall_existing_docker
        print_status "SUCCESS" "Docker uninstallation completed"
        exit 0
        ;;
    --version)
        DOCKER_VERSION="${2:-$DOCKER_VERSION}"
        shift 2
        ;;
esac

# メイン実行
main "$@"