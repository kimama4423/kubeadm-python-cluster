#!/bin/bash
# setup/init-cluster.sh
# Kubernetesクラスター初期化スクリプト

set -euo pipefail

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# グローバル変数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"
LOG_FILE="$SCRIPT_DIR/cluster-init.log"
BACKUP_DIR="$SCRIPT_DIR/cluster-backup-$(date +%Y%m%d_%H%M%S)"
EXIT_CODE=0

# クラスター設定
CLUSTER_NAME="kubeadm-python-cluster"
KUBECONFIG_PATH="$HOME/.kube/config"
JOIN_COMMAND_FILE="$SCRIPT_DIR/join-cluster-command.sh"

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}Kubernetes Cluster Initialization${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting Kubernetes cluster initialization"
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

# 前提条件チェック
check_prerequisites() {
    print_status "INFO" "Checking prerequisites for cluster initialization..."
    
    # kubeadmコマンドチェック
    if ! command -v kubeadm >/dev/null 2>&1; then
        print_status "ERROR" "kubeadm not found. Please run ./install-kubernetes.sh first"
        return 1
    fi
    
    # kubectlコマンドチェック
    if ! command -v kubectl >/dev/null 2>&1; then
        print_status "ERROR" "kubectl not found. Please run ./install-kubernetes.sh first"
        return 1
    fi
    
    # Dockerまたはcontainerdチェック
    if ! command -v docker >/dev/null 2>&1 && ! command -v containerd >/dev/null 2>&1; then
        print_status "ERROR" "Neither Docker nor containerd found. Please run ./install-docker.sh first"
        return 1
    fi
    
    # swapチェック
    local swap_total=$(free | awk '/^Swap:/{print $2}')
    if [[ $swap_total -ne 0 ]]; then
        print_status "ERROR" "Swap is enabled. Kubernetes requires swap to be disabled"
        return 1
    fi
    
    # kubeletサービスチェック
    if ! sudo systemctl is-enabled kubelet >/dev/null 2>&1; then
        print_status "ERROR" "kubelet service is not enabled. Please run ./install-kubernetes.sh first"
        return 1
    fi
    
    print_status "SUCCESS" "All prerequisites check passed"
}

# 既存クラスターチェック
check_existing_cluster() {
    print_status "INFO" "Checking for existing cluster..."
    
    # 既存のkubectl設定チェック
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        print_status "WARNING" "Existing kubectl config found: $KUBECONFIG_PATH"
        
        # クラスターへの接続テスト
        if kubectl cluster-info >/dev/null 2>&1; then
            print_status "WARNING" "Active Kubernetes cluster detected"
            
            echo ""
            echo "Existing cluster information:"
            kubectl cluster-info 2>/dev/null || true
            echo ""
            
            echo "Options:"
            echo "1) Reset existing cluster and reinitialize"
            echo "2) Skip initialization (keep existing cluster)"
            echo "3) Backup existing config and continue"
            echo "4) Exit"
            
            read -p "Choose option [1-4]: " choice
            case $choice in
                1)
                    print_status "INFO" "Resetting existing cluster..."
                    reset_existing_cluster
                    ;;
                2)
                    print_status "INFO" "Keeping existing cluster"
                    return 1
                    ;;
                3)
                    print_status "INFO" "Backing up existing configuration"
                    backup_existing_cluster
                    ;;
                4)
                    print_status "INFO" "Installation cancelled by user"
                    exit 0
                    ;;
                *)
                    print_status "WARNING" "Invalid choice, proceeding with backup"
                    backup_existing_cluster
                    ;;
            esac
        else
            print_status "WARNING" "kubectl config exists but cluster is not accessible"
            backup_existing_cluster
        fi
    else
        print_status "SUCCESS" "No existing cluster configuration found"
    fi
}

# 既存クラスターのリセット
reset_existing_cluster() {
    print_status "INFO" "Resetting existing Kubernetes cluster..."
    
    # クラスターリセット
    sudo kubeadm reset -f
    
    # iptablesルールをクリア
    sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
    
    # CNI設定削除
    sudo rm -rf /etc/cni/net.d
    
    # kubeletデータディレクトリクリア
    sudo rm -rf /var/lib/kubelet/*
    
    print_status "SUCCESS" "Existing cluster reset completed"
}

# 既存設定のバックアップ
backup_existing_cluster() {
    print_status "INFO" "Creating backup of existing cluster configuration..."
    mkdir -p "$BACKUP_DIR"
    
    # kubectl設定のバックアップ
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        cp "$KUBECONFIG_PATH" "$BACKUP_DIR/config"
        log "Backed up kubectl config"
    fi
    
    # Kubernetes設定のバックアップ
    if [[ -d /etc/kubernetes ]]; then
        sudo cp -r /etc/kubernetes "$BACKUP_DIR/kubernetes-system"
        sudo chown -R "$USER:$USER" "$BACKUP_DIR/kubernetes-system"
        log "Backed up system Kubernetes configuration"
    fi
    
    print_status "SUCCESS" "Backup created at: $BACKUP_DIR"
}

# kubeadm設定ファイル準備
create_kubeadm_config() {
    print_status "INFO" "Preparing kubeadm configuration..."
    
    # 現在のホスト情報取得
    local hostname=$(hostname)
    local primary_ip=$(ip route get 1.1.1.1 | awk '{print $7}' | head -1)
    local public_ip=""
    
    # パブリックIPの取得試行
    if command -v curl >/dev/null 2>&1; then
        public_ip=$(timeout 5 curl -s https://ipinfo.io/ip 2>/dev/null || echo "")
    fi
    
    log "Detected hostname: $hostname"
    log "Detected primary IP: $primary_ip"
    log "Detected public IP: ${public_ip:-'N/A'}"
    
    # 設定ファイルのカスタマイズ
    local config_file="$SCRIPT_DIR/kubeadm-config-custom.yaml"
    cp "$CONFIG_DIR/kubeadm-config.yaml" "$config_file"
    
    # IPアドレスの置換
    sed -i "s/advertiseAddress: \"0.0.0.0\"/advertiseAddress: \"$primary_ip\"/" "$config_file"
    
    # ホスト名の設定
    sed -i "s/name: \"\"/name: \"$hostname\"/" "$config_file"
    
    # 証明書SANsの追加
    if [[ -n "$public_ip" && "$public_ip" != "$primary_ip" ]]; then
        sed -i "/certSANs: \[\]/c\\  certSANs:\\n    - \"$primary_ip\"\\n    - \"$public_ip\"\\n    - \"$hostname\"\\n    - \"localhost\"\\n    - \"127.0.0.1\"" "$config_file"
    else
        sed -i "/certSANs: \[\]/c\\  certSANs:\\n    - \"$primary_ip\"\\n    - \"$hostname\"\\n    - \"localhost\"\\n    - \"127.0.0.1\"" "$config_file"
    fi
    
    print_status "SUCCESS" "kubeadm configuration prepared: $config_file"
    log "Configuration file: $config_file"
}

# コントロールプレーン初期化
init_control_plane() {
    print_status "INFO" "Initializing Kubernetes control plane..."
    
    local config_file="$SCRIPT_DIR/kubeadm-config-custom.yaml"
    
    # kubeadm init実行
    print_status "INFO" "Running kubeadm init (this may take several minutes)..."
    
    # kubeadm initの実行とログ保存
    if sudo kubeadm init --config="$config_file" --upload-certs 2>&1 | tee -a "$LOG_FILE"; then
        print_status "SUCCESS" "Control plane initialized successfully"
    else
        print_status "ERROR" "Failed to initialize control plane"
        return 1
    fi
    
    print_status "SUCCESS" "Kubernetes control plane initialization completed"
}

# kubectl設定
setup_kubectl_config() {
    print_status "INFO" "Setting up kubectl configuration..."
    
    # kubectl設定ディレクトリ作成
    mkdir -p "$HOME/.kube"
    
    # 設定ファイルのコピー
    if [[ -f /etc/kubernetes/admin.conf ]]; then
        sudo cp -i /etc/kubernetes/admin.conf "$KUBECONFIG_PATH"
        sudo chown "$USER:$USER" "$KUBECONFIG_PATH"
        chmod 600 "$KUBECONFIG_PATH"
        print_status "SUCCESS" "kubectl configuration set up"
    else
        print_status "ERROR" "admin.conf not found"
        return 1
    fi
    
    # 設定の検証
    if kubectl cluster-info >/dev/null 2>&1; then
        print_status "SUCCESS" "kubectl configuration verified"
    else
        print_status "ERROR" "kubectl configuration verification failed"
        return 1
    fi
}

# ワーカーノード参加用コマンド保存
save_join_command() {
    print_status "INFO" "Saving worker node join command..."
    
    # join-commandの生成
    local join_command
    if join_command=$(kubeadm token create --print-join-command 2>/dev/null); then
        
        # joinコマンドスクリプトの作成
        cat > "$JOIN_COMMAND_FILE" <<EOF
#!/bin/bash
# join-cluster-command.sh
# Worker node join command for kubeadm-python-cluster
# Generated on $(date)

echo "Joining worker node to kubeadm-python-cluster..."
echo "Make sure this script is run with sudo on the worker node"
echo ""

# Join command (run with sudo on worker node)
$join_command

echo ""
echo "After joining, verify the node:"
echo "kubectl get nodes"
EOF
        
        chmod +x "$JOIN_COMMAND_FILE"
        print_status "SUCCESS" "Join command saved: $JOIN_COMMAND_FILE"
        
        # トークン情報もログに保存
        log "Join command: $join_command"
        kubeadm token list 2>/dev/null | tee -a "$LOG_FILE" || true
        
    else
        print_status "WARNING" "Failed to generate join command automatically"
        print_status "INFO" "You can generate it later with: kubeadm token create --print-join-command"
    fi
}

# CNIプラグインのプリインストール確認
install_cni_plugin() {
    print_status "INFO" "Checking CNI plugin installation..."
    
    # Flannelのインストール
    print_status "INFO" "Installing Flannel CNI plugin..."
    
    local flannel_url="https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
    
    if kubectl apply -f "$flannel_url" 2>&1 | tee -a "$LOG_FILE"; then
        print_status "SUCCESS" "Flannel CNI plugin installed"
        
        # Flannel Podの起動待機
        print_status "INFO" "Waiting for Flannel pods to start..."
        local timeout=120
        local count=0
        
        while [[ $count -lt $timeout ]]; do
            if kubectl get pods -n kube-flannel | grep -q "Running"; then
                print_status "SUCCESS" "Flannel pods are running"
                break
            fi
            
            sleep 5
            ((count+=5))
            
            if [[ $((count % 30)) -eq 0 ]]; then
                print_status "INFO" "Still waiting for Flannel pods... ($count/${timeout}s)"
            fi
        done
        
        if [[ $count -ge $timeout ]]; then
            print_status "WARNING" "Timeout waiting for Flannel pods to start"
            print_status "INFO" "You may need to troubleshoot CNI installation manually"
        fi
        
    else
        print_status "ERROR" "Failed to install Flannel CNI plugin"
        return 1
    fi
}

# クラスター状態確認
verify_cluster_status() {
    print_status "INFO" "Verifying cluster status..."
    
    # クラスター情報
    print_status "INFO" "Cluster information:"
    kubectl cluster-info 2>&1 | tee -a "$LOG_FILE" || true
    
    # ノード状態
    print_status "INFO" "Node status:"
    kubectl get nodes -o wide 2>&1 | tee -a "$LOG_FILE" || true
    
    # システムPod状態
    print_status "INFO" "System pods status:"
    kubectl get pods -n kube-system 2>&1 | tee -a "$LOG_FILE" || true
    
    # CNI Pod状態
    print_status "INFO" "CNI pods status:"
    kubectl get pods -n kube-flannel 2>&1 | tee -a "$LOG_FILE" || true
    
    # ノードがReadyか確認
    local ready_nodes
    if ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready"); then
        if [[ $ready_nodes -gt 0 ]]; then
            print_status "SUCCESS" "Cluster has $ready_nodes Ready node(s)"
        else
            print_status "WARNING" "No Ready nodes found"
        fi
    else
        print_status "WARNING" "Could not check node status"
    fi
    
    # 基本的なクラスター機能テスト
    test_cluster_functionality
}

# クラスター機能テスト
test_cluster_functionality() {
    print_status "INFO" "Testing basic cluster functionality..."
    
    # テスト用の名前空間作成
    if kubectl create namespace cluster-test >/dev/null 2>&1; then
        print_status "SUCCESS" "Test namespace created"
        
        # 簡単なPodをデプロイしてテスト
        local test_pod_yaml=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cluster-test-pod
  namespace: cluster-test
spec:
  containers:
  - name: test-container
    image: busybox:1.35
    command: ['sleep', '30']
  restartPolicy: Never
EOF
)
        
        if echo "$test_pod_yaml" | kubectl apply -f - >/dev/null 2>&1; then
            print_status "INFO" "Test pod created, waiting for it to run..."
            
            # Pod起動待機
            local timeout=60
            local count=0
            
            while [[ $count -lt $timeout ]]; do
                local pod_status
                if pod_status=$(kubectl get pod cluster-test-pod -n cluster-test -o jsonpath='{.status.phase}' 2>/dev/null); then
                    if [[ "$pod_status" == "Running" || "$pod_status" == "Succeeded" ]]; then
                        print_status "SUCCESS" "Test pod is running ($pod_status)"
                        break
                    fi
                fi
                
                sleep 2
                ((count+=2))
            done
            
            # テスト用リソースの削除
            kubectl delete namespace cluster-test >/dev/null 2>&1 || true
            
            if [[ $count -lt $timeout ]]; then
                print_status "SUCCESS" "Basic cluster functionality test passed"
            else
                print_status "WARNING" "Test pod did not start within timeout"
            fi
        else
            print_status "WARNING" "Could not create test pod"
            kubectl delete namespace cluster-test >/dev/null 2>&1 || true
        fi
    else
        print_status "WARNING" "Could not create test namespace"
    fi
}

# クリーンアップ機能
cleanup_on_failure() {
    print_status "WARNING" "Initialization failed, performing cleanup..."
    
    # kubeadm reset
    sudo kubeadm reset -f >/dev/null 2>&1 || true
    
    # kubectl設定削除
    rm -f "$KUBECONFIG_PATH" 2>/dev/null || true
    
    # 一時ファイル削除
    rm -f "$SCRIPT_DIR/kubeadm-config-custom.yaml" 2>/dev/null || true
    
    print_status "ERROR" "Cleanup completed. Check logs: $LOG_FILE"
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # エラーハンドリング設定
    trap 'cleanup_on_failure' ERR
    
    # クラスター初期化プロセス
    check_prerequisites
    check_existing_cluster || {
        print_status "INFO" "Keeping existing cluster as requested"
        exit 0
    }
    
    create_kubeadm_config
    init_control_plane
    setup_kubectl_config
    save_join_command
    install_cni_plugin
    verify_cluster_status
    
    # 一時ファイル削除
    rm -f "$SCRIPT_DIR/kubeadm-config-custom.yaml" 2>/dev/null || true
    
    echo -e "\n${BLUE}=== Cluster Initialization Summary ===${NC}"
    print_status "SUCCESS" "Kubernetes cluster initialization completed successfully!"
    
    echo ""
    echo "Cluster information:"
    kubectl cluster-info
    
    echo ""
    echo "Node status:"
    kubectl get nodes
    
    echo ""
    echo "System pods:"
    kubectl get pods -n kube-system
    
    echo ""
    echo "Important files:"
    echo "- kubectl config: $KUBECONFIG_PATH"
    echo "- Join command: $JOIN_COMMAND_FILE"
    echo "- Log file: $LOG_FILE"
    
    if [[ -d "$BACKUP_DIR" ]]; then
        echo "- Backup directory: $BACKUP_DIR"
    fi
    
    echo ""
    echo "Next steps:"
    echo "1. To add worker nodes, copy and run: $JOIN_COMMAND_FILE"
    echo "2. To deploy applications, start with: kubectl create namespace jupyterhub"
    echo "3. Run the networking setup: ./setup-networking.sh"
    echo ""
    echo "Cluster is ready for use!"
    
    exit 0
}

# 引数処理
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  -h, --help    Show this help message"
        echo "  --reset       Reset existing cluster before initialization"
        echo "  --dry-run     Show what would be done without executing"
        exit 0
        ;;
    --reset)
        print_status "INFO" "Force reset mode enabled"
        check_prerequisites
        reset_existing_cluster
        exit 0
        ;;
    --dry-run)
        print_status "INFO" "Dry run mode - showing configuration only"
        check_prerequisites
        create_kubeadm_config
        echo ""
        echo "Generated kubeadm configuration:"
        cat "$SCRIPT_DIR/kubeadm-config-custom.yaml"
        rm -f "$SCRIPT_DIR/kubeadm-config-custom.yaml"
        exit 0
        ;;
esac

# メイン実行
main "$@"