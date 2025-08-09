#!/bin/bash
# scripts/setup-registry.sh
# ローカルコンテナレジストリ設定スクリプト

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
LOG_FILE="$SCRIPT_DIR/registry-setup.log"
EXIT_CODE=0

# レジストリ設定
REGISTRY_NAME="kubeadm-registry"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_DATA_DIR="${REGISTRY_DATA_DIR:-/var/lib/registry}"
REGISTRY_CONFIG_DIR="$SCRIPT_DIR/registry-config"

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}Container Registry Setup${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting container registry setup"
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

# Docker環境チェック
check_docker() {
    print_status "INFO" "Checking Docker environment..."
    
    if ! command -v docker >/dev/null 2>&1; then
        print_status "ERROR" "Docker not found. Please run ./setup/install-docker.sh first"
        return 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        print_status "ERROR" "Docker daemon is not running"
        return 1
    fi
    
    local docker_version=$(docker --version | awk '{print $3}' | sed 's/,//')
    print_status "SUCCESS" "Docker found: $docker_version"
}

# 既存レジストリチェック
check_existing_registry() {
    print_status "INFO" "Checking for existing registry..."
    
    # 既存のレジストリコンテナチェック
    if docker ps -a --format "{{.Names}}" | grep -q "^$REGISTRY_NAME$"; then
        local registry_status=$(docker inspect --format="{{.State.Status}}" "$REGISTRY_NAME" 2>/dev/null)
        print_status "WARNING" "Registry container '$REGISTRY_NAME' already exists (Status: $registry_status)"
        
        echo ""
        echo "Options:"
        echo "1) Stop and remove existing registry"
        echo "2) Start existing registry if stopped"
        echo "3) Skip registry setup"
        echo "4) Exit"
        
        read -p "Choose option [1-4]: " choice
        case $choice in
            1)
                print_status "INFO" "Removing existing registry..."
                docker stop "$REGISTRY_NAME" >/dev/null 2>&1 || true
                docker rm "$REGISTRY_NAME" >/dev/null 2>&1 || true
                print_status "SUCCESS" "Existing registry removed"
                ;;
            2)
                print_status "INFO" "Starting existing registry..."
                if docker start "$REGISTRY_NAME" >/dev/null 2>&1; then
                    print_status "SUCCESS" "Registry started"
                    return 1
                else
                    print_status "ERROR" "Failed to start existing registry"
                    return 1
                fi
                ;;
            3)
                print_status "INFO" "Skipping registry setup"
                return 1
                ;;
            4)
                print_status "INFO" "Setup cancelled by user"
                exit 0
                ;;
            *)
                print_status "WARNING" "Invalid choice, removing existing registry"
                docker stop "$REGISTRY_NAME" >/dev/null 2>&1 || true
                docker rm "$REGISTRY_NAME" >/dev/null 2>&1 || true
                ;;
        esac
    else
        print_status "SUCCESS" "No existing registry found"
    fi
    
    # ポートチェック
    if ss -tuln | grep -q ":$REGISTRY_PORT "; then
        print_status "ERROR" "Port $REGISTRY_PORT is already in use"
        return 1
    fi
}

# レジストリ設定準備
prepare_registry_config() {
    print_status "INFO" "Preparing registry configuration..."
    
    # 設定ディレクトリ作成
    mkdir -p "$REGISTRY_CONFIG_DIR"
    
    # レジストリ設定ファイル作成
    cat > "$REGISTRY_CONFIG_DIR/config.yml" <<EOF
version: 0.1
log:
  fields:
    service: registry
  level: info
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
    Access-Control-Allow-Origin: ['*']
    Access-Control-Allow-Methods: ['HEAD', 'GET', 'OPTIONS', 'DELETE']
    Access-Control-Allow-Headers: ['Authorization', 'Accept', 'Content-Type']
    Access-Control-Max-Age: [1728000]
    Access-Control-Allow-Credentials: [true]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF
    
    # HTTPS設定（オプション）
    if [[ "${REGISTRY_ENABLE_TLS:-false}" == "true" ]]; then
        print_status "INFO" "Enabling TLS for registry..."
        
        # 自己署名証明書作成
        mkdir -p "$REGISTRY_CONFIG_DIR/certs"
        openssl req -newkey rsa:4096 -nodes -sha256 -keyout "$REGISTRY_CONFIG_DIR/certs/registry.key" \
            -x509 -days 365 -out "$REGISTRY_CONFIG_DIR/certs/registry.crt" \
            -subj "/C=US/ST=CA/L=San Francisco/O=kubeadm-python-cluster/CN=localhost"
        
        # TLS設定を追加
        cat >> "$REGISTRY_CONFIG_DIR/config.yml" <<EOF
http:
  tls:
    certificate: /certs/registry.crt
    key: /certs/registry.key
EOF
    fi
    
    print_status "SUCCESS" "Registry configuration prepared"
}

# データディレクトリ準備
prepare_data_directory() {
    print_status "INFO" "Preparing registry data directory..."
    
    # データディレクトリ作成
    sudo mkdir -p "$REGISTRY_DATA_DIR"
    sudo chown -R "$USER:$USER" "$REGISTRY_DATA_DIR" 2>/dev/null || true
    
    print_status "SUCCESS" "Data directory prepared: $REGISTRY_DATA_DIR"
}

# レジストリコンテナ起動
start_registry() {
    print_status "INFO" "Starting registry container..."
    
    # Docker run引数構築
    local run_args=(
        "-d"
        "--name=$REGISTRY_NAME"
        "--restart=unless-stopped"
        "-p $REGISTRY_PORT:5000"
        "-v $REGISTRY_DATA_DIR:/var/lib/registry"
        "-v $REGISTRY_CONFIG_DIR/config.yml:/etc/docker/registry/config.yml"
    )
    
    # TLS設定
    if [[ "${REGISTRY_ENABLE_TLS:-false}" == "true" ]]; then
        run_args+=("-v $REGISTRY_CONFIG_DIR/certs:/certs")
    fi
    
    # 環境変数設定
    local env_vars=(
        "-e REGISTRY_STORAGE_DELETE_ENABLED=true"
    )
    
    # レジストリコンテナ起動
    if docker run "${run_args[@]}" "${env_vars[@]}" registry:2.8 2>&1 | tee -a "$LOG_FILE"; then
        print_status "SUCCESS" "Registry container started"
        
        # 起動確認待機
        local timeout=30
        local count=0
        
        print_status "INFO" "Waiting for registry to be ready..."
        while [[ $count -lt $timeout ]]; do
            if curl -f "http://localhost:$REGISTRY_PORT/v2/" >/dev/null 2>&1; then
                print_status "SUCCESS" "Registry is ready and responding"
                return 0
            fi
            
            sleep 1
            ((count++))
        done
        
        print_status "ERROR" "Registry failed to start within timeout"
        return 1
    else
        print_status "ERROR" "Failed to start registry container"
        return 1
    fi
}

# Docker daemon設定
configure_docker_daemon() {
    print_status "INFO" "Configuring Docker daemon for insecure registry..."
    
    local daemon_config="/etc/docker/daemon.json"
    local registry_url="localhost:$REGISTRY_PORT"
    
    # 既存設定読み込み
    local insecure_registries="[]"
    if [[ -f "$daemon_config" ]]; then
        if jq -e '.["insecure-registries"]' "$daemon_config" >/dev/null 2>&1; then
            insecure_registries=$(jq -r '.["insecure-registries"]' "$daemon_config")
        fi
    fi
    
    # レジストリ追加チェック
    if echo "$insecure_registries" | jq -e --arg reg "$registry_url" 'index($reg)' >/dev/null 2>&1; then
        print_status "INFO" "Registry already configured in Docker daemon"
    else
        print_status "INFO" "Adding registry to Docker daemon configuration..."
        
        # バックアップ作成
        if [[ -f "$daemon_config" ]]; then
            sudo cp "$daemon_config" "$daemon_config.backup-$(date +%Y%m%d_%H%M%S)"
        fi
        
        # 新しい設定作成
        local new_config
        if [[ -f "$daemon_config" ]]; then
            new_config=$(jq --arg reg "$registry_url" '.["insecure-registries"] += [$reg]' "$daemon_config")
        else
            new_config=$(jq -n --arg reg "$registry_url" '{"insecure-registries": [$reg]}')
        fi
        
        # 設定ファイル更新
        echo "$new_config" | sudo tee "$daemon_config" >/dev/null
        
        print_status "WARNING" "Docker daemon configuration updated. Restart required:"
        print_status "INFO" "sudo systemctl restart docker"
        
        read -p "Restart Docker daemon now? [y/N]: " restart_docker
        if [[ "$restart_docker" =~ ^[Yy]$ ]]; then
            print_status "INFO" "Restarting Docker daemon..."
            sudo systemctl restart docker
            sleep 5
            
            # レジストリ再起動
            print_status "INFO" "Restarting registry after Docker restart..."
            docker start "$REGISTRY_NAME" >/dev/null 2>&1 || true
            sleep 3
            
            print_status "SUCCESS" "Docker daemon restarted"
        fi
    fi
}

# レジストリテスト
test_registry() {
    print_status "INFO" "Testing registry functionality..."
    
    local registry_url="localhost:$REGISTRY_PORT"
    local test_image="hello-world"
    local test_tag="$registry_url/test/hello-world:latest"
    
    # テストイメージのpull
    print_status "INFO" "Pulling test image..."
    if docker pull "$test_image" >/dev/null 2>&1; then
        print_status "SUCCESS" "Test image pulled successfully"
    else
        print_status "WARNING" "Failed to pull test image"
        return 1
    fi
    
    # テストイメージのタグ付け
    print_status "INFO" "Tagging test image..."
    if docker tag "$test_image" "$test_tag" >/dev/null 2>&1; then
        print_status "SUCCESS" "Test image tagged"
    else
        print_status "ERROR" "Failed to tag test image"
        return 1
    fi
    
    # テストイメージのpush
    print_status "INFO" "Pushing test image to registry..."
    if docker push "$test_tag" >/dev/null 2>&1; then
        print_status "SUCCESS" "Test image pushed successfully"
    else
        print_status "ERROR" "Failed to push test image to registry"
        return 1
    fi
    
    # レジストリカタログ確認
    print_status "INFO" "Checking registry catalog..."
    if curl -f "http://$registry_url/v2/_catalog" | jq . >/dev/null 2>&1; then
        print_status "SUCCESS" "Registry catalog accessible"
    else
        print_status "WARNING" "Registry catalog not accessible"
    fi
    
    # クリーンアップ
    docker rmi "$test_tag" >/dev/null 2>&1 || true
    
    print_status "SUCCESS" "Registry functionality test completed"
}

# Kubernetes統合設定
setup_kubernetes_integration() {
    print_status "INFO" "Setting up Kubernetes integration..."
    
    # kubectlチェック
    if ! command -v kubectl >/dev/null 2>&1; then
        print_status "WARNING" "kubectl not found, skipping Kubernetes integration"
        return 0
    fi
    
    # クラスターチェック
    if ! kubectl cluster-info >/dev/null 2>&1; then
        print_status "WARNING" "No active Kubernetes cluster, skipping integration"
        return 0
    fi
    
    # ConfigMap作成
    local registry_url="localhost:$REGISTRY_PORT"
    
    # レジストリConfigMap作成
    cat > "$SCRIPT_DIR/registry-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: container-registry-config
  namespace: kube-system
data:
  registry-url: "$registry_url"
  registry-name: "$REGISTRY_NAME"
  registry-port: "$REGISTRY_PORT"
  setup-date: "$(date -Iseconds)"
EOF
    
    if kubectl apply -f "$SCRIPT_DIR/registry-configmap.yaml" >/dev/null 2>&1; then
        print_status "SUCCESS" "Registry ConfigMap created in Kubernetes"
    else
        print_status "WARNING" "Failed to create registry ConfigMap"
    fi
    
    # クリーンアップ
    rm -f "$SCRIPT_DIR/registry-configmap.yaml"
    
    print_status "SUCCESS" "Kubernetes integration completed"
}

# レジストリ管理スクリプト作成
create_management_scripts() {
    print_status "INFO" "Creating registry management scripts..."
    
    # レジストリ管理スクリプト
    cat > "$SCRIPT_DIR/manage-registry.sh" <<EOF
#!/bin/bash
# manage-registry.sh
# Container Registry Management Script

REGISTRY_NAME="$REGISTRY_NAME"
REGISTRY_PORT="$REGISTRY_PORT"

case "\${1:-}" in
    start)
        echo "Starting registry..."
        docker start "\$REGISTRY_NAME"
        ;;
    stop)
        echo "Stopping registry..."
        docker stop "\$REGISTRY_NAME"
        ;;
    restart)
        echo "Restarting registry..."
        docker restart "\$REGISTRY_NAME"
        ;;
    status)
        echo "Registry status:"
        docker ps --filter "name=\$REGISTRY_NAME"
        ;;
    logs)
        echo "Registry logs:"
        docker logs "\$REGISTRY_NAME"
        ;;
    catalog)
        echo "Registry catalog:"
        curl -s "http://localhost:\$REGISTRY_PORT/v2/_catalog" | jq .
        ;;
    cleanup)
        echo "Cleaning up unused images in registry..."
        docker exec "\$REGISTRY_NAME" registry garbage-collect /etc/docker/registry/config.yml
        ;;
    remove)
        echo "Removing registry container..."
        docker stop "\$REGISTRY_NAME" 2>/dev/null || true
        docker rm "\$REGISTRY_NAME" 2>/dev/null || true
        echo "Registry removed"
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status|logs|catalog|cleanup|remove}"
        echo ""
        echo "Commands:"
        echo "  start    - Start the registry container"
        echo "  stop     - Stop the registry container"
        echo "  restart  - Restart the registry container"
        echo "  status   - Show registry container status"
        echo "  logs     - Show registry container logs"
        echo "  catalog  - List images in registry"
        echo "  cleanup  - Clean up unused registry data"
        echo "  remove   - Remove registry container completely"
        ;;
esac
EOF
    
    chmod +x "$SCRIPT_DIR/manage-registry.sh"
    
    # イメージビルド・プッシュスクリプト
    cat > "$SCRIPT_DIR/build-and-push.sh" <<EOF
#!/bin/bash
# build-and-push.sh
# Build and push images to local registry

set -euo pipefail

REGISTRY_URL="localhost:$REGISTRY_PORT"
PROJECT_ROOT="$PROJECT_ROOT"

# Base Python images build and push
echo "Building and pushing base Python images..."
cd "\$PROJECT_ROOT/docker/base-python"
./build-images.sh --registry-prefix "\$REGISTRY_URL/kubeadm-python-cluster"

# Push base images
docker push "\$REGISTRY_URL/kubeadm-python-cluster/base-python:3.8" || true
docker push "\$REGISTRY_URL/kubeadm-python-cluster/base-python:3.9" || true
docker push "\$REGISTRY_URL/kubeadm-python-cluster/base-python:3.10" || true
docker push "\$REGISTRY_URL/kubeadm-python-cluster/base-python:3.11" || true

echo "All images built and pushed successfully!"
echo "Registry URL: http://\$REGISTRY_URL"
echo "Catalog: curl -s http://\$REGISTRY_URL/v2/_catalog | jq ."
EOF
    
    chmod +x "$SCRIPT_DIR/build-and-push.sh"
    
    print_status "SUCCESS" "Management scripts created"
}

# レジストリ状態確認
verify_registry_status() {
    print_status "INFO" "Verifying registry status..."
    
    local registry_url="localhost:$REGISTRY_PORT"
    
    # コンテナ状態
    if docker ps --filter "name=$REGISTRY_NAME" --format "{{.Names}}\t{{.Status}}" | grep -q "$REGISTRY_NAME"; then
        local status=$(docker ps --filter "name=$REGISTRY_NAME" --format "{{.Status}}")
        print_status "SUCCESS" "Registry container is running: $status"
    else
        print_status "ERROR" "Registry container is not running"
        return 1
    fi
    
    # HTTP応答確認
    if curl -f "http://$registry_url/v2/" >/dev/null 2>&1; then
        print_status "SUCCESS" "Registry HTTP API is responding"
    else
        print_status "ERROR" "Registry HTTP API is not responding"
        return 1
    fi
    
    # カタログ確認
    local catalog=$(curl -s "http://$registry_url/v2/_catalog" | jq -r '.repositories | length' 2>/dev/null || echo "0")
    print_status "INFO" "Registry contains $catalog repositories"
    
    print_status "SUCCESS" "Registry verification completed"
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    check_docker
    check_existing_registry || {
        print_status "INFO" "Using existing registry setup"
        exit 0
    }
    
    prepare_registry_config
    prepare_data_directory
    start_registry
    configure_docker_daemon
    test_registry
    setup_kubernetes_integration
    create_management_scripts
    verify_registry_status
    
    echo -e "\n${BLUE}=== Registry Setup Summary ===${NC}"
    print_status "SUCCESS" "Container registry setup completed successfully!"
    
    echo ""
    echo "Registry information:"
    echo "- Registry URL: http://localhost:$REGISTRY_PORT"
    echo "- Container name: $REGISTRY_NAME"
    echo "- Data directory: $REGISTRY_DATA_DIR"
    echo "- Config directory: $REGISTRY_CONFIG_DIR"
    
    echo ""
    echo "Management commands:"
    echo "- Start/stop: $SCRIPT_DIR/manage-registry.sh {start|stop|restart}"
    echo "- Status: $SCRIPT_DIR/manage-registry.sh status"
    echo "- Catalog: $SCRIPT_DIR/manage-registry.sh catalog"
    echo "- Build images: $SCRIPT_DIR/build-and-push.sh"
    
    echo ""
    echo "API endpoints:"
    echo "- Health: curl http://localhost:$REGISTRY_PORT/v2/"
    echo "- Catalog: curl http://localhost:$REGISTRY_PORT/v2/_catalog"
    
    echo ""
    echo "Next steps:"
    echo "1. Build and push your images: $SCRIPT_DIR/build-and-push.sh"
    echo "2. Use images in Kubernetes: localhost:$REGISTRY_PORT/kubeadm-python-cluster/..."
    echo "3. Configure JupyterHub to use local registry"
    
    echo ""
    echo "Container registry is ready for use!"
    
    exit 0
}

# 引数処理
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  -h, --help    Show this help message"
        echo "  --port PORT   Registry port (default: 5000)"
        echo "  --data-dir    Registry data directory (default: /var/lib/registry)"
        echo "  --enable-tls  Enable TLS/SSL (default: false)"
        exit 0
        ;;
    --port)
        REGISTRY_PORT="${2:-$REGISTRY_PORT}"
        shift 2
        ;;
    --data-dir)
        REGISTRY_DATA_DIR="${2:-$REGISTRY_DATA_DIR}"
        shift 2
        ;;
    --enable-tls)
        export REGISTRY_ENABLE_TLS=true
        shift 1
        ;;
esac

# メイン実行
main "$@"