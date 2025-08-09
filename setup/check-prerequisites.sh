#!/bin/bash
# setup/check-prerequisites.sh
# システム要件チェックスクリプト

set -euo pipefail

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# グローバル変数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/prerequisite-check.log"
REPORT_FILE="$SCRIPT_DIR/prerequisite-report.html"
EXIT_CODE=0

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}System Prerequisites Check${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting system prerequisites check"
}

print_result() {
    local status=$1
    local message=$2
    
    if [[ $status == "OK" ]]; then
        echo -e "✅ ${GREEN}$message${NC}"
        log "OK: $message"
    elif [[ $status == "WARNING" ]]; then
        echo -e "⚠️  ${YELLOW}$message${NC}"
        log "WARNING: $message"
    else
        echo -e "❌ ${RED}$message${NC}"
        log "ERROR: $message"
        EXIT_CODE=1
    fi
}

# OS検出とバージョンチェック
check_os_version() {
    echo -e "\n${BLUE}=== OS Version Check ===${NC}"
    
    if [[ ! -f /etc/os-release ]]; then
        print_result "ERROR" "Cannot detect OS version (/etc/os-release not found)"
        return 1
    fi
    
    source /etc/os-release
    log "Detected OS: $NAME $VERSION"
    
    case "$ID" in
        ubuntu)
            if [[ "$VERSION_ID" =~ ^(20\.04|22\.04)$ ]]; then
                print_result "OK" "Ubuntu $VERSION_ID (Supported)"
            else
                print_result "WARNING" "Ubuntu $VERSION_ID (Not tested, recommended: 20.04 or 22.04)"
            fi
            ;;
        centos|rhel)
            if [[ "$VERSION_ID" =~ ^[78]$ ]]; then
                print_result "OK" "$NAME $VERSION_ID (Supported)"
            else
                print_result "WARNING" "$NAME $VERSION_ID (Not tested, recommended: 7 or 8)"
            fi
            ;;
        *)
            print_result "WARNING" "$NAME $VERSION_ID (Not tested, may work)"
            ;;
    esac
}

# メモリ容量チェック
check_memory() {
    echo -e "\n${BLUE}=== Memory Check ===${NC}"
    
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    local mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    
    log "Available memory: ${mem_gb}GB (${mem_mb}MB)"
    
    if [[ $mem_gb -lt 4 ]]; then
        if [[ $mem_mb -lt 3800 ]]; then
            print_result "ERROR" "Insufficient memory: ${mem_gb}GB (minimum 4GB required)"
        else
            print_result "WARNING" "Memory: ${mem_gb}GB (close to minimum, 4GB recommended)"
        fi
    elif [[ $mem_gb -ge 8 ]]; then
        print_result "OK" "Memory: ${mem_gb}GB (Excellent)"
    else
        print_result "OK" "Memory: ${mem_gb}GB (Sufficient)"
    fi
}

# ディスク容量チェック
check_disk_space() {
    echo -e "\n${BLUE}=== Disk Space Check ===${NC}"
    
    local disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    local disk_usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    
    log "Available disk space: ${disk_gb}GB (Usage: ${disk_usage}%)"
    
    if [[ $disk_gb -lt 50 ]]; then
        print_result "ERROR" "Insufficient disk space: ${disk_gb}GB (minimum 50GB required)"
    elif [[ $disk_gb -lt 100 ]]; then
        print_result "WARNING" "Disk space: ${disk_gb}GB (minimum met, 100GB+ recommended)"
    else
        print_result "OK" "Disk space: ${disk_gb}GB (Sufficient)"
    fi
    
    if [[ $disk_usage -gt 80 ]]; then
        print_result "WARNING" "High disk usage: ${disk_usage}% (consider cleaning up)"
    fi
}

# ネットワーク接続チェック
check_network() {
    echo -e "\n${BLUE}=== Network Connectivity Check ===${NC}"
    
    # インターネット接続チェック
    if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
        print_result "OK" "Internet connectivity (8.8.8.8)"
    else
        print_result "ERROR" "No internet connectivity (required for downloading packages)"
        return 1
    fi
    
    # DNS解決チェック
    if nslookup kubernetes.io >/dev/null 2>&1; then
        print_result "OK" "DNS resolution (kubernetes.io)"
    else
        print_result "WARNING" "DNS resolution issues (may affect package installation)"
    fi
    
    # 重要なホストへの接続チェック
    local hosts=("registry.k8s.io" "download.docker.com" "packages.cloud.google.com")
    local failed_hosts=0
    
    for host in "${hosts[@]}"; do
        if timeout 5 bash -c "</dev/tcp/$host/443" 2>/dev/null; then
            log "Network connectivity to $host: OK"
        else
            log "Network connectivity to $host: FAILED"
            ((failed_hosts++))
        fi
    done
    
    if [[ $failed_hosts -eq 0 ]]; then
        print_result "OK" "All required hosts accessible"
    elif [[ $failed_hosts -lt 3 ]]; then
        print_result "WARNING" "Some hosts inaccessible ($failed_hosts/${#hosts[@]})"
    else
        print_result "ERROR" "Most required hosts inaccessible"
    fi
}

# ポート利用可能性チェック
check_ports() {
    echo -e "\n${BLUE}=== Port Availability Check ===${NC}"
    
    # Kubernetesが使用するポート
    local k8s_ports=(6443 2379 2380 10250 10251 10252 10259)
    local nodeport_range_start=30000
    local nodeport_range_end=32767
    local blocked_ports=()
    
    # 個別ポートチェック
    for port in "${k8s_ports[@]}"; do
        if ss -tuln | grep -q ":$port "; then
            blocked_ports+=($port)
            log "Port $port: BLOCKED"
        else
            log "Port $port: AVAILABLE"
        fi
    done
    
    if [[ ${#blocked_ports[@]} -eq 0 ]]; then
        print_result "OK" "All Kubernetes ports available (6443, 2379-2380, 10250-10259)"
    else
        print_result "ERROR" "Blocked ports: ${blocked_ports[*]} (required for Kubernetes)"
    fi
    
    # NodePortレンジ内のポート使用状況
    local nodeport_used=$(ss -tuln | awk -v start="$nodeport_range_start" -v end="$nodeport_range_end" \
        '$2 ~ /:[0-9]+$/ { port=gensub(/.*:([0-9]+)$/, "\\1", "g", $2); if (port >= start && port <= end) count++ } END { print count+0 }')
    
    if [[ $nodeport_used -lt 10 ]]; then
        print_result "OK" "NodePort range (30000-32767): ${nodeport_used} ports used"
    else
        print_result "WARNING" "NodePort range: ${nodeport_used} ports used (may limit services)"
    fi
}

# sudo権限チェック
check_sudo_access() {
    echo -e "\n${BLUE}=== Sudo Access Check ===${NC}"
    
    if sudo -n true 2>/dev/null; then
        print_result "OK" "Passwordless sudo access available"
    elif sudo -v 2>/dev/null; then
        print_result "WARNING" "Sudo access available (password required)"
        echo "Note: For automated installation, configure passwordless sudo"
    else
        print_result "ERROR" "No sudo access (required for installation)"
        echo "Run: sudo visudo and add: $USER ALL=(ALL) NOPASSWD:ALL"
    fi
}

# CPU・アーキテクチャチェック
check_cpu_architecture() {
    echo -e "\n${BLUE}=== CPU Architecture Check ===${NC}"
    
    local arch=$(uname -m)
    local cpu_cores=$(nproc)
    
    log "Architecture: $arch, CPU cores: $cpu_cores"
    
    case "$arch" in
        x86_64|amd64)
            print_result "OK" "Architecture: $arch (Supported)"
            ;;
        aarch64|arm64)
            print_result "OK" "Architecture: $arch (Supported)"
            ;;
        *)
            print_result "WARNING" "Architecture: $arch (May not be supported)"
            ;;
    esac
    
    if [[ $cpu_cores -ge 4 ]]; then
        print_result "OK" "CPU cores: $cpu_cores (Excellent)"
    elif [[ $cpu_cores -ge 2 ]]; then
        print_result "OK" "CPU cores: $cpu_cores (Sufficient)"
    else
        print_result "WARNING" "CPU cores: $cpu_cores (Minimum, 2+ recommended)"
    fi
}

# swapチェック
check_swap() {
    echo -e "\n${BLUE}=== Swap Check ===${NC}"
    
    local swap_total=$(free | awk '/^Swap:/{print $2}')
    
    if [[ $swap_total -eq 0 ]]; then
        print_result "OK" "Swap is disabled (Kubernetes requirement)"
    else
        local swap_used=$(free | awk '/^Swap:/{print $3}')
        print_result "WARNING" "Swap is enabled (${swap_used}/${swap_total} used)"
        echo "Note: Kubernetes requires swap to be disabled"
        echo "Run: sudo swapoff -a && sudo sed -i '/swap/d' /etc/fstab"
    fi
}

# 必要なパッケージチェック
check_required_packages() {
    echo -e "\n${BLUE}=== Required Packages Check ===${NC}"
    
    local packages=("curl" "wget" "apt-transport-https" "ca-certificates" "gnupg" "lsb-release")
    local missing_packages=()
    
    for package in "${packages[@]}"; do
        if command -v "$package" >/dev/null 2>&1 || dpkg -l "$package" >/dev/null 2>&1; then
            log "Package $package: INSTALLED"
        else
            missing_packages+=("$package")
            log "Package $package: MISSING"
        fi
    done
    
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        print_result "OK" "All required packages installed"
    else
        print_result "WARNING" "Missing packages: ${missing_packages[*]} (will be installed)"
    fi
}

# HTMLレポート生成
generate_report() {
    echo -e "\n${BLUE}=== Generating HTML Report ===${NC}"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(hostname)
    local overall_status="PASS"
    
    if [[ $EXIT_CODE -ne 0 ]]; then
        overall_status="FAIL"
    fi
    
    cat > "$REPORT_FILE" <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>kubeadm-python-cluster Prerequisites Check</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background-color: #f0f0f0; padding: 20px; border-radius: 5px; }
        .section { margin: 20px 0; padding: 15px; border-left: 4px solid #007cba; background-color: #f9f9f9; }
        .pass { color: green; }
        .warning { color: orange; }
        .fail { color: red; }
        .log { background-color: #f5f5f5; padding: 10px; font-family: monospace; white-space: pre-wrap; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <div class="header">
        <h1>kubeadm-python-cluster Prerequisites Check</h1>
        <p><strong>Hostname:</strong> $hostname</p>
        <p><strong>Check Date:</strong> $timestamp</p>
        <p><strong>Overall Status:</strong> <span class="$(echo $overall_status | tr '[:upper:]' '[:lower:]')">$overall_status</span></p>
    </div>
    
    <div class="section">
        <h2>System Information</h2>
        <table>
            <tr><th>Item</th><th>Value</th></tr>
            <tr><td>OS</td><td>$(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)</td></tr>
            <tr><td>Architecture</td><td>$(uname -m)</td></tr>
            <tr><td>CPU Cores</td><td>$(nproc)</td></tr>
            <tr><td>Memory</td><td>$(free -h | awk '/^Mem:/{print $2}')</td></tr>
            <tr><td>Disk Space</td><td>$(df -h / | awk 'NR==2{print $4 " available (" $5 " used)"}')</td></tr>
        </table>
    </div>
    
    <div class="section">
        <h2>Detailed Log</h2>
        <div class="log">$(cat "$LOG_FILE")</div>
    </div>
</body>
</html>
EOF
    
    print_result "OK" "HTML report generated: $REPORT_FILE"
}

# メイン実行
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # 各チェック実行
    check_os_version
    check_cpu_architecture
    check_memory
    check_disk_space
    check_swap
    check_network
    check_ports
    check_sudo_access
    check_required_packages
    
    # レポート生成
    generate_report
    
    echo -e "\n${BLUE}=== Summary ===${NC}"
    if [[ $EXIT_CODE -eq 0 ]]; then
        echo -e "✅ ${GREEN}All prerequisites checks passed!${NC}"
        echo -e "${GREEN}You can proceed with the installation.${NC}"
        echo ""
        echo "Next steps:"
        echo "1. Run: ./install-docker.sh"
        echo "2. Run: ./install-kubernetes.sh"
    else
        echo -e "❌ ${RED}Some prerequisite checks failed!${NC}"
        echo -e "${RED}Please resolve the issues before proceeding.${NC}"
    fi
    
    echo ""
    echo "Log file: $LOG_FILE"
    echo "Report file: $REPORT_FILE"
    
    exit $EXIT_CODE
}

# 引数処理
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  -h, --help    Show this help message"
        echo "  --log-only    Only generate log, no interactive output"
        exit 0
        ;;
    --log-only)
        exec > "$LOG_FILE" 2>&1
        ;;
esac

# メイン実行
main "$@"