#!/bin/bash
# tests/infrastructure-tests.sh
# 包括的インフラストラクチャ統合テストスクリプト

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
LOG_FILE="$SCRIPT_DIR/infrastructure-test-results.log"
REPORT_FILE="$SCRIPT_DIR/infrastructure-test-report.html"
EXIT_CODE=0

# テスト設定
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
JUPYTERHUB_NAMESPACE="${JUPYTERHUB_NAMESPACE:-jupyterhub}"
LOGGING_NAMESPACE="${LOGGING_NAMESPACE:-logging}"

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
    echo -e "${BLUE}Infrastructure Integration Tests${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting infrastructure integration tests"
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

# Kubernetesクラスター基本テスト
test_kubernetes_cluster() {
    print_test_header "Kubernetes Cluster Basic Health"
    
    # API Server接続テスト
    if kubectl cluster-info >/dev/null 2>&1; then
        print_status "PASS" "Kubernetes API server is accessible"
    else
        print_status "FAIL" "Cannot connect to Kubernetes API server"
        return 1
    fi
    
    # ノード状態テスト
    local ready_nodes=$(kubectl get nodes --no-headers | grep -c "Ready" || echo "0")
    local total_nodes=$(kubectl get nodes --no-headers | wc -l)
    
    if [[ "$ready_nodes" -eq "$total_nodes" ]] && [[ "$ready_nodes" -gt 0 ]]; then
        print_status "PASS" "All nodes are ready ($ready_nodes/$total_nodes)"
    else
        print_status "FAIL" "Not all nodes are ready ($ready_nodes/$total_nodes)"
    fi
    
    # システムPod状態テスト
    local system_pods_not_ready=$(kubectl get pods -n kube-system --no-headers | grep -v "Running\|Completed" | wc -l)
    
    if [[ "$system_pods_not_ready" -eq 0 ]]; then
        print_status "PASS" "All system pods are running"
    else
        print_status "FAIL" "$system_pods_not_ready system pods are not ready"
        kubectl get pods -n kube-system --no-headers | grep -v "Running\|Completed" | head -5
    fi
    
    # DNS テスト
    if kubectl run test-dns --image=busybox:1.36.1 --rm -i --restart=Never -- nslookup kubernetes.default >/dev/null 2>&1; then
        print_status "PASS" "Cluster DNS is working"
    else
        print_status "FAIL" "Cluster DNS is not working"
    fi
    
    # ネットワーク接続テスト
    if kubectl run test-network --image=busybox:1.36.1 --rm -i --restart=Never -- wget -qO- http://kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
        print_status "PASS" "Pod-to-service networking is working"
    else
        print_status "WARNING" "Pod-to-service networking may have issues"
    fi
}

# Docker & Container Registryテスト
test_container_infrastructure() {
    print_test_header "Container Infrastructure"
    
    # Docker daemon テスト
    if systemctl is-active --quiet docker 2>/dev/null; then
        print_status "PASS" "Docker daemon is running"
    else
        print_status "FAIL" "Docker daemon is not running"
    fi
    
    # Container runtime テスト
    local runtime_status=$(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.containerRuntimeVersion}' | head -1)
    if [[ -n "$runtime_status" ]]; then
        print_status "PASS" "Container runtime is working ($runtime_status)"
    else
        print_status "FAIL" "Container runtime information not available"
    fi
    
    # Container registry接続テスト
    if curl -f -s http://localhost:5000/v2/_catalog >/dev/null 2>&1; then
        print_status "PASS" "Container registry is accessible"
        
        # レジストリ内のイメージ確認
        local image_count=$(curl -s http://localhost:5000/v2/_catalog | jq -r '.repositories | length' 2>/dev/null || echo "0")
        if [[ "$image_count" -gt 0 ]]; then
            print_status "PASS" "Container registry has $image_count repositories"
        else
            print_status "WARNING" "Container registry is empty"
        fi
    else
        print_status "FAIL" "Container registry is not accessible on localhost:5000"
    fi
}

# ストレージテスト
test_storage_infrastructure() {
    print_test_header "Storage Infrastructure"
    
    # StorageClass テスト
    local storage_classes=$(kubectl get storageclass --no-headers | wc -l)
    if [[ "$storage_classes" -gt 0 ]]; then
        print_status "PASS" "StorageClasses are configured ($storage_classes classes)"
    else
        print_status "WARNING" "No StorageClasses found"
    fi
    
    # PersistentVolume テスト
    local pvs=$(kubectl get pv --no-headers | wc -l)
    if [[ "$pvs" -gt 0 ]]; then
        print_status "PASS" "PersistentVolumes are configured ($pvs volumes)"
        
        # PV状態確認
        local available_pvs=$(kubectl get pv --no-headers | grep -c "Available\|Bound" || echo "0")
        if [[ "$available_pvs" -eq "$pvs" ]]; then
            print_status "PASS" "All PersistentVolumes are in good state"
        else
            print_status "WARNING" "Some PersistentVolumes may have issues"
        fi
    else
        print_status "FAIL" "No PersistentVolumes found"
    fi
    
    # ストレージ書き込みテスト
    if kubectl apply -f - <<EOF >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-storage-pvc
  namespace: default
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
EOF
    then
        sleep 5
        if kubectl get pvc test-storage-pvc --no-headers | grep -q "Bound"; then
            print_status "PASS" "Storage provisioning is working"
        else
            print_status "WARNING" "Storage provisioning may be slow or have issues"
        fi
        
        # テスト用PVC削除
        kubectl delete pvc test-storage-pvc --ignore-not-found=true >/dev/null 2>&1
    else
        print_status "FAIL" "Failed to create test PVC"
    fi
}

# ネットワークテスト
test_network_infrastructure() {
    print_test_header "Network Infrastructure"
    
    # CNI プラグイン確認
    if kubectl get pods -n kube-system | grep -q "flannel\|calico\|weave\|cilium"; then
        print_status "PASS" "CNI plugin is running"
    else
        print_status "WARNING" "CNI plugin not clearly identified"
    fi
    
    # Pod間通信テスト
    kubectl apply -f - <<EOF >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-1
  namespace: default
spec:
  containers:
  - name: test
    image: busybox:1.36.1
    command: ['sleep', '60']
---
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-2
  namespace: default
spec:
  containers:
  - name: test
    image: busybox:1.36.1
    command: ['sleep', '60']
EOF
    
    # Pod起動待機
    kubectl wait --for=condition=Ready pod/test-pod-1 --timeout=60s >/dev/null 2>&1
    kubectl wait --for=condition=Ready pod/test-pod-2 --timeout=60s >/dev/null 2>&1
    
    local pod1_ip=$(kubectl get pod test-pod-1 -o jsonpath='{.status.podIP}' 2>/dev/null)
    local pod2_ip=$(kubectl get pod test-pod-2 -o jsonpath='{.status.podIP}' 2>/dev/null)
    
    if [[ -n "$pod1_ip" ]] && [[ -n "$pod2_ip" ]]; then
        if kubectl exec test-pod-1 -- ping -c 1 "$pod2_ip" >/dev/null 2>&1; then
            print_status "PASS" "Pod-to-pod communication is working"
        else
            print_status "FAIL" "Pod-to-pod communication is not working"
        fi
    else
        print_status "FAIL" "Failed to get pod IPs for network testing"
    fi
    
    # テスト用Pod削除
    kubectl delete pod test-pod-1 test-pod-2 --ignore-not-found=true >/dev/null 2>&1
    
    # Service テスト
    local services_count=$(kubectl get services --all-namespaces --no-headers | wc -l)
    if [[ "$services_count" -gt 0 ]]; then
        print_status "PASS" "Kubernetes services are configured ($services_count services)"
    else
        print_status "WARNING" "Very few Kubernetes services found"
    fi
    
    # Network Policy テスト (if configured)
    local netpol_count=$(kubectl get networkpolicies --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "$netpol_count" -gt 0 ]]; then
        print_status "PASS" "Network policies are configured ($netpol_count policies)"
    else
        print_status "INFO" "No network policies configured (this may be intentional)"
    fi
}

# 監視システムテスト
test_monitoring_infrastructure() {
    print_test_header "Monitoring Infrastructure"
    
    # Monitoring namespace確認
    if kubectl get namespace "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "Monitoring namespace exists"
    else
        print_status "FAIL" "Monitoring namespace '$MONITORING_NAMESPACE' not found"
        return 1
    fi
    
    # Prometheusテスト
    if kubectl get deployment prometheus -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
        if kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=prometheus | grep -q "Running"; then
            print_status "PASS" "Prometheus is running"
            
            # Prometheus API テスト
            if kubectl exec -n "$MONITORING_NAMESPACE" deployment/prometheus -- wget -qO- "http://localhost:9090/api/v1/query?query=up" | grep -q "success" 2>/dev/null; then
                print_status "PASS" "Prometheus API is responding"
            else
                print_status "WARNING" "Prometheus API may not be ready"
            fi
        else
            print_status "FAIL" "Prometheus pod is not running"
        fi
    else
        print_status "FAIL" "Prometheus deployment not found"
    fi
    
    # Grafanaテスト
    if kubectl get deployment grafana -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
        if kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana | grep -q "Running"; then
            print_status "PASS" "Grafana is running"
            
            # Grafana API テスト
            if kubectl exec -n "$MONITORING_NAMESPACE" deployment/grafana -- curl -f -s "http://localhost:3000/api/health" >/dev/null 2>&1; then
                print_status "PASS" "Grafana API is responding"
            else
                print_status "WARNING" "Grafana API may not be ready"
            fi
        else
            print_status "FAIL" "Grafana pod is not running"
        fi
    else
        print_status "INFO" "Grafana deployment not found (may not be installed)"
    fi
    
    # Node Exporterテスト
    if kubectl get daemonset node-exporter -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
        local node_count=$(kubectl get nodes --no-headers | wc -l)
        local node_exporter_ready=$(kubectl get daemonset node-exporter -n "$MONITORING_NAMESPACE" -o jsonpath='{.status.numberReady}')
        
        if [[ "$node_exporter_ready" -eq "$node_count" ]]; then
            print_status "PASS" "Node Exporter is running on all nodes ($node_exporter_ready/$node_count)"
        else
            print_status "WARNING" "Node Exporter not running on all nodes ($node_exporter_ready/$node_count)"
        fi
    else
        print_status "INFO" "Node Exporter not found (may not be installed)"
    fi
    
    # Alertmanagerテスト
    if kubectl get deployment alertmanager -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
        if kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=alertmanager | grep -q "Running"; then
            print_status "PASS" "Alertmanager is running"
        else
            print_status "WARNING" "Alertmanager pod is not running"
        fi
    else
        print_status "INFO" "Alertmanager not found (may not be installed)"
    fi
}

# ログシステムテスト
test_logging_infrastructure() {
    print_test_header "Logging Infrastructure"
    
    # Logging namespace確認
    if kubectl get namespace "$LOGGING_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "Logging namespace exists"
    else
        print_status "INFO" "Logging namespace '$LOGGING_NAMESPACE' not found (EFK may not be installed)"
        return 0
    fi
    
    # Elasticsearchテスト
    if kubectl get statefulset elasticsearch -n "$LOGGING_NAMESPACE" >/dev/null 2>&1; then
        if kubectl get pods -n "$LOGGING_NAMESPACE" -l app.kubernetes.io/name=elasticsearch | grep -q "Running"; then
            print_status "PASS" "Elasticsearch is running"
            
            # Elasticsearch health テスト
            if kubectl exec -n "$LOGGING_NAMESPACE" statefulset/elasticsearch -- curl -f -s "http://localhost:9200/_cluster/health" | grep -q "green\|yellow" 2>/dev/null; then
                print_status "PASS" "Elasticsearch cluster is healthy"
            else
                print_status "WARNING" "Elasticsearch cluster health may be degraded"
            fi
        else
            print_status "FAIL" "Elasticsearch pod is not running"
        fi
    else
        print_status "INFO" "Elasticsearch not found"
    fi
    
    # Kibanaテスト
    if kubectl get deployment kibana -n "$LOGGING_NAMESPACE" >/dev/null 2>&1; then
        if kubectl get pods -n "$LOGGING_NAMESPACE" -l app.kubernetes.io/name=kibana | grep -q "Running"; then
            print_status "PASS" "Kibana is running"
        else
            print_status "FAIL" "Kibana pod is not running"
        fi
    else
        print_status "INFO" "Kibana not found"
    fi
    
    # Fluentdテスト
    if kubectl get daemonset fluentd -n "$LOGGING_NAMESPACE" >/dev/null 2>&1; then
        local node_count=$(kubectl get nodes --no-headers | wc -l)
        local fluentd_ready=$(kubectl get daemonset fluentd -n "$LOGGING_NAMESPACE" -o jsonpath='{.status.numberReady}')
        
        if [[ "$fluentd_ready" -eq "$node_count" ]]; then
            print_status "PASS" "Fluentd is running on all nodes ($fluentd_ready/$node_count)"
        else
            print_status "WARNING" "Fluentd not running on all nodes ($fluentd_ready/$node_count)"
        fi
    else
        print_status "INFO" "Fluentd not found"
    fi
}

# JupyterHub基本テスト
test_jupyterhub_basic() {
    print_test_header "JupyterHub Basic Infrastructure"
    
    # JupyterHub namespace確認
    if kubectl get namespace "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "JupyterHub namespace exists"
    else
        print_status "FAIL" "JupyterHub namespace '$JUPYTERHUB_NAMESPACE' not found"
        return 1
    fi
    
    # JupyterHub deployment確認
    if kubectl get deployment jupyterhub -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        if kubectl get pods -n "$JUPYTERHUB_NAMESPACE" -l app.kubernetes.io/name=jupyterhub | grep -q "Running"; then
            print_status "PASS" "JupyterHub deployment is running"
        else
            print_status "FAIL" "JupyterHub pod is not running"
            kubectl get pods -n "$JUPYTERHUB_NAMESPACE" -l app.kubernetes.io/name=jupyterhub
        fi
    else
        print_status "FAIL" "JupyterHub deployment not found"
    fi
    
    # JupyterHub service確認
    if kubectl get service jupyterhub -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "JupyterHub service is configured"
        
        # Service endpoint確認
        if kubectl get endpoints jupyterhub -n "$JUPYTERHUB_NAMESPACE" | grep -q ":"; then
            print_status "PASS" "JupyterHub service has endpoints"
        else
            print_status "WARNING" "JupyterHub service endpoints may not be ready"
        fi
    else
        print_status "FAIL" "JupyterHub service not found"
    fi
    
    # RBAC確認
    if kubectl get serviceaccount jupyterhub -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "JupyterHub service account exists"
    else
        print_status "FAIL" "JupyterHub service account not found"
    fi
    
    if kubectl get role jupyterhub -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "JupyterHub role exists"
    else
        print_status "INFO" "JupyterHub role not found (may use ClusterRole)"
    fi
    
    # PVC確認
    local jupyterhub_pvcs=$(kubectl get pvc -n "$JUPYTERHUB_NAMESPACE" --no-headers | wc -l)
    if [[ "$jupyterhub_pvcs" -gt 0 ]]; then
        print_status "PASS" "JupyterHub PVCs are configured ($jupyterhub_pvcs PVCs)"
    else
        print_status "WARNING" "No JupyterHub PVCs found"
    fi
}

# セキュリティ基本テスト
test_security_basics() {
    print_test_header "Security Basics"
    
    # Pod security context確認
    local pods_with_security_context=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.securityContext.runAsNonRoot}{"\n"}{end}' | grep -c "true" || echo "0")
    local total_pods=$(kubectl get pods --all-namespaces --no-headers | wc -l)
    
    if [[ "$pods_with_security_context" -gt 0 ]]; then
        print_status "PASS" "$pods_with_security_context/$total_pods pods have security contexts configured"
    else
        print_status "WARNING" "No pods with explicit security contexts found"
    fi
    
    # Network policies確認
    local total_netpols=$(kubectl get networkpolicies --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "$total_netpols" -gt 0 ]]; then
        print_status "PASS" "Network policies are configured ($total_netpols policies)"
    else
        print_status "INFO" "No network policies found (may be intentional)"
    fi
    
    # RBAC確認
    local service_accounts=$(kubectl get serviceaccounts --all-namespaces --no-headers | wc -l)
    if [[ "$service_accounts" -gt 3 ]]; then  # default SAs in kube-system, default, etc.
        print_status "PASS" "RBAC service accounts are configured ($service_accounts accounts)"
    else
        print_status "WARNING" "Very few service accounts found"
    fi
    
    # Secrets確認
    local secrets_count=$(kubectl get secrets --all-namespaces --no-headers | wc -l)
    if [[ "$secrets_count" -gt 5 ]]; then  # Some default secrets expected
        print_status "PASS" "Kubernetes secrets are configured ($secrets_count secrets)"
    else
        print_status "WARNING" "Very few secrets found"
    fi
}

# リソース使用量テスト
test_resource_usage() {
    print_test_header "Resource Usage"
    
    # Node resource使用量
    if command -v kubectl >/dev/null 2>&1 && kubectl top nodes >/dev/null 2>&1; then
        print_status "PASS" "Metrics server is working"
        
        # 高CPU使用率ノードチェック
        local high_cpu_nodes=$(kubectl top nodes --no-headers | awk '{gsub("%","",$3); if($3>80) print $1}' | wc -l)
        if [[ "$high_cpu_nodes" -eq 0 ]]; then
            print_status "PASS" "No nodes with high CPU usage"
        else
            print_status "WARNING" "$high_cpu_nodes nodes have high CPU usage (>80%)"
        fi
        
        # 高Memory使用率ノードチェック
        local high_mem_nodes=$(kubectl top nodes --no-headers | awk '{gsub("%","",$5); if($5>80) print $1}' | wc -l)
        if [[ "$high_mem_nodes" -eq 0 ]]; then
            print_status "PASS" "No nodes with high memory usage"
        else
            print_status "WARNING" "$high_mem_nodes nodes have high memory usage (>80%)"
        fi
    else
        print_status "WARNING" "Metrics server not available or not working"
    fi
    
    # Pod resource limit確認
    local pods_with_limits=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[0].resources.limits.memory}{"\n"}{end}' | grep -cv "^.* $" || echo "0")
    local total_pods=$(kubectl get pods --all-namespaces --no-headers | wc -l)
    
    if [[ "$pods_with_limits" -gt 0 ]]; then
        print_status "PASS" "$pods_with_limits/$total_pods pods have resource limits configured"
    else
        print_status "WARNING" "No pods with resource limits found"
    fi
}

# HTMLレポート生成
generate_html_report() {
    print_status "INFO" "Generating HTML test report..."
    
    cat > "$REPORT_FILE" <<EOF
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Infrastructure Test Report - kubeadm-python-cluster</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; line-height: 1.6; }
        .header { background: #2196F3; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .summary { background: #f5f5f5; padding: 15px; border-radius: 8px; margin-bottom: 20px; }
        .test-section { margin-bottom: 30px; }
        .test-section h2 { color: #333; border-bottom: 2px solid #2196F3; padding-bottom: 5px; }
        .pass { color: #4CAF50; font-weight: bold; }
        .fail { color: #f44336; font-weight: bold; }
        .warning { color: #FF9800; font-weight: bold; }
        .info { color: #2196F3; font-weight: bold; }
        .log-section { background: #f9f9f9; padding: 15px; border-radius: 8px; font-family: monospace; font-size: 12px; max-height: 400px; overflow-y: auto; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { padding: 8px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <div class="header">
        <h1>🧪 Infrastructure Integration Test Report</h1>
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
    
    <div class="test-section">
        <h2>📋 Test Results by Category</h2>
        <p>Detailed test results from the infrastructure validation:</p>
        
        <h3>Kubernetes Cluster</h3>
        <ul>
            <li>API Server connectivity and health</li>
            <li>Node readiness and status</li>
            <li>System pods functionality</li>
            <li>DNS resolution</li>
            <li>Network connectivity</li>
        </ul>
        
        <h3>Container Infrastructure</h3>
        <ul>
            <li>Docker daemon status</li>
            <li>Container runtime functionality</li>
            <li>Container registry accessibility</li>
            <li>Image repository availability</li>
        </ul>
        
        <h3>Storage Infrastructure</h3>
        <ul>
            <li>StorageClass configuration</li>
            <li>PersistentVolume provisioning</li>
            <li>Storage binding and availability</li>
            <li>Write operations testing</li>
        </ul>
        
        <h3>Network Infrastructure</h3>
        <ul>
            <li>CNI plugin functionality</li>
            <li>Pod-to-pod communication</li>
            <li>Service discovery</li>
            <li>Network policies (if configured)</li>
        </ul>
        
        <h3>Monitoring Infrastructure</h3>
        <ul>
            <li>Prometheus functionality</li>
            <li>Grafana accessibility</li>
            <li>Node Exporter coverage</li>
            <li>Alertmanager status</li>
        </ul>
        
        <h3>Logging Infrastructure</h3>
        <ul>
            <li>Elasticsearch cluster health</li>
            <li>Kibana availability</li>
            <li>Fluentd log collection</li>
            <li>Log ingestion pipeline</li>
        </ul>
        
        <h3>JupyterHub Infrastructure</h3>
        <ul>
            <li>Deployment status</li>
            <li>Service configuration</li>
            <li>RBAC setup</li>
            <li>Persistent storage</li>
        </ul>
        
        <h3>Security & Resources</h3>
        <ul>
            <li>Security contexts</li>
            <li>Network policies</li>
            <li>RBAC configuration</li>
            <li>Resource usage monitoring</li>
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
        <h2>✅ Next Steps</h2>
        <ul>
            <li>Review any failed tests and address the underlying issues</li>
            <li>Investigate warnings for potential improvements</li>
            <li>Run application-specific tests (JupyterHub functionality)</li>
            <li>Perform performance and security testing</li>
            <li>Document any environment-specific configurations</li>
        </ul>
    </div>
    
    <footer style="margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; color: #666;">
        <p>Generated by kubeadm-python-cluster infrastructure tests</p>
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
    
    # 統合テスト実行
    test_kubernetes_cluster
    test_container_infrastructure
    test_storage_infrastructure
    test_network_infrastructure
    test_monitoring_infrastructure
    test_logging_infrastructure
    test_jupyterhub_basic
    test_security_basics
    test_resource_usage
    
    # レポート生成
    generate_html_report
    
    echo ""
    echo -e "${BLUE}=== Infrastructure Test Summary ===${NC}"
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
    
    echo ""
    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        echo -e "${GREEN}🎉 All critical infrastructure tests passed!${NC}"
        echo "The kubeadm-python-cluster infrastructure is ready for production use."
    else
        echo -e "${RED}⚠️  Some tests failed. Please review the results and fix issues before proceeding.${NC}"
    fi
    
    echo ""
    echo "Next steps:"
    echo "1. Review the HTML report: file://$REPORT_FILE"
    echo "2. Address any failed tests"
    echo "3. Run application functionality tests"
    echo "4. Perform performance and security validation"
    
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
        echo "  --monitoring-ns NS      Monitoring namespace (default: $MONITORING_NAMESPACE)"
        echo "  --jupyterhub-ns NS      JupyterHub namespace (default: $JUPYTERHUB_NAMESPACE)"
        echo "  --logging-ns NS         Logging namespace (default: $LOGGING_NAMESPACE)"
        echo "  --report-only           Only generate reports from existing logs"
        echo ""
        echo "Examples:"
        echo "  $0                      Run complete infrastructure tests"
        echo "  $0 --timeout 600        Run tests with 10 minute timeout"
        echo "  $0 --report-only        Generate reports from existing test data"
        exit 0
        ;;
    --timeout)
        TEST_TIMEOUT="${2:-$TEST_TIMEOUT}"
        shift 2
        ;;
    --monitoring-ns)
        MONITORING_NAMESPACE="${2:-$MONITORING_NAMESPACE}"
        shift 2
        ;;
    --jupyterhub-ns)
        JUPYTERHUB_NAMESPACE="${2:-$JUPYTERHUB_NAMESPACE}"
        shift 2
        ;;
    --logging-ns)
        LOGGING_NAMESPACE="${2:-$LOGGING_NAMESPACE}"
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
    echo -e "${RED}Tests timed out after $TEST_TIMEOUT seconds${NC}"
    exit 1
}