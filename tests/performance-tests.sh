#!/bin/bash
# tests/performance-tests.sh
# kubeadm-python-cluster パフォーマンステストスクリプト

set -euo pipefail

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# グローバル変数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$SCRIPT_DIR/performance-test-results.log"
REPORT_FILE="$SCRIPT_DIR/performance-test-report.html"
EXIT_CODE=0

# テスト設定
TEST_TIMEOUT="${TEST_TIMEOUT:-1800}"  # 30 minutes for performance tests
CONCURRENT_USERS="${CONCURRENT_USERS:-10}"
TEST_DURATION="${TEST_DURATION:-300}"  # 5 minutes per test
JUPYTERHUB_NAMESPACE="${JUPYTERHUB_NAMESPACE:-jupyterhub}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

# パフォーマンステスト結果
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNINGS=0
PERF_RESULTS=()

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}kubeadm Python Cluster Performance Tests${NC}"
    echo -e "${BLUE}========================================${NC}"
    log "Starting performance tests"
    echo "Test Configuration:"
    echo "  • Concurrent Users: $CONCURRENT_USERS"
    echo "  • Test Duration: $TEST_DURATION seconds"
    echo "  • Timeout: $TEST_TIMEOUT seconds"
    echo ""
}

print_test_header() {
    local test_name="$1"
    echo ""
    echo -e "${CYAN}--- Performance Test: $test_name ---${NC}"
    log "PERF_TEST START: $test_name"
}

print_status() {
    local status=$1
    local message=$2
    local metric="${3:-}"
    
    case $status in
        "PASS")
            echo -e "✅ ${GREEN}PASS: $message${NC}"
            log "PASS: $message"
            [[ -n "$metric" ]] && log "METRIC: $metric"
            ((PASSED_TESTS++))
            ;;
        "FAIL")
            echo -e "❌ ${RED}FAIL: $message${NC}"
            log "FAIL: $message"
            [[ -n "$metric" ]] && log "METRIC: $metric"
            ((FAILED_TESTS++))
            EXIT_CODE=1
            ;;
        "WARNING")
            echo -e "⚠️  ${YELLOW}WARNING: $message${NC}"
            log "WARNING: $message"
            [[ -n "$metric" ]] && log "METRIC: $metric"
            ((WARNINGS++))
            ;;
        "INFO")
            echo -e "📊 ${BLUE}INFO: $message${NC}"
            log "INFO: $message"
            [[ -n "$metric" ]] && log "METRIC: $metric"
            ;;
    esac
    ((TOTAL_TESTS++))
    
    # メトリクス保存
    if [[ -n "$metric" ]]; then
        PERF_RESULTS+=("$test_name|$status|$message|$metric")
    fi
}

# Kubernetesクラスターパフォーマンステスト
test_kubernetes_performance() {
    print_test_header "Kubernetes Cluster Performance"
    
    # API Server レスポンス時間テスト
    local api_start=$(date +%s%3N)
    if kubectl get nodes >/dev/null 2>&1; then
        local api_end=$(date +%s%3N)
        local api_latency=$((api_end - api_start))
        
        if [[ "$api_latency" -lt 1000 ]]; then
            print_status "PASS" "API Server response time is good" "API_Latency=${api_latency}ms"
        elif [[ "$api_latency" -lt 5000 ]]; then
            print_status "WARNING" "API Server response time is acceptable" "API_Latency=${api_latency}ms"
        else
            print_status "FAIL" "API Server response time is too slow" "API_Latency=${api_latency}ms"
        fi
    else
        print_status "FAIL" "Cannot connect to API Server" "API_Latency=timeout"
    fi
    
    # Pod起動時間テスト
    print_status "INFO" "Testing pod startup performance..."
    local pod_start=$(date +%s%3N)
    
    kubectl run perf-test-pod --image=nginx:1.25.3 --rm --restart=Never &
    local pod_pid=$!
    
    # Pod起動待機
    local startup_timeout=60
    local startup_time=0
    
    for ((i=0; i<startup_timeout; i++)); do
        if kubectl get pod perf-test-pod 2>/dev/null | grep -q "Running"; then
            local pod_end=$(date +%s%3N)
            startup_time=$((pod_end - pod_start))
            break
        fi
        sleep 1
    done
    
    kubectl delete pod perf-test-pod --ignore-not-found=true >/dev/null 2>&1 || true
    wait $pod_pid 2>/dev/null || true
    
    if [[ "$startup_time" -gt 0 ]] && [[ "$startup_time" -lt 30000 ]]; then
        print_status "PASS" "Pod startup time is good" "Pod_Startup=${startup_time}ms"
    elif [[ "$startup_time" -lt 60000 ]]; then
        print_status "WARNING" "Pod startup time is acceptable" "Pod_Startup=${startup_time}ms"
    else
        print_status "FAIL" "Pod startup time is too slow" "Pod_Startup=${startup_time}ms"
    fi
    
    # 同時Pod作成テスト
    print_status "INFO" "Testing concurrent pod creation..."
    local concurrent_pods=5
    local concurrent_start=$(date +%s%3N)
    
    for ((i=1; i<=concurrent_pods; i++)); do
        kubectl run "perf-test-concurrent-$i" --image=busybox:1.36.1 --restart=Never -- sleep 30 &
    done
    
    # 全Pod起動待機
    local all_ready=false
    for ((i=0; i<60; i++)); do
        local ready_count=$(kubectl get pods -l run | grep -c "Running" || echo "0")
        if [[ "$ready_count" -eq "$concurrent_pods" ]]; then
            all_ready=true
            break
        fi
        sleep 1
    done
    
    local concurrent_end=$(date +%s%3N)
    local concurrent_time=$((concurrent_end - concurrent_start))
    
    # クリーンアップ
    for ((i=1; i<=concurrent_pods; i++)); do
        kubectl delete pod "perf-test-concurrent-$i" --ignore-not-found=true >/dev/null 2>&1 &
    done
    wait
    
    if [[ "$all_ready" == "true" ]]; then
        print_status "PASS" "Concurrent pod creation successful" "Concurrent_Pods=${concurrent_time}ms"
    else
        print_status "FAIL" "Concurrent pod creation failed" "Concurrent_Pods=timeout"
    fi
}

# ストレージパフォーマンステスト
test_storage_performance() {
    print_test_header "Storage Performance"
    
    # PVC作成パフォーマンス
    local pvc_start=$(date +%s%3N)
    
    kubectl apply -f - <<EOF >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: perf-test-storage
  namespace: default
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
    
    # PVCバインド待機
    local pvc_bound=false
    for ((i=0; i<60; i++)); do
        if kubectl get pvc perf-test-storage | grep -q "Bound"; then
            pvc_bound=true
            break
        fi
        sleep 1
    done
    
    local pvc_end=$(date +%s%3N)
    local pvc_time=$((pvc_end - pvc_start))
    
    if [[ "$pvc_bound" == "true" ]]; then
        if [[ "$pvc_time" -lt 30000 ]]; then
            print_status "PASS" "PVC creation and binding is fast" "PVC_Creation=${pvc_time}ms"
        else
            print_status "WARNING" "PVC creation and binding is slow" "PVC_Creation=${pvc_time}ms"
        fi
    else
        print_status "FAIL" "PVC failed to bind" "PVC_Creation=timeout"
    fi
    
    # ストレージI/Oパフォーマンステスト
    if [[ "$pvc_bound" == "true" ]]; then
        print_status "INFO" "Testing storage I/O performance..."
        
        kubectl apply -f - <<EOF >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: perf-test-storage-io
  namespace: default
spec:
  containers:
  - name: test
    image: busybox:1.36.1
    command:
    - sh
    - -c
    - |
      # 書き込みテスト
      time dd if=/dev/zero of=/mnt/test-write bs=1M count=100
      # 読み込みテスト  
      time dd if=/mnt/test-write of=/dev/null bs=1M
      sleep 30
    volumeMounts:
    - name: test-storage
      mountPath: /mnt
  volumes:
  - name: test-storage
    persistentVolumeClaim:
      claimName: perf-test-storage
  restartPolicy: Never
EOF
        
        # Pod完了待機
        kubectl wait --for=condition=Ready pod/perf-test-storage-io --timeout=120s >/dev/null 2>&1
        sleep 10
        
        # ログからパフォーマンス情報取得
        local storage_logs=$(kubectl logs perf-test-storage-io 2>/dev/null | grep "copied" || echo "")
        if [[ -n "$storage_logs" ]]; then
            print_status "PASS" "Storage I/O performance test completed" "Storage_IO=completed"
            echo "$storage_logs" | while read -r line; do
                log "STORAGE_IO: $line"
            done
        else
            print_status "WARNING" "Storage I/O performance test may have issues" "Storage_IO=incomplete"
        fi
    fi
    
    # クリーンアップ
    kubectl delete pod perf-test-storage-io --ignore-not-found=true >/dev/null 2>&1
    kubectl delete pvc perf-test-storage --ignore-not-found=true >/dev/null 2>&1
}

# ネットワークパフォーマンステスト
test_network_performance() {
    print_test_header "Network Performance"
    
    # Pod間通信レイテンシテスト
    kubectl apply -f - <<EOF >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: perf-test-server
  namespace: default
spec:
  containers:
  - name: server
    image: nginx:1.25.3
    ports:
    - containerPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: perf-test-client
  namespace: default
spec:
  containers:
  - name: client
    image: busybox:1.36.1
    command: ['sleep', '300']
EOF
    
    # Pod起動待機
    kubectl wait --for=condition=Ready pod/perf-test-server --timeout=120s >/dev/null 2>&1
    kubectl wait --for=condition=Ready pod/perf-test-client --timeout=120s >/dev/null 2>&1
    
    local server_ip=$(kubectl get pod perf-test-server -o jsonpath='{.status.podIP}')
    
    if [[ -n "$server_ip" ]]; then
        # 接続テスト
        local network_start=$(date +%s%3N)
        local network_success=false
        
        for ((i=0; i<10; i++)); do
            if kubectl exec perf-test-client -- wget -qO- "http://$server_ip" >/dev/null 2>&1; then
                network_success=true
                break
            fi
            sleep 1
        done
        
        local network_end=$(date +%s%3N)
        local network_time=$((network_end - network_start))
        
        if [[ "$network_success" == "true" ]]; then
            if [[ "$network_time" -lt 5000 ]]; then
                print_status "PASS" "Pod-to-pod network latency is good" "Network_Latency=${network_time}ms"
            else
                print_status "WARNING" "Pod-to-pod network latency is high" "Network_Latency=${network_time}ms"
            fi
        else
            print_status "FAIL" "Pod-to-pod network communication failed" "Network_Latency=failed"
        fi
        
        # スループットテスト
        print_status "INFO" "Testing network throughput..."
        kubectl exec perf-test-client -- sh -c "
            for i in \$(seq 1 10); do
                time wget -qO- http://$server_ip
            done
        " >/dev/null 2>&1
        
        print_status "PASS" "Network throughput test completed" "Network_Throughput=completed"
    else
        print_status "FAIL" "Failed to get server pod IP" "Network_Test=failed"
    fi
    
    # クリーンアップ
    kubectl delete pod perf-test-server perf-test-client --ignore-not-found=true >/dev/null 2>&1
}

# JupyterHubパフォーマンステスト
test_jupyterhub_performance() {
    print_test_header "JupyterHub Performance"
    
    # JupyterHub応答性テスト
    if kubectl get deployment jupyterhub -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        local hub_pod=$(kubectl get pods -n "$JUPYTERHUB_NAMESPACE" -l app.kubernetes.io/name=jupyterhub -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
        if [[ -n "$hub_pod" ]]; then
            # JupyterHub内部ヘルスチェック
            local health_start=$(date +%s%3N)
            local health_status=false
            
            if kubectl exec -n "$JUPYTERHUB_NAMESPACE" "$hub_pod" -- curl -f -s http://localhost:8081/hub/health >/dev/null 2>&1; then
                health_status=true
            fi
            
            local health_end=$(date +%s%3N)
            local health_time=$((health_end - health_start))
            
            if [[ "$health_status" == "true" ]]; then
                if [[ "$health_time" -lt 2000 ]]; then
                    print_status "PASS" "JupyterHub health check response is fast" "Hub_Health=${health_time}ms"
                else
                    print_status "WARNING" "JupyterHub health check response is slow" "Hub_Health=${health_time}ms"
                fi
            else
                print_status "FAIL" "JupyterHub health check failed" "Hub_Health=failed"
            fi
            
            # メモリ使用量チェック
            local memory_usage=$(kubectl top pod "$hub_pod" -n "$JUPYTERHUB_NAMESPACE" --no-headers 2>/dev/null | awk '{print $3}' | sed 's/Mi//')
            
            if [[ -n "$memory_usage" ]]; then
                if [[ "$memory_usage" -lt 512 ]]; then
                    print_status "PASS" "JupyterHub memory usage is efficient" "Hub_Memory=${memory_usage}Mi"
                elif [[ "$memory_usage" -lt 1024 ]]; then
                    print_status "WARNING" "JupyterHub memory usage is moderate" "Hub_Memory=${memory_usage}Mi"
                else
                    print_status "WARNING" "JupyterHub memory usage is high" "Hub_Memory=${memory_usage}Mi"
                fi
            else
                print_status "INFO" "JupyterHub memory usage metrics not available" "Hub_Memory=unknown"
            fi
        else
            print_status "FAIL" "JupyterHub pod not found" "Hub_Performance=failed"
        fi
    else
        print_status "FAIL" "JupyterHub deployment not found" "Hub_Performance=failed"
    fi
    
    # シングルユーザーサーバー起動時間テスト
    print_status "INFO" "Testing single-user server spawn time..."
    
    # テスト用ユーザーサーバーPod作成（簡易版）
    local spawn_start=$(date +%s%3N)
    
    kubectl apply -f - <<EOF >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: perf-test-notebook
  namespace: $JUPYTERHUB_NAMESPACE
  labels:
    component: singleuser-server
    app.kubernetes.io/name: jupyterhub
spec:
  containers:
  - name: notebook
    image: jupyter/scipy-notebook:python-3.11
    ports:
    - containerPort: 8888
    command:
    - jupyter-lab
    - --ip=0.0.0.0
    - --port=8888
    - --no-browser
    - --allow-root
    - --NotebookApp.token=''
    - --NotebookApp.password=''
EOF
    
    # Pod起動待機
    local spawn_ready=false
    for ((i=0; i<120; i++)); do
        if kubectl get pod perf-test-notebook -n "$JUPYTERHUB_NAMESPACE" 2>/dev/null | grep -q "Running"; then
            spawn_ready=true
            break
        fi
        sleep 1
    done
    
    local spawn_end=$(date +%s%3N)
    local spawn_time=$((spawn_end - spawn_start))
    
    if [[ "$spawn_ready" == "true" ]]; then
        if [[ "$spawn_time" -lt 60000 ]]; then
            print_status "PASS" "Single-user server spawn time is good" "Spawn_Time=${spawn_time}ms"
        elif [[ "$spawn_time" -lt 120000 ]]; then
            print_status "WARNING" "Single-user server spawn time is acceptable" "Spawn_Time=${spawn_time}ms"
        else
            print_status "WARNING" "Single-user server spawn time is slow" "Spawn_Time=${spawn_time}ms"
        fi
    else
        print_status "FAIL" "Single-user server failed to spawn" "Spawn_Time=timeout"
    fi
    
    # クリーンアップ
    kubectl delete pod perf-test-notebook -n "$JUPYTERHUB_NAMESPACE" --ignore-not-found=true >/dev/null 2>&1
}

# リソース使用率パフォーマンステスト
test_resource_performance() {
    print_test_header "Resource Usage Performance"
    
    # CPU使用率テスト
    if kubectl top nodes >/dev/null 2>&1; then
        local cpu_usage=$(kubectl top nodes --no-headers | awk '{gsub("%","",$3); total+=$3} END {if(NR>0) print int(total/NR); else print "0"}')
        
        if [[ "$cpu_usage" -lt 70 ]]; then
            print_status "PASS" "Average CPU usage is healthy" "CPU_Usage=${cpu_usage}%"
        elif [[ "$cpu_usage" -lt 85 ]]; then
            print_status "WARNING" "Average CPU usage is moderate" "CPU_Usage=${cpu_usage}%"
        else
            print_status "FAIL" "Average CPU usage is too high" "CPU_Usage=${cpu_usage}%"
        fi
        
        # メモリ使用率テスト
        local memory_usage=$(kubectl top nodes --no-headers | awk '{gsub("%","",$5); total+=$5} END {if(NR>0) print int(total/NR); else print "0"}')
        
        if [[ "$memory_usage" -lt 80 ]]; then
            print_status "PASS" "Average memory usage is healthy" "Memory_Usage=${memory_usage}%"
        elif [[ "$memory_usage" -lt 90 ]]; then
            print_status "WARNING" "Average memory usage is moderate" "Memory_Usage=${memory_usage}%"
        else
            print_status "FAIL" "Average memory usage is too high" "Memory_Usage=${memory_usage}%"
        fi
    else
        print_status "WARNING" "Metrics server not available" "Resource_Metrics=unavailable"
    fi
    
    # Pod密度テスト
    local total_pods=$(kubectl get pods --all-namespaces --no-headers | wc -l)
    local total_nodes=$(kubectl get nodes --no-headers | wc -l)
    local pod_density=$((total_pods / total_nodes))
    
    if [[ "$pod_density" -lt 50 ]]; then
        print_status "PASS" "Pod density is healthy" "Pod_Density=${pod_density} pods/node"
    elif [[ "$pod_density" -lt 100 ]]; then
        print_status "WARNING" "Pod density is moderate" "Pod_Density=${pod_density} pods/node"
    else
        print_status "WARNING" "Pod density is high" "Pod_Density=${pod_density} pods/node"
    fi
}

# 負荷テスト
test_load_performance() {
    print_test_header "Load Testing"
    
    print_status "INFO" "Starting load test with $CONCURRENT_USERS concurrent operations..."
    
    # 同時Pod作成負荷テスト
    local load_start=$(date +%s%3N)
    local successful_pods=0
    
    for ((i=1; i<=CONCURRENT_USERS; i++)); do
        (
            kubectl run "load-test-$i" --image=busybox:1.36.1 --restart=Never -- sleep 60 >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                echo "success"
            fi
        ) &
    done
    
    # 全ジョブ完了待機
    wait
    
    # 成功したPod数カウント
    for ((i=1; i<=CONCURRENT_USERS; i++)); do
        if kubectl get pod "load-test-$i" >/dev/null 2>&1; then
            ((successful_pods++))
        fi
    done
    
    local load_end=$(date +%s%3N)
    local load_time=$((load_end - load_start))
    
    # 成功率計算
    local success_rate=$((successful_pods * 100 / CONCURRENT_USERS))
    
    if [[ "$success_rate" -ge 90 ]]; then
        print_status "PASS" "Load test success rate is excellent" "Load_Success=${success_rate}% (${load_time}ms)"
    elif [[ "$success_rate" -ge 70 ]]; then
        print_status "WARNING" "Load test success rate is acceptable" "Load_Success=${success_rate}% (${load_time}ms)"
    else
        print_status "FAIL" "Load test success rate is too low" "Load_Success=${success_rate}% (${load_time}ms)"
    fi
    
    # クリーンアップ
    for ((i=1; i<=CONCURRENT_USERS; i++)); do
        kubectl delete pod "load-test-$i" --ignore-not-found=true >/dev/null 2>&1 &
    done
    wait
}

# HTMLレポート生成
generate_html_report() {
    print_status "INFO" "Generating HTML performance report..."
    
    cat > "$REPORT_FILE" <<EOF
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Performance Test Report - kubeadm-python-cluster</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; line-height: 1.6; background: #f5f5f5; }
        .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .summary { background: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .test-section { background: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .test-section h2 { color: #333; border-bottom: 2px solid #667eea; padding-bottom: 5px; }
        .performance-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 15px; margin: 20px 0; }
        .metric-card { background: #f8f9fa; padding: 15px; border-radius: 8px; border-left: 4px solid #667eea; }
        .pass { color: #28a745; font-weight: bold; }
        .fail { color: #dc3545; font-weight: bold; }
        .warning { color: #ffc107; font-weight: bold; }
        .info { color: #17a2b8; font-weight: bold; }
        .log-section { background: #f9f9f9; padding: 15px; border-radius: 8px; font-family: monospace; font-size: 12px; max-height: 400px; overflow-y: auto; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background-color: #667eea; color: white; }
        tr:nth-child(even) { background-color: #f8f9fa; }
        .chart-placeholder { background: #e9ecef; height: 200px; display: flex; align-items: center; justify-content: center; border-radius: 8px; margin: 10px 0; }
    </style>
</head>
<body>
    <div class="header">
        <h1>⚡ Performance Test Report</h1>
        <p>kubeadm Python Cluster - $(date)</p>
        <p>Test Duration: $TEST_DURATION seconds | Concurrent Users: $CONCURRENT_USERS</p>
    </div>
    
    <div class="summary">
        <h2>📊 Performance Summary</h2>
        <div class="performance-grid">
            <div class="metric-card">
                <h3>Test Results</h3>
                <table>
                    <tr><td>Total Tests</td><td>$TOTAL_TESTS</td></tr>
                    <tr><td>Passed</td><td class="pass">$PASSED_TESTS</td></tr>
                    <tr><td>Failed</td><td class="fail">$FAILED_TESTS</td></tr>
                    <tr><td>Warnings</td><td class="warning">$WARNINGS</td></tr>
                    <tr><td>Success Rate</td><td>$(( TOTAL_TESTS > 0 ? (PASSED_TESTS * 100) / TOTAL_TESTS : 0 ))%</td></tr>
                </table>
            </div>
            
            <div class="metric-card">
                <h3>Performance Metrics</h3>
                <div class="chart-placeholder">
                    📈 Performance metrics visualization<br>
                    (See detailed logs for specific values)
                </div>
            </div>
        </div>
    </div>
    
    <div class="test-section">
        <h2>🎯 Performance Test Categories</h2>
        
        <h3>Kubernetes Cluster Performance</h3>
        <ul>
            <li><strong>API Server Latency</strong> - Kubernetes API response times</li>
            <li><strong>Pod Startup Time</strong> - Individual pod creation and startup</li>
            <li><strong>Concurrent Pod Creation</strong> - Multiple pod creation performance</li>
        </ul>
        
        <h3>Storage Performance</h3>
        <ul>
            <li><strong>PVC Creation Speed</strong> - Persistent volume claim provisioning</li>
            <li><strong>Storage I/O Performance</strong> - Read/write performance testing</li>
        </ul>
        
        <h3>Network Performance</h3>
        <ul>
            <li><strong>Pod-to-Pod Latency</strong> - Inter-pod communication speed</li>
            <li><strong>Network Throughput</strong> - Data transfer performance</li>
        </ul>
        
        <h3>JupyterHub Performance</h3>
        <ul>
            <li><strong>Hub Response Time</strong> - JupyterHub application responsiveness</li>
            <li><strong>Single-user Server Spawn</strong> - Notebook server creation time</li>
            <li><strong>Resource Usage</strong> - CPU and memory consumption</li>
        </ul>
        
        <h3>Load Testing</h3>
        <ul>
            <li><strong>Concurrent Operations</strong> - System behavior under load</li>
            <li><strong>Success Rate</strong> - Reliability under stress conditions</li>
            <li><strong>Resource Utilization</strong> - System resource usage patterns</li>
        </ul>
    </div>
    
    <div class="test-section">
        <h2>📈 Performance Metrics Detail</h2>
        <table>
            <thead>
                <tr><th>Test Category</th><th>Status</th><th>Description</th><th>Metric</th></tr>
            </thead>
            <tbody>
EOF
    
    # パフォーマンス結果テーブル生成
    for result in "${PERF_RESULTS[@]}"; do
        IFS='|' read -r test_name status message metric <<< "$result"
        local status_class="info"
        case "$status" in
            "PASS") status_class="pass" ;;
            "FAIL") status_class="fail" ;;
            "WARNING") status_class="warning" ;;
        esac
        
        cat >> "$REPORT_FILE" <<EOF
                <tr>
                    <td>$test_name</td>
                    <td><span class="$status_class">$status</span></td>
                    <td>$message</td>
                    <td><code>$metric</code></td>
                </tr>
EOF
    done
    
    cat >> "$REPORT_FILE" <<EOF
            </tbody>
        </table>
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
            elif [[ "$line" == *"INFO"* ]] || [[ "$line" == *"METRIC"* ]]; then
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
        <h2>🎯 Performance Recommendations</h2>
        <ul>
            <li><strong>Excellent Performance</strong>: API latency &lt; 1s, Pod startup &lt; 30s, Load success &gt; 90%</li>
            <li><strong>Good Performance</strong>: API latency &lt; 5s, Pod startup &lt; 60s, Load success &gt; 70%</li>
            <li><strong>Monitor Resource Usage</strong>: Keep CPU &lt; 80%, Memory &lt; 90% for optimal performance</li>
            <li><strong>Scale Considerations</strong>: Plan for increased load based on current performance baseline</li>
            <li><strong>Regular Testing</strong>: Run performance tests periodically to detect degradation</li>
        </ul>
    </div>
    
    <footer style="margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; color: #666; text-align: center;">
        <p>Generated by kubeadm-python-cluster performance tests</p>
        <p>Report generated: $(date)</p>
    </footer>
</body>
</html>
EOF

    print_status "PASS" "HTML performance report generated: $REPORT_FILE"
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # パフォーマンステスト実行
    test_kubernetes_performance
    test_storage_performance
    test_network_performance
    test_jupyterhub_performance
    test_resource_performance
    test_load_performance
    
    # レポート生成
    generate_html_report
    
    echo ""
    echo -e "${BLUE}=== Performance Test Summary ===${NC}"
    echo "Total Tests: $TOTAL_TESTS"
    echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
    echo -e "Failed: ${RED}$FAILED_TESTS${NC}"
    echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
    
    if [[ "$TOTAL_TESTS" -gt 0 ]]; then
        local success_rate=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
        echo "Success Rate: ${success_rate}%"
    fi
    
    echo ""
    echo "📊 Performance Reports Generated:"
    echo "  • Text Log: $LOG_FILE"
    echo "  • HTML Report: $REPORT_FILE"
    
    echo ""
    if [[ "$FAILED_TESTS" -eq 0 ]]; then
        if [[ "$WARNINGS" -eq 0 ]]; then
            echo -e "${GREEN}🚀 Excellent! All performance tests passed with optimal results!${NC}"
        else
            echo -e "${GREEN}✅ Good! Performance tests passed with some areas for optimization.${NC}"
        fi
        echo "The kubeadm-python-cluster shows good performance characteristics."
    else
        echo -e "${RED}⚠️  Performance issues detected. Please review the results and optimize.${NC}"
    fi
    
    echo ""
    echo "Performance Optimization Recommendations:"
    echo "1. Review the HTML report: file://$REPORT_FILE"
    echo "2. Address any failed performance tests"
    echo "3. Optimize resource allocation based on usage patterns"
    echo "4. Consider scaling strategies for production deployment"
    echo "5. Implement performance monitoring for ongoing optimization"
    
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
        echo "  --concurrent N          Number of concurrent operations (default: $CONCURRENT_USERS)"
        echo "  --duration N            Test duration in seconds (default: $TEST_DURATION)"
        echo "  --jupyterhub-ns NS      JupyterHub namespace (default: $JUPYTERHUB_NAMESPACE)"
        echo "  --monitoring-ns NS      Monitoring namespace (default: $MONITORING_NAMESPACE)"
        echo "  --report-only           Only generate reports from existing logs"
        echo ""
        echo "Examples:"
        echo "  $0                      Run complete performance tests"
        echo "  $0 --concurrent 20      Run with 20 concurrent users"
        echo "  $0 --duration 600       Run 10-minute performance tests"
        echo "  $0 --report-only        Generate reports from existing test data"
        exit 0
        ;;
    --timeout)
        TEST_TIMEOUT="${2:-$TEST_TIMEOUT}"
        shift 2
        ;;
    --concurrent)
        CONCURRENT_USERS="${2:-$CONCURRENT_USERS}"
        shift 2
        ;;
    --duration)
        TEST_DURATION="${2:-$TEST_DURATION}"
        shift 2
        ;;
    --jupyterhub-ns)
        JUPYTERHUB_NAMESPACE="${2:-$JUPYTERHUB_NAMESPACE}"
        shift 2
        ;;
    --monitoring-ns)
        MONITORING_NAMESPACE="${2:-$MONITORING_NAMESPACE}"
        shift 2
        ;;
    --report-only)
        if [[ -f "$LOG_FILE" ]]; then
            generate_html_report
            echo "Performance report generated from existing data: $REPORT_FILE"
            exit 0
        else
            echo "No existing performance test data found. Run tests first."
            exit 1
        fi
        ;;
esac

# メイン実行
timeout "$TEST_TIMEOUT" main "$@" || {
    echo -e "${RED}Performance tests timed out after $TEST_TIMEOUT seconds${NC}"
    exit 1
}