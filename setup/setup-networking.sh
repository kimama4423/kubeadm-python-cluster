#!/bin/bash
# setup/setup-networking.sh
# Kubernetesネットワーキング詳細設定スクリプト

set -euo pipefail

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# グローバル変数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/networking-setup.log"
BACKUP_DIR="$SCRIPT_DIR/network-backup-$(date +%Y%m%d_%H%M%S)"
EXIT_CODE=0

# ネットワーク設定
CNI_PLUGIN="flannel"
FLANNEL_VERSION="v0.24.0"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}Kubernetes Networking Setup${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting Kubernetes networking setup"
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
    print_status "INFO" "Checking prerequisites for networking setup..."
    
    # クラスターチェック
    if ! kubectl cluster-info >/dev/null 2>&1; then
        print_status "ERROR" "No active Kubernetes cluster found. Please run ./init-cluster.sh first"
        return 1
    fi
    
    # ノードチェック
    local ready_nodes
    if ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready"); then
        if [[ $ready_nodes -gt 0 ]]; then
            print_status "SUCCESS" "Found $ready_nodes Ready node(s)"
        else
            print_status "ERROR" "No Ready nodes found"
            return 1
        fi
    else
        print_status "ERROR" "Cannot check node status"
        return 1
    fi
    
    print_status "SUCCESS" "Prerequisites check passed"
}

# 既存CNI確認
check_existing_cni() {
    print_status "INFO" "Checking for existing CNI configuration..."
    
    # kube-systemポッド確認
    local cni_pods
    if cni_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -E "(flannel|calico|weave|cilium)"); then
        print_status "WARNING" "Existing CNI pods found:"
        echo "$cni_pods"
        
        echo ""
        echo "Options:"
        echo "1) Continue and upgrade/reinstall CNI"
        echo "2) Skip CNI installation"
        echo "3) Remove existing CNI and clean install"
        echo "4) Exit"
        
        read -p "Choose option [1-4]: " choice
        case $choice in
            1)
                print_status "INFO" "Proceeding with CNI upgrade/reinstall"
                ;;
            2)
                print_status "INFO" "Skipping CNI installation"
                return 1
                ;;
            3)
                print_status "INFO" "Removing existing CNI configuration"
                remove_existing_cni
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
        print_status "SUCCESS" "No existing CNI configuration found"
    fi
    
    # CNI設定ファイル確認
    if [[ -d /etc/cni/net.d ]] && [[ -n "$(ls -A /etc/cni/net.d 2>/dev/null)" ]]; then
        print_status "INFO" "Found existing CNI configuration files in /etc/cni/net.d"
        ls -la /etc/cni/net.d/ | tee -a "$LOG_FILE"
    fi
}

# 既存CNI削除
remove_existing_cni() {
    print_status "INFO" "Removing existing CNI configuration..."
    
    # バックアップ作成
    backup_cni_config
    
    # kube-flannel削除
    kubectl delete -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml >/dev/null 2>&1 || true
    kubectl delete namespace kube-flannel >/dev/null 2>&1 || true
    
    # calico削除（もしある場合）
    kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/calico.yaml >/dev/null 2>&1 || true
    
    # CNI設定ファイル削除
    sudo rm -rf /etc/cni/net.d/* 2>/dev/null || true
    sudo rm -rf /opt/cni/bin/flannel* 2>/dev/null || true
    
    # 待機
    print_status "INFO" "Waiting for CNI cleanup to complete..."
    sleep 10
    
    print_status "SUCCESS" "Existing CNI configuration removed"
}

# CNI設定バックアップ
backup_cni_config() {
    print_status "INFO" "Creating backup of existing CNI configuration..."
    mkdir -p "$BACKUP_DIR"
    
    # CNI設定ファイルのバックアップ
    if [[ -d /etc/cni/net.d ]] && [[ -n "$(ls -A /etc/cni/net.d 2>/dev/null)" ]]; then
        sudo cp -r /etc/cni/net.d "$BACKUP_DIR/cni-config" 2>/dev/null || true
        sudo chown -R "$USER:$USER" "$BACKUP_DIR/cni-config" 2>/dev/null || true
        log "Backed up CNI configuration files"
    fi
    
    # Kubernetes CNIマニフェストのバックアップ
    kubectl get pods -n kube-system -o yaml > "$BACKUP_DIR/kube-system-pods.yaml" 2>/dev/null || true
    kubectl get daemonsets -n kube-flannel -o yaml > "$BACKUP_DIR/flannel-daemonsets.yaml" 2>/dev/null || true
    
    print_status "SUCCESS" "Backup created at: $BACKUP_DIR"
}

# Flannelインストール
install_flannel_cni() {
    print_status "INFO" "Installing Flannel CNI plugin..."
    
    # Flannel設定のカスタマイズ
    create_flannel_config
    
    # Flannelのインストール
    print_status "INFO" "Applying Flannel configuration..."
    local flannel_manifest="$SCRIPT_DIR/flannel-custom.yaml"
    
    if kubectl apply -f "$flannel_manifest" 2>&1 | tee -a "$LOG_FILE"; then
        print_status "SUCCESS" "Flannel CNI plugin installed"
        
        # Flannel Podの起動待機
        wait_for_flannel_pods
        
    else
        print_status "ERROR" "Failed to install Flannel CNI plugin"
        return 1
    fi
}

# カスタムFlannel設定作成
create_flannel_config() {
    print_status "INFO" "Creating custom Flannel configuration..."
    
    local flannel_config="$SCRIPT_DIR/flannel-custom.yaml"
    
    # オリジナルのFlannel設定をダウンロードしてカスタマイズ
    curl -sSL "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml" > "$flannel_config.tmp"
    
    # Pod CIDR設定のカスタマイズ
    sed "s|10.244.0.0/16|$POD_CIDR|g" "$flannel_config.tmp" > "$flannel_config"
    
    # 追加設定の適用
    cat >> "$flannel_config" <<EOF

---
# Custom Flannel Configuration for kubeadm-python-cluster
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-flannel-cfg-custom
  namespace: kube-flannel
  labels:
    tier: node
    app: flannel
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": {
            "portMappings": true
          }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "$POD_CIDR",
      "Backend": {
        "Type": "vxlan",
        "Port": 8472
      }
    }
EOF
    
    rm -f "$flannel_config.tmp"
    
    print_status "SUCCESS" "Custom Flannel configuration created: $flannel_config"
}

# Flannel Pod待機
wait_for_flannel_pods() {
    print_status "INFO" "Waiting for Flannel pods to start..."
    
    local timeout=180
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        local running_pods
        if running_pods=$(kubectl get pods -n kube-flannel --no-headers 2>/dev/null | grep "Running" | wc -l); then
            local total_pods
            if total_pods=$(kubectl get pods -n kube-flannel --no-headers 2>/dev/null | wc -l); then
                if [[ $running_pods -gt 0 && $running_pods -eq $total_pods ]]; then
                    print_status "SUCCESS" "All Flannel pods are running ($running_pods/$total_pods)"
                    return 0
                fi
            fi
        fi
        
        sleep 5
        ((count+=5))
        
        if [[ $((count % 30)) -eq 0 ]]; then
            print_status "INFO" "Still waiting for Flannel pods... ($count/${timeout}s)"
            kubectl get pods -n kube-flannel 2>/dev/null || true
        fi
    done
    
    print_status "WARNING" "Timeout waiting for Flannel pods to start"
    return 1
}

# ネットワーク接続テスト
test_network_connectivity() {
    print_status "INFO" "Testing network connectivity..."
    
    # テスト用Podのデプロイ
    local test_namespace="network-test"
    
    print_status "INFO" "Creating test namespace and pods..."
    
    kubectl create namespace "$test_namespace" >/dev/null 2>&1 || true
    
    # テスト用Pod YAML
    cat > "$SCRIPT_DIR/network-test-pods.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: network-test-pod-1
  namespace: $test_namespace
  labels:
    app: network-test
spec:
  containers:
  - name: test-container
    image: busybox:1.35
    command: ['sleep', '300']
  restartPolicy: Never
---
apiVersion: v1
kind: Pod
metadata:
  name: network-test-pod-2
  namespace: $test_namespace
  labels:
    app: network-test
spec:
  containers:
  - name: test-container
    image: busybox:1.35
    command: ['sleep', '300']
  restartPolicy: Never
---
apiVersion: v1
kind: Service
metadata:
  name: network-test-service
  namespace: $test_namespace
spec:
  selector:
    app: network-test
  ports:
  - port: 80
    targetPort: 8080
  type: ClusterIP
EOF
    
    if kubectl apply -f "$SCRIPT_DIR/network-test-pods.yaml" >/dev/null 2>&1; then
        print_status "SUCCESS" "Test pods created"
        
        # Pod起動待機
        print_status "INFO" "Waiting for test pods to start..."
        local timeout=60
        local count=0
        
        while [[ $count -lt $timeout ]]; do
            local running_pods
            if running_pods=$(kubectl get pods -n "$test_namespace" --no-headers 2>/dev/null | grep "Running" | wc -l); then
                if [[ $running_pods -eq 2 ]]; then
                    print_status "SUCCESS" "Test pods are running"
                    break
                fi
            fi
            
            sleep 3
            ((count+=3))
        done
        
        if [[ $count -lt $timeout ]]; then
            # Pod間通信テスト
            test_pod_to_pod_communication "$test_namespace"
            
            # サービス通信テスト
            test_service_connectivity "$test_namespace"
        else
            print_status "WARNING" "Test pods did not start within timeout"
        fi
        
        # テストリソース削除
        kubectl delete namespace "$test_namespace" >/dev/null 2>&1 || true
        rm -f "$SCRIPT_DIR/network-test-pods.yaml"
        
    else
        print_status "WARNING" "Could not create test pods"
    fi
}

# Pod間通信テスト
test_pod_to_pod_communication() {
    local namespace=$1
    print_status "INFO" "Testing pod-to-pod communication..."
    
    # Pod IPの取得
    local pod1_ip
    local pod2_ip
    
    pod1_ip=$(kubectl get pod network-test-pod-1 -n "$namespace" -o jsonpath='{.status.podIP}' 2>/dev/null)
    pod2_ip=$(kubectl get pod network-test-pod-2 -n "$namespace" -o jsonpath='{.status.podIP}' 2>/dev/null)
    
    if [[ -n "$pod1_ip" && -n "$pod2_ip" ]]; then
        log "Pod IPs: pod1=$pod1_ip, pod2=$pod2_ip"
        
        # ping テスト (pod1 -> pod2)
        if kubectl exec -n "$namespace" network-test-pod-1 -- ping -c 3 "$pod2_ip" >/dev/null 2>&1; then
            print_status "SUCCESS" "Pod-to-pod communication test passed"
        else
            print_status "WARNING" "Pod-to-pod communication test failed"
        fi
    else
        print_status "WARNING" "Could not get pod IPs for communication test"
    fi
}

# サービス接続テスト
test_service_connectivity() {
    local namespace=$1
    print_status "INFO" "Testing service connectivity..."
    
    # DNS解決テスト
    if kubectl exec -n "$namespace" network-test-pod-1 -- nslookup network-test-service >/dev/null 2>&1; then
        print_status "SUCCESS" "Service DNS resolution test passed"
    else
        print_status "WARNING" "Service DNS resolution test failed"
    fi
}

# ネットワークポリシー設定
setup_network_policies() {
    print_status "INFO" "Setting up basic network policies..."
    
    # デフォルトネットワークポリシー作成
    cat > "$SCRIPT_DIR/default-network-policies.yaml" <<EOF
# Default deny-all ingress policy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
# Allow DNS policy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
---
# Allow inter-pod communication within namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector: {}
  egress:
  - to:
    - podSelector: {}
EOF
    
    if kubectl apply -f "$SCRIPT_DIR/default-network-policies.yaml" 2>&1 | tee -a "$LOG_FILE"; then
        print_status "SUCCESS" "Basic network policies applied"
    else
        print_status "WARNING" "Failed to apply network policies (may not be supported by CNI)"
    fi
    
    rm -f "$SCRIPT_DIR/default-network-policies.yaml"
}

# ネットワーク状態確認
verify_network_status() {
    print_status "INFO" "Verifying network status..."
    
    # ノード状態
    print_status "INFO" "Node network status:"
    kubectl get nodes -o wide 2>&1 | tee -a "$LOG_FILE" || true
    
    # CNI Pods状態
    print_status "INFO" "CNI pods status:"
    kubectl get pods -n kube-flannel -o wide 2>&1 | tee -a "$LOG_FILE" || true
    
    # ネットワーク設定確認
    print_status "INFO" "Network configuration:"
    echo "Pod CIDR: $POD_CIDR" | tee -a "$LOG_FILE"
    echo "Service CIDR: $SERVICE_CIDR" | tee -a "$LOG_FILE"
    
    # CNI設定ファイル確認
    if [[ -d /etc/cni/net.d ]]; then
        print_status "INFO" "CNI configuration files:"
        ls -la /etc/cni/net.d/ | tee -a "$LOG_FILE" || true
    fi
    
    # iptables ルール確認
    print_status "INFO" "Key iptables rules (FORWARD chain):"
    sudo iptables -L FORWARD -n | head -20 | tee -a "$LOG_FILE" || true
}

# クリーンアップ機能
cleanup_on_failure() {
    print_status "WARNING" "Networking setup failed, performing cleanup..."
    
    # テスト用ファイルの削除
    rm -f "$SCRIPT_DIR/flannel-custom.yaml" 2>/dev/null || true
    rm -f "$SCRIPT_DIR/network-test-pods.yaml" 2>/dev/null || true
    rm -f "$SCRIPT_DIR/default-network-policies.yaml" 2>/dev/null || true
    
    print_status "ERROR" "Cleanup completed. Check logs: $LOG_FILE"
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # エラーハンドリング設定
    trap 'cleanup_on_failure' ERR
    
    # ネットワークセットアッププロセス
    check_prerequisites
    check_existing_cni || {
        print_status "INFO" "Skipping CNI installation as requested"
        exit 0
    }
    
    install_flannel_cni
    setup_network_policies
    test_network_connectivity
    verify_network_status
    
    # 一時ファイル削除
    rm -f "$SCRIPT_DIR/flannel-custom.yaml" 2>/dev/null || true
    
    echo -e "\n${BLUE}=== Networking Setup Summary ===${NC}"
    print_status "SUCCESS" "Kubernetes networking setup completed successfully!"
    
    echo ""
    echo "Network configuration:"
    echo "- CNI Plugin: Flannel"
    echo "- Pod CIDR: $POD_CIDR"
    echo "- Service CIDR: $SERVICE_CIDR"
    echo "- Backend: VXLAN (Port 8472)"
    
    echo ""
    echo "Cluster network status:"
    kubectl get nodes
    
    echo ""
    echo "CNI pods status:"
    kubectl get pods -n kube-flannel
    
    echo ""
    echo "Important files:"
    echo "- Log file: $LOG_FILE"
    
    if [[ -d "$BACKUP_DIR" ]]; then
        echo "- Backup directory: $BACKUP_DIR"
    fi
    
    echo ""
    echo "Next steps:"
    echo "1. Test pod deployment: kubectl run test-pod --image=busybox -- sleep 3600"
    echo "2. Check pod networking: kubectl exec test-pod -- ip addr"
    echo "3. Proceed with JupyterHub deployment setup"
    echo ""
    echo "Kubernetes networking is ready!"
    
    exit 0
}

# 引数処理
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  -h, --help       Show this help message"
        echo "  --cni PLUGIN     Specify CNI plugin (default: flannel)"
        echo "  --pod-cidr CIDR  Specify Pod CIDR (default: $POD_CIDR)"
        echo "  --test-only      Run network tests only"
        exit 0
        ;;
    --cni)
        CNI_PLUGIN="${2:-$CNI_PLUGIN}"
        shift 2
        ;;
    --pod-cidr)
        POD_CIDR="${2:-$POD_CIDR}"
        shift 2
        ;;
    --test-only)
        print_status "INFO" "Running network connectivity tests only"
        check_prerequisites
        test_network_connectivity
        verify_network_status
        exit 0
        ;;
esac

# メイン実行
main "$@"