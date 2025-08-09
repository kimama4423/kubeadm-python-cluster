#!/bin/bash
# scripts/setup-grafana.sh
# Grafanaダッシュボードセットアップスクリプト for kubeadm-python-cluster

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
LOG_FILE="$SCRIPT_DIR/grafana-setup.log"
EXIT_CODE=0

# Grafana設定
GRAFANA_VERSION="${GRAFANA_VERSION:-10.2.3}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
STORAGE_SIZE="${STORAGE_SIZE:-10Gi}"

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}Grafana Dashboard Setup${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting Grafana dashboard setup"
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
    print_status "INFO" "Checking prerequisites for Grafana setup..."
    
    # kubectl確認
    if ! command -v kubectl >/dev/null 2>&1; then
        print_status "ERROR" "kubectl not found. Please install kubectl"
        return 1
    fi
    
    # クラスター接続確認
    if ! kubectl cluster-info >/dev/null 2>&1; then
        print_status "ERROR" "Cannot connect to Kubernetes cluster"
        return 1
    fi
    
    # monitoring名前空間確認
    if ! kubectl get namespace "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
        print_status "ERROR" "Monitoring namespace '$MONITORING_NAMESPACE' not found. Please run setup-prometheus.sh first"
        return 1
    fi
    
    # Prometheus確認
    if ! kubectl get service prometheus -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
        print_status "ERROR" "Prometheus service not found. Please setup Prometheus first"
        return 1
    fi
    
    print_status "SUCCESS" "Prerequisites check completed"
}

# Grafana ConfigMap作成
create_grafana_config() {
    print_status "INFO" "Creating Grafana configuration..."
    
    local config_manifest="$PROJECT_ROOT/k8s-manifests/grafana-config.yaml"
    
    cat > "$config_manifest" <<EOF
---
# Grafana Configuration ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-config
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: config
data:
  grafana.ini: |
    [analytics]
    check_for_updates = true
    
    [grafana_net]
    url = https://grafana.net
    
    [log]
    mode = console
    level = info
    
    [paths]
    data = /var/lib/grafana/
    logs = /var/log/grafana
    plugins = /var/lib/grafana/plugins
    provisioning = /etc/grafana/provisioning
    
    [server]
    http_port = 3000
    protocol = http
    domain = localhost
    root_url = http://localhost:3000/
    serve_from_sub_path = false
    
    [database]
    type = sqlite3
    host = 127.0.0.1:3306
    name = grafana
    user = root
    password =
    url = sqlite3:///var/lib/grafana/grafana.db
    ssl_mode = disable
    
    [session]
    provider = file
    provider_config = sessions
    cookie_name = grafana_sess
    cookie_secure = false
    session_life_time = 86400
    gc_interval_time = 86400
    
    [security]
    admin_user = admin
    admin_password = $GRAFANA_ADMIN_PASSWORD
    secret_key = SW2YcwTIb9zpOOhoPsMm
    login_remember_days = 7
    cookie_username = grafana_user
    cookie_remember_name = grafana_remember
    disable_gravatar = false
    
    [snapshots]
    external_enabled = true
    external_snapshot_url = https://snapshots-origin.raintank.io
    external_snapshot_name = Publish to snapshot.raintank.io
    snapshot_remove_expired = true
    
    [dashboards]
    versions_to_keep = 20
    min_refresh_interval = 5s
    default_home_dashboard_path = /etc/grafana/dashboards/home.json
    
    [users]
    allow_sign_up = false
    allow_org_create = false
    auto_assign_org = true
    auto_assign_org_id = 1
    auto_assign_org_role = Viewer
    verify_email_enabled = false
    login_hint = email or username
    password_hint = password
    default_theme = dark
    
    [auth]
    disable_login_form = false
    disable_signout_menu = false
    
    [auth.anonymous]
    enabled = false
    org_name = Main Org.
    org_role = Viewer
    hide_version = false
    
    [auth.basic]
    enabled = true
    
    [smtp]
    enabled = false
    
    [emails]
    welcome_email_on_sign_up = false
    templates_pattern = emails/*.html
    
    [alerting]
    enabled = true
    execute_alerts = true
    error_or_timeout = alerting
    nodata_or_nullvalues = no_data
    concurrent_render_limit = 5
    evaluation_timeout_seconds = 30
    notification_timeout_seconds = 30
    max_attempts = 3
    min_interval_seconds = 1
    
    [explore]
    enabled = true
    
    [help]
    enabled = true
    
    [profile]
    enabled = true
    
    [query_history]
    enabled = true
    
    [unified_alerting]
    enabled = true
    ha_peers = ""
    ha_listen_address = "0.0.0.0:9094"
    ha_advertise_address = ""
    ha_gossip_interval = "200ms"
    ha_push_pull_interval = "60s"
    ha_peer_timeout = "15s"
    min_interval = 10s
    
    [feature_toggles]
    enable = ngalert
    
    [ngalert]
    enabled = true

---
# Grafana Datasources Configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: config
data:
  datasources.yaml: |
    apiVersion: 1
    deleteDatasources:
      - name: Prometheus
        orgId: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        orgId: 1
        url: http://prometheus.$MONITORING_NAMESPACE.svc.cluster.local:9090
        basicAuth: false
        isDefault: true
        version: 1
        editable: true
        jsonData:
          httpMethod: POST
          manageAlerts: false
          prometheusType: Prometheus
          prometheusVersion: 2.48.0
          cacheLevel: 'High'
          disableRecordingRules: false
          incrementalQueryOverlapWindow: 10m
          exemplarTraceIdDestinations: []

---
# Grafana Dashboards Provider Configuration  
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards-provider
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: config
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        editable: true
        updateIntervalSeconds: 10
        allowUiUpdates: true
        options:
          path: /var/lib/grafana/dashboards/default
      - name: 'kubernetes'
        orgId: 1
        folder: 'Kubernetes'
        type: file
        disableDeletion: false
        editable: true
        updateIntervalSeconds: 10
        allowUiUpdates: true
        options:
          path: /var/lib/grafana/dashboards/kubernetes
      - name: 'jupyterhub'
        orgId: 1
        folder: 'JupyterHub'
        type: file
        disableDeletion: false
        editable: true
        updateIntervalSeconds: 10
        allowUiUpdates: true
        options:
          path: /var/lib/grafana/dashboards/jupyterhub
EOF

    if kubectl apply -f "$config_manifest"; then
        print_status "SUCCESS" "Grafana configuration created"
    else
        print_status "ERROR" "Failed to create Grafana configuration"
        return 1
    fi
    
    print_status "SUCCESS" "Grafana configuration completed"
}

# Grafanaダッシュボード作成
create_grafana_dashboards() {
    print_status "INFO" "Creating Grafana dashboards..."
    
    local dashboard_manifest="$PROJECT_ROOT/k8s-manifests/grafana-dashboards.yaml"
    
    cat > "$dashboard_manifest" <<EOF
---
# Kubernetes Cluster Overview Dashboard
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-kubernetes-cluster
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: dashboard
    grafana_dashboard: "1"
data:
  kubernetes-cluster.json: |
    {
      "dashboard": {
        "id": null,
        "title": "Kubernetes Cluster Overview",
        "tags": ["kubernetes", "cluster", "overview"],
        "style": "dark",
        "timezone": "",
        "panels": [
          {
            "id": 1,
            "title": "Cluster Status",
            "type": "stat",
            "targets": [
              {
                "expr": "up{job=\"kubernetes-apiservers\"}",
                "legendFormat": "API Server"
              }
            ],
            "fieldConfig": {
              "defaults": {
                "color": {"mode": "thresholds"},
                "mappings": [],
                "thresholds": {
                  "steps": [
                    {"color": "green", "value": null}
                  ]
                },
                "unit": "none"
              }
            },
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}
          },
          {
            "id": 2,
            "title": "Node Count",
            "type": "stat",
            "targets": [
              {
                "expr": "count(kube_node_info)",
                "legendFormat": "Total Nodes"
              }
            ],
            "fieldConfig": {
              "defaults": {
                "color": {"mode": "thresholds"},
                "mappings": [],
                "thresholds": {
                  "steps": [
                    {"color": "green", "value": null}
                  ]
                },
                "unit": "none"
              }
            },
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}
          }
        ],
        "time": {
          "from": "now-1h",
          "to": "now"
        },
        "refresh": "5s",
        "schemaVersion": 16,
        "version": 1,
        "links": []
      }
    }

---
# Node Exporter Dashboard
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-node-exporter
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: dashboard
    grafana_dashboard: "1"
data:
  node-exporter.json: |
    {
      "dashboard": {
        "id": null,
        "title": "Node Exporter Full",
        "tags": ["node-exporter", "system", "monitoring"],
        "style": "dark",
        "timezone": "",
        "panels": [
          {
            "id": 1,
            "title": "CPU Usage",
            "type": "graph",
            "targets": [
              {
                "expr": "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
                "legendFormat": "CPU Usage %"
              }
            ],
            "yAxes": [
              {
                "min": 0,
                "max": 100,
                "unit": "percent"
              }
            ],
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}
          },
          {
            "id": 2,
            "title": "Memory Usage",
            "type": "graph",
            "targets": [
              {
                "expr": "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100",
                "legendFormat": "Memory Usage %"
              }
            ],
            "yAxes": [
              {
                "min": 0,
                "max": 100,
                "unit": "percent"
              }
            ],
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}
          }
        ],
        "time": {
          "from": "now-1h",
          "to": "now"
        },
        "refresh": "5s",
        "schemaVersion": 16,
        "version": 1,
        "links": []
      }
    }

---
# JupyterHub Dashboard
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-jupyterhub
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: dashboard
    grafana_dashboard: "1"
data:
  jupyterhub.json: |
    {
      "dashboard": {
        "id": null,
        "title": "JupyterHub Monitoring",
        "tags": ["jupyterhub", "application", "monitoring"],
        "style": "dark",
        "timezone": "",
        "panels": [
          {
            "id": 1,
            "title": "JupyterHub Status",
            "type": "stat",
            "targets": [
              {
                "expr": "up{job=\"jupyterhub\"}",
                "legendFormat": "JupyterHub"
              }
            ],
            "fieldConfig": {
              "defaults": {
                "color": {"mode": "thresholds"},
                "mappings": [
                  {"options": {"0": {"text": "DOWN"}}, "type": "value"},
                  {"options": {"1": {"text": "UP"}}, "type": "value"}
                ],
                "thresholds": {
                  "steps": [
                    {"color": "red", "value": 0},
                    {"color": "green", "value": 1}
                  ]
                },
                "unit": "none"
              }
            },
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}
          },
          {
            "id": 2,
            "title": "Active Users",
            "type": "stat",
            "targets": [
              {
                "expr": "kube_deployment_status_replicas_available{deployment=\"jupyterhub\", namespace=\"jupyterhub\"}",
                "legendFormat": "Active Pods"
              }
            ],
            "fieldConfig": {
              "defaults": {
                "color": {"mode": "thresholds"},
                "mappings": [],
                "thresholds": {
                  "steps": [
                    {"color": "green", "value": null}
                  ]
                },
                "unit": "none"
              }
            },
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}
          }
        ],
        "time": {
          "from": "now-1h",
          "to": "now"
        },
        "refresh": "5s",
        "schemaVersion": 16,
        "version": 1,
        "links": []
      }
    }

---
# Home Dashboard
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-home
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: dashboard
    grafana_dashboard: "1"
data:
  home.json: |
    {
      "dashboard": {
        "id": null,
        "title": "kubeadm Python Cluster - Home",
        "tags": ["home", "overview"],
        "style": "dark",
        "timezone": "",
        "panels": [
          {
            "id": 1,
            "title": "Cluster Overview",
            "type": "text",
            "content": "# kubeadm Python Cluster\\n\\nWelcome to the monitoring dashboard for your Kubernetes cluster with JupyterHub.\\n\\n## Available Dashboards:\\n- **Kubernetes Cluster**: Overall cluster health and metrics\\n- **Node Exporter**: System-level monitoring for all nodes\\n- **JupyterHub**: Application-specific monitoring\\n\\n## Quick Links:\\n- [Prometheus](http://localhost:30900)\\n- [JupyterHub](http://localhost:30443)\\n\\n## Cluster Information:\\n- **Namespace**: monitoring\\n- **JupyterHub Namespace**: jupyterhub\\n- **Container Registry**: localhost:5000",
            "mode": "markdown",
            "gridPos": {"h": 16, "w": 24, "x": 0, "y": 0}
          }
        ],
        "time": {
          "from": "now-1h",
          "to": "now"
        },
        "refresh": "5s",
        "schemaVersion": 16,
        "version": 1,
        "links": []
      }
    }
EOF

    if kubectl apply -f "$dashboard_manifest"; then
        print_status "SUCCESS" "Grafana dashboards created"
    else
        print_status "ERROR" "Failed to create Grafana dashboards"
        return 1
    fi
    
    print_status "SUCCESS" "Grafana dashboards completed"
}

# Grafana永続ストレージ設定
setup_grafana_storage() {
    print_status "INFO" "Setting up Grafana storage..."
    
    local storage_manifest="$PROJECT_ROOT/k8s-manifests/grafana-storage.yaml"
    
    cat > "$storage_manifest" <<EOF
---
# Grafana Storage Class
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: grafana-storage
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain

---
# Grafana Persistent Volume
apiVersion: v1
kind: PersistentVolume
metadata:
  name: grafana-pv
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: storage
spec:
  capacity:
    storage: $STORAGE_SIZE
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: grafana-storage
  hostPath:
    path: /opt/grafana-data
    type: DirectoryOrCreate

---
# Grafana Persistent Volume Claim
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-pvc
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: storage
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: $STORAGE_SIZE
  storageClassName: grafana-storage
EOF

    if kubectl apply -f "$storage_manifest"; then
        print_status "SUCCESS" "Grafana storage configured"
    else
        print_status "ERROR" "Failed to setup Grafana storage"
        return 1
    fi
    
    print_status "SUCCESS" "Storage setup completed"
}

# Grafana Deployment作成
create_grafana_deployment() {
    print_status "INFO" "Creating Grafana deployment..."
    
    local deployment_manifest="$PROJECT_ROOT/k8s-manifests/grafana-deployment.yaml"
    
    cat > "$deployment_manifest" <<EOF
---
# Grafana ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: service-account

---
# Grafana Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: dashboard
    app.kubernetes.io/version: "$GRAFANA_VERSION"
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: grafana
      app.kubernetes.io/component: dashboard
  template:
    metadata:
      labels:
        app.kubernetes.io/name: grafana
        app.kubernetes.io/instance: kubeadm-python-cluster
        app.kubernetes.io/component: dashboard
    spec:
      serviceAccountName: grafana
      securityContext:
        runAsUser: 472
        runAsGroup: 472
        fsGroup: 472
        runAsNonRoot: true
      containers:
      - name: grafana
        image: grafana/grafana:$GRAFANA_VERSION
        imagePullPolicy: IfNotPresent
        ports:
        - name: http
          containerPort: 3000
          protocol: TCP
        env:
        - name: GF_SECURITY_ADMIN_USER
          value: admin
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: "$GRAFANA_ADMIN_PASSWORD"
        - name: GF_PATHS_DATA
          value: /var/lib/grafana/
        - name: GF_PATHS_LOGS
          value: /var/log/grafana
        - name: GF_PATHS_PLUGINS
          value: /var/lib/grafana/plugins
        - name: GF_PATHS_PROVISIONING
          value: /etc/grafana/provisioning
        - name: GF_INSTALL_PLUGINS
          value: grafana-piechart-panel,grafana-worldmap-panel
        livenessProbe:
          httpGet:
            path: /api/health
            port: http
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /api/health
            port: http
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        volumeMounts:
        - name: config
          mountPath: /etc/grafana/grafana.ini
          subPath: grafana.ini
          readOnly: true
        - name: datasources
          mountPath: /etc/grafana/provisioning/datasources/datasources.yaml
          subPath: datasources.yaml
          readOnly: true
        - name: dashboards-provider
          mountPath: /etc/grafana/provisioning/dashboards/dashboards.yaml
          subPath: dashboards.yaml
          readOnly: true
        - name: dashboard-kubernetes-cluster
          mountPath: /var/lib/grafana/dashboards/kubernetes/kubernetes-cluster.json
          subPath: kubernetes-cluster.json
          readOnly: true
        - name: dashboard-node-exporter
          mountPath: /var/lib/grafana/dashboards/kubernetes/node-exporter.json
          subPath: node-exporter.json
          readOnly: true
        - name: dashboard-jupyterhub
          mountPath: /var/lib/grafana/dashboards/jupyterhub/jupyterhub.json
          subPath: jupyterhub.json
          readOnly: true
        - name: dashboard-home
          mountPath: /var/lib/grafana/dashboards/default/home.json
          subPath: home.json
          readOnly: true
        - name: data
          mountPath: /var/lib/grafana
        - name: logs
          mountPath: /var/log/grafana
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          runAsNonRoot: true
          runAsUser: 472
          runAsGroup: 472
          capabilities:
            drop:
            - ALL
      volumes:
      - name: config
        configMap:
          name: grafana-config
          defaultMode: 0644
      - name: datasources
        configMap:
          name: grafana-datasources
          defaultMode: 0644
      - name: dashboards-provider
        configMap:
          name: grafana-dashboards-provider
          defaultMode: 0644
      - name: dashboard-kubernetes-cluster
        configMap:
          name: dashboard-kubernetes-cluster
          defaultMode: 0644
      - name: dashboard-node-exporter
        configMap:
          name: dashboard-node-exporter
          defaultMode: 0644
      - name: dashboard-jupyterhub
        configMap:
          name: dashboard-jupyterhub
          defaultMode: 0644
      - name: dashboard-home
        configMap:
          name: dashboard-home
          defaultMode: 0644
      - name: data
        persistentVolumeClaim:
          claimName: grafana-pvc
      - name: logs
        emptyDir: {}
      nodeSelector:
        kubernetes.io/os: linux

---
# Grafana Service
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: dashboard
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "3000"
    prometheus.io/path: "/metrics"
spec:
  type: NodePort
  ports:
  - name: http
    port: 3000
    targetPort: http
    protocol: TCP
    nodePort: 30300
  selector:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/component: dashboard

---
# Grafana Internal Service
apiVersion: v1
kind: Service
metadata:
  name: grafana-internal
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: dashboard-internal
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 3000
    targetPort: http
    protocol: TCP
  selector:
    app.kubernetes.io/name: grafana
    app.kubernetes.io/component: dashboard
EOF

    if kubectl apply -f "$deployment_manifest"; then
        print_status "SUCCESS" "Grafana deployment created"
    else
        print_status "ERROR" "Failed to create Grafana deployment"
        return 1
    fi
    
    print_status "SUCCESS" "Grafana deployment completed"
}

# Grafanaデプロイメント確認
verify_grafana_deployment() {
    print_status "INFO" "Verifying Grafana deployment..."
    
    local timeout=300
    local interval=10
    local elapsed=0
    
    # Grafana Pod起動確認
    while [[ $elapsed -lt $timeout ]]; do
        if kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana | grep -q "Running"; then
            print_status "SUCCESS" "Grafana pod is running"
            break
        fi
        
        print_status "INFO" "Waiting for Grafana pod to start... ($elapsed/${timeout}s)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    if [[ $elapsed -ge $timeout ]]; then
        print_status "ERROR" "Grafana deployment timeout"
        return 1
    fi
    
    # Grafana サービス確認
    if kubectl get endpoints -n "$MONITORING_NAMESPACE" grafana | grep -q ":3000"; then
        print_status "SUCCESS" "Grafana service endpoint is available"
    else
        print_status "WARNING" "Grafana service endpoint not ready"
    fi
    
    # 簡易ヘルスチェック
    print_status "INFO" "Performing Grafana health check..."
    
    local node_ip
    if node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); then
        # NodePort経由でのヘルスチェック
        local count=0
        local max_attempts=10
        
        while [[ $count -lt $max_attempts ]]; do
            if curl -f -s "http://$node_ip:30300/api/health" >/dev/null 2>&1; then
                print_status "SUCCESS" "Grafana health check passed"
                break
            fi
            
            ((count++))
            sleep 5
        done
        
        if [[ $count -ge $max_attempts ]]; then
            print_status "WARNING" "Grafana health check timeout (service may not be ready)"
        fi
    fi
    
    print_status "SUCCESS" "Grafana deployment verification completed"
}

# アクセス情報表示
show_access_information() {
    print_status "INFO" "Grafana access information:"
    
    local node_ip
    if node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); then
        echo ""
        echo "=== Grafana Access Information ==="
        echo "Grafana UI: http://$node_ip:30300"
        echo "Username: admin"
        echo "Password: $GRAFANA_ADMIN_PASSWORD"
        echo ""
        echo "=== Internal Service URLs ==="
        echo "Grafana: http://grafana.$MONITORING_NAMESPACE.svc.cluster.local:3000"
        echo ""
        echo "=== Available Dashboards ==="
        echo "• Home: kubeadm Python Cluster overview"
        echo "• Kubernetes Cluster: Overall cluster monitoring"
        echo "• Node Exporter: System-level metrics"
        echo "• JupyterHub: Application-specific monitoring"
        echo ""
        echo "=== Grafana Status ==="
        kubectl get all -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana
        echo ""
        echo "=== Storage Usage ==="
        kubectl get pvc -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana
    else
        print_status "WARNING" "Unable to determine node IP address"
    fi
}

# 管理スクリプト作成
create_grafana_management_script() {
    print_status "INFO" "Creating Grafana management script..."
    
    local management_script="$SCRIPT_DIR/manage-grafana.sh"
    
    cat > "$management_script" <<'EOF'
#!/bin/bash
# scripts/manage-grafana.sh
# Grafana管理スクリプト

set -euo pipefail

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

print_usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  status         Show Grafana deployment status"
    echo "  logs           Show Grafana pod logs"
    echo "  restart        Restart Grafana deployment"
    echo "  backup         Backup Grafana data"
    echo "  restore        Restore Grafana data from backup"
    echo "  reset-admin    Reset admin password"
    echo "  add-dashboard  Add new dashboard from file"
    echo ""
    echo "Options:"
    echo "  --namespace NS     Monitoring namespace (default: monitoring)"
    echo "  --file FILE        Dashboard JSON file (for add-dashboard)"
    echo "  --password PASS    New admin password (for reset-admin)"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 logs --tail 50"
    echo "  $0 add-dashboard --file my-dashboard.json"
}

show_status() {
    echo "=== Grafana Deployment Status ==="
    kubectl get deployment grafana -n "$MONITORING_NAMESPACE" -o wide
    echo ""
    echo "=== Grafana Pods ==="
    kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana
    echo ""
    echo "=== Grafana Service ==="
    kubectl get service grafana -n "$MONITORING_NAMESPACE" -o wide
    echo ""
    echo "=== Grafana PVC ==="
    kubectl get pvc -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana
}

show_logs() {
    local tail_lines="${1:-100}"
    kubectl logs -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana --tail="$tail_lines" -f
}

restart_grafana() {
    echo "Restarting Grafana deployment..."
    kubectl rollout restart deployment/grafana -n "$MONITORING_NAMESPACE"
    kubectl rollout status deployment/grafana -n "$MONITORING_NAMESPACE" --timeout=300s
    echo "Grafana restarted successfully"
}

backup_data() {
    local backup_dir="grafana-backup-$(date +%Y%m%d_%H%M%S)"
    local pod_name=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -z "$pod_name" ]]; then
        echo "Error: Grafana pod not found"
        return 1
    fi
    
    mkdir -p "$backup_dir"
    echo "Backing up Grafana data to $backup_dir..."
    
    kubectl exec -n "$MONITORING_NAMESPACE" "$pod_name" -- tar czf - -C /var/lib/grafana . | tar xzf - -C "$backup_dir"
    echo "Backup completed: $backup_dir"
}

case "${1:-}" in
    status)
        show_status
        ;;
    logs)
        show_logs "${2:-100}"
        ;;
    restart)
        restart_grafana
        ;;
    backup)
        backup_data
        ;;
    -h|--help)
        print_usage
        ;;
    *)
        echo "Error: Unknown command '${1:-}'"
        print_usage
        exit 1
        ;;
esac
EOF

    chmod +x "$management_script"
    print_status "SUCCESS" "Grafana management script created: $management_script"
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # Grafanaダッシュボードセットアッププロセス
    check_prerequisites
    create_grafana_config
    create_grafana_dashboards
    setup_grafana_storage
    create_grafana_deployment
    verify_grafana_deployment
    create_grafana_management_script
    show_access_information
    
    echo -e "\n${BLUE}=== Grafana Setup Summary ===${NC}"
    print_status "SUCCESS" "Grafana dashboard setup completed successfully!"
    
    echo ""
    echo "📊 Grafana Components Deployed:"
    echo "  • Grafana Server (NodePort 30300)"
    echo "  • Prometheus DataSource (configured)"
    echo "  • Pre-built Dashboards (4 dashboards)"
    echo "  • Persistent Storage (data retention)"
    
    echo ""
    echo "🎨 Available Dashboards:"
    echo "  • Home Dashboard: Cluster overview"
    echo "  • Kubernetes Cluster: API server and nodes"
    echo "  • Node Exporter: System metrics"
    echo "  • JupyterHub: Application monitoring"
    
    echo ""
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "N/A")
    echo "🌐 Access Information:"
    echo "  URL: http://$node_ip:30300"
    echo "  Username: admin"
    echo "  Password: $GRAFANA_ADMIN_PASSWORD"
    
    echo ""
    echo "Management commands:"
    echo "- Check status: $SCRIPT_DIR/manage-grafana.sh status"
    echo "- View logs: $SCRIPT_DIR/manage-grafana.sh logs"
    echo "- Restart: $SCRIPT_DIR/manage-grafana.sh restart"
    echo "- Backup: $SCRIPT_DIR/manage-grafana.sh backup"
    
    exit 0
}

# 引数処理
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  -h, --help              Show this help message"
        echo "  --namespace NS          Monitoring namespace (default: monitoring)"
        echo "  --password PASS         Grafana admin password (default: admin)"
        echo "  --storage-size SIZE     Grafana storage size (default: 10Gi)"
        echo "  --grafana-version V     Grafana version (default: $GRAFANA_VERSION)"
        echo "  --verify-only           Only verify existing deployment"
        echo "  --status                Show Grafana status"
        echo ""
        echo "Examples:"
        echo "  $0                      Setup complete Grafana dashboard"
        echo "  $0 --password mypass    Setup with custom admin password"
        echo "  $0 --status             Show current Grafana status"
        exit 0
        ;;
    --namespace)
        MONITORING_NAMESPACE="${2:-$MONITORING_NAMESPACE}"
        shift 2
        ;;
    --password)
        GRAFANA_ADMIN_PASSWORD="${2:-$GRAFANA_ADMIN_PASSWORD}"
        shift 2
        ;;
    --storage-size)
        STORAGE_SIZE="${2:-$STORAGE_SIZE}"
        shift 2
        ;;
    --grafana-version)
        GRAFANA_VERSION="${2:-$GRAFANA_VERSION}"
        shift 2
        ;;
    --verify-only)
        check_prerequisites
        verify_grafana_deployment
        show_access_information
        exit 0
        ;;
    --status)
        check_prerequisites
        show_access_information
        exit 0
        ;;
esac

# メイン実行
main "$@"