#!/bin/bash
# scripts/setup-prometheus.sh
# Prometheus監視セットアップスクリプト for kubeadm-python-cluster

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
LOG_FILE="$SCRIPT_DIR/prometheus-setup.log"
EXIT_CODE=0

# Prometheus設定
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-2.48.1}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.6.1}"
KUBE_STATE_METRICS_VERSION="${KUBE_STATE_METRICS_VERSION:-2.10.1}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
STORAGE_SIZE="${STORAGE_SIZE:-20Gi}"

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}Prometheus Monitoring Setup${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting Prometheus monitoring setup"
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
    print_status "INFO" "Checking prerequisites for Prometheus setup..."
    
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
    
    # クラスター管理者権限確認
    if ! kubectl auth can-i create namespaces >/dev/null 2>&1; then
        print_status "ERROR" "Insufficient cluster privileges. Need cluster-admin access"
        return 1
    fi
    
    # Helm確認（オプション）
    if command -v helm >/dev/null 2>&1; then
        print_status "INFO" "Helm found: $(helm version --short)"
    else
        print_status "WARNING" "Helm not found. Using kubectl manifests only"
    fi
    
    print_status "SUCCESS" "Prerequisites check completed"
}

# 監視用名前空間作成
create_monitoring_namespace() {
    print_status "INFO" "Creating monitoring namespace..."
    
    local namespace_manifest="$PROJECT_ROOT/k8s-manifests/monitoring-namespace.yaml"
    
    cat > "$namespace_manifest" <<EOF
---
# Monitoring Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: $MONITORING_NAMESPACE
  labels:
    name: $MONITORING_NAMESPACE
    app.kubernetes.io/name: monitoring
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: namespace
spec: {}

---
# Monitoring ConfigMap for global configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: monitoring-config
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: monitoring
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: config
data:
  cluster-name: "kubeadm-python-cluster"
  retention-days: "15"
  scrape-interval: "15s"
  evaluation-interval: "15s"
EOF

    if kubectl apply -f "$namespace_manifest"; then
        print_status "SUCCESS" "Monitoring namespace created"
    else
        print_status "ERROR" "Failed to create monitoring namespace"
        return 1
    fi
    
    # 名前空間ラベル追加
    kubectl label namespace "$MONITORING_NAMESPACE" monitoring=enabled --overwrite
    
    print_status "SUCCESS" "Monitoring namespace configured"
}

# Prometheus RBAC設定
setup_prometheus_rbac() {
    print_status "INFO" "Setting up Prometheus RBAC..."
    
    local rbac_manifest="$PROJECT_ROOT/k8s-manifests/prometheus-rbac.yaml"
    
    cat > "$rbac_manifest" <<EOF
---
# Prometheus ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: server

---
# Prometheus ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: server
rules:
- apiGroups: [""]
  resources:
  - nodes
  - nodes/proxy
  - nodes/metrics
  - services
  - endpoints
  - pods
  - ingresses
  - configmaps
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions", "networking.k8s.io"]
  resources:
  - ingresses
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources:
  - deployments
  - replicasets
  - daemonsets
  - statefulsets
  verbs: ["get", "list", "watch"]
- nonResourceURLs: ["/metrics", "/metrics/cadvisor"]
  verbs: ["get"]

---
# Prometheus ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus
subjects:
- kind: ServiceAccount
  name: prometheus
  namespace: $MONITORING_NAMESPACE

---
# Node Exporter ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-exporter
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: node-exporter
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: exporter

---
# Node Exporter ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-exporter
  labels:
    app.kubernetes.io/name: node-exporter
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: exporter
rules:
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
- apiGroups: ["authorization.k8s.io"]
  resources: ["subjectaccessreviews"]
  verbs: ["create"]

---
# Node Exporter ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: node-exporter
  labels:
    app.kubernetes.io/name: node-exporter
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: exporter
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: node-exporter
subjects:
- kind: ServiceAccount
  name: node-exporter
  namespace: $MONITORING_NAMESPACE

---
# Kube State Metrics ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-state-metrics
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: kube-state-metrics
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: exporter

---
# Kube State Metrics ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-state-metrics
  labels:
    app.kubernetes.io/name: kube-state-metrics
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: exporter
rules:
- apiGroups: [""]
  resources:
  - configmaps
  - secrets
  - nodes
  - pods
  - services
  - resourcequotas
  - replicationcontrollers
  - limitranges
  - persistentvolumeclaims
  - persistentvolumes
  - namespaces
  - endpoints
  verbs: ["list", "watch"]
- apiGroups: ["apps"]
  resources:
  - statefulsets
  - daemonsets
  - deployments
  - replicasets
  verbs: ["list", "watch"]
- apiGroups: ["batch"]
  resources:
  - cronjobs
  - jobs
  verbs: ["list", "watch"]
- apiGroups: ["autoscaling"]
  resources:
  - horizontalpodautoscalers
  verbs: ["list", "watch"]
- apiGroups: ["authentication.k8s.io"]
  resources:
  - tokenreviews
  verbs: ["create"]
- apiGroups: ["authorization.k8s.io"]
  resources:
  - subjectaccessreviews
  verbs: ["create"]
- apiGroups: ["policy"]
  resources:
  - poddisruptionbudgets
  verbs: ["list", "watch"]
- apiGroups: ["certificates.k8s.io"]
  resources:
  - certificatesigningrequests
  verbs: ["list", "watch"]
- apiGroups: ["storage.k8s.io"]
  resources:
  - storageclasses
  - volumeattachments
  verbs: ["list", "watch"]
- apiGroups: ["admissionregistration.k8s.io"]
  resources:
  - mutatingwebhookconfigurations
  - validatingwebhookconfigurations
  verbs: ["list", "watch"]
- apiGroups: ["networking.k8s.io"]
  resources:
  - networkpolicies
  - ingresses
  verbs: ["list", "watch"]
- apiGroups: ["coordination.k8s.io"]
  resources:
  - leases
  verbs: ["list", "watch"]

---
# Kube State Metrics ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-state-metrics
  labels:
    app.kubernetes.io/name: kube-state-metrics
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: exporter
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-state-metrics
subjects:
- kind: ServiceAccount
  name: kube-state-metrics
  namespace: $MONITORING_NAMESPACE
EOF

    if kubectl apply -f "$rbac_manifest"; then
        print_status "SUCCESS" "Prometheus RBAC configured"
    else
        print_status "ERROR" "Failed to setup Prometheus RBAC"
        return 1
    fi
    
    print_status "SUCCESS" "RBAC setup completed"
}

# Prometheus設定ConfigMap作成
create_prometheus_config() {
    print_status "INFO" "Creating Prometheus configuration..."
    
    local config_manifest="$PROJECT_ROOT/k8s-manifests/prometheus-config.yaml"
    
    cat > "$config_manifest" <<EOF
---
# Prometheus Configuration ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: config
data:
  prometheus.yml: |
    # Prometheus Configuration for kubeadm-python-cluster
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
      external_labels:
        cluster: 'kubeadm-python-cluster'
        environment: 'production'

    # Rule files
    rule_files:
      - "/etc/prometheus/rules/*.yml"

    # Alerting configuration
    alerting:
      alertmanagers:
        - static_configs:
            - targets:
              - alertmanager:9093

    # Scrape configurations
    scrape_configs:

    # Prometheus itself
    - job_name: 'prometheus'
      static_configs:
        - targets: ['localhost:9090']
      scrape_interval: 30s
      metrics_path: '/metrics'

    # Kubernetes API Server
    - job_name: 'kubernetes-apiservers'
      kubernetes_sd_configs:
      - role: endpoints
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        insecure_skip_verify: true
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      relabel_configs:
      - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: default;kubernetes;https

    # Kubernetes nodes (kubelet)
    - job_name: 'kubernetes-nodes'
      kubernetes_sd_configs:
      - role: node
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        insecure_skip_verify: true
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - target_label: __address__
        replacement: kubernetes.default.svc:443
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/\${1}/proxy/metrics

    # Kubernetes node cadvisor
    - job_name: 'kubernetes-cadvisor'
      kubernetes_sd_configs:
      - role: node
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        insecure_skip_verify: true
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - target_label: __address__
        replacement: kubernetes.default.svc:443
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/\${1}/proxy/metrics/cadvisor

    # Node Exporter
    - job_name: 'node-exporter'
      kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
          - $MONITORING_NAMESPACE
      relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: node-exporter
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: metrics

    # Kube State Metrics
    - job_name: 'kube-state-metrics'
      kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
          - $MONITORING_NAMESPACE
      relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: kube-state-metrics
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: http-metrics

    # JupyterHub monitoring
    - job_name: 'jupyterhub'
      kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
          - jupyterhub
      relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: jupyterhub
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: metrics
      scrape_interval: 30s
      metrics_path: /hub/metrics

    # Container Registry monitoring
    - job_name: 'registry'
      static_configs:
        - targets: ['localhost:5000']
      metrics_path: /metrics
      scrape_interval: 60s

    # Service discovery for additional services
    - job_name: 'kubernetes-services'
      kubernetes_sd_configs:
      - role: endpoints
      relabel_configs:
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scheme]
        action: replace
        target_label: __scheme__
        regex: (https?)
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_service_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: \$1:\$2
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_service_name]
        action: replace
        target_label: kubernetes_name

    # Pod monitoring
    - job_name: 'kubernetes-pods'
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: \$1:\$2
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: kubernetes_pod_name

  prometheus.rules.yml: |
    # Prometheus Alerting Rules for kubeadm-python-cluster
    groups:
    - name: kubernetes-cluster
      rules:
      - alert: KubernetesNodeReady
        expr: kube_node_status_condition{condition="Ready",status="true"} == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Kubernetes node not ready (instance {{ \$labels.instance }})"
          description: "Node {{ \$labels.node }} has been unready for more than 5 minutes"

      - alert: KubernetesPodCrashLooping
        expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Kubernetes pod crash looping (instance {{ \$labels.instance }})"
          description: "Pod {{ \$labels.pod }} is crash looping"

      - alert: KubernetesMemoryPressure
        expr: kube_node_status_condition{condition="MemoryPressure",status="true"} == 1
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Kubernetes memory pressure (instance {{ \$labels.instance }})"
          description: "Node {{ \$labels.node }} has memory pressure"

    - name: jupyterhub
      rules:
      - alert: JupyterHubDown
        expr: up{job="jupyterhub"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "JupyterHub is down"
          description: "JupyterHub has been down for more than 2 minutes"

      - alert: JupyterHubHighCPU
        expr: rate(container_cpu_usage_seconds_total{container="jupyterhub"}[5m]) > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "JupyterHub high CPU usage"
          description: "JupyterHub CPU usage is above 80% for more than 5 minutes"

    - name: node-exporter
      rules:
      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage detected"
          description: "CPU usage is above 80% for more than 5 minutes on {{ \$labels.instance }}"

      - alert: HighMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage detected"
          description: "Memory usage is above 85% for more than 5 minutes on {{ \$labels.instance }}"

      - alert: DiskSpaceLow
        expr: (1 - (node_filesystem_free_bytes / node_filesystem_size_bytes)) * 100 > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Disk space is low"
          description: "Disk usage is above 90% on {{ \$labels.instance }}"
EOF

    if kubectl apply -f "$config_manifest"; then
        print_status "SUCCESS" "Prometheus configuration created"
    else
        print_status "ERROR" "Failed to create Prometheus configuration"
        return 1
    fi
    
    print_status "SUCCESS" "Prometheus configuration completed"
}

# Prometheus永続ストレージ設定
setup_prometheus_storage() {
    print_status "INFO" "Setting up Prometheus storage..."
    
    local storage_manifest="$PROJECT_ROOT/k8s-manifests/prometheus-storage.yaml"
    
    cat > "$storage_manifest" <<EOF
---
# Prometheus Storage Class
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: prometheus-storage
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain

---
# Prometheus Persistent Volume
apiVersion: v1
kind: PersistentVolume
metadata:
  name: prometheus-pv
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: storage
spec:
  capacity:
    storage: $STORAGE_SIZE
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: prometheus-storage
  hostPath:
    path: /opt/prometheus-data
    type: DirectoryOrCreate

---
# Prometheus Persistent Volume Claim
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-pvc
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: storage
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: $STORAGE_SIZE
  storageClassName: prometheus-storage
EOF

    if kubectl apply -f "$storage_manifest"; then
        print_status "SUCCESS" "Prometheus storage configured"
    else
        print_status "ERROR" "Failed to setup Prometheus storage"
        return 1
    fi
    
    print_status "SUCCESS" "Storage setup completed"
}

# Prometheus Deployment作成
create_prometheus_deployment() {
    print_status "INFO" "Creating Prometheus deployment..."
    
    local deployment_manifest="$PROJECT_ROOT/k8s-manifests/prometheus-deployment.yaml"
    
    cat > "$deployment_manifest" <<EOF
---
# Prometheus Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: server
    app.kubernetes.io/version: "$PROMETHEUS_VERSION"
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus
      app.kubernetes.io/component: server
  template:
    metadata:
      labels:
        app.kubernetes.io/name: prometheus
        app.kubernetes.io/instance: kubeadm-python-cluster
        app.kubernetes.io/component: server
    spec:
      serviceAccountName: prometheus
      securityContext:
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
        runAsNonRoot: true
      containers:
      - name: prometheus
        image: prom/prometheus:v$PROMETHEUS_VERSION
        imagePullPolicy: IfNotPresent
        args:
          - '--storage.tsdb.retention.time=15d'
          - '--config.file=/etc/prometheus/prometheus.yml'
          - '--storage.tsdb.path=/prometheus/'
          - '--web.console.libraries=/etc/prometheus/console_libraries'
          - '--web.console.templates=/etc/prometheus/consoles'
          - '--web.enable-lifecycle'
          - '--web.enable-admin-api'
          - '--log.level=info'
        ports:
        - name: web
          containerPort: 9090
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /-/healthy
            port: web
          initialDelaySeconds: 30
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /-/ready
            port: web
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "2000m"
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
          readOnly: true
        - name: data
          mountPath: /prometheus
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 65534
          runAsGroup: 65534
          capabilities:
            drop:
            - ALL
      - name: configmap-reload
        image: jimmidyson/configmap-reload:v0.8.0
        imagePullPolicy: IfNotPresent
        args:
          - --volume-dir=/etc/prometheus
          - --webhook-url=http://127.0.0.1:9090/-/reload
        resources:
          requests:
            memory: "32Mi"
            cpu: "100m"
          limits:
            memory: "64Mi"
            cpu: "200m"
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
          readOnly: true
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 65534
          runAsGroup: 65534
          capabilities:
            drop:
            - ALL
      volumes:
      - name: config
        configMap:
          name: prometheus-config
          defaultMode: 0644
      - name: data
        persistentVolumeClaim:
          claimName: prometheus-pvc
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
      - effect: NoSchedule
        operator: Exists

---
# Prometheus Service
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: server
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
    prometheus.io/path: "/metrics"
spec:
  type: NodePort
  ports:
  - name: web
    port: 9090
    targetPort: web
    protocol: TCP
    nodePort: 30900
  selector:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/component: server

---
# Prometheus Internal Service
apiVersion: v1
kind: Service
metadata:
  name: prometheus-internal
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: server-internal
spec:
  type: ClusterIP
  ports:
  - name: web
    port: 9090
    targetPort: web
    protocol: TCP
  selector:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/component: server
EOF

    if kubectl apply -f "$deployment_manifest"; then
        print_status "SUCCESS" "Prometheus deployment created"
    else
        print_status "ERROR" "Failed to create Prometheus deployment"
        return 1
    fi
    
    print_status "SUCCESS" "Prometheus deployment completed"
}

# Node Exporter DaemonSet作成
create_node_exporter() {
    print_status "INFO" "Creating Node Exporter DaemonSet..."
    
    local node_exporter_manifest="$PROJECT_ROOT/k8s-manifests/node-exporter.yaml"
    
    cat > "$node_exporter_manifest" <<EOF
---
# Node Exporter DaemonSet
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: node-exporter
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: exporter
    app.kubernetes.io/version: "$NODE_EXPORTER_VERSION"
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-exporter
      app.kubernetes.io/component: exporter
  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-exporter
        app.kubernetes.io/instance: kubeadm-python-cluster
        app.kubernetes.io/component: exporter
    spec:
      serviceAccountName: node-exporter
      hostNetwork: true
      hostPID: true
      securityContext:
        runAsUser: 65534
        runAsGroup: 65534
        runAsNonRoot: true
      containers:
      - name: node-exporter
        image: prom/node-exporter:v$NODE_EXPORTER_VERSION
        imagePullPolicy: IfNotPresent
        args:
          - --path.sysfs=/host/sys
          - --path.rootfs=/host/root
          - --no-collector.wifi
          - --no-collector.hwmon
          - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+|var/lib/kubelet/pods/.+)(\$|/)
          - --collector.netclass.ignored-devices=^(veth.*|docker.*|[0-9a-f]{12,})$
          - --collector.netdev.device-exclude=^(veth.*|docker.*|[0-9a-f]{12,})$
        ports:
        - name: metrics
          containerPort: 9100
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /
            port: metrics
          initialDelaySeconds: 10
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /
            port: metrics
          initialDelaySeconds: 5
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
        volumeMounts:
        - name: sys
          mountPath: /host/sys
          mountPropagation: HostToContainer
          readOnly: true
        - name: root
          mountPath: /host/root
          mountPropagation: HostToContainer
          readOnly: true
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 65534
          runAsGroup: 65534
          capabilities:
            drop:
            - ALL
      volumes:
      - name: sys
        hostPath:
          path: /sys
      - name: root
        hostPath:
          path: /
      tolerations:
      - effect: NoSchedule
        operator: Exists
      - effect: NoExecute
        operator: Exists

---
# Node Exporter Service
apiVersion: v1
kind: Service
metadata:
  name: node-exporter
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: node-exporter
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: exporter
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9100"
    prometheus.io/path: "/metrics"
spec:
  type: ClusterIP
  clusterIP: None
  ports:
  - name: metrics
    port: 9100
    targetPort: metrics
    protocol: TCP
  selector:
    app.kubernetes.io/name: node-exporter
    app.kubernetes.io/component: exporter
EOF

    if kubectl apply -f "$node_exporter_manifest"; then
        print_status "SUCCESS" "Node Exporter created"
    else
        print_status "ERROR" "Failed to create Node Exporter"
        return 1
    fi
    
    print_status "SUCCESS" "Node Exporter setup completed"
}

# Kube State Metrics Deployment作成
create_kube_state_metrics() {
    print_status "INFO" "Creating Kube State Metrics deployment..."
    
    local ksm_manifest="$PROJECT_ROOT/k8s-manifests/kube-state-metrics.yaml"
    
    cat > "$ksm_manifest" <<EOF
---
# Kube State Metrics Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-state-metrics
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: kube-state-metrics
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: exporter
    app.kubernetes.io/version: "$KUBE_STATE_METRICS_VERSION"
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: kube-state-metrics
      app.kubernetes.io/component: exporter
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kube-state-metrics
        app.kubernetes.io/instance: kubeadm-python-cluster
        app.kubernetes.io/component: exporter
    spec:
      serviceAccountName: kube-state-metrics
      securityContext:
        runAsUser: 65534
        runAsGroup: 65534
        runAsNonRoot: true
      containers:
      - name: kube-state-metrics
        image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v$KUBE_STATE_METRICS_VERSION
        imagePullPolicy: IfNotPresent
        ports:
        - name: http-metrics
          containerPort: 8080
          protocol: TCP
        - name: telemetry
          containerPort: 8081
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /healthz
            port: http-metrics
          initialDelaySeconds: 5
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /
            port: telemetry
          initialDelaySeconds: 5
          timeoutSeconds: 5
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 65534
          runAsGroup: 65534
          capabilities:
            drop:
            - ALL
      nodeSelector:
        kubernetes.io/os: linux

---
# Kube State Metrics Service
apiVersion: v1
kind: Service
metadata:
  name: kube-state-metrics
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: kube-state-metrics
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: exporter
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/metrics"
spec:
  type: ClusterIP
  ports:
  - name: http-metrics
    port: 8080
    targetPort: http-metrics
    protocol: TCP
  - name: telemetry
    port: 8081
    targetPort: telemetry
    protocol: TCP
  selector:
    app.kubernetes.io/name: kube-state-metrics
    app.kubernetes.io/component: exporter
EOF

    if kubectl apply -f "$ksm_manifest"; then
        print_status "SUCCESS" "Kube State Metrics created"
    else
        print_status "ERROR" "Failed to create Kube State Metrics"
        return 1
    fi
    
    print_status "SUCCESS" "Kube State Metrics setup completed"
}

# Prometheusデプロイメント確認
verify_prometheus_deployment() {
    print_status "INFO" "Verifying Prometheus deployment..."
    
    local timeout=300
    local interval=10
    local elapsed=0
    
    # Prometheus Pod起動確認
    while [[ $elapsed -lt $timeout ]]; do
        if kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=prometheus | grep -q "Running"; then
            print_status "SUCCESS" "Prometheus pod is running"
            break
        fi
        
        print_status "INFO" "Waiting for Prometheus pod to start... ($elapsed/${timeout}s)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    if [[ $elapsed -ge $timeout ]]; then
        print_status "ERROR" "Prometheus deployment timeout"
        return 1
    fi
    
    # Node Exporter DaemonSet確認
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    local ready_nodes=0
    
    elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        ready_nodes=$(kubectl get ds -n "$MONITORING_NAMESPACE" node-exporter -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
        
        if [[ "$ready_nodes" == "$node_count" ]]; then
            print_status "SUCCESS" "Node Exporter running on all nodes ($ready_nodes/$node_count)"
            break
        fi
        
        print_status "INFO" "Waiting for Node Exporter on all nodes... ($ready_nodes/$node_count ready)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    # Kube State Metrics確認
    if kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=kube-state-metrics | grep -q "Running"; then
        print_status "SUCCESS" "Kube State Metrics is running"
    else
        print_status "WARNING" "Kube State Metrics may not be ready yet"
    fi
    
    print_status "SUCCESS" "Prometheus deployment verification completed"
}

# アクセス情報とテスト
show_access_information() {
    print_status "INFO" "Prometheus access information:"
    
    local node_ip
    if node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); then
        echo ""
        echo "=== Prometheus Access URLs ==="
        echo "Prometheus UI: http://$node_ip:30900"
        echo ""
        echo "=== Internal Service URLs ==="
        echo "Prometheus: http://prometheus.$MONITORING_NAMESPACE.svc.cluster.local:9090"
        echo "Node Exporter: http://node-exporter.$MONITORING_NAMESPACE.svc.cluster.local:9100"
        echo "Kube State Metrics: http://kube-state-metrics.$MONITORING_NAMESPACE.svc.cluster.local:8080"
        echo ""
        echo "=== Monitoring Status ==="
        kubectl get all -n "$MONITORING_NAMESPACE"
        echo ""
        echo "=== Storage Usage ==="
        kubectl get pvc -n "$MONITORING_NAMESPACE"
    else
        print_status "WARNING" "Unable to determine node IP address"
    fi
    
    # 基本ヘルスチェック
    print_status "INFO" "Performing basic health checks..."
    
    if kubectl get endpoints -n "$MONITORING_NAMESPACE" prometheus | grep -q ":9090"; then
        print_status "SUCCESS" "Prometheus endpoint is available"
    else
        print_status "WARNING" "Prometheus endpoint not ready"
    fi
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # Prometheus監視セットアッププロセス
    check_prerequisites
    create_monitoring_namespace
    setup_prometheus_rbac
    create_prometheus_config
    setup_prometheus_storage
    create_prometheus_deployment
    create_node_exporter
    create_kube_state_metrics
    verify_prometheus_deployment
    show_access_information
    
    echo -e "\n${BLUE}=== Prometheus Setup Summary ===${NC}"
    print_status "SUCCESS" "Prometheus monitoring setup completed successfully!"
    
    echo ""
    echo "📊 Monitoring Components Deployed:"
    echo "  • Prometheus Server (NodePort 30900)"
    echo "  • Node Exporter (DaemonSet on all nodes)"
    echo "  • Kube State Metrics (Cluster metrics)"
    echo "  • Alerting Rules (Basic set configured)"
    
    echo ""
    echo "🔍 Monitoring Features:"
    echo "  • Kubernetes cluster monitoring"
    echo "  • Node resource monitoring"  
    echo "  • JupyterHub application monitoring"
    echo "  • Container registry monitoring"
    echo "  • Pod and service discovery"
    
    echo ""
    echo "Next steps:"
    echo "1. Access Prometheus UI at http://$node_ip:30900"
    echo "2. Setup Grafana for visualization (TASK-020)"
    echo "3. Configure alerting with Alertmanager"
    echo "4. Add custom metrics for JupyterHub"
    
    echo ""
    echo "Management commands:"
    echo "- View monitoring status: kubectl get all -n $MONITORING_NAMESPACE"
    echo "- Check Prometheus config: kubectl get configmap prometheus-config -n $MONITORING_NAMESPACE -o yaml"
    echo "- Scale Prometheus: kubectl scale deployment prometheus -n $MONITORING_NAMESPACE --replicas=1"
    
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
        echo "  --storage-size SIZE     Prometheus storage size (default: 20Gi)"
        echo "  --prometheus-version V  Prometheus version (default: $PROMETHEUS_VERSION)"
        echo "  --node-exporter-version V  Node Exporter version (default: $NODE_EXPORTER_VERSION)"
        echo "  --verify-only          Only verify existing deployment"
        echo "  --status               Show monitoring status"
        echo ""
        echo "Examples:"
        echo "  $0                     Setup complete Prometheus monitoring"
        echo "  $0 --storage-size 50Gi Setup with larger storage"
        echo "  $0 --status            Show current monitoring status"
        exit 0
        ;;
    --namespace)
        MONITORING_NAMESPACE="${2:-$MONITORING_NAMESPACE}"
        shift 2
        ;;
    --storage-size)
        STORAGE_SIZE="${2:-$STORAGE_SIZE}"
        shift 2
        ;;
    --prometheus-version)
        PROMETHEUS_VERSION="${2:-$PROMETHEUS_VERSION}"
        shift 2
        ;;
    --node-exporter-version)
        NODE_EXPORTER_VERSION="${2:-$NODE_EXPORTER_VERSION}"
        shift 2
        ;;
    --verify-only)
        check_prerequisites
        verify_prometheus_deployment
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