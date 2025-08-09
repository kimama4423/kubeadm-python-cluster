#!/bin/bash
# start-jupyterhub.sh
# JupyterHub起動スクリプト

set -euo pipefail

# 環境変数のデフォルト値設定
export JUPYTERHUB_CONFIG_DIR=${JUPYTERHUB_CONFIG_DIR:-/etc/jupyterhub}
export JUPYTERHUB_DATA_DIR=${JUPYTERHUB_DATA_DIR:-/srv/jupyterhub}
export JUPYTERHUB_LOG_LEVEL=${JUPYTERHUB_LOG_LEVEL:-INFO}
export JUPYTERHUB_PORT=${JUPYTERHUB_PORT:-8000}
export JUPYTERHUB_HUB_PORT=${JUPYTERHUB_HUB_PORT:-8081}

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[JupyterHub]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[JupyterHub]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[JupyterHub]${NC} $1"
}

log_error() {
    echo -e "${RED}[JupyterHub]${NC} $1"
}

# ヘッダー表示
print_header() {
    echo "======================================"
    echo "JupyterHub for kubeadm-python-cluster"
    echo "======================================"
    echo "Start Time: $(date)"
    echo "Config Dir: $JUPYTERHUB_CONFIG_DIR"
    echo "Data Dir: $JUPYTERHUB_DATA_DIR"
    echo "Log Level: $JUPYTERHUB_LOG_LEVEL"
    echo "Hub Port: $JUPYTERHUB_HUB_PORT"
    echo "Service Port: $JUPYTERHUB_PORT"
    echo "======================================"
}

# 前提条件チェック
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Python環境確認
    if ! command -v python >/dev/null 2>&1; then
        log_error "Python not found"
        exit 1
    fi
    
    # JupyterHub確認
    if ! command -v jupyterhub >/dev/null 2>&1; then
        log_error "JupyterHub not found"
        exit 1
    fi
    
    # configurable-http-proxy確認
    if ! command -v configurable-http-proxy >/dev/null 2>&1; then
        log_error "configurable-http-proxy not found"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# ディレクトリ準備
prepare_directories() {
    log "Preparing directories..."
    
    # 必要なディレクトリを作成
    mkdir -p "$JUPYTERHUB_DATA_DIR"
    mkdir -p "$JUPYTERHUB_CONFIG_DIR"
    mkdir -p /var/log/jupyterhub
    
    # 権限設定
    if [[ "$(whoami)" == "root" ]]; then
        chown -R jupyterhub:jupyterhub "$JUPYTERHUB_DATA_DIR" || true
        chown -R jupyterhub:jupyterhub /var/log/jupyterhub || true
    fi
    
    log_success "Directories prepared"
}

# Cookie secretファイル生成
generate_cookie_secret() {
    local cookie_file="$JUPYTERHUB_DATA_DIR/jupyterhub_cookie_secret"
    
    if [[ ! -f "$cookie_file" ]]; then
        log "Generating cookie secret..."
        openssl rand -hex 32 > "$cookie_file"
        chmod 600 "$cookie_file"
        log_success "Cookie secret generated"
    else
        log "Using existing cookie secret"
    fi
}

# データベース初期化
initialize_database() {
    log "Initializing database..."
    
    # データベースマイグレーション実行
    cd "$JUPYTERHUB_DATA_DIR"
    
    if jupyterhub upgrade-db --config="$JUPYTERHUB_CONFIG_DIR/jupyterhub_config.py"; then
        log_success "Database initialized/upgraded"
    else
        log_warning "Database upgrade failed or not needed"
    fi
}

# Kubernetes接続確認
check_kubernetes() {
    log "Checking Kubernetes connection..."
    
    # kubectl確認
    if command -v kubectl >/dev/null 2>&1; then
        if kubectl cluster-info >/dev/null 2>&1; then
            log_success "Kubernetes connection verified"
            
            # ネームスペース確認
            local namespace=${JUPYTERHUB_NAMESPACE:-jupyterhub}
            if kubectl get namespace "$namespace" >/dev/null 2>&1; then
                log_success "Namespace '$namespace' found"
            else
                log_warning "Namespace '$namespace' not found - may be created by JupyterHub"
            fi
        else
            log_warning "Cannot connect to Kubernetes cluster"
        fi
    else
        log_warning "kubectl not found - running without Kubernetes integration"
    fi
}

# 設定ファイル検証
validate_config() {
    log "Validating configuration..."
    
    local config_file="$JUPYTERHUB_CONFIG_DIR/jupyterhub_config.py"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        exit 1
    fi
    
    # 設定ファイルの構文チェック
    if python -m py_compile "$config_file"; then
        log_success "Configuration file is valid"
    else
        log_error "Configuration file has syntax errors"
        exit 1
    fi
}

# 環境情報表示
show_environment_info() {
    log "Environment information:"
    echo "  Python version: $(python --version)"
    echo "  JupyterHub version: $(jupyterhub --version)"
    echo "  Node.js version: $(node --version 2>/dev/null || echo 'Not available')"
    echo "  Configurable HTTP Proxy: $(configurable-http-proxy --version 2>/dev/null || echo 'Not available')"
    echo "  Current user: $(whoami)"
    echo "  Working directory: $(pwd)"
    echo "  Available memory: $(free -h | grep ^Mem | awk '{print $2}' || echo 'Unknown')"
    
    # Kubernetes情報
    if command -v kubectl >/dev/null 2>&1; then
        local k8s_version=$(kubectl version --client -o json 2>/dev/null | python -c "import json,sys; print(json.load(sys.stdin)['clientVersion']['gitVersion'])" 2>/dev/null || echo 'Unknown')
        echo "  Kubernetes client version: $k8s_version"
    fi
}

# JupyterHub起動
start_jupyterhub() {
    log "Starting JupyterHub..."
    
    cd "$JUPYTERHUB_DATA_DIR"
    
    # 起動コマンド構築
    local cmd="jupyterhub"
    cmd="$cmd --config=$JUPYTERHUB_CONFIG_DIR/jupyterhub_config.py"
    cmd="$cmd --log-level=$JUPYTERHUB_LOG_LEVEL"
    
    # デバッグモード
    if [[ "${JUPYTERHUB_DEBUG:-false}" == "true" ]]; then
        cmd="$cmd --debug"
        log "Debug mode enabled"
    fi
    
    log_success "Starting JupyterHub with command: $cmd"
    
    # JupyterHub実行
    exec $cmd
}

# シグナルハンドラー
cleanup() {
    log "Received shutdown signal, cleaning up..."
    exit 0
}

# メイン実行
main() {
    # シグナルハンドラー設定
    trap cleanup SIGTERM SIGINT
    
    print_header
    check_prerequisites
    prepare_directories
    generate_cookie_secret
    validate_config
    initialize_database
    check_kubernetes
    show_environment_info
    
    log_success "All checks passed, starting JupyterHub..."
    start_jupyterhub
}

# スクリプト実行
main "$@"