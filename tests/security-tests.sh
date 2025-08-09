#!/bin/bash
# tests/security-tests.sh
# kubeadm-python-cluster セキュリティテストスクリプト

set -euo pipefail

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# グローバル変数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$SCRIPT_DIR/security-test-results.log"
REPORT_FILE="$SCRIPT_DIR/security-test-report.html"
VULN_REPORT="$SCRIPT_DIR/vulnerability-scan-results.json"
EXIT_CODE=0

# テスト設定
TEST_TIMEOUT="${TEST_TIMEOUT:-1800}"  # 30 minutes for security tests
JUPYTERHUB_NAMESPACE="${JUPYTERHUB_NAMESPACE:-jupyterhub}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
LOGGING_NAMESPACE="${LOGGING_NAMESPACE:-logging}"

# セキュリティテスト結果
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNINGS=0
CRITICAL_ISSUES=0
HIGH_ISSUES=0
MEDIUM_ISSUES=0
LOW_ISSUES=0

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${PURPLE}============================================${NC}"
    echo -e "${PURPLE}kubeadm Python Cluster Security Tests${NC}"
    echo -e "${PURPLE}============================================${NC}"
    log "Starting comprehensive security tests"
    echo "Security Test Configuration:"
    echo "  • Test Timeout: $TEST_TIMEOUT seconds"
    echo "  • Target Namespaces: default, $JUPYTERHUB_NAMESPACE, $MONITORING_NAMESPACE"
    echo "  • CIS Kubernetes Benchmark Compliance Testing"
    echo ""
}

print_test_header() {
    local test_name="$1"
    echo ""
    echo -e "${CYAN}--- Security Test: $test_name ---${NC}"
    log "SECURITY_TEST START: $test_name"
}

print_status() {
    local status=$1
    local message=$2
    local severity="${3:-}"
    
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
            
            # 深刻度による分類
            case "${severity,,}" in
                "critical") ((CRITICAL_ISSUES++)) ;;
                "high") ((HIGH_ISSUES++)) ;;
                "medium") ((MEDIUM_ISSUES++)) ;;
                "low") ((LOW_ISSUES++)) ;;
            esac
            ;;
        "WARNING")
            echo -e "⚠️  ${YELLOW}WARNING: $message${NC}"
            log "WARNING: $message"
            ((WARNINGS++))
            ;;
        "INFO")
            echo -e "🔍 ${BLUE}INFO: $message${NC}"
            log "INFO: $message"
            ;;
    esac
    ((TOTAL_TESTS++))
}

# RBAC セキュリティテスト
test_rbac_security() {
    print_test_header "RBAC Security Assessment"
    
    # Service Account 権限チェック
    log "INFO: Checking service account permissions..."
    
    # 過度な権限を持つService Accountの検出
    local admin_bindings=$(kubectl get clusterrolebindings -o json | jq -r '.items[] | select(.roleRef.name == "cluster-admin") | .subjects[]? | select(.kind == "ServiceAccount") | "\(.namespace)/\(.name)"' 2>/dev/null || echo "")
    
    if [[ -z "$admin_bindings" ]]; then
        print_status "PASS" "No service accounts with cluster-admin privileges found"
    else
        print_status "WARNING" "Service accounts with cluster-admin privileges detected: $admin_bindings" "medium"
        log "RBAC_WARNING: Admin service accounts: $admin_bindings"
    fi
    
    # システムService Accountsの確認
    local system_sa_count=$(kubectl get serviceaccounts --all-namespaces | grep -E "(default|system)" | wc -l)
    if [[ "$system_sa_count" -ge 3 ]]; then
        print_status "PASS" "System service accounts are properly configured ($system_sa_count accounts)"
    else
        print_status "WARNING" "Insufficient system service accounts found" "low"
    fi
    
    # JupyterHub RBAC設定確認
    if kubectl get role jupyterhub -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "JupyterHub RBAC role is configured"
    else
        print_status "FAIL" "JupyterHub RBAC role not found" "high"
    fi
    
    if kubectl get rolebinding jupyterhub -n "$JUPYTERHUB_NAMESPACE" >/dev/null 2>&1; then
        print_status "PASS" "JupyterHub RBAC binding is configured"
    else
        print_status "FAIL" "JupyterHub RBAC binding not found" "high"
    fi
    
    # 匿名アクセスの確認
    local anonymous_access=$(kubectl auth can-i create pods --as=system:anonymous 2>&1 | grep -c "yes" || echo "0")
    if [[ "$anonymous_access" -eq 0 ]]; then
        print_status "PASS" "Anonymous access is properly restricted"
    else
        print_status "FAIL" "Anonymous access is enabled" "critical"
    fi
}

# Pod Security Context テスト
test_pod_security_contexts() {
    print_test_header "Pod Security Context Assessment"
    
    # 全Podのsecurity contextチェック
    log "INFO: Analyzing pod security contexts..."
    
    # runAsNonRootの設定確認
    local pods_with_nonroot=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{" "}{.spec.securityContext.runAsNonRoot}{"\n"}{end}' | grep "true" | wc -l)
    local total_pods=$(kubectl get pods --all-namespaces --no-headers | wc -l)
    
    if [[ "$pods_with_nonroot" -gt 0 ]]; then
        local coverage=$((pods_with_nonroot * 100 / total_pods))
        if [[ "$coverage" -ge 80 ]]; then
            print_status "PASS" "Good security context coverage: $pods_with_nonroot/$total_pods pods run as non-root ($coverage%)"
        elif [[ "$coverage" -ge 50 ]]; then
            print_status "WARNING" "Moderate security context coverage: $pods_with_nonroot/$total_pods pods run as non-root ($coverage%)" "medium"
        else
            print_status "FAIL" "Low security context coverage: $pods_with_nonroot/$total_pods pods run as non-root ($coverage%)" "high"
        fi
    else
        print_status "FAIL" "No pods configured to run as non-root" "critical"
    fi
    
    # Read-only root filesystemの確認
    local readonly_fs_count=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.securityContext.readOnlyRootFilesystem}{"\n"}{end}{end}' | grep -c "true" || echo "0")
    
    if [[ "$readonly_fs_count" -gt 0 ]]; then
        print_status "PASS" "Read-only root filesystem configured for $readonly_fs_count containers"
    else
        print_status "WARNING" "No containers with read-only root filesystem found" "medium"
    fi
    
    # Privileged containerの検出
    local privileged_pods=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{" "}{range .spec.containers[*]}{.securityContext.privileged}{"\n"}{end}{end}' | grep "true" || echo "")
    
    if [[ -z "$privileged_pods" ]]; then
        print_status "PASS" "No privileged containers detected"
    else
        print_status "FAIL" "Privileged containers detected" "critical"
        log "PRIVILEGED_CONTAINERS: $privileged_pods"
    fi
    
    # Capabilities の確認
    local caps_add=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{" "}{range .spec.containers[*]}{.securityContext.capabilities.add[*]}{"\n"}{end}{end}' | grep -v "^$" || echo "")
    
    if [[ -z "$caps_add" ]]; then
        print_status "PASS" "No additional capabilities granted to containers"
    else
        print_status "WARNING" "Additional capabilities detected in containers" "low"
        log "CAPABILITIES_ADD: $caps_add"
    fi
}

# Network Security テスト
test_network_security() {
    print_test_header "Network Security Assessment"
    
    # Network Policies の確認
    local netpol_count=$(kubectl get networkpolicies --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [[ "$netpol_count" -gt 0 ]]; then
        print_status "PASS" "Network policies are configured ($netpol_count policies)"
        
        # Network Policy の詳細分析
        kubectl get networkpolicies --all-namespaces -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): ingress=\(.spec.ingress | length), egress=\(.spec.egress | length)"' | while read -r policy; do
            log "NETWORK_POLICY: $policy"
        done
    else
        print_status "FAIL" "No network policies configured - network traffic is unrestricted" "high"
    fi
    
    # Service exposure の確認
    local external_services=$(kubectl get services --all-namespaces | grep -E "(LoadBalancer|NodePort)" | wc -l)
    if [[ "$external_services" -gt 0 ]]; then
        print_status "INFO" "External services found ($external_services services)"
        kubectl get services --all-namespaces | grep -E "(LoadBalancer|NodePort)" | while read -r service; do
            log "EXTERNAL_SERVICE: $service"
        done
    else
        print_status "PASS" "No external services exposing cluster resources"
    fi
    
    # Ingress security の確認
    local ingress_count=$(kubectl get ingress --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "$ingress_count" -gt 0 ]]; then
        print_status "INFO" "Ingress resources found ($ingress_count ingresses)"
        
        # TLS設定の確認
        local tls_ingress=$(kubectl get ingress --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.tls}{"\n"}{end}' | grep -v "null" | wc -l)
        if [[ "$tls_ingress" -gt 0 ]]; then
            print_status "PASS" "TLS configured for $tls_ingress ingress resources"
        else
            print_status "FAIL" "No TLS configuration found for ingress resources" "medium"
        fi
    else
        print_status "INFO" "No ingress resources configured"
    fi
}

# Secrets Security テスト
test_secrets_security() {
    print_test_header "Secrets Security Assessment"
    
    # Secrets の確認
    local secrets_count=$(kubectl get secrets --all-namespaces --no-headers | wc -l)
    if [[ "$secrets_count" -gt 0 ]]; then
        print_status "PASS" "Kubernetes secrets are configured ($secrets_count secrets)"
    else
        print_status "WARNING" "Very few secrets found" "low"
    fi
    
    # Base64エンコードされていない potential secretsの検出
    log "INFO: Scanning for potential hardcoded secrets..."
    
    # ConfigMapsでのsecret-likeデータの検出
    local suspicious_configmaps=$(kubectl get configmaps --all-namespaces -o json | jq -r '.items[] | select(.data | keys[] | test("password|secret|key|token"; "i")) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")
    
    if [[ -z "$suspicious_configmaps" ]]; then
        print_status "PASS" "No suspicious data found in ConfigMaps"
    else
        print_status "WARNING" "Potential sensitive data in ConfigMaps: $suspicious_configmaps" "medium"
    fi
    
    # Secret types の分析
    kubectl get secrets --all-namespaces -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.type)"' | sort | uniq -c | while read -r count type; do
        log "SECRET_TYPE: $count × $type"
    done
    
    # Service Account tokensの確認
    local sa_tokens=$(kubectl get secrets --all-namespaces | grep "service-account-token" | wc -l)
    print_status "INFO" "Service account tokens: $sa_tokens"
}

# Image Security テスト
test_image_security() {
    print_test_header "Container Image Security Assessment"
    
    # イメージのタグ分析
    log "INFO: Analyzing container image tags..."
    
    # "latest" タグの使用確認
    local latest_images=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | grep -c ":latest" || echo "0")
    local total_containers=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | wc -l)
    
    if [[ "$latest_images" -eq 0 ]]; then
        print_status "PASS" "No containers using 'latest' tag"
    else
        local latest_percentage=$((latest_images * 100 / total_containers))
        if [[ "$latest_percentage" -lt 20 ]]; then
            print_status "WARNING" "Some containers using 'latest' tag ($latest_images/$total_containers = $latest_percentage%)" "low"
        else
            print_status "FAIL" "Many containers using 'latest' tag ($latest_images/$total_containers = $latest_percentage%)" "medium"
        fi
    fi
    
    # Image pull policyの確認
    local always_pull=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.imagePullPolicy}{"\n"}{end}{end}' | grep -c "Always" || echo "0")
    
    if [[ "$always_pull" -gt 0 ]]; then
        print_status "PASS" "ImagePullPolicy 'Always' configured for $always_pull containers"
    else
        print_status "WARNING" "No containers with ImagePullPolicy 'Always' - may use cached vulnerable images" "medium"
    fi
    
    # Private registryの使用確認
    local private_registry=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | grep -v -E "(^|/)docker\.io|gcr\.io|quay\.io" | wc -l)
    
    if [[ "$private_registry" -gt 0 ]]; then
        print_status "PASS" "Private/local registry images detected ($private_registry images)"
    else
        print_status "INFO" "All images from public registries"
    fi
    
    # Image pull secretsの確認
    local image_pull_secrets=$(kubectl get serviceaccounts --all-namespaces -o json | jq -r '.items[] | select(.imagePullSecrets) | "\(.metadata.namespace)/\(.metadata.name)"' | wc -l)
    
    if [[ "$image_pull_secrets" -gt 0 ]]; then
        print_status "PASS" "Image pull secrets configured for $image_pull_secrets service accounts"
    else
        print_status "WARNING" "No image pull secrets configured" "low"
    fi
}

# Resource Security テスト  
test_resource_security() {
    print_test_header "Resource Security Assessment"
    
    # Resource limits/requestsの確認
    local pods_with_limits=$(kubectl get pods --all-namespaces -o json | jq -r '.items[] | select(.spec.containers[].resources.limits) | .metadata.name' | wc -l)
    local total_pods=$(kubectl get pods --all-namespaces --no-headers | wc -l)
    
    if [[ "$pods_with_limits" -gt 0 ]]; then
        local limit_coverage=$((pods_with_limits * 100 / total_pods))
        if [[ "$limit_coverage" -ge 80 ]]; then
            print_status "PASS" "Good resource limits coverage: $pods_with_limits/$total_pods pods ($limit_coverage%)"
        else
            print_status "WARNING" "Moderate resource limits coverage: $pods_with_limits/$total_pods pods ($limit_coverage%)" "medium"
        fi
    else
        print_status "FAIL" "No pods with resource limits - potential DoS vulnerability" "high"
    fi
    
    # Resource quotasの確認
    local resource_quotas=$(kubectl get resourcequotas --all-namespaces --no-headers | wc -l)
    
    if [[ "$resource_quotas" -gt 0 ]]; then
        print_status "PASS" "Resource quotas configured ($resource_quotas quotas)"
    else
        print_status "WARNING" "No resource quotas configured - unlimited resource usage possible" "medium"
    fi
    
    # Limit rangesの確認
    local limit_ranges=$(kubectl get limitranges --all-namespaces --no-headers | wc -l)
    
    if [[ "$limit_ranges" -gt 0 ]]; then
        print_status "PASS" "Limit ranges configured ($limit_ranges ranges)"
    else
        print_status "WARNING" "No limit ranges configured" "low"
    fi
}

# API Server Security テスト
test_apiserver_security() {
    print_test_header "API Server Security Assessment"
    
    # API Server設定の確認（可能な範囲で）
    local api_health=$(kubectl get --raw=/healthz 2>/dev/null | head -1 || echo "")
    
    if [[ "$api_health" == "ok" ]]; then
        print_status "PASS" "API Server is healthy and responsive"
    else
        print_status "FAIL" "API Server health check failed" "critical"
    fi
    
    # Admission controllersの確認（間接的）
    # PodSecurityPolicyの存在確認
    local psp_count=$(kubectl get podsecuritypolicies 2>/dev/null | wc -l || echo "0")
    
    if [[ "$psp_count" -gt 0 ]]; then
        print_status "PASS" "Pod Security Policies are configured ($psp_count policies)"
    else
        print_status "INFO" "Pod Security Policies not found (may use Pod Security Standards)"
    fi
    
    # ValidatingAdmissionWebhooksの確認
    local validating_webhooks=$(kubectl get validatingadmissionwebhooks 2>/dev/null | wc -l || echo "0")
    
    if [[ "$validating_webhooks" -gt 0 ]]; then
        print_status "PASS" "Validating admission webhooks configured ($validating_webhooks webhooks)"
    else
        print_status "INFO" "No validating admission webhooks found"
    fi
    
    # MutatingAdmissionWebhooksの確認
    local mutating_webhooks=$(kubectl get mutatingadmissionwebhooks 2>/dev/null | wc -l || echo "0")
    
    if [[ "$mutating_webhooks" -gt 0 ]]; then
        print_status "INFO" "Mutating admission webhooks configured ($mutating_webhooks webhooks)"
    else
        print_status "INFO" "No mutating admission webhooks found"
    fi
}

# Compliance テスト（CIS Kubernetes Benchmark）
test_cis_compliance() {
    print_test_header "CIS Kubernetes Benchmark Compliance"
    
    log "INFO: Running basic CIS Kubernetes Benchmark checks..."
    
    # 4.2.1 - すべてのNamespaceにdefault network policyが設定されているか
    local namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
    local compliant_ns=0
    local total_ns=0
    
    for ns in $namespaces; do
        ((total_ns++))
        local ns_netpol=$(kubectl get networkpolicies -n "$ns" 2>/dev/null | wc -l || echo "0")
        if [[ "$ns_netpol" -gt 0 ]]; then
            ((compliant_ns++))
        fi
    done
    
    if [[ "$compliant_ns" -eq "$total_ns" ]]; then
        print_status "PASS" "CIS 4.2.1: All namespaces have network policies"
    elif [[ "$compliant_ns" -gt 0 ]]; then
        print_status "WARNING" "CIS 4.2.1: Some namespaces lack network policies ($compliant_ns/$total_ns)" "medium"
    else
        print_status "FAIL" "CIS 4.2.1: No network policies configured" "high"
    fi
    
    # 5.1.3 - ServiceAccountのauto-mountingの確認
    local automount_disabled=$(kubectl get serviceaccounts --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.automountServiceAccountToken}{"\n"}{end}' | grep -c "false" || echo "0")
    local total_sa=$(kubectl get serviceaccounts --all-namespaces --no-headers | wc -l)
    
    if [[ "$automount_disabled" -gt 0 ]]; then
        print_status "PASS" "CIS 5.1.3: Service account token auto-mounting disabled for $automount_disabled/$total_sa accounts"
    else
        print_status "WARNING" "CIS 5.1.3: All service accounts have auto-mounting enabled" "medium"
    fi
    
    # 5.7.3 - Container capabilities の制限
    local restricted_caps=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.securityContext.capabilities.drop[*]}{"\n"}{end}{end}' | grep -c "ALL" || echo "0")
    
    if [[ "$restricted_caps" -gt 0 ]]; then
        print_status "PASS" "CIS 5.7.3: Containers with restricted capabilities found ($restricted_caps containers)"
    else
        print_status "FAIL" "CIS 5.7.3: No containers with capability restrictions (drop ALL)" "medium"
    fi
    
    # 5.7.4 - Container privilege escalation の確認
    local no_priv_escalation=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.securityContext.allowPrivilegeEscalation}{"\n"}{end}{end}' | grep -c "false" || echo "0")
    
    if [[ "$no_priv_escalation" -gt 0 ]]; then
        print_status "PASS" "CIS 5.7.4: Privilege escalation disabled for $no_priv_escalation containers"
    else
        print_status "FAIL" "CIS 5.7.4: No containers with privilege escalation disabled" "high"
    fi
}

# 脆弱性スキャン（基本版）
test_vulnerability_scan() {
    print_test_header "Basic Vulnerability Assessment"
    
    log "INFO: Performing basic vulnerability checks..."
    
    # 古いKubernetesバージョンの確認
    local k8s_version=$(kubectl version --short 2>/dev/null | grep "Server Version" | cut -d' ' -f3 || echo "unknown")
    log "KUBERNETES_VERSION: $k8s_version"
    
    # バージョンが取得できた場合の脆弱性チェック
    if [[ "$k8s_version" != "unknown" ]]; then
        local major_version=$(echo "$k8s_version" | cut -d'.' -f1 | sed 's/v//')
        local minor_version=$(echo "$k8s_version" | cut -d'.' -f2)
        
        if [[ "$major_version" -ge 1 ]] && [[ "$minor_version" -ge 24 ]]; then
            print_status "PASS" "Kubernetes version is recent ($k8s_version)"
        else
            print_status "FAIL" "Kubernetes version may have known vulnerabilities ($k8s_version)" "high"
        fi
    fi
    
    # Dockerバージョンの確認
    local docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | sed 's/,//' || echo "unknown")
    log "DOCKER_VERSION: $docker_version"
    
    if [[ "$docker_version" != "unknown" ]]; then
        print_status "INFO" "Docker version: $docker_version"
    fi
    
    # 公開されたDashboardの確認
    local kubernetes_dashboard=$(kubectl get services --all-namespaces | grep -i dashboard | wc -l)
    
    if [[ "$kubernetes_dashboard" -eq 0 ]]; then
        print_status "PASS" "No Kubernetes Dashboard exposed"
    else
        print_status "WARNING" "Kubernetes Dashboard service found - ensure proper authentication" "medium"
    fi
    
    # 脆弱性レポート生成
    cat > "$VULN_REPORT" <<EOF
{
    "scan_date": "$(date -Iseconds)",
    "kubernetes_version": "$k8s_version",
    "docker_version": "$docker_version",
    "total_tests": $TOTAL_TESTS,
    "critical_issues": $CRITICAL_ISSUES,
    "high_issues": $HIGH_ISSUES,
    "medium_issues": $MEDIUM_ISSUES,
    "low_issues": $LOW_ISSUES,
    "recommendations": [
        "Regular security updates",
        "Implement Pod Security Standards",
        "Enable audit logging",
        "Use network policies",
        "Implement resource limits",
        "Regular vulnerability scanning"
    ]
}
EOF
    
    print_status "INFO" "Vulnerability scan report generated: $VULN_REPORT"
}

# HTMLレポート生成
generate_html_report() {
    print_status "INFO" "Generating HTML security report..."
    
    local risk_level="LOW"
    if [[ "$CRITICAL_ISSUES" -gt 0 ]]; then
        risk_level="CRITICAL"
    elif [[ "$HIGH_ISSUES" -gt 0 ]]; then
        risk_level="HIGH"
    elif [[ "$MEDIUM_ISSUES" -gt 0 ]]; then
        risk_level="MEDIUM"
    fi
    
    cat > "$REPORT_FILE" <<EOF
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Security Assessment Report - kubeadm-python-cluster</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; line-height: 1.6; background: #f8f9fa; }
        .header { background: linear-gradient(135deg, #dc3545 0%, #6f42c1 100%); color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .summary { background: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .risk-critical { background: linear-gradient(135deg, #dc3545 0%, #c82333 100%); }
        .risk-high { background: linear-gradient(135deg, #fd7e14 0%, #e55100 100%); }
        .risk-medium { background: linear-gradient(135deg, #ffc107 0%, #e0a800 100%); }
        .risk-low { background: linear-gradient(135deg, #28a745 0%, #20c997 100%); }
        .test-section { background: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .test-section h2 { color: #333; border-bottom: 2px solid #6f42c1; padding-bottom: 5px; }
        .security-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 15px; margin: 20px 0; }
        .metric-card { background: #f8f9fa; padding: 15px; border-radius: 8px; border-left: 4px solid; }
        .metric-critical { border-left-color: #dc3545; background: #f8d7da; }
        .metric-high { border-left-color: #fd7e14; background: #fff3cd; }
        .metric-medium { border-left-color: #ffc107; background: #fff3cd; }
        .metric-low { border-left-color: #28a745; background: #d1edff; }
        .pass { color: #28a745; font-weight: bold; }
        .fail { color: #dc3545; font-weight: bold; }
        .warning { color: #ffc107; font-weight: bold; }
        .info { color: #17a2b8; font-weight: bold; }
        .log-section { background: #f9f9f9; padding: 15px; border-radius: 8px; font-family: monospace; font-size: 12px; max-height: 400px; overflow-y: auto; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background-color: #6f42c1; color: white; }
        tr:nth-child(even) { background-color: #f8f9fa; }
        .compliance-score { font-size: 2em; font-weight: bold; text-align: center; padding: 20px; }
        .recommendations { background: #e9ecef; padding: 15px; border-radius: 8px; margin: 15px 0; }
    </style>
</head>
<body>
    <div class="header risk-$risk_level">
        <h1>🛡️ Security Assessment Report</h1>
        <p>kubeadm Python Cluster - $(date)</p>
        <p>Overall Risk Level: <strong>$risk_level</strong></p>
    </div>
    
    <div class="summary">
        <h2>🎯 Security Summary</h2>
        <div class="security-grid">
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
            
            <div class="metric-card metric-critical">
                <h3>Issues by Severity</h3>
                <table>
                    <tr><td>Critical</td><td class="fail">$CRITICAL_ISSUES</td></tr>
                    <tr><td>High</td><td class="warning">$HIGH_ISSUES</td></tr>
                    <tr><td>Medium</td><td class="warning">$MEDIUM_ISSUES</td></tr>
                    <tr><td>Low</td><td class="info">$LOW_ISSUES</td></tr>
                </table>
            </div>
            
            <div class="metric-card">
                <h3>Compliance Score</h3>
                <div class="compliance-score">
                    $(( TOTAL_TESTS > 0 ? (PASSED_TESTS * 100) / TOTAL_TESTS : 0 ))%
                </div>
                <p>CIS Kubernetes Benchmark alignment</p>
            </div>
        </div>
    </div>
    
    <div class="test-section">
        <h2>🔍 Security Assessment Categories</h2>
        
        <h3>RBAC (Role-Based Access Control)</h3>
        <ul>
            <li><strong>Service Account Permissions</strong> - Excessive privilege detection</li>
            <li><strong>Role Bindings</strong> - Proper role assignment verification</li>
            <li><strong>Anonymous Access</strong> - Unauthorized access prevention</li>
        </ul>
        
        <h3>Pod Security Contexts</h3>
        <ul>
            <li><strong>Non-root Execution</strong> - Container execution as non-root user</li>
            <li><strong>Read-only Filesystem</strong> - Immutable container filesystem</li>
            <li><strong>Privileged Containers</strong> - Detection of privileged access</li>
            <li><strong>Capabilities Management</strong> - Linux capabilities restrictions</li>
        </ul>
        
        <h3>Network Security</h3>
        <ul>
            <li><strong>Network Policies</strong> - Traffic segmentation and restrictions</li>
            <li><strong>Service Exposure</strong> - External service accessibility</li>
            <li><strong>TLS Configuration</strong> - Encryption in transit</li>
        </ul>
        
        <h3>Secrets Management</h3>
        <ul>
            <li><strong>Secret Configuration</strong> - Proper secret handling</li>
            <li><strong>Hardcoded Secrets</strong> - Detection of embedded credentials</li>
            <li><strong>Service Account Tokens</strong> - Token management</li>
        </ul>
        
        <h3>Container Image Security</h3>
        <ul>
            <li><strong>Image Tags</strong> - Specific version usage vs 'latest'</li>
            <li><strong>Image Pull Policy</strong> - Image update mechanisms</li>
            <li><strong>Private Registries</strong> - Controlled image sources</li>
        </ul>
        
        <h3>Resource Security</h3>
        <ul>
            <li><strong>Resource Limits</strong> - CPU/Memory consumption controls</li>
            <li><strong>Resource Quotas</strong> - Namespace-level restrictions</li>
            <li><strong>Limit Ranges</strong> - Default resource constraints</li>
        </ul>
        
        <h3>CIS Kubernetes Benchmark</h3>
        <ul>
            <li><strong>Network Policy Coverage</strong> - CIS 4.2.1 compliance</li>
            <li><strong>Service Account Token Auto-mounting</strong> - CIS 5.1.3 compliance</li>
            <li><strong>Container Capabilities</strong> - CIS 5.7.3 compliance</li>
            <li><strong>Privilege Escalation</strong> - CIS 5.7.4 compliance</li>
        </ul>
    </div>
    
    <div class="test-section">
        <h2>🚨 Security Recommendations</h2>
        <div class="recommendations">
            <h3>Immediate Actions (Critical/High Issues)</h3>
            <ul>
                <li>Address all critical and high severity security issues</li>
                <li>Implement Pod Security Standards or Pod Security Policies</li>
                <li>Configure network policies for all namespaces</li>
                <li>Ensure all containers run as non-root users</li>
                <li>Disable privilege escalation for all containers</li>
            </ul>
            
            <h3>Short-term Improvements (Medium Issues)</h3>
            <ul>
                <li>Implement resource limits and quotas</li>
                <li>Use specific image tags instead of 'latest'</li>
                <li>Configure TLS for all ingress resources</li>
                <li>Enable audit logging</li>
                <li>Regular vulnerability scanning</li>
            </ul>
            
            <h3>Long-term Security Enhancements</h3>
            <ul>
                <li>Implement admission controllers for policy enforcement</li>
                <li>Set up automated security scanning in CI/CD pipeline</li>
                <li>Regular security assessments and penetration testing</li>
                <li>Security monitoring and incident response procedures</li>
                <li>Staff security training and awareness programs</li>
            </ul>
        </div>
    </div>
    
    <div class="test-section">
        <h2>📝 Detailed Security Test Log</h2>
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
    
    <footer style="margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; color: #666; text-align: center;">
        <p>Generated by kubeadm-python-cluster security assessment</p>
        <p>Report generated: $(date)</p>
        <p>⚠️ This report should be reviewed by security professionals</p>
    </footer>
</body>
</html>
EOF

    print_status "PASS" "HTML security report generated: $REPORT_FILE"
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # セキュリティテスト実行
    test_rbac_security
    test_pod_security_contexts
    test_network_security
    test_secrets_security
    test_image_security
    test_resource_security
    test_apiserver_security
    test_cis_compliance
    test_vulnerability_scan
    
    # レポート生成
    generate_html_report
    
    echo ""
    echo -e "${PURPLE}=== Security Assessment Summary ===${NC}"
    echo "Total Tests: $TOTAL_TESTS"
    echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
    echo -e "Failed: ${RED}$FAILED_TESTS${NC}"
    echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
    
    echo ""
    echo "Security Issues by Severity:"
    echo -e "Critical: ${RED}$CRITICAL_ISSUES${NC}"
    echo -e "High: ${YELLOW}$HIGH_ISSUES${NC}"
    echo -e "Medium: ${YELLOW}$MEDIUM_ISSUES${NC}"
    echo -e "Low: ${BLUE}$LOW_ISSUES${NC}"
    
    if [[ "$TOTAL_TESTS" -gt 0 ]]; then
        local success_rate=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
        echo "Security Compliance: ${success_rate}%"
    fi
    
    echo ""
    echo "🛡️ Security Reports Generated:"
    echo "  • Text Log: $LOG_FILE"
    echo "  • HTML Report: $REPORT_FILE"
    echo "  • Vulnerability Scan: $VULN_REPORT"
    
    echo ""
    if [[ "$CRITICAL_ISSUES" -eq 0 ]] && [[ "$HIGH_ISSUES" -eq 0 ]]; then
        if [[ "$FAILED_TESTS" -eq 0 ]]; then
            echo -e "${GREEN}🛡️ Excellent! Strong security posture with no critical issues.${NC}"
        else
            echo -e "${GREEN}✅ Good security posture. Address remaining medium/low issues.${NC}"
        fi
        echo "The kubeadm-python-cluster demonstrates good security practices."
    else
        echo -e "${RED}⚠️  Security vulnerabilities detected. Immediate action required!${NC}"
        echo -e "${RED}Critical Issues: $CRITICAL_ISSUES | High Issues: $HIGH_ISSUES${NC}"
    fi
    
    echo ""
    echo "Security Action Items:"
    echo "1. Review the HTML report: file://$REPORT_FILE"
    echo "2. Address all critical and high severity issues immediately"
    echo "3. Implement recommended security controls"
    echo "4. Schedule regular security assessments"
    echo "5. Consider professional security audit for production deployment"
    
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
        echo "  --jupyterhub-ns NS      JupyterHub namespace (default: $JUPYTERHUB_NAMESPACE)"
        echo "  --monitoring-ns NS      Monitoring namespace (default: $MONITORING_NAMESPACE)"
        echo "  --logging-ns NS         Logging namespace (default: $LOGGING_NAMESPACE)"
        echo "  --report-only           Only generate reports from existing logs"
        echo ""
        echo "Examples:"
        echo "  $0                      Run complete security assessment"
        echo "  $0 --timeout 3600       Run with 1 hour timeout"
        echo "  $0 --report-only        Generate reports from existing test data"
        exit 0
        ;;
    --timeout)
        TEST_TIMEOUT="${2:-$TEST_TIMEOUT}"
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
    --logging-ns)
        LOGGING_NAMESPACE="${2:-$LOGGING_NAMESPACE}"
        shift 2
        ;;
    --report-only)
        if [[ -f "$LOG_FILE" ]]; then
            generate_html_report
            echo "Security report generated from existing data: $REPORT_FILE"
            exit 0
        else
            echo "No existing security test data found. Run tests first."
            exit 1
        fi
        ;;
esac

# メイン実行
timeout "$TEST_TIMEOUT" main "$@" || {
    echo -e "${RED}Security tests timed out after $TEST_TIMEOUT seconds${NC}"
    exit 1
}