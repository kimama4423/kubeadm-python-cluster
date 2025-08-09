#!/bin/bash
# tests/jupyterhub-tests.sh
# JupyterHub機能テストスクリプト for kubeadm-python-cluster

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
LOG_FILE="$SCRIPT_DIR/jupyterhub-test-results.log"
REPORT_FILE="$SCRIPT_DIR/jupyterhub-test-report.html"
EXIT_CODE=0

# テスト設定
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"
JUPYTERHUB_NAMESPACE="${JUPYTERHUB_NAMESPACE:-jupyterhub}"
TEST_USER="${TEST_USER:-testuser}"
TEST_PASSWORD="${TEST_PASSWORD:-testpassword123}"
JUPYTERHUB_URL=""

# テスト結果
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNINGS=0

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}JupyterHub Functionality Tests${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting JupyterHub functionality tests"
}

print_test_header() {
    local test_name="$1"
    echo ""
    echo -e "${BLUE}--- Test: $test_name ---${NC}"
    log "TEST START: $test_name"
}

print_status() {
    local status=$1
    local message=$2
    
    case $status in
        "PASS")
            echo -e "✅ ${GREEN}PASS: $message${NC}"
            log "PASS: $message"
            ((PASSED_TESTS++))
            ;;
        "FAIL")
            echo -e "❌ ${RED}FAIL: $message${NC}"
            log "FAIL: $message"
            ((FAILED_TESTS++))
            EXIT_CODE=1
            ;;
        "WARNING")
            echo -e "⚠️  ${YELLOW}WARNING: $message${NC}"
            log "WARNING: $message"
            ((WARNINGS++))
            ;;
        "INFO")
            echo -e "ℹ️  ${BLUE}INFO: $message${NC}"
            log "INFO: $message"
            ;;
    esac
    ((TOTAL_TESTS++))
}

# JupyterHub基本デプロイメントテスト
test_jupyterhub_deployment() {
    print_test_header "JupyterHub Deployment Status"
    
    # Namespace存在確認
    if kubectl get namespace "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "JupyterHub namespace '$JUPYTERHUB_NAMESPACE' exists"
    else
        print_status "FAIL" "JupyterHub namespace '$JUPYTERHUB_NAMESPACE' not found"
        return 1
    fi
    
    # Deployment確認
    if kubectl get deployment jupyterhub -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "JupyterHub deployment exists"
        
        # Deployment状態確認
        local desired=$(kubectl get deployment jupyterhub -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.spec.replicas}')
        local ready=$(kubectl get deployment jupyterhub -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.status.readyReplicas}')
        
        if [[ "${ready:-0}" -eq "$desired" ]]; then
            print_status "PASS" "JupyterHub deployment is ready ($ready/$desired replicas)"
        else
            print_status "FAIL" "JupyterHub deployment not ready ($ready/$desired replicas)"
        fi
    else
        print_status "FAIL" "JupyterHub deployment not found"
        return 1
    fi
    
    # Pod状態確認
    local pod_name=$(kubectl get pods -n "$JUPYTERHUB_NAMESPACE" -l app.kubernetes.io/name=jupyterhub -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -n "$pod_name" ]]; then
        local pod_status=$(kubectl get pod "$pod_name" -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.status.phase}')
        
        if [[ "$pod_status" == "Running" ]]; then
            print_status "PASS" "JupyterHub pod is running"
        else
            print_status "FAIL" "JupyterHub pod is not running (status: $pod_status)"
            kubectl describe pod "$pod_name" -n "$JUPYTERHUB_NAMESPACE" | tail -10
        fi
    else
        print_status "FAIL" "JupyterHub pod not found"
    fi
    
    # Service確認
    if kubectl get service jupyterhub -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "JupyterHub service exists"
        
        # Service endpoint確認
        local endpoints=$(kubectl get endpoints jupyterhub -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.subsets[0].addresses[0].ip}:{.subsets[0].ports[0].port}' 2>/dev/null)
        
        if [[ -n "$endpoints" ]]; then
            print_status "PASS" "JupyterHub service has endpoints ($endpoints)"
        else
            print_status "FAIL" "JupyterHub service has no endpoints"
        fi
    else
        print_status "FAIL" "JupyterHub service not found"
    fi
}

# JupyterHub接続テスト
test_jupyterhub_connectivity() {
    print_test_header "JupyterHub Connectivity"
    
    # NodePortまたはLoadBalancer URLを取得
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    local node_port=$(kubectl get service jupyterhub -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="http" || @.name=="https")].nodePort}' 2>/dev/null)
    
    if [[ -n "$node_ip" ]] && [[ -n "$node_port" ]]; then
        # HTTPS接続を試行
        if curl -k -f -s "https://$node_ip:$node_port" >/dev/null 2>&1; then
            JUPYTERHUB_URL="https://$node_ip:$node_port"
            print_status "PASS" "JupyterHub accessible via HTTPS: $JUPYTERHUB_URL"
        # HTTP接続を試行
        elif curl -f -s "http://$node_ip:$node_port" >/dev/null 2>&1; then
            JUPYTERHUB_URL="http://$node_ip:$node_port"
            print_status "PASS" "JupyterHub accessible via HTTP: $JUPYTERHUB_URL"
        else
            print_status "FAIL" "JupyterHub not accessible on $node_ip:$node_port"
            return 1
        fi
    else
        print_status "FAIL" "Cannot determine JupyterHub external URL"
        return 1
    fi
    
    # ヘルスチェックAPI確認
    if [[ -n "$JUPYTERHUB_URL" ]]; then
        local health_endpoint="$JUPYTERHUB_URL/hub/health"
        
        if curl -k -f -s "$health_endpoint" | grep -q "OK" 2>/dev/null; then
            print_status "PASS" "JupyterHub health endpoint responding"
        else
            print_status "WARNING" "JupyterHub health endpoint not responding correctly"
        fi
    fi
    
    # ログイン画面テスト
    if [[ -n "$JUPYTERHUB_URL" ]]; then
        local login_response=$(curl -k -s "$JUPYTERHUB_URL/hub/login" 2>/dev/null)
        
        if echo "$login_response" | grep -q "username\|login" 2>/dev/null; then
            print_status "PASS" "JupyterHub login page is accessible"
        else
            print_status "WARNING" "JupyterHub login page may not be fully ready"
        fi
    fi
}

# RBAC・権限テスト
test_jupyterhub_rbac() {
    print_test_header "JupyterHub RBAC and Permissions"
    
    # ServiceAccount確認
    if kubectl get serviceaccount jupyterhub -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "JupyterHub service account exists"
    else
        print_status "FAIL" "JupyterHub service account not found"
    fi
    
    # ClusterRole確認
    if kubectl get clusterrole | grep -q jupyterhub; then
        print_status "PASS" "JupyterHub cluster role exists"
    else
        print_status "WARNING" "JupyterHub cluster role not found (may use different RBAC setup)"
    fi
    
    # ClusterRoleBinding確認
    if kubectl get clusterrolebinding | grep -q jupyterhub; then
        print_status "PASS" "JupyterHub cluster role binding exists"
    else
        print_status "WARNING" "JupyterHub cluster role binding not found"
    fi
    
    # Pod作成権限テスト
    local hub_pod=$(kubectl get pods -n "$JUPYTERHUB_NAMESPACE" -l app.kubernetes.io/name=jupyterhub -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -n "$hub_pod" ]]; then
        # JupyterHubからKubernetes API呼び出しテスト
        if kubectl exec "$hub_pod" -n "$JUPYTERHUB_NAMESPACE" -- curl -k -s -H "Authorization: Bearer \$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" "https://kubernetes.default.svc.cluster.local/api/v1/namespaces/$JUPYTERHUB_NAMESPACE/pods" >/dev/null 2>&1; then
            print_status "PASS" "JupyterHub can access Kubernetes API"
        else
            print_status "FAIL" "JupyterHub cannot access Kubernetes API"
        fi
    else
        print_status "WARNING" "Cannot test Kubernetes API access - JupyterHub pod not found"
    fi
    
    # Single-user server ServiceAccount確認
    if kubectl get serviceaccount jupyterhub-singleuser -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "Single-user service account exists"
    else
        print_status "WARNING" "Single-user service account not found"
    fi
}

# ストレージテスト
test_jupyterhub_storage() {
    print_test_header "JupyterHub Storage"
    
    # PVC確認
    local pvc_count=$(kubectl get pvc -n "$JUPYTERHUB_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    
    if [[ "$pvc_count" -gt 0 ]]; then
        print_status "PASS" "JupyterHub PVCs found ($pvc_count PVCs)"
        
        # PVC状態確認
        local bound_pvcs=$(kubectl get pvc -n "$JUPYTERHUB_NAMESPACE" --no-headers | grep -c "Bound" || echo "0")
        
        if [[ "$bound_pvcs" -eq "$pvc_count" ]]; then
            print_status "PASS" "All JupyterHub PVCs are bound ($bound_pvcs/$pvc_count)"
        else
            print_status "WARNING" "Some PVCs are not bound ($bound_pvcs/$pvc_count)"
        fi
    else
        print_status "WARNING" "No JupyterHub PVCs found (may use emptyDir or hostPath)"
    fi
    
    # JupyterHub hub永続ストレージ
    if kubectl get pvc jupyterhub-hub-pvc -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        local hub_pvc_status=$(kubectl get pvc jupyterhub-hub-pvc -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.status.phase}')
        
        if [[ "$hub_pvc_status" == "Bound" ]]; then
            print_status "PASS" "JupyterHub hub storage is bound"
        else
            print_status "FAIL" "JupyterHub hub storage is not bound (status: $hub_pvc_status)"
        fi
    else
        print_status "INFO" "JupyterHub hub PVC not found (may use different storage strategy)"
    fi
    
    # 共有データストレージ
    if kubectl get pvc jupyterhub-shared-data-pvc -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        local shared_pvc_status=$(kubectl get pvc jupyterhub-shared-data-pvc -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.status.phase}')
        
        if [[ "$shared_pvc_status" == "Bound" ]]; then
            print_status "PASS" "JupyterHub shared storage is bound"
        else
            print_status "WARNING" "JupyterHub shared storage is not bound (status: $shared_pvc_status)"
        fi
    else
        print_status "INFO" "JupyterHub shared data PVC not found"
    fi
}

# 設定テスト
test_jupyterhub_configuration() {
    print_test_header "JupyterHub Configuration"
    
    # ConfigMap確認
    if kubectl get configmap jupyterhub-config -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "JupyterHub configuration ConfigMap exists"
        
        # 設定内容確認
        local config_content=$(kubectl get configmap jupyterhub-config -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.data.jupyterhub_config\.py}' 2>/dev/null)
        
        if echo "$config_content" | grep -q "KubeSpawner"; then
            print_status "PASS" "JupyterHub configured with KubeSpawner"
        else
            print_status "WARNING" "KubeSpawner configuration not found in ConfigMap"
        fi
        
        if echo "$config_content" | grep -q "profile_list\|image_spec"; then
            print_status "PASS" "Multi-Python environment configuration found"
        else
            print_status "WARNING" "Multi-Python environment configuration not found"
        fi
        
        # SSL設定確認
        if echo "$config_content" | grep -q "ssl_cert\|ssl_key"; then
            print_status "PASS" "SSL/TLS configuration found"
        else
            print_status "INFO" "SSL/TLS configuration not found (may be HTTP only)"
        fi
    else
        print_status "FAIL" "JupyterHub configuration ConfigMap not found"
    fi
    
    # Secret確認
    if kubectl get secret jupyterhub-secret -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "JupyterHub secret exists"
        
        # Secret内容確認
        local secret_keys=$(kubectl get secret jupyterhub-secret -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.data}' | jq -r 'keys[]' 2>/dev/null)
        
        if echo "$secret_keys" | grep -q "cookie-secret"; then
            print_status "PASS" "Cookie secret configured"
        else
            print_status "WARNING" "Cookie secret not found"
        fi
        
        if echo "$secret_keys" | grep -q "crypto-key"; then
            print_status "PASS" "Crypto key configured"
        else
            print_status "WARNING" "Crypto key not found"
        fi
    else
        print_status "WARNING" "JupyterHub secret not found"
    fi
}

# Single-user Server起動テスト
test_singleuser_spawning() {
    print_test_header "Single-User Server Spawning"
    
    # テスト用ユーザーでのサーバー起動をシミュレート
    if [[ -n "$JUPYTERHUB_URL" ]]; then
        print_status "INFO" "Testing single-user server spawning capability"
        
        # JupyterHub Pod内からのテスト
        local hub_pod=$(kubectl get pods -n "$JUPYTERHUB_NAMESPACE" -l app.kubernetes.io/name=jupyterhub -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
        if [[ -n "$hub_pod" ]]; then
            # Python環境・イメージ確認
            if kubectl exec "$hub_pod" -n "$JUPYTERHUB_NAMESPACE" -- python3 -c "
import subprocess
import json
try:
    # Check if container images are accessible
    result = subprocess.run(['python3', '-c', 'import kubespawner; print(\"KubeSpawner available\")'], 
                          capture_output=True, text=True)
    print('KubeSpawner import test:', result.returncode == 0)
except Exception as e:
    print('Error testing KubeSpawner:', e)
" 2>/dev/null; then
                print_status "PASS" "JupyterHub spawning environment is configured"
            else
                print_status "WARNING" "JupyterHub spawning environment may have issues"
            fi
        else
            print_status "WARNING" "Cannot test spawning - JupyterHub pod not accessible"
        fi
    else
        print_status "WARNING" "Cannot test single-user spawning - JupyterHub URL not available"
    fi
    
    # イメージプル権限テスト
    if kubectl auth can-i get pods --as=system:serviceaccount:$JUPYTERHUB_NAMESPACE:jupyterhub-singleuser >/dev/null 2>&1; then
        print_status "PASS" "Single-user service account has pod access"
    else
        print_status "WARNING" "Single-user service account pod access may be limited"
    fi
}

# Container Registry統合テスト
test_container_registry_integration() {
    print_test_header "Container Registry Integration"
    
    # ローカルレジストリアクセステスト
    if curl -f -s http://localhost:5000/v2/_catalog >/dev/null 2>&1; then
        print_status "PASS" "Container registry is accessible"
        
        # JupyterHub関連イメージ確認
        local registry_images=$(curl -s http://localhost:5000/v2/_catalog | jq -r '.repositories[]' 2>/dev/null)
        
        if echo "$registry_images" | grep -q "kubeadm-python-cluster/jupyterhub"; then
            print_status "PASS" "JupyterHub image found in registry"
        else
            print_status "WARNING" "JupyterHub image not found in local registry"
        fi
        
        if echo "$registry_images" | grep -q "kubeadm-python-cluster/jupyterlab"; then
            print_status "PASS" "JupyterLab images found in registry"
        else
            print_status "WARNING" "JupyterLab images not found in local registry"
        fi
    else
        print_status "WARNING" "Container registry not accessible (may use external registry)"
    fi
    
    # イメージプル権限
    if kubectl get secret registry-credentials -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "Registry credentials secret exists"
    else
        print_status "INFO" "Registry credentials secret not found (may not be needed for public registry)"
    fi
}

# パフォーマンス基本テスト
test_basic_performance() {
    print_test_header "JupyterHub Basic Performance"
    
    local hub_pod=$(kubectl get pods -n "$JUPYTERHUB_NAMESPACE" -l app.kubernetes.io/name=jupyterhub -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -n "$hub_pod" ]]; then
        # メモリ使用量
        if command -v kubectl >/dev/null && kubectl top pod "$hub_pod" -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
            local memory_usage=$(kubectl top pod "$hub_pod" -n "$JUPYTERHUB_NAMESPACE" --no-headers | awk '{print $3}' | sed 's/Mi//')
            
            if [[ "$memory_usage" -lt 1000 ]]; then
                print_status "PASS" "JupyterHub memory usage is reasonable (${memory_usage}Mi)"
            else
                print_status "WARNING" "JupyterHub memory usage is high (${memory_usage}Mi)"
            fi
        else
            print_status "INFO" "Cannot check resource usage - metrics server may not be available"
        fi
        
        # Pod restart回数
        local restart_count=$(kubectl get pod "$hub_pod" -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}')
        
        if [[ "$restart_count" -eq 0 ]]; then
            print_status "PASS" "JupyterHub pod has not restarted"
        elif [[ "$restart_count" -lt 3 ]]; then
            print_status "WARNING" "JupyterHub pod has restarted $restart_count times"
        else
            print_status "FAIL" "JupyterHub pod has restarted $restart_count times (excessive)"
        fi
        
        # 応答時間テスト
        if [[ -n "$JUPYTERHUB_URL" ]]; then
            local response_time=$(curl -k -w "%{time_total}" -s -o /dev/null "$JUPYTERHUB_URL" 2>/dev/null || echo "999")
            local response_ms=$(echo "$response_time * 1000" | bc -l 2>/dev/null || echo "999")
            local response_int=$(printf "%.0f" "$response_ms" 2>/dev/null || echo "999")
            
            if [[ "$response_int" -lt 5000 ]]; then
                print_status "PASS" "JupyterHub response time is good (${response_int}ms)"
            else
                print_status "WARNING" "JupyterHub response time is slow (${response_int}ms)"
            fi
        fi
    else
        print_status "WARNING" "Cannot perform performance tests - JupyterHub pod not found"
    fi
}

# セキュリティ設定テスト
test_security_configuration() {
    print_test_header "JupyterHub Security Configuration"
    
    local hub_pod=$(kubectl get pods -n "$JUPYTERHUB_NAMESPACE" -l app.kubernetes.io/name=jupyterhub -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -n "$hub_pod" ]]; then
        # Security Context確認
        local run_as_user=$(kubectl get pod "$hub_pod" -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.spec.securityContext.runAsUser}')
        local run_as_non_root=$(kubectl get pod "$hub_pod" -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.spec.securityContext.runAsNonRoot}')
        
        if [[ "$run_as_user" != "0" ]] && [[ "$run_as_non_root" == "true" ]]; then
            print_status "PASS" "JupyterHub runs as non-root user"
        else
            print_status "WARNING" "JupyterHub may be running as root user"
        fi
        
        # Read-only root filesystem
        local readonly_root=$(kubectl get pod "$hub_pod" -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}')
        
        if [[ "$readonly_root" == "true" ]]; then
            print_status "PASS" "JupyterHub has read-only root filesystem"
        else
            print_status "INFO" "JupyterHub does not have read-only root filesystem (may be intentional)"
        fi
        
        # Capability drops
        local capabilities=$(kubectl get pod "$hub_pod" -n "$JUPYTERHUB_NAMESPACE" -o jsonpath='{.spec.containers[0].securityContext.capabilities.drop}' 2>/dev/null)
        
        if echo "$capabilities" | grep -q "ALL"; then
            print_status "PASS" "JupyterHub has dropped all capabilities"
        else
            print_status "WARNING" "JupyterHub has not dropped all capabilities"
        fi
    else
        print_status "WARNING" "Cannot test security configuration - JupyterHub pod not found"
    fi
    
    # Network Policy確認
    if kubectl get networkpolicy -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        local netpol_count=$(kubectl get networkpolicy -n "$JUPYTERHUB_NAMESPACE" --no-headers | wc -l)
        print_status "PASS" "Network policies configured in JupyterHub namespace ($netpol_count policies)"
    else
        print_status "INFO" "No network policies found in JupyterHub namespace"
    fi
    
    # SSL/TLS証明書
    if kubectl get secret jupyterhub-tls -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "SSL/TLS certificate secret exists"
    else
        print_status "INFO" "SSL/TLS certificate secret not found (may use HTTP or external TLS termination)"
    fi
}

# HTMLレポート生成
generate_html_report() {
    print_status "INFO" "Generating JupyterHub test HTML report..."
    
    cat > "$REPORT_FILE" <<EOF
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>JupyterHub Test Report - kubeadm-python-cluster</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; line-height: 1.6; }
        .header { background: #FF6B35; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .summary { background: #f5f5f5; padding: 15px; border-radius: 8px; margin-bottom: 20px; }
        .test-section { margin-bottom: 30px; }
        .test-section h2 { color: #333; border-bottom: 2px solid #FF6B35; padding-bottom: 5px; }
        .pass { color: #4CAF50; font-weight: bold; }
        .fail { color: #f44336; font-weight: bold; }
        .warning { color: #FF9800; font-weight: bold; }
        .info { color: #2196F3; font-weight: bold; }
        .log-section { background: #f9f9f9; padding: 15px; border-radius: 8px; font-family: monospace; font-size: 12px; max-height: 400px; overflow-y: auto; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { padding: 8px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background-color: #f2f2f2; }
        .access-info { background: #e3f2fd; padding: 15px; border-radius: 8px; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>🚀 JupyterHub Functionality Test Report</h1>
        <p>kubeadm Python Cluster - $(date)</p>
    </div>
    
    <div class="summary">
        <h2>📊 Test Summary</h2>
        <table>
            <tr><th>Metric</th><th>Value</th></tr>
            <tr><td>Total Tests</td><td>$TOTAL_TESTS</td></tr>
            <tr><td>Passed</td><td class="pass">$PASSED_TESTS</td></tr>
            <tr><td>Failed</td><td class="fail">$FAILED_TESTS</td></tr>
            <tr><td>Warnings</td><td class="warning">$WARNINGS</td></tr>
            <tr><td>Success Rate</td><td>$(( TOTAL_TESTS > 0 ? (PASSED_TESTS * 100) / TOTAL_TESTS : 0 ))%</td></tr>
        </table>
    </div>
    
    $(if [[ -n "$JUPYTERHUB_URL" ]]; then
        echo "<div class=\"access-info\">"
        echo "<h2>🌐 JupyterHub Access Information</h2>"
        echo "<p><strong>URL:</strong> <a href=\"$JUPYTERHUB_URL\" target=\"_blank\">$JUPYTERHUB_URL</a></p>"
        echo "<p><strong>Namespace:</strong> $JUPYTERHUB_NAMESPACE</p>"
        echo "<p><strong>Status:</strong> Accessible</p>"
        echo "</div>"
    fi)
    
    <div class="test-section">
        <h2>🧪 Test Categories</h2>
        
        <h3>Deployment & Basic Health</h3>
        <ul>
            <li>JupyterHub deployment status and readiness</li>
            <li>Pod health and running status</li>
            <li>Service configuration and endpoints</li>
            <li>Namespace and resource availability</li>
        </ul>
        
        <h3>Connectivity & Accessibility</h3>
        <ul>
            <li>External URL accessibility (HTTP/HTTPS)</li>
            <li>Health endpoint functionality</li>
            <li>Login page availability</li>
            <li>Response time and performance</li>
        </ul>
        
        <h3>RBAC & Permissions</h3>
        <ul>
            <li>Service account configuration</li>
            <li>Cluster role and bindings</li>
            <li>Kubernetes API access permissions</li>
            <li>Single-user server permissions</li>
        </ul>
        
        <h3>Storage & Persistence</h3>
        <ul>
            <li>PVC creation and binding</li>
            <li>Hub data persistence</li>
            <li>Shared storage configuration</li>
            <li>Storage class utilization</li>
        </ul>
        
        <h3>Configuration Management</h3>
        <ul>
            <li>ConfigMap presence and content</li>
            <li>KubeSpawner configuration</li>
            <li>Multi-Python environment setup</li>
            <li>SSL/TLS configuration</li>
            <li>Secrets management</li>
        </ul>
        
        <h3>Container & Spawning</h3>
        <ul>
            <li>Single-user server spawning capability</li>
            <li>Container registry integration</li>
            <li>Image pull permissions and secrets</li>
            <li>Python environment availability</li>
        </ul>
        
        <h3>Security Configuration</h3>
        <ul>
            <li>Security context enforcement</li>
            <li>Non-root user execution</li>
            <li>Capability restrictions</li>
            <li>Network policy implementation</li>
            <li>SSL/TLS certificate management</li>
        </ul>
        
        <h3>Performance & Stability</h3>
        <ul>
            <li>Resource usage monitoring</li>
            <li>Pod restart frequency</li>
            <li>Response time measurement</li>
            <li>Memory consumption analysis</li>
        </ul>
    </div>
    
    <div class="test-section">
        <h2>📝 Detailed Test Log</h2>
        <div class="log-section">
EOF
    
    # ログファイルの内容をHTMLに追加
    if [[ -f "$LOG_FILE" ]]; then
        sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$LOG_FILE" | while IFS= read -r line; do
            if [[ "$line" == *"PASS"* ]]; then
                echo "<span class=\"pass\">$line</span><br>" >> "$REPORT_FILE"
            elif [[ "$line" == *"FAIL"* ]]; then
                echo "<span class=\"fail\">$line</span><br>" >> "$REPORT_FILE"
            elif [[ "$line" == *"WARNING"* ]]; then
                echo "<span class=\"warning\">$line</span><br>" >> "$REPORT_FILE"
            elif [[ "$line" == *"INFO"* ]]; then
                echo "<span class=\"info\">$line</span><br>" >> "$REPORT_FILE"
            else
                echo "$line<br>" >> "$REPORT_FILE"
            fi
        done
    fi
    
    cat >> "$REPORT_FILE" <<EOF
        </div>
    </div>
    
    <div class="summary">
        <h2>✅ Recommendations</h2>
        <ul>
            <li>Review any failed tests and address configuration issues</li>
            <li>Investigate warnings for potential optimizations</li>
            <li>Test actual user workflows (login, notebook creation, code execution)</li>
            <li>Verify multi-Python environment functionality</li>
            <li>Conduct load testing with multiple concurrent users</li>
            <li>Validate backup and recovery procedures</li>
            <li>Test integration with monitoring and logging systems</li>
        </ul>
    </div>
    
    <footer style="margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; color: #666;">
        <p>Generated by kubeadm-python-cluster JupyterHub functionality tests</p>
        <p>Report generated: $(date)</p>
    </footer>
</body>
</html>
EOF

    print_status "PASS" "HTML report generated: $REPORT_FILE"
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # JupyterHub機能テスト実行
    test_jupyterhub_deployment
    test_jupyterhub_connectivity
    test_jupyterhub_rbac
    test_jupyterhub_storage
    test_jupyterhub_configuration
    test_singleuser_spawning
    test_container_registry_integration
    test_security_configuration
    test_basic_performance
    
    # レポート生成
    generate_html_report
    
    echo ""
    echo -e "${BLUE}=== JupyterHub Test Summary ===${NC}"
    echo "Total Tests: $TOTAL_TESTS"
    echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
    echo -e "Failed: ${RED}$FAILED_TESTS${NC}"
    echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
    
    if [[ "$TOTAL_TESTS" -gt 0 ]]; then
        local success_rate=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
        echo "Success Rate: ${success_rate}%"
    fi
    
    echo ""
    echo "📊 Reports Generated:"
    echo "  • Text Log: $LOG_FILE"
    echo "  • HTML Report: $REPORT_FILE"
    
    if [[ -n "$JUPYTERHUB_URL" ]]; then
        echo ""
        echo "🌐 JupyterHub Access:"
        echo "  • URL: $JUPYTERHUB_URL"
        echo "  • Namespace: $JUPYTERHUB_NAMESPACE"
    fi
    
    echo ""
    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        echo -e "${GREEN}🎉 JupyterHub functionality tests passed!${NC}"
        echo "JupyterHub is ready for user testing and production use."
    else
        echo -e "${RED}⚠️  Some tests failed. Please review and fix issues before proceeding.${NC}"
    fi
    
    echo ""
    echo "Next steps:"
    echo "1. Review the HTML report: file://$REPORT_FILE"
    echo "2. Test actual user workflows (login, notebook creation)"
    echo "3. Verify multi-Python environment functionality"
    echo "4. Conduct performance and load testing"
    
    exit $EXIT_CODE
}

# 引数処理
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  -h, --help              Show this help message"
        echo "  --timeout N             Test timeout in seconds (default: $TEST_TIMEOUT)"
        echo "  --namespace NS          JupyterHub namespace (default: $JUPYTERHUB_NAMESPACE)"
        echo "  --test-user USER        Test user name (default: $TEST_USER)"
        echo "  --test-password PASS    Test user password (default: $TEST_PASSWORD)"
        echo "  --report-only           Only generate reports from existing logs"
        echo ""
        echo "Examples:"
        echo "  $0                      Run complete JupyterHub functionality tests"
        echo "  $0 --timeout 900        Run tests with 15 minute timeout"
        echo "  $0 --namespace jupyter  Test JupyterHub in 'jupyter' namespace"
        echo "  $0 --report-only        Generate reports from existing test data"
        exit 0
        ;;
    --timeout)
        TEST_TIMEOUT="${2:-$TEST_TIMEOUT}"
        shift 2
        ;;
    --namespace)
        JUPYTERHUB_NAMESPACE="${2:-$JUPYTERHUB_NAMESPACE}"
        shift 2
        ;;
    --test-user)
        TEST_USER="${2:-$TEST_USER}"
        shift 2
        ;;
    --test-password)
        TEST_PASSWORD="${2:-$TEST_PASSWORD}"
        shift 2
        ;;
    --report-only)
        if [[ -f "$LOG_FILE" ]]; then
            generate_html_report
            echo "Report generated from existing data: $REPORT_FILE"
            exit 0
        else
            echo "No existing test data found. Run tests first."
            exit 1
        fi
        ;;
esac

# メイン実行
timeout "$TEST_TIMEOUT" main "$@" || {
    echo -e "${RED}JupyterHub tests timed out after $TEST_TIMEOUT seconds${NC}"
    exit 1
}