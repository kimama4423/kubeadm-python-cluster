#!/bin/bash
# setup/install-kubernetes.sh
# Kubernetes (kubeadm, kubectl, kubelet) 自動インストールスクリプト

set -euo pipefail

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# グローバル変数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/kubernetes-install.log"
BACKUP_DIR="$SCRIPT_DIR/k8s-backup-$(date +%Y%m%d_%H%M%S)"
EXIT_CODE=0

# Kubernetes設定
KUBERNETES_VERSION="1.28"
KUBERNETES_PATCH_VERSION="1.28.2-1.1"
CGROUP_DRIVER="systemd"

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}Kubernetes Installation Script${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting Kubernetes installation"
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
}

# 既存Kubernetesの確認
check_existing_kubernetes() {
    print_status "INFO" "Checking for existing Kubernetes installation..."
    
    local existing_tools=()
    
    if command -v kubeadm >/dev/null 2>&1; then
        local kubeadm_version=$(kubeadm version -o short 2>/dev/null || echo "unknown")
        existing_tools+=("kubeadm: $kubeadm_version")
    fi
    
    if command -v kubectl >/dev/null 2>&1; then
        local kubectl_version=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo "unknown")
        existing_tools+=("kubectl: $kubectl_version")
    fi
    
    if command -v kubelet >/dev/null 2>&1; then
        local kubelet_version=$(kubelet --version 2>/dev/null | awk '{print $2}' || echo "unknown")
        existing_tools+=("kubelet: $kubelet_version")
    fi
    
    if [[ ${#existing_tools[@]} -gt 0 ]]; then
        print_status "WARNING" "Existing Kubernetes components found:"
        for tool in "${existing_tools[@]}"; do
            echo "  - $tool"
        done
        
        echo ""
        echo "Options:"
        echo "1) Continue and upgrade Kubernetes"
        echo "2) Skip Kubernetes installation"
        echo "3) Backup and clean install"
        echo "4) Exit"
        
        read -p "Choose option [1-4]: " choice
        case $choice in
            1)
                print_status "INFO" "Proceeding with Kubernetes upgrade"
                ;;
            2)
                print_status "INFO" "Skipping Kubernetes installation"
                return 1
                ;;
            3)
                print_status "INFO" "Backing up existing Kubernetes configuration"
                backup_existing_kubernetes
                uninstall_existing_kubernetes
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
        print_status "SUCCESS" "No existing Kubernetes installation found"
    fi
}

# 既存Kubernetesのバックアップ
backup_existing_kubernetes() {
    print_status "INFO" "Creating backup of existing Kubernetes configuration..."
    mkdir -p "$BACKUP_DIR"
    
    # kubectl設定のバックアップ
    if [[ -d "$HOME/.kube" ]]; then
        cp -r "$HOME/.kube" "$BACKUP_DIR/kube-user-config" 2>/dev/null || true
        log "Backed up user kubectl configuration"
    fi
    
    # システム設定のバックアップ
    if [[ -d /etc/kubernetes ]]; then
        sudo cp -r /etc/kubernetes "$BACKUP_DIR/kubernetes-system-config" 2>/dev/null || true
        log "Backed up system Kubernetes configuration"
    fi
    
    # kubeletサービス設定
    if [[ -f /etc/systemd/system/kubelet.service.d/10-kubeadm.conf ]]; then
        sudo cp /etc/systemd/system/kubelet.service.d/10-kubeadm.conf "$BACKUP_DIR/" 2>/dev/null || true
        log "Backed up kubelet service configuration"
    fi
    
    print_status "SUCCESS" "Backup created at: $BACKUP_DIR"
}

# 既存Kubernetesのアンインストール
uninstall_existing_kubernetes() {
    print_status "INFO" "Removing existing Kubernetes installation..."
    
    # サービス停止
    sudo systemctl stop kubelet 2>/dev/null || true
    
    case "$OS_ID" in
        ubuntu|debian)
            sudo apt-get remove -y kubeadm kubectl kubelet kubernetes-cni 2>/dev/null || true
            sudo apt-get purge -y kubeadm kubectl kubelet kubernetes-cni 2>/dev/null || true
            ;;
        centos|rhel|fedora)
            sudo yum remove -y kubeadm kubectl kubelet kubernetes-cni 2>/dev/null || true
            ;;
    esac
    
    # 設定ディレクトリの削除（オプション）
    read -p "Remove Kubernetes configuration directories? [y/N]: " remove_config
    if [[ "$remove_config" =~ ^[Yy]$ ]]; then
        sudo rm -rf /etc/kubernetes
        sudo rm -rf /var/lib/kubelet
        sudo rm -rf /var/lib/etcd
        print_status "WARNING" "Kubernetes configuration directories removed"
    fi
    
    print_status "SUCCESS" "Existing Kubernetes installation removed"
}

# システム要件チェック
check_system_requirements() {
    print_status "INFO" "Checking system requirements for Kubernetes..."
    
    # メモリチェック
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $mem_gb -lt 2 ]]; then
        print_status "ERROR" "Insufficient memory: ${mem_gb}GB (minimum 2GB required)"
        return 1
    else
        print_status "SUCCESS" "Memory check passed: ${mem_gb}GB"
    fi
    
    # CPUチェック
    local cpu_cores=$(nproc)
    if [[ $cpu_cores -lt 2 ]]; then
        print_status "WARNING" "Limited CPU cores: ${cpu_cores} (2+ recommended)"
    else
        print_status "SUCCESS" "CPU check passed: ${cpu_cores} cores"
    fi
    
    # Dockerチェック
    if ! command -v docker >/dev/null 2>&1; then
        print_status "ERROR" "Docker not found. Please install Docker first"
        echo "Run: ./install-docker.sh"
        return 1
    else
        local docker_version=$(docker --version | awk '{print $3}' | sed 's/,//')
        print_status "SUCCESS" "Docker found: $docker_version"
    fi
    
    # ネットワークチェック
    local required_hosts=("packages.cloud.google.com" "apt.kubernetes.io" "registry.k8s.io")
    for host in "${required_hosts[@]}"; do
        if timeout 5 bash -c "</dev/tcp/$host/443" 2>/dev/null; then
            log "Network connectivity to $host: OK"
        else
            print_status "WARNING" "Cannot reach $host (may affect installation)"
        fi
    done
}

# swapの無効化
disable_swap() {
    print_status "INFO" "Disabling swap (Kubernetes requirement)..."
    
    # 現在のswap状況確認
    local swap_total=$(free | awk '/^Swap:/{print $2}')
    
    if [[ $swap_total -eq 0 ]]; then
        print_status "SUCCESS" "Swap already disabled"
        return 0
    fi
    
    # 一時的にswap無効化
    sudo swapoff -a
    print_status "INFO" "Swap temporarily disabled"
    
    # fstabからswapエントリを削除
    if grep -q swap /etc/fstab; then
        # バックアップ作成
        sudo cp /etc/fstab /etc/fstab.backup-$(date +%Y%m%d_%H%M%S)
        
        # swapエントリをコメントアウト
        sudo sed -i '/swap/s/^/#/' /etc/fstab
        print_status "SUCCESS" "Swap permanently disabled in /etc/fstab"
    else
        print_status "INFO" "No swap entries found in /etc/fstab"
    fi
    
    # 確認
    if [[ $(free | awk '/^Swap:/{print $2}') -eq 0 ]]; then
        print_status "SUCCESS" "Swap successfully disabled"
    else
        print_status "ERROR" "Failed to disable swap"
        return 1
    fi
}

# カーネルモジュール設定
configure_kernel_modules() {
    print_status "INFO" "Configuring kernel modules for Kubernetes..."
    
    # 必要なモジュール
    local modules=("overlay" "br_netfilter")
    
    # モジュールロード
    for module in "${modules[@]}"; do
        if ! lsmod | grep -q "^$module"; then
            sudo modprobe "$module"
            log "Loaded kernel module: $module"
        else
            log "Kernel module already loaded: $module"
        fi
    done
    
    # 永続化設定
    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    
    print_status "SUCCESS" "Kernel modules configured"
}

# sysctl設定
configure_sysctl() {
    print_status "INFO" "Configuring sysctl parameters for Kubernetes..."
    
    # sysctl設定
    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    
    # 設定適用
    sudo sysctl --system >/dev/null 2>&1
    
    print_status "SUCCESS" "sysctl parameters configured"
}

# cgroup設定
configure_cgroup() {
    print_status "INFO" "Configuring cgroup driver..."
    
    # Dockerのcgroup driver確認
    local docker_cgroup_driver
    if command -v docker >/dev/null 2>&1; then
        docker_cgroup_driver=$(docker info 2>/dev/null | grep "Cgroup Driver" | awk '{print $3}' || echo "unknown")
        log "Docker cgroup driver: $docker_cgroup_driver"
    fi
    
    # kubeletのcgroup driver設定
    sudo mkdir -p /etc/systemd/system/kubelet.service.d
    
    cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/20-cgroup-driver.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=$CGROUP_DRIVER"
EOF
    
    print_status "SUCCESS" "cgroup driver configured: $CGROUP_DRIVER"
}

# Kubernetesリポジトリ追加
add_kubernetes_repository() {
    print_status "INFO" "Adding Kubernetes repository..."
    
    case "$OS_ID" in
        ubuntu|debian)
            # GPGキーの追加
            curl -fsSL https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
            
            # リポジトリの追加
            echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
            
            # パッケージリスト更新
            sudo apt-get update
            ;;
        centos|rhel)
            # リポジトリ設定
            cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
            ;;
        fedora)
            # Fedora用リポジトリ設定
            cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v$KUBERNETES_VERSION/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
            ;;
    esac
    
    print_status "SUCCESS" "Kubernetes repository added"
}

# Kubernetesツールのインストール
install_kubeadm_tools() {
    print_status "INFO" "Installing Kubernetes tools..."
    
    case "$OS_ID" in
        ubuntu|debian)
            install_kubeadm_tools_ubuntu
            ;;
        centos|rhel)
            install_kubeadm_tools_centos
            ;;
        fedora)
            install_kubeadm_tools_fedora
            ;;
    esac
    
    print_status "SUCCESS" "Kubernetes tools installed"
}

install_kubeadm_tools_ubuntu() {
    print_status "INFO" "Installing Kubernetes tools on Ubuntu/Debian..."
    
    # 利用可能なバージョンを確認
    local available_versions=$(apt-cache madison kubeadm | grep "$KUBERNETES_VERSION" | awk '{print $3}' | head -5)
    log "Available Kubernetes versions: $available_versions"
    
    # 特定バージョンのインストール
    if apt-cache madison kubeadm | grep -q "$KUBERNETES_PATCH_VERSION"; then
        sudo apt-get install -y \
            kubelet="$KUBERNETES_PATCH_VERSION" \
            kubeadm="$KUBERNETES_PATCH_VERSION" \
            kubectl="$KUBERNETES_PATCH_VERSION"
        print_status "SUCCESS" "Kubernetes $KUBERNETES_PATCH_VERSION installed"
    else
        print_status "WARNING" "Specific patch version not found, installing latest $KUBERNETES_VERSION"
        local latest_version=$(apt-cache madison kubeadm | grep "$KUBERNETES_VERSION" | awk '{print $3}' | head -1)
        sudo apt-get install -y \
            kubelet="$latest_version" \
            kubeadm="$latest_version" \
            kubectl="$latest_version"
    fi
    
    # パッケージ固定
    sudo apt-mark hold kubelet kubeadm kubectl
    print_status "INFO" "Kubernetes packages marked as held"
}

install_kubeadm_tools_centos() {
    print_status "INFO" "Installing Kubernetes tools on CentOS/RHEL..."
    
    # SELinuxをpermissiveに設定
    if command -v getenforce >/dev/null 2>&1; then
        sudo setenforce 0 2>/dev/null || true
        sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
        print_status "INFO" "SELinux set to permissive mode"
    fi
    
    # Kubernetesツールのインストール
    sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
    
    print_status "SUCCESS" "Kubernetes tools installed"
}

install_kubeadm_tools_fedora() {
    print_status "INFO" "Installing Kubernetes tools on Fedora..."
    
    sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
    
    print_status "SUCCESS" "Kubernetes tools installed"
}

# kubeletサービス有効化
enable_kubelet_service() {
    print_status "INFO" "Enabling kubelet service..."
    
    # systemd設定再読込み
    sudo systemctl daemon-reload
    
    # kubelet有効化（ただし開始はしない）
    sudo systemctl enable kubelet
    
    print_status "SUCCESS" "kubelet service enabled"
    print_status "INFO" "kubelet will start after kubeadm init"
}

# インストール検証
verify_installation() {
    print_status "INFO" "Verifying Kubernetes installation..."
    
    # kubeadmバージョン確認
    if command -v kubeadm >/dev/null 2>&1; then
        local kubeadm_version=$(kubeadm version -o short)
        print_status "SUCCESS" "kubeadm version: $kubeadm_version"
    else
        print_status "ERROR" "kubeadm not found"
        return 1
    fi
    
    # kubectlバージョン確認
    if command -v kubectl >/dev/null 2>&1; then
        local kubectl_version=$(kubectl version --client --short 2>/dev/null || kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion')
        print_status "SUCCESS" "kubectl version: $kubectl_version"
    else
        print_status "ERROR" "kubectl not found"
        return 1
    fi
    
    # kubeletサービス状態確認
    if sudo systemctl is-enabled kubelet >/dev/null 2>&1; then
        print_status "SUCCESS" "kubelet service enabled"
    else
        print_status "ERROR" "kubelet service not enabled"
        return 1
    fi
    
    # kubeadm設定チェック
    if kubeadm config print init-defaults >/dev/null 2>&1; then
        print_status "SUCCESS" "kubeadm configuration check passed"
    else
        print_status "WARNING" "kubeadm configuration check failed (may be normal)"
    fi
    
    # システム設定確認
    local swap_status=$(free | awk '/^Swap:/{print $2}')
    if [[ $swap_status -eq 0 ]]; then
        print_status "SUCCESS" "Swap is disabled"
    else
        print_status "ERROR" "Swap is still enabled"
        return 1
    fi
}

# コマンド補完設定
setup_command_completion() {
    print_status "INFO" "Setting up kubectl command completion..."
    
    # bash補完
    if [[ -n "${BASH_VERSION:-}" ]]; then
        # システム全体の補完
        kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null
        
        # ユーザー固有の補完
        if [[ ! -f "$HOME/.bashrc" ]] || ! grep -q "kubectl completion" "$HOME/.bashrc"; then
            echo 'source <(kubectl completion bash)' >> "$HOME/.bashrc"
            echo 'alias k=kubectl' >> "$HOME/.bashrc"
            echo 'complete -F __start_kubectl k' >> "$HOME/.bashrc"
        fi
        
        print_status "SUCCESS" "kubectl bash completion configured"
    fi
    
    # kubeadm補完も設定
    if command -v kubeadm >/dev/null 2>&1; then
        kubeadm completion bash | sudo tee /etc/bash_completion.d/kubeadm > /dev/null
        print_status "SUCCESS" "kubeadm bash completion configured"
    fi
}

# ロールバック機能
rollback_installation() {
    print_status "WARNING" "Rolling back Kubernetes installation..."
    
    if [[ -d "$BACKUP_DIR" ]]; then
        print_status "INFO" "Restoring from backup: $BACKUP_DIR"
        
        # 設定ファイルの復元
        if [[ -d "$BACKUP_DIR/kube-user-config" ]]; then
            cp -r "$BACKUP_DIR/kube-user-config" "$HOME/.kube" 2>/dev/null || true
        fi
        
        if [[ -d "$BACKUP_DIR/kubernetes-system-config" ]]; then
            sudo cp -r "$BACKUP_DIR/kubernetes-system-config" /etc/kubernetes 2>/dev/null || true
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
    
    # Kubernetesインストールプロセス
    detect_os
    check_existing_kubernetes || {
        print_status "INFO" "Skipping Kubernetes installation as requested"
        exit 0
    }
    
    # エラーハンドリング設定
    trap 'rollback_installation' ERR
    
    check_system_requirements
    disable_swap
    configure_kernel_modules
    configure_sysctl
    configure_cgroup
    add_kubernetes_repository
    install_kubeadm_tools
    enable_kubelet_service
    setup_command_completion
    verify_installation
    
    echo -e "\n${BLUE}=== Installation Summary ===${NC}"
    print_status "SUCCESS" "Kubernetes installation completed successfully!"
    
    echo ""
    echo "Installed versions:"
    kubeadm version -o short
    kubectl version --client --short 2>/dev/null || kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion'
    
    echo ""
    echo "System configuration:"
    echo "- Swap: Disabled"
    echo "- cgroup driver: $CGROUP_DRIVER"
    echo "- kubelet: Enabled (will start after kubeadm init)"
    
    echo ""
    echo "Important notes:"
    echo "1. Kubernetes tools installed and configured"
    echo "2. kubelet service enabled but not started"
    echo "3. System configured for Kubernetes (swap disabled, kernel modules, sysctl)"
    echo "4. kubectl command completion configured"
    echo "5. Log file: $LOG_FILE"
    
    if [[ -d "$BACKUP_DIR" ]]; then
        echo "6. Backup directory: $BACKUP_DIR"
    fi
    
    echo ""
    echo "Next step: Run ./init-cluster.sh to initialize the Kubernetes cluster"
    
    exit 0
}

# 引数処理
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  -h, --help              Show this help message"
        echo "  --uninstall             Uninstall existing Kubernetes"
        echo "  --version VERSION       Specify Kubernetes version (default: $KUBERNETES_VERSION)"
        echo "  --cgroup-driver DRIVER  Specify cgroup driver (default: $CGROUP_DRIVER)"
        exit 0
        ;;
    --uninstall)
        detect_os
        backup_existing_kubernetes
        uninstall_existing_kubernetes
        print_status "SUCCESS" "Kubernetes uninstallation completed"
        exit 0
        ;;
    --version)
        KUBERNETES_VERSION="${2:-$KUBERNETES_VERSION}"
        KUBERNETES_PATCH_VERSION="${2:-$KUBERNETES_PATCH_VERSION}"
        shift 2
        ;;
    --cgroup-driver)
        CGROUP_DRIVER="${2:-$CGROUP_DRIVER}"
        shift 2
        ;;
esac

# メイン実行
main "$@"