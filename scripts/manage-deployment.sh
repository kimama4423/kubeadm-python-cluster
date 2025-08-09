#!/bin/bash
# scripts/manage-deployment.sh
# JupyterHub Kubernetes デプロイメント管理スクリプト

set -euo pipefail

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# グローバル変数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-jupyterhub}"

print_status() {
    local status=$1
    local message=$2
    
    case $status in
        "INFO")
            echo -e "ℹ️  ${BLUE}$message${NC}"
            ;;
        "SUCCESS")
            echo -e "✅ ${GREEN}$message${NC}"
            ;;
        "WARNING")
            echo -e "⚠️  ${YELLOW}$message${NC}"
            ;;
        "ERROR")
            echo -e "❌ ${RED}$message${NC}"
            ;;
    esac
}

# デプロイメント状況確認
status() {
    print_status "INFO" "JupyterHub Deployment Status"
    echo "================================"
    
    # 名前空間確認
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        print_status "SUCCESS" "Namespace '$NAMESPACE' exists"
    else
        print_status "ERROR" "Namespace '$NAMESPACE' not found"
        return 1
    fi
    
    echo ""
    echo "=== Deployments ==="
    kubectl get deployments -n "$NAMESPACE" -o wide
    
    echo ""
    echo "=== Pods ==="
    kubectl get pods -n "$NAMESPACE" -o wide
    
    echo ""
    echo "=== Services ==="
    kubectl get services -n "$NAMESPACE" -o wide
    
    echo ""
    echo "=== PersistentVolumeClaims ==="
    kubectl get pvc -n "$NAMESPACE" -o wide
    
    # 接続情報表示
    local node_port=$(kubectl get service -n "$NAMESPACE" jupyterhub -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "N/A")
    
    echo ""
    echo "=== Access Information ==="
    echo "JupyterHub URL: http://$node_ip:$node_port"
    echo "Health Check: http://$node_ip:$node_port/hub/health"
    
    # ヘルスチェック実行
    if curl -f -s "http://$node_ip:$node_port/hub/health" >/dev/null 2>&1; then
        print_status "SUCCESS" "JupyterHub is responding"
    else
        print_status "WARNING" "JupyterHub health check failed"
    fi
}

# ログ確認
logs() {
    local follow="${2:-false}"
    
    print_status "INFO" "JupyterHub Logs"
    
    if [[ "$follow" == "follow" || "$follow" == "-f" ]]; then
        kubectl logs -f -n "$NAMESPACE" deployment/jupyterhub
    else
        kubectl logs -n "$NAMESPACE" deployment/jupyterhub --tail=100
    fi
}

# スケーリング
scale() {
    local replicas="${2:-1}"
    
    print_status "INFO" "Scaling JupyterHub to $replicas replicas..."
    
    if kubectl scale -n "$NAMESPACE" deployment/jupyterhub --replicas="$replicas"; then
        print_status "SUCCESS" "Scaling completed"
        
        # スケーリング確認
        sleep 5
        kubectl get deployment -n "$NAMESPACE" jupyterhub
    else
        print_status "ERROR" "Scaling failed"
        return 1
    fi
}

# 再起動
restart() {
    print_status "INFO" "Restarting JupyterHub deployment..."
    
    if kubectl rollout restart -n "$NAMESPACE" deployment/jupyterhub; then
        print_status "SUCCESS" "Restart initiated"
        
        print_status "INFO" "Waiting for rollout to complete..."
        kubectl rollout status -n "$NAMESPACE" deployment/jupyterhub --timeout=300s
        
        print_status "SUCCESS" "Deployment restarted successfully"
    else
        print_status "ERROR" "Restart failed"
        return 1
    fi
}

# アップデート
update() {
    local image="${2:-localhost:5000/kubeadm-python-cluster/jupyterhub:latest}"
    
    print_status "INFO" "Updating JupyterHub image to: $image"
    
    if kubectl set image -n "$NAMESPACE" deployment/jupyterhub jupyterhub="$image"; then
        print_status "SUCCESS" "Image update initiated"
        
        print_status "INFO" "Waiting for rollout to complete..."
        kubectl rollout status -n "$NAMESPACE" deployment/jupyterhub --timeout=300s
        
        print_status "SUCCESS" "Deployment updated successfully"
    else
        print_status "ERROR" "Update failed"
        return 1
    fi
}

# バックアップ
backup() {
    local backup_dir="${2:-$SCRIPT_DIR/backup-$(date +%Y%m%d_%H%M%S)}"
    
    print_status "INFO" "Creating backup in: $backup_dir"
    mkdir -p "$backup_dir"
    
    # Kubernetes リソースのバックアップ
    kubectl get all -n "$NAMESPACE" -o yaml > "$backup_dir/all-resources.yaml"
    kubectl get configmaps -n "$NAMESPACE" -o yaml > "$backup_dir/configmaps.yaml"
    kubectl get secrets -n "$NAMESPACE" -o yaml > "$backup_dir/secrets.yaml"
    kubectl get pvc -n "$NAMESPACE" -o yaml > "$backup_dir/pvcs.yaml"
    
    # データベースバックアップ (SQLiteの場合)
    local hub_pod=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=hub -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$hub_pod" ]]; then
        print_status "INFO" "Backing up JupyterHub database..."
        kubectl exec -n "$NAMESPACE" "$hub_pod" -- cp /srv/jupyterhub/jupyterhub.sqlite /tmp/jupyterhub-backup.sqlite 2>/dev/null || true
        kubectl cp -n "$NAMESPACE" "$hub_pod":/tmp/jupyterhub-backup.sqlite "$backup_dir/jupyterhub.sqlite" 2>/dev/null || true
    fi
    
    print_status "SUCCESS" "Backup completed: $backup_dir"
}

# 設定更新
update_config() {
    print_status "INFO" "Updating JupyterHub configuration..."
    
    # ConfigMapを再適用
    local project_root="$(cd "$SCRIPT_DIR/.." && pwd)"
    local configmap_file="$project_root/k8s-manifests/configmap.yaml"
    
    if [[ -f "$configmap_file" ]]; then
        kubectl apply -f "$configmap_file"
        print_status "SUCCESS" "ConfigMap updated"
        
        # デプロイメント再起動
        print_status "INFO" "Restarting deployment to apply new configuration..."
        restart
    else
        print_status "ERROR" "ConfigMap file not found: $configmap_file"
        return 1
    fi
}

# ユーザー管理
users() {
    local action="${2:-list}"
    local username="${3:-}"
    
    case "$action" in
        list)
            print_status "INFO" "Active user sessions:"
            kubectl exec -n "$NAMESPACE" deployment/jupyterhub -- jupyterhub token list 2>/dev/null || {
                print_status "WARNING" "Could not list user sessions"
            }
            ;;
        pods)
            print_status "INFO" "User pods:"
            kubectl get pods -n "$NAMESPACE" -l component=singleuser-server -o wide
            ;;
        clean)
            print_status "INFO" "Cleaning up terminated user pods..."
            kubectl delete pods -n "$NAMESPACE" -l component=singleuser-server --field-selector=status.phase=Succeeded,status.phase=Failed 2>/dev/null || true
            print_status "SUCCESS" "Cleanup completed"
            ;;
        *)
            echo "Usage: $0 users {list|pods|clean}"
            ;;
    esac
}

# トラブルシューティング
troubleshoot() {
    print_status "INFO" "JupyterHub Troubleshooting Information"
    echo "======================================="
    
    echo ""
    echo "=== Deployment Status ==="
    kubectl describe deployment -n "$NAMESPACE" jupyterhub
    
    echo ""
    echo "=== Pod Status ==="
    kubectl describe pods -n "$NAMESPACE" -l app.kubernetes.io/component=hub
    
    echo ""
    echo "=== Recent Events ==="
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20
    
    echo ""
    echo "=== Service Status ==="
    kubectl describe service -n "$NAMESPACE" jupyterhub
    
    echo ""
    echo "=== Storage Status ==="
    kubectl describe pvc -n "$NAMESPACE"
    
    echo ""
    echo "=== Container Logs (last 50 lines) ==="
    kubectl logs -n "$NAMESPACE" deployment/jupyterhub --tail=50
}

# クリーンアップ
cleanup() {
    local force="${2:-false}"
    
    if [[ "$force" != "force" && "$force" != "-f" ]]; then
        echo "⚠️  This will delete the entire JupyterHub deployment including user data!"
        read -p "Are you sure? [y/N]: " confirm
        
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_status "INFO" "Cleanup cancelled"
            return 0
        fi
    fi
    
    print_status "WARNING" "Deleting JupyterHub deployment..."
    
    # バックアップ作成
    print_status "INFO" "Creating final backup before cleanup..."
    backup "$SCRIPT_DIR/final-backup-$(date +%Y%m%d_%H%M%S)"
    
    # 名前空間削除
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
    
    # PVの手動削除確認
    print_status "WARNING" "Note: PersistentVolumes may need manual cleanup"
    kubectl get pv | grep "jupyterhub" || true
    
    print_status "SUCCESS" "Cleanup completed"
}

# ヘルプ表示
show_help() {
    echo "JupyterHub Kubernetes Deployment Management"
    echo "=========================================="
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  status              Show deployment status"
    echo "  logs [follow]       Show logs (use 'follow' or '-f' to follow)"
    echo "  scale <replicas>    Scale deployment (default: 1)"
    echo "  restart             Restart deployment"
    echo "  update [image]      Update container image"
    echo "  backup [dir]        Backup deployment and data"
    echo "  update-config       Update configuration"
    echo "  users <action>      Manage users (list|pods|clean)"
    echo "  troubleshoot        Show troubleshooting information"
    echo "  cleanup [force]     Delete entire deployment (use 'force' to skip confirmation)"
    echo "  help                Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  NAMESPACE           Kubernetes namespace (default: jupyterhub)"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 logs follow"
    echo "  $0 scale 2"
    echo "  $0 backup /tmp/my-backup"
    echo "  $0 users list"
    echo "  NAMESPACE=my-jupyterhub $0 status"
}

# メイン実行
main() {
    local command="${1:-help}"
    
    case "$command" in
        status|st)
            status
            ;;
        logs|log)
            logs "$@"
            ;;
        scale)
            scale "$@"
            ;;
        restart|rs)
            restart
            ;;
        update|up)
            update "$@"
            ;;
        backup|bk)
            backup "$@"
            ;;
        update-config|config)
            update_config
            ;;
        users|user)
            users "$@"
            ;;
        troubleshoot|debug)
            troubleshoot
            ;;
        cleanup|clean|delete)
            cleanup "$@"
            ;;
        help|h|-h|--help)
            show_help
            ;;
        *)
            print_status "ERROR" "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# 前提条件チェック
if ! command -v kubectl >/dev/null 2>&1; then
    print_status "ERROR" "kubectl not found. Please install kubectl first"
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    print_status "ERROR" "Cannot connect to Kubernetes cluster"
    exit 1
fi

# メイン実行
main "$@"