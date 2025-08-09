#!/bin/bash
# scripts/deploy-jupyterhub.sh
# JupyterHub Kubernetesデプロイメントスクリプト

set -euo pipefail

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# グローバル変数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
K8S_MANIFESTS_DIR="$PROJECT_ROOT/k8s-manifests"
LOG_FILE="$SCRIPT_DIR/deploy-jupyterhub.log"
EXIT_CODE=0

# デプロイメント設定
NAMESPACE="jupyterhub"
REGISTRY_URL="${CONTAINER_REGISTRY:-localhost:5000}"
DEPLOY_MODE="${DEPLOY_MODE:-apply}"

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}JupyterHub Kubernetes Deployment${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting JupyterHub deployment process"
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
    print_status "INFO" "Checking prerequisites..."
    
    # kubectl確認
    if ! command -v kubectl >/dev/null 2>&1; then
        print_status "ERROR" "kubectl not found. Please install kubectl first"
        return 1
    fi
    
    # クラスター接続確認
    if ! kubectl cluster-info >/dev/null 2>&1; then
        print_status "ERROR" "Cannot connect to Kubernetes cluster"
        return 1
    fi
    
    # マニフェストディレクトリ確認
    if [[ ! -d "$K8S_MANIFESTS_DIR" ]]; then
        print_status "ERROR" "Kubernetes manifests directory not found: $K8S_MANIFESTS_DIR"
        return 1
    fi
    
    # 必要なマニフェストファイル確認
    local required_files=(
        "namespace.yaml"
        "rbac.yaml"
        "storage.yaml"
        "configmap.yaml"
        "secret.yaml"
        "jupyterhub-deployment.yaml"
        "service.yaml"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$K8S_MANIFESTS_DIR/$file" ]]; then
            print_status "ERROR" "Required manifest file not found: $file"
            return 1
        fi
    done
    
    print_status "SUCCESS" "Prerequisites check passed"
}

# クラスター状態確認
check_cluster_status() {
    print_status "INFO" "Checking cluster status..."
    
    # ノード状態確認
    local ready_nodes
    if ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready"); then
        if [[ $ready_nodes -gt 0 ]]; then
            print_status "SUCCESS" "Cluster has $ready_nodes Ready node(s)"
        else
            print_status "ERROR" "No Ready nodes found"
            return 1
        fi
    else
        print_status "ERROR" "Cannot check node status"
        return 1
    fi
    
    # kube-systemポッド確認
    local system_pods_ready
    if system_pods_ready=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep "Running\|Completed" | wc -l); then
        print_status "INFO" "System pods running: $system_pods_ready"
    else
        print_status "WARNING" "Cannot check system pods status"
    fi
    
    print_status "SUCCESS" "Cluster status check passed"
}

# 既存デプロイメントチェック
check_existing_deployment() {
    print_status "INFO" "Checking for existing JupyterHub deployment..."
    
    # 名前空間チェック
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        print_status "WARNING" "Namespace '$NAMESPACE' already exists"
        
        # 既存のJupyterHubデプロイメントチェック
        if kubectl get deployment -n "$NAMESPACE" jupyterhub >/dev/null 2>&1; then
            local deployment_status=$(kubectl get deployment -n "$NAMESPACE" jupyterhub -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
            print_status "WARNING" "JupyterHub deployment already exists (Available: $deployment_status)"
            
            echo ""
            echo "Options:"
            echo "1) Update existing deployment"
            echo "2) Delete and recreate deployment"
            echo "3) Skip deployment"
            echo "4) Exit"
            
            read -p "Choose option [1-4]: " choice
            case $choice in
                1)
                    print_status "INFO" "Updating existing deployment"
                    DEPLOY_MODE="apply"
                    ;;
                2)
                    print_status "INFO" "Deleting existing deployment"
                    delete_existing_deployment
                    DEPLOY_MODE="apply"
                    ;;
                3)
                    print_status "INFO" "Skipping deployment"
                    return 1
                    ;;
                4)
                    print_status "INFO" "Deployment cancelled by user"
                    exit 0
                    ;;
                *)
                    print_status "WARNING" "Invalid choice, updating existing deployment"
                    DEPLOY_MODE="apply"
                    ;;
            esac
        else
            print_status "INFO" "Namespace exists but no JupyterHub deployment found"
        fi
    else
        print_status "SUCCESS" "No existing deployment found"
    fi
}

# 既存デプロイメント削除
delete_existing_deployment() {
    print_status "INFO" "Deleting existing JupyterHub deployment..."
    
    # 順序だった削除
    kubectl delete deployment -n "$NAMESPACE" jupyterhub --ignore-not-found=true
    kubectl delete service -n "$NAMESPACE" --all --ignore-not-found=true
    kubectl delete configmap -n "$NAMESPACE" --all --ignore-not-found=true
    kubectl delete secret -n "$NAMESPACE" --all --ignore-not-found=true
    kubectl delete pvc -n "$NAMESPACE" --all --ignore-not-found=true
    
    # Pod終了待機
    print_status "INFO" "Waiting for pods to terminate..."
    local timeout=60
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        local running_pods
        if running_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l); then
            if [[ $running_pods -eq 0 ]]; then
                print_status "SUCCESS" "All pods terminated"
                break
            fi
        fi
        
        sleep 2
        ((count+=2))
        
        if [[ $((count % 10)) -eq 0 ]]; then
            print_status "INFO" "Still waiting for pod termination... ($count/${timeout}s)"
        fi
    done
    
    print_status "SUCCESS" "Existing deployment deleted"
}

# コンテナイメージ確認
check_container_images() {
    print_status "INFO" "Checking container images availability..."
    
    local registry_url="$REGISTRY_URL"
    local required_images=(
        "kubeadm-python-cluster/jupyterhub:latest"
        "kubeadm-python-cluster/jupyterlab:3.11"
        "kubeadm-python-cluster/jupyterlab:3.10"
        "kubeadm-python-cluster/jupyterlab:3.9"
        "kubeadm-python-cluster/jupyterlab:3.8"
    )
    
    local available_images=()
    local missing_images=()
    
    print_status "INFO" "Checking registry: $registry_url"
    
    # レジストリ接続確認
    if ! curl -f "http://$registry_url/v2/" >/dev/null 2>&1; then
        print_status "WARNING" "Cannot connect to container registry: $registry_url"
        print_status "INFO" "You may need to start the registry: ./scripts/setup-registry.sh"
        return 0
    fi
    
    # イメージ存在確認
    for image in "${required_images[@]}"; do
        local image_name=$(echo "$image" | cut -d: -f1)
        local tag=$(echo "$image" | cut -d: -f2)
        
        if curl -f "http://$registry_url/v2/$image_name/manifests/$tag" >/dev/null 2>&1; then
            available_images+=("$image")
        else
            missing_images+=("$image")
        fi
    done
    
    if [[ ${#available_images[@]} -gt 0 ]]; then
        print_status "SUCCESS" "Available images: ${#available_images[@]}"
        for image in "${available_images[@]}"; do
            log "  ✅ $registry_url/$image"
        done
    fi
    
    if [[ ${#missing_images[@]} -gt 0 ]]; then
        print_status "WARNING" "Missing images: ${#missing_images[@]}"
        for image in "${missing_images[@]}"; do
            log "  ❌ $registry_url/$image"
        done
        print_status "INFO" "You may need to build and push images: ./scripts/build-and-push.sh"
    fi
    
    print_status "SUCCESS" "Container images check completed"
}

# シークレット生成
generate_secrets() {
    print_status "INFO" "Generating fresh secrets..."
    
    # Cookie secretとcrypto key生成
    local cookie_secret=$(openssl rand -base64 32)
    local crypto_key=$(openssl rand -base64 32)
    
    # シークレットファイル更新
    local secret_file="$K8S_MANIFESTS_DIR/secret.yaml"
    local temp_secret_file="$K8S_MANIFESTS_DIR/secret-updated.yaml"
    
    # Cookie secretの更新
    sed "s/cookie-secret: .*/cookie-secret: $(echo -n "$cookie_secret" | base64 -w 0)/" "$secret_file" > "$temp_secret_file"
    
    # Crypto keyの更新
    sed -i "s/crypto-key: .*/crypto-key: $(echo -n "$crypto_key" | base64 -w 0)/" "$temp_secret_file"
    
    mv "$temp_secret_file" "$secret_file"
    
    print_status "SUCCESS" "Fresh secrets generated"
}

# Kubernetesリソースデプロイ
deploy_kubernetes_resources() {
    print_status "INFO" "Deploying Kubernetes resources..."
    
    local deployment_order=(
        "namespace.yaml"
        "rbac.yaml"
        "storage.yaml"
        "configmap.yaml"
        "secret.yaml"
        "jupyterhub-deployment.yaml"
        "service.yaml"
    )
    
    # 順序だったデプロイ
    for manifest in "${deployment_order[@]}"; do
        local manifest_file="$K8S_MANIFESTS_DIR/$manifest"
        
        print_status "INFO" "Applying $manifest..."
        
        if kubectl apply -f "$manifest_file" 2>&1 | tee -a "$LOG_FILE"; then
            print_status "SUCCESS" "$manifest applied successfully"
        else
            print_status "ERROR" "Failed to apply $manifest"
            return 1
        fi
        
        # 短い待機（リソース作成の順序確保）
        sleep 2
    done
    
    print_status "SUCCESS" "All Kubernetes resources deployed"
}

# デプロイメント状態確認
check_deployment_status() {
    print_status "INFO" "Checking deployment status..."
    
    # デプロイメント状態確認
    print_status "INFO" "Waiting for JupyterHub deployment to be ready..."
    
    local timeout=300  # 5分
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        local ready_replicas
        if ready_replicas=$(kubectl get deployment -n "$NAMESPACE" jupyterhub -o jsonpath='{.status.readyReplicas}' 2>/dev/null); then
            if [[ "$ready_replicas" == "1" ]]; then
                print_status "SUCCESS" "JupyterHub deployment is ready"
                break
            fi
        fi
        
        sleep 5
        ((count+=5))
        
        if [[ $((count % 30)) -eq 0 ]]; then
            print_status "INFO" "Still waiting for deployment... ($count/${timeout}s)"
            
            # ポッド状態表示
            kubectl get pods -n "$NAMESPACE" --no-headers | while read -r line; do
                log "  Pod status: $line"
            done
        fi
    done
    
    if [[ $count -ge $timeout ]]; then
        print_status "ERROR" "Deployment timeout. Check pod status manually"
        return 1
    fi
    
    # サービス状態確認
    print_status "INFO" "Checking service status..."
    if kubectl get service -n "$NAMESPACE" jupyterhub >/dev/null 2>&1; then
        print_status "SUCCESS" "JupyterHub service is available"
    else
        print_status "ERROR" "JupyterHub service not found"
        return 1
    fi
    
    print_status "SUCCESS" "Deployment status check completed"
}

# 接続テスト
test_connectivity() {
    print_status "INFO" "Testing JupyterHub connectivity..."
    
    # NodePortの取得
    local node_port
    if node_port=$(kubectl get service -n "$NAMESPACE" jupyterhub -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null); then
        print_status "INFO" "JupyterHub NodePort: $node_port"
    else
        print_status "WARNING" "Could not get NodePort"
        return 0
    fi
    
    # ノードIPの取得
    local node_ip
    if node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); then
        print_status "INFO" "Node IP: $node_ip"
    else
        print_status "WARNING" "Could not get node IP"
        return 0
    fi
    
    # HTTP接続テスト
    local jupyterhub_url="http://$node_ip:$node_port"
    print_status "INFO" "Testing connectivity to: $jupyterhub_url"
    
    local timeout=60
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        if curl -f -s "$jupyterhub_url/hub/health" >/dev/null 2>&1; then
            print_status "SUCCESS" "JupyterHub is responding to health checks"
            print_status "SUCCESS" "JupyterHub is accessible at: $jupyterhub_url"
            return 0
        fi
        
        sleep 3
        ((count+=3))
        
        if [[ $((count % 15)) -eq 0 ]]; then
            print_status "INFO" "Still waiting for JupyterHub to respond... ($count/${timeout}s)"
        fi
    done
    
    print_status "WARNING" "JupyterHub health check timeout, but deployment may still be starting"
    print_status "INFO" "Try accessing: $jupyterhub_url"
    
    return 0
}

# ステータスサマリー表示
show_deployment_summary() {
    print_status "INFO" "Deployment summary:"
    
    echo ""
    echo "=== Namespace: $NAMESPACE ==="
    kubectl get all -n "$NAMESPACE" 2>/dev/null || true
    
    echo ""
    echo "=== Persistent Volume Claims ==="
    kubectl get pvc -n "$NAMESPACE" 2>/dev/null || true
    
    echo ""
    echo "=== ConfigMaps and Secrets ==="
    kubectl get configmaps,secrets -n "$NAMESPACE" 2>/dev/null || true
    
    # 接続情報表示
    local node_port=$(kubectl get service -n "$NAMESPACE" jupyterhub -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "N/A")
    
    echo ""
    echo "=== Connection Information ==="
    echo "JupyterHub URL: http://$node_ip:$node_port"
    echo "Health Check: http://$node_ip:$node_port/hub/health"
    echo "Registry: $REGISTRY_URL"
    
    echo ""
    echo "=== Quick Commands ==="
    echo "Check logs: kubectl logs -n $NAMESPACE deployment/jupyterhub"
    echo "Get pods: kubectl get pods -n $NAMESPACE"
    echo "Port forward: kubectl port-forward -n $NAMESPACE svc/jupyterhub 8080:80"
    echo "Delete deployment: kubectl delete namespace $NAMESPACE"
}

# クリーンアップ機能
cleanup_on_failure() {
    print_status "WARNING" "Deployment failed, cleanup may be required"
    
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Check pod logs: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=jupyterhub"
    echo "2. Check events: kubectl get events -n $NAMESPACE"
    echo "3. Check pod status: kubectl get pods -n $NAMESPACE -o wide"
    echo "4. Clean up: kubectl delete namespace $NAMESPACE"
    
    print_status "ERROR" "Deployment failed. Check logs: $LOG_FILE"
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # エラーハンドリング設定
    trap 'cleanup_on_failure' ERR
    
    # デプロイメントプロセス
    check_prerequisites
    check_cluster_status
    check_existing_deployment || {
        print_status "INFO" "Skipping deployment as requested"
        exit 0
    }
    
    check_container_images
    generate_secrets
    deploy_kubernetes_resources
    check_deployment_status
    test_connectivity
    show_deployment_summary
    
    echo -e "\n${BLUE}=== Deployment Summary ===${NC}"
    print_status "SUCCESS" "JupyterHub deployment completed successfully!"
    
    local node_port=$(kubectl get service -n "$NAMESPACE" jupyterhub -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "N/A")
    
    echo ""
    echo "🚀 JupyterHub is now running!"
    echo "📍 Access URL: http://$node_ip:$node_port"
    echo "👤 Default admin user: admin"
    echo "🔑 Create account at: http://$node_ip:$node_port/hub/signup"
    
    echo ""
    echo "Next steps:"
    echo "1. Access JupyterHub at the URL above"
    echo "2. Create user accounts or configure authentication"
    echo "3. Select Python version from the profile menu"
    echo "4. Start coding in JupyterLab!"
    
    echo ""
    echo "Management commands:"
    echo "- Scale: kubectl scale -n $NAMESPACE deployment/jupyterhub --replicas=N"
    echo "- Update: kubectl rollout restart -n $NAMESPACE deployment/jupyterhub"
    echo "- Monitor: kubectl logs -f -n $NAMESPACE deployment/jupyterhub"
    
    exit 0
}

# 引数処理
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  -h, --help         Show this help message"
        echo "  --registry URL     Container registry URL (default: localhost:5000)"
        echo "  --namespace NS     Kubernetes namespace (default: jupyterhub)"
        echo "  --delete           Delete existing deployment"
        echo "  --status           Show deployment status only"
        echo "  --dry-run          Show what would be deployed"
        exit 0
        ;;
    --registry)
        REGISTRY_URL="${2:-$REGISTRY_URL}"
        shift 2
        ;;
    --namespace)
        NAMESPACE="${2:-$NAMESPACE}"
        shift 2
        ;;
    --delete)
        print_status "INFO" "Deleting JupyterHub deployment..."
        kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
        print_status "SUCCESS" "Deployment deleted"
        exit 0
        ;;
    --status)
        check_prerequisites
        show_deployment_summary
        exit 0
        ;;
    --dry-run)
        DEPLOY_MODE="dry-run"
        print_status "INFO" "Dry run mode enabled"
        ;;
esac

# メイン実行
main "$@"