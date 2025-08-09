#!/bin/bash
# start-notebook.sh
# JupyterLab起動スクリプト for Single-User Servers

set -euo pipefail

# 環境変数のデフォルト値設定
export JUPYTER_ENABLE_LAB=${JUPYTER_ENABLE_LAB:-yes}
export JUPYTER_PORT=${JUPYTER_PORT:-8888}
export JUPYTER_TOKEN=${JUPYTER_TOKEN:-""}
export JUPYTER_BASE_URL=${JUPYTER_BASE_URL:-"/"}
export NB_USER=${NB_USER:-jovyan}
export HOME=${HOME:-/home/jovyan}
export SHELL=${SHELL:-/bin/bash}

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[Notebook]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[Notebook]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[Notebook]${NC} $1"
}

log_error() {
    echo -e "${RED}[Notebook]${NC} $1"
}

# ヘッダー表示
print_header() {
    echo "======================================"
    echo "JupyterLab Single-User Server"
    echo "kubeadm-python-cluster"
    echo "======================================"
    echo "Start Time: $(date)"
    echo "User: $NB_USER"
    echo "Home: $HOME"
    echo "Python: $(python --version)"
    echo "Jupyter: $(jupyter --version | head -1)"
    echo "Port: $JUPYTER_PORT"
    echo "Enable Lab: $JUPYTER_ENABLE_LAB"
    echo "======================================"
}

# ユーザー環境チェック
check_user_environment() {
    log "Checking user environment..."
    
    # ホームディレクトリの確認
    if [[ ! -d "$HOME" ]]; then
        log_error "Home directory does not exist: $HOME"
        exit 1
    fi
    
    # 権限確認
    if [[ ! -w "$HOME" ]]; then
        log_warning "Home directory is not writable: $HOME"
    fi
    
    log_success "User environment check passed"
}

# ディレクトリ準備
prepare_directories() {
    log "Preparing user directories..."
    
    # 必要なディレクトリを作成
    mkdir -p "$HOME/.jupyter"
    mkdir -p "$HOME/.local/share/jupyter"
    mkdir -p "$HOME/notebooks"
    mkdir -p "$HOME/data"
    mkdir -p "$HOME/projects"
    
    # Jupyter設定ディレクトリ
    mkdir -p "$HOME/.jupyter/lab/user-settings"
    mkdir -p "$HOME/.jupyter/lab/workspaces"
    
    log_success "Directories prepared"
}

# Git設定
setup_git_config() {
    log "Setting up Git configuration..."
    
    # Gitユーザー設定（デフォルト）
    if ! git config --global user.name >/dev/null 2>&1; then
        git config --global user.name "$NB_USER"
    fi
    
    if ! git config --global user.email >/dev/null 2>&1; then
        git config --global user.email "$NB_USER@kubeadm-python-cluster.local"
    fi
    
    # Git設定を確認
    local git_user=$(git config --global user.name || echo "Not set")
    local git_email=$(git config --global user.email || echo "Not set")
    log "Git user: $git_user <$git_email>"
    
    log_success "Git configuration completed"
}

# Python環境確認
check_python_environment() {
    log "Checking Python environment..."
    
    # Python実行確認
    if ! command -v python >/dev/null 2>&1; then
        log_error "Python not found"
        exit 1
    fi
    
    # Jupyter確認
    if ! command -v jupyter >/dev/null 2>&1; then
        log_error "Jupyter not found"
        exit 1
    fi
    
    # 主要ライブラリ確認
    python -c "
try:
    import numpy, pandas, matplotlib, sklearn
    print('Core libraries available: numpy, pandas, matplotlib, sklearn')
except ImportError as e:
    print(f'Warning: Some core libraries missing: {e}')
"
    
    log_success "Python environment check passed"
}

# Jupyter設定
setup_jupyter_config() {
    log "Setting up Jupyter configuration..."
    
    # JupyterLab設定ファイルの場所確認
    local config_files=(
        "/etc/jupyter/jupyter_lab_config.py"
        "/etc/jupyter/jupyter_server_config.py"
    )
    
    for config_file in "${config_files[@]}"; do
        if [[ -f "$config_file" ]]; then
            log "Found config file: $config_file"
        else
            log_warning "Config file not found: $config_file"
        fi
    done
    
    log_success "Jupyter configuration check completed"
}

# 環境変数表示
show_environment() {
    log "Environment variables:"
    env | grep -E "^(JUPYTER|NB_|GRANT_|PYTHON|PATH)" | sort | while read -r line; do
        echo "  $line"
    done
}

# JupyterLab/Notebook起動
start_jupyter() {
    log "Starting Jupyter server..."
    
    cd "$HOME"
    
    # 起動コマンドの決定
    local jupyter_cmd
    if [[ "$JUPYTER_ENABLE_LAB" == "yes" ]] || [[ "$JUPYTER_ENABLE_LAB" == "true" ]]; then
        jupyter_cmd="jupyter lab"
        log "Starting JupyterLab"
    else
        jupyter_cmd="jupyter notebook"
        log "Starting Jupyter Notebook"
    fi
    
    # 設定ファイル指定
    local config_args=""
    if [[ -f "/etc/jupyter/jupyter_lab_config.py" ]]; then
        config_args="--config=/etc/jupyter/jupyter_lab_config.py"
    fi
    
    # 起動引数構築
    local start_args=(
        "--ip=0.0.0.0"
        "--port=$JUPYTER_PORT"
        "--no-browser"
        "--allow-root"
    )
    
    # トークン設定
    if [[ -n "$JUPYTER_TOKEN" ]]; then
        start_args+=("--token=$JUPYTER_TOKEN")
    else
        start_args+=("--token=''")
    fi
    
    # Base URL設定
    if [[ -n "$JUPYTER_BASE_URL" && "$JUPYTER_BASE_URL" != "/" ]]; then
        start_args+=("--base-url=$JUPYTER_BASE_URL")
    fi
    
    # JupyterHub統合チェック
    if [[ -n "${JUPYTERHUB_API_TOKEN:-}" ]]; then
        start_args+=("--hub-api-url=${JUPYTERHUB_API_URL:-}")
        log "JupyterHub integration enabled"
    fi
    
    # 最終コマンド構築
    local final_cmd="$jupyter_cmd $config_args ${start_args[*]}"
    
    log_success "Starting with command: $final_cmd"
    
    # Jupyter実行
    exec $final_cmd
}

# シグナルハンドラー
cleanup() {
    log "Received shutdown signal, cleaning up..."
    # 必要に応じてクリーンアップ処理
    exit 0
}

# メイン実行
main() {
    # シグナルハンドラー設定
    trap cleanup SIGTERM SIGINT
    
    print_header
    check_user_environment
    prepare_directories
    setup_git_config
    check_python_environment
    setup_jupyter_config
    show_environment
    
    log_success "All checks passed, starting Jupyter server..."
    start_jupyter
}

# スクリプト実行
main "$@"