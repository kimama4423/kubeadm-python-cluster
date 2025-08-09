#!/bin/bash
# scripts/setup-alerting.sh
# Alertmanager + アラートルール設定スクリプト for kubeadm-python-cluster

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
LOG_FILE="$SCRIPT_DIR/alerting-setup.log"
EXIT_CODE=0

# アラート設定
ALERTMANAGER_VERSION="${ALERTMANAGER_VERSION:-0.26.0}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
ALERTMANAGER_STORAGE_SIZE="${ALERTMANAGER_STORAGE_SIZE:-5Gi}"
SMTP_SERVER="${SMTP_SERVER:-localhost:587}"
ALERT_EMAIL="${ALERT_EMAIL:-admin@example.com}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}Alertmanager & Alerting Setup${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting alerting setup"
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
    print_status "INFO" "Checking prerequisites for alerting setup..."
    
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

# Alertmanager設定作成
create_alertmanager_config() {
    print_status "INFO" "Creating Alertmanager configuration..."
    
    local config_manifest="$PROJECT_ROOT/k8s-manifests/alertmanager-config.yaml"
    
    cat > "$config_manifest" <<EOF
---
# Alertmanager Configuration Secret
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: alertmanager
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: config
type: Opaque
stringData:
  alertmanager.yml: |
    # Alertmanager Configuration for kubeadm-python-cluster
    global:
      smtp_smarthost: '$SMTP_SERVER'
      smtp_from: 'alertmanager@kubeadm-python-cluster'
      smtp_auth_username: ''
      smtp_auth_password: ''
      smtp_require_tls: false
      
    # Templates
    templates:
    - '/etc/alertmanager/templates/*.tmpl'
    
    # Route configuration
    route:
      group_by: ['alertname', 'cluster', 'service']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 1h
      receiver: 'web.hook'
      routes:
      - match:
          severity: critical
        receiver: critical-alerts
        group_wait: 10s
        repeat_interval: 10m
      - match:
          severity: warning
        receiver: warning-alerts
        group_wait: 30s
        repeat_interval: 30m
      - match:
          alertname: JupyterHubDown
        receiver: jupyterhub-alerts
        group_wait: 5s
        repeat_interval: 5m
      - match:
          alertname: KubernetesNodeReady
        receiver: node-alerts
        group_wait: 5s
        repeat_interval: 15m
    
    # Inhibition rules
    inhibit_rules:
    - source_match:
        severity: 'critical'
      target_match:
        severity: 'warning'
      equal: ['alertname', 'cluster', 'service']
    
    # Alert receivers
    receivers:
    - name: 'web.hook'
      webhook_configs:
      - url: 'http://localhost:5001/'
        send_resolved: true
    
    - name: 'critical-alerts'
      email_configs:
      - to: '$ALERT_EMAIL'
        from: 'alertmanager@kubeadm-python-cluster'
        subject: '[CRITICAL] {{ .GroupLabels.alertname }} - kubeadm-python-cluster'
        body: |
          {{ range .Alerts }}
          Alert: {{ .Annotations.summary }}
          Description: {{ .Annotations.description }}
          
          Labels:
          {{ range .Labels.SortedPairs }}  - {{ .Name }} = {{ .Value }}
          {{ end }}
          
          Started: {{ .StartsAt }}
          Ends: {{ .EndsAt }}
          {{ end }}
        html: |
          <!DOCTYPE html>
          <html>
          <head>
            <meta charset="UTF-8">
            <title>Critical Alert</title>
          </head>
          <body>
            <h2 style="color: red;">🚨 Critical Alert - kubeadm-python-cluster</h2>
            {{ range .Alerts }}
            <div style="border: 1px solid red; margin: 10px; padding: 15px; background-color: #fff5f5;">
              <h3>{{ .Annotations.summary }}</h3>
              <p><strong>Description:</strong> {{ .Annotations.description }}</p>
              <p><strong>Started:</strong> {{ .StartsAt }}</p>
              <p><strong>Status:</strong> {{ .Status }}</p>
              <h4>Labels:</h4>
              <ul>
              {{ range .Labels.SortedPairs }}
                <li>{{ .Name }}: {{ .Value }}</li>
              {{ end }}
              </ul>
            </div>
            {{ end }}
          </body>
          </html>
      webhook_configs:
      - url: 'http://alertmanager-webhook-service.monitoring.svc.cluster.local:9093/api/v1/alerts'
        send_resolved: true
    
    - name: 'warning-alerts'
      email_configs:
      - to: '$ALERT_EMAIL'
        from: 'alertmanager@kubeadm-python-cluster'
        subject: '[WARNING] {{ .GroupLabels.alertname }} - kubeadm-python-cluster'
        body: |
          {{ range .Alerts }}
          Alert: {{ .Annotations.summary }}
          Description: {{ .Annotations.description }}
          
          Labels:
          {{ range .Labels.SortedPairs }}  - {{ .Name }} = {{ .Value }}
          {{ end }}
          
          Started: {{ .StartsAt }}
          {{ end }}
    
    - name: 'jupyterhub-alerts'
      email_configs:
      - to: '$ALERT_EMAIL'
        from: 'alertmanager@kubeadm-python-cluster'
        subject: '[JupyterHub] Alert - {{ .GroupLabels.alertname }}'
        body: |
          JupyterHub Alert Detected!
          
          {{ range .Alerts }}
          Summary: {{ .Annotations.summary }}
          Description: {{ .Annotations.description }}
          
          Severity: {{ .Labels.severity }}
          Instance: {{ .Labels.instance }}
          Started: {{ .StartsAt }}
          {{ end }}
          
          Please check JupyterHub service immediately.
    
    - name: 'node-alerts'
      email_configs:
      - to: '$ALERT_EMAIL'
        from: 'alertmanager@kubeadm-python-cluster'
        subject: '[Node] Alert - {{ .GroupLabels.alertname }}'
        body: |
          Kubernetes Node Alert!
          
          {{ range .Alerts }}
          Summary: {{ .Annotations.summary }}
          Description: {{ .Annotations.description }}
          
          Node: {{ .Labels.node }}
          Started: {{ .StartsAt }}
          {{ end }}

  # Alert templates
  default.tmpl: |
    {{ define "cluster" }}{{ .ExternalURL | reReplaceAll ".*alertmanager\\.(.*)" "\$1" }}{{ end }}
    
    {{ define "slack.default.title" }}
    [{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .GroupLabels.SortedPairs.Values | join " " }} {{ if gt (len .GroupLabels) 0 }}({{ range .GroupLabels.SortedPairs }}{{ .Name }}={{ .Value }} {{ end }}){{ end }}
    {{ end }}
    
    {{ define "slack.default.text" }}
    {{ range .Alerts }}
    {{ .Annotations.summary }}
    {{ .Annotations.description }}
    {{ end }}
    {{ end }}
    
    {{ define "email.default.subject" }}
    [{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .GroupLabels.SortedPairs.Values | join " " }}
    {{ end }}
EOF

    # Slackウェブフック設定追加（設定されている場合）
    if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
        cat >> "$config_manifest" <<EOF

    - name: 'slack-alerts'
      slack_configs:
      - api_url: '$SLACK_WEBHOOK_URL'
        channel: '#alerts'
        username: 'Alertmanager'
        color: '{{ if eq .Status "firing" }}danger{{ else }}good{{ end }}'
        title: '[{{ .Status | toUpper }}] kubeadm-python-cluster Alert'
        text: |
          {{ range .Alerts }}
          *{{ .Annotations.summary }}*
          {{ .Annotations.description }}
          
          *Labels:*
          {{ range .Labels.SortedPairs }}• {{ .Name }}: {{ .Value }}
          {{ end }}
          {{ end }}
        send_resolved: true
EOF
    fi

    if kubectl apply -f "$config_manifest"; then
        print_status "SUCCESS" "Alertmanager configuration created"
    else
        print_status "ERROR" "Failed to create Alertmanager configuration"
        return 1
    fi
    
    print_status "SUCCESS" "Alertmanager configuration completed"
}

# Alertmanager永続ストレージ設定
setup_alertmanager_storage() {
    print_status "INFO" "Setting up Alertmanager storage..."
    
    local storage_manifest="$PROJECT_ROOT/k8s-manifests/alertmanager-storage.yaml"
    
    cat > "$storage_manifest" <<EOF
---
# Alertmanager Storage Class
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: alertmanager-storage
  labels:
    app.kubernetes.io/name: alertmanager
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain

---
# Alertmanager Persistent Volume
apiVersion: v1
kind: PersistentVolume
metadata:
  name: alertmanager-pv
  labels:
    app.kubernetes.io/name: alertmanager
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: storage
spec:
  capacity:
    storage: $ALERTMANAGER_STORAGE_SIZE
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: alertmanager-storage
  hostPath:
    path: /opt/alertmanager-data
    type: DirectoryOrCreate

---
# Alertmanager Persistent Volume Claim
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: alertmanager-pvc
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: alertmanager
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: storage
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: $ALERTMANAGER_STORAGE_SIZE
  storageClassName: alertmanager-storage
EOF

    if kubectl apply -f "$storage_manifest"; then
        print_status "SUCCESS" "Alertmanager storage configured"
    else
        print_status "ERROR" "Failed to setup Alertmanager storage"
        return 1
    fi
    
    print_status "SUCCESS" "Storage setup completed"
}

# Alertmanager Deployment作成
create_alertmanager_deployment() {
    print_status "INFO" "Creating Alertmanager deployment..."
    
    local deployment_manifest="$PROJECT_ROOT/k8s-manifests/alertmanager-deployment.yaml"
    
    cat > "$deployment_manifest" <<EOF
---
# Alertmanager ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: alertmanager
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: alertmanager
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: service-account

---
# Alertmanager Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alertmanager
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: alertmanager
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: alerting
    app.kubernetes.io/version: "$ALERTMANAGER_VERSION"
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: alertmanager
      app.kubernetes.io/component: alerting
  template:
    metadata:
      labels:
        app.kubernetes.io/name: alertmanager
        app.kubernetes.io/instance: kubeadm-python-cluster
        app.kubernetes.io/component: alerting
    spec:
      serviceAccountName: alertmanager
      securityContext:
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
        runAsNonRoot: true
      containers:
      - name: alertmanager
        image: prom/alertmanager:v$ALERTMANAGER_VERSION
        imagePullPolicy: IfNotPresent
        args:
          - --config.file=/etc/alertmanager/alertmanager.yml
          - --storage.path=/alertmanager
          - --data.retention=120h
          - --web.listen-address=:9093
          - --web.external-url=http://localhost:30903/
          - --cluster.listen-address=0.0.0.0:9094
          - --log.level=info
        ports:
        - name: web
          containerPort: 9093
          protocol: TCP
        - name: cluster
          containerPort: 9094
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
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        volumeMounts:
        - name: config
          mountPath: /etc/alertmanager
          readOnly: true
        - name: data
          mountPath: /alertmanager
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
        secret:
          secretName: alertmanager-config
          defaultMode: 0644
      - name: data
        persistentVolumeClaim:
          claimName: alertmanager-pvc
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
      - effect: NoSchedule
        operator: Exists

---
# Alertmanager Service
apiVersion: v1
kind: Service
metadata:
  name: alertmanager
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: alertmanager
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: alerting
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9093"
    prometheus.io/path: "/metrics"
spec:
  type: NodePort
  ports:
  - name: web
    port: 9093
    targetPort: web
    protocol: TCP
    nodePort: 30903
  - name: cluster
    port: 9094
    targetPort: cluster
    protocol: TCP
  selector:
    app.kubernetes.io/name: alertmanager
    app.kubernetes.io/component: alerting

---
# Alertmanager Internal Service
apiVersion: v1
kind: Service
metadata:
  name: alertmanager-internal
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: alertmanager
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: alerting-internal
spec:
  type: ClusterIP
  ports:
  - name: web
    port: 9093
    targetPort: web
    protocol: TCP
  selector:
    app.kubernetes.io/name: alertmanager
    app.kubernetes.io/component: alerting
EOF

    if kubectl apply -f "$deployment_manifest"; then
        print_status "SUCCESS" "Alertmanager deployment created"
    else
        print_status "ERROR" "Failed to create Alertmanager deployment"
        return 1
    fi
    
    print_status "SUCCESS" "Alertmanager deployment completed"
}

# 拡張アラートルール作成
create_enhanced_alert_rules() {
    print_status "INFO" "Creating enhanced alert rules..."
    
    local rules_manifest="$PROJECT_ROOT/k8s-manifests/prometheus-alert-rules.yaml"
    
    cat > "$rules_manifest" <<EOF
---
# Enhanced Prometheus Alert Rules
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-alert-rules
  namespace: $MONITORING_NAMESPACE
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: alert-rules
data:
  alert.rules.yml: |
    # Enhanced Alert Rules for kubeadm-python-cluster
    groups:
    
    # Kubernetes Cluster Alerts
    - name: kubernetes.cluster
      rules:
      - alert: KubernetesAPIServerDown
        expr: up{job="kubernetes-apiservers"} == 0
        for: 5m
        labels:
          severity: critical
          component: api-server
        annotations:
          summary: "Kubernetes API Server is down"
          description: "Kubernetes API Server has been down for more than 5 minutes"
      
      - alert: KubernetesNodeNotReady
        expr: kube_node_status_condition{condition="Ready",status="true"} == 0
        for: 5m
        labels:
          severity: critical
          component: node
        annotations:
          summary: "Kubernetes node {{ \$labels.node }} not ready"
          description: "Node {{ \$labels.node }} has been unready for more than 5 minutes"
      
      - alert: KubernetesPodCrashLooping
        expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
        for: 5m
        labels:
          severity: warning
          component: pod
        annotations:
          summary: "Pod {{ \$labels.pod }} is crash looping"
          description: "Pod {{ \$labels.pod }} in namespace {{ \$labels.namespace }} is crash looping"
      
      - alert: KubernetesPodNotReady
        expr: kube_pod_status_ready{condition="true"} == 0
        for: 10m
        labels:
          severity: warning
          component: pod
        annotations:
          summary: "Pod {{ \$labels.pod }} not ready"
          description: "Pod {{ \$labels.pod }} in namespace {{ \$labels.namespace }} has been not ready for more than 10 minutes"
      
      - alert: KubernetesMemoryPressure
        expr: kube_node_status_condition{condition="MemoryPressure",status="true"} == 1
        for: 2m
        labels:
          severity: critical
          component: node
        annotations:
          summary: "Node {{ \$labels.node }} under memory pressure"
          description: "Node {{ \$labels.node }} is under memory pressure"
      
      - alert: KubernetesDiskPressure
        expr: kube_node_status_condition{condition="DiskPressure",status="true"} == 1
        for: 2m
        labels:
          severity: critical
          component: node
        annotations:
          summary: "Node {{ \$labels.node }} under disk pressure"
          description: "Node {{ \$labels.node }} is under disk pressure"

    # JupyterHub Application Alerts  
    - name: jupyterhub.application
      rules:
      - alert: JupyterHubDown
        expr: up{job="jupyterhub"} == 0
        for: 2m
        labels:
          severity: critical
          component: jupyterhub
          application: jupyterhub
        annotations:
          summary: "JupyterHub is down"
          description: "JupyterHub service has been down for more than 2 minutes"
      
      - alert: JupyterHubHighCPU
        expr: rate(container_cpu_usage_seconds_total{container="jupyterhub"}[5m]) > 0.8
        for: 5m
        labels:
          severity: warning
          component: jupyterhub
          application: jupyterhub
        annotations:
          summary: "JupyterHub high CPU usage"
          description: "JupyterHub CPU usage is above 80% for more than 5 minutes"
      
      - alert: JupyterHubHighMemory
        expr: container_memory_working_set_bytes{container="jupyterhub"} / container_spec_memory_limit_bytes{container="jupyterhub"} > 0.8
        for: 5m
        labels:
          severity: warning
          component: jupyterhub
          application: jupyterhub
        annotations:
          summary: "JupyterHub high memory usage"
          description: "JupyterHub memory usage is above 80% for more than 5 minutes"
      
      - alert: JupyterHubTooManyRestarts
        expr: rate(kube_pod_container_status_restarts_total{container="jupyterhub"}[1h]) > 0
        for: 1m
        labels:
          severity: warning
          component: jupyterhub
          application: jupyterhub
        annotations:
          summary: "JupyterHub pod restarting"
          description: "JupyterHub pod has restarted {{ \$value }} times in the last hour"

    # Node System Alerts
    - name: node.system
      rules:
      - alert: NodeHighCPUUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
          component: node
        annotations:
          summary: "High CPU usage on {{ \$labels.instance }}"
          description: "CPU usage is above 80% for more than 5 minutes on {{ \$labels.instance }}"
      
      - alert: NodeHighMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
        for: 5m
        labels:
          severity: warning
          component: node
        annotations:
          summary: "High memory usage on {{ \$labels.instance }}"
          description: "Memory usage is above 85% for more than 5 minutes on {{ \$labels.instance }}"
      
      - alert: NodeDiskSpaceLow
        expr: (1 - (node_filesystem_free_bytes{fstype!="tmpfs"} / node_filesystem_size_bytes{fstype!="tmpfs"})) * 100 > 90
        for: 5m
        labels:
          severity: critical
          component: node
        annotations:
          summary: "Low disk space on {{ \$labels.instance }}"
          description: "Disk space is above 90% on {{ \$labels.instance }} ({{ \$labels.mountpoint }})"
      
      - alert: NodeDiskSpaceWillFillIn4Hours
        expr: predict_linear(node_filesystem_free_bytes{fstype!="tmpfs"}[1h], 4*3600) < 0
        for: 5m
        labels:
          severity: warning
          component: node
        annotations:
          summary: "Disk space will be full in 4 hours on {{ \$labels.instance }}"
          description: "Based on current usage, disk will be full in 4 hours on {{ \$labels.instance }} ({{ \$labels.mountpoint }})"
      
      - alert: NodeLoadHigh
        expr: node_load15 / on(instance) count by (instance)(node_cpu_seconds_total{mode="idle"}) > 0.8
        for: 5m
        labels:
          severity: warning
          component: node
        annotations:
          summary: "High load average on {{ \$labels.instance }}"
          description: "Load average is above 80% of CPU cores for more than 5 minutes on {{ \$labels.instance }}"

    # Container Registry Alerts
    - name: container.registry
      rules:
      - alert: ContainerRegistryDown
        expr: up{job="registry"} == 0
        for: 2m
        labels:
          severity: warning
          component: registry
        annotations:
          summary: "Container registry is down"
          description: "Container registry service has been down for more than 2 minutes"

    # Monitoring Infrastructure Alerts
    - name: monitoring.infrastructure
      rules:
      - alert: PrometheusTargetDown
        expr: up == 0
        for: 5m
        labels:
          severity: warning
          component: prometheus
        annotations:
          summary: "Prometheus target {{ \$labels.instance }} is down"
          description: "Prometheus target {{ \$labels.instance }} of job {{ \$labels.job }} has been down for more than 5 minutes"
      
      - alert: PrometheusConfigReloadFailed
        expr: prometheus_config_last_reload_successful != 1
        for: 5m
        labels:
          severity: warning
          component: prometheus
        annotations:
          summary: "Prometheus configuration reload failed"
          description: "Prometheus configuration reload has failed"
      
      - alert: AlertmanagerDown
        expr: up{job="alertmanager"} == 0
        for: 2m
        labels:
          severity: warning
          component: alertmanager
        annotations:
          summary: "Alertmanager is down"
          description: "Alertmanager service has been down for more than 2 minutes"
      
      - alert: GrafanaDown
        expr: up{job="grafana"} == 0
        for: 2m
        labels:
          severity: warning
          component: grafana
        annotations:
          summary: "Grafana is down"
          description: "Grafana service has been down for more than 2 minutes"

    # Storage Alerts
    - name: storage.alerts
      rules:
      - alert: PersistentVolumeUsageHigh
        expr: (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100 > 90
        for: 5m
        labels:
          severity: warning
          component: storage
        annotations:
          summary: "PersistentVolume {{ \$labels.persistentvolumeclaim }} usage high"
          description: "PersistentVolume {{ \$labels.persistentvolumeclaim }} in namespace {{ \$labels.namespace }} is {{ \$value }}% full"
      
      - alert: PersistentVolumeFullIn4Hours
        expr: predict_linear(kubelet_volume_stats_used_bytes[6h], 4*3600) > kubelet_volume_stats_capacity_bytes
        for: 5m
        labels:
          severity: warning
          component: storage
        annotations:
          summary: "PersistentVolume {{ \$labels.persistentvolumeclaim }} will be full in 4 hours"
          description: "PersistentVolume {{ \$labels.persistentvolumeclaim }} in namespace {{ \$labels.namespace }} will be full in 4 hours based on current usage"

    # Network Alerts
    - name: network.alerts
      rules:
      - alert: PodNetworkReceiveErrors
        expr: rate(container_network_receive_errors_total[5m]) > 0.01
        for: 5m
        labels:
          severity: warning
          component: network
        annotations:
          summary: "Pod {{ \$labels.pod }} has network receive errors"
          description: "Pod {{ \$labels.pod }} in namespace {{ \$labels.namespace }} has network receive errors"
      
      - alert: PodNetworkTransmitErrors
        expr: rate(container_network_transmit_errors_total[5m]) > 0.01
        for: 5m
        labels:
          severity: warning
          component: network
        annotations:
          summary: "Pod {{ \$labels.pod }} has network transmit errors"
          description: "Pod {{ \$labels.pod }} in namespace {{ \$labels.namespace }} has network transmit errors"

    # Security Alerts
    - name: security.alerts
      rules:
      - alert: PodSecurityViolation
        expr: increase(container_security_context_privileged[5m]) > 0
        for: 1m
        labels:
          severity: critical
          component: security
        annotations:
          summary: "Privileged container detected"
          description: "Privileged container detected in pod {{ \$labels.pod }} in namespace {{ \$labels.namespace }}"
EOF

    if kubectl apply -f "$rules_manifest"; then
        print_status "SUCCESS" "Enhanced alert rules created"
    else
        print_status "ERROR" "Failed to create alert rules"
        return 1
    fi
    
    print_status "SUCCESS" "Alert rules configuration completed"
}

# Prometheus設定にAlertmanager統合を追加
update_prometheus_config_for_alerting() {
    print_status "INFO" "Updating Prometheus configuration for alerting..."
    
    # Prometheusの設定をAlertmanager統合に更新
    kubectl patch configmap prometheus-config -n "$MONITORING_NAMESPACE" --type merge -p '{
      "data": {
        "prometheus.yml": "# Prometheus Configuration for kubeadm-python-cluster\nglobal:\n  scrape_interval: 15s\n  evaluation_interval: 15s\n  external_labels:\n    cluster: '\''kubeadm-python-cluster'\''\n    environment: '\''production'\''\n\n# Rule files\nrule_files:\n  - \"/etc/prometheus/rules/*.yml\"\n\n# Alerting configuration\nalerting:\n  alertmanagers:\n    - static_configs:\n        - targets:\n          - alertmanager.monitoring.svc.cluster.local:9093\n      path_prefix: /\n      scheme: http\n\n# Scrape configurations\nscrape_configs:\n\n# Prometheus itself\n- job_name: '\''prometheus'\''\n  static_configs:\n    - targets: ['\''localhost:9090'\'']\n  scrape_interval: 30s\n  metrics_path: '\''/metrics'\''\n\n# Alertmanager\n- job_name: '\''alertmanager'\''\n  static_configs:\n    - targets: ['\''alertmanager.monitoring.svc.cluster.local:9093'\'']\n  scrape_interval: 30s\n  metrics_path: '\''/metrics'\''\n\n# [Previous scrape configs from original prometheus.yml would be here]\n# This is a simplified version for alerting integration"
      }
    }'
    
    if [[ $? -eq 0 ]]; then
        print_status "SUCCESS" "Prometheus configuration updated for alerting"
    else
        print_status "ERROR" "Failed to update Prometheus configuration"
        return 1
    fi
    
    # Prometheusをリロード
    kubectl rollout restart deployment/prometheus -n "$MONITORING_NAMESPACE"
    
    print_status "SUCCESS" "Prometheus configuration update completed"
}

# アラートデプロイメント確認
verify_alerting_deployment() {
    print_status "INFO" "Verifying alerting deployment..."
    
    local timeout=300
    local interval=10
    local elapsed=0
    
    # Alertmanager確認
    while [[ $elapsed -lt $timeout ]]; do
        if kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=alertmanager | grep -q "Running"; then
            print_status "SUCCESS" "Alertmanager is running"
            break
        fi
        
        print_status "INFO" "Waiting for Alertmanager... ($elapsed/${timeout}s)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    if [[ $elapsed -ge $timeout ]]; then
        print_status "ERROR" "Alertmanager deployment timeout"
        return 1
    fi
    
    # Prometheusからのアラート確認
    print_status "INFO" "Checking Prometheus alerting integration..."
    
    if kubectl exec -n "$MONITORING_NAMESPACE" deployment/prometheus -- wget -qO- http://localhost:9090/api/v1/alertmanagers 2>/dev/null | grep -q "alertmanager"; then
        print_status "SUCCESS" "Prometheus-Alertmanager integration verified"
    else
        print_status "WARNING" "Prometheus-Alertmanager integration not fully ready yet"
    fi
    
    print_status "SUCCESS" "Alerting deployment verification completed"
}

# アクセス情報表示
show_access_information() {
    print_status "INFO" "Alerting system access information:"
    
    local node_ip
    if node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); then
        echo ""
        echo "=== Alerting System Access URLs ==="
        echo "Alertmanager UI: http://$node_ip:30903"
        echo "Prometheus UI: http://$node_ip:30900 (Alerts tab)"
        echo ""
        echo "=== Internal Service URLs ==="
        echo "Alertmanager: http://alertmanager.$MONITORING_NAMESPACE.svc.cluster.local:9093"
        echo ""
        echo "=== Alerting Status ==="
        kubectl get all -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=alertmanager
        echo ""
        echo "=== Alert Rules Status ==="
        kubectl get configmap prometheus-alert-rules -n "$MONITORING_NAMESPACE"
        echo ""
        echo "=== Email Configuration ==="
        echo "Alert Email: $ALERT_EMAIL"
        echo "SMTP Server: $SMTP_SERVER"
        
        if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
            echo "Slack Integration: Enabled"
        else
            echo "Slack Integration: Not configured"
        fi
    else
        print_status "WARNING" "Unable to determine node IP address"
    fi
}

# アラート管理スクリプト作成
create_alerting_management_script() {
    print_status "INFO" "Creating alerting management script..."
    
    local management_script="$SCRIPT_DIR/manage-alerting.sh"
    
    cat > "$management_script" <<'EOF'
#!/bin/bash
# scripts/manage-alerting.sh
# Alerting管理スクリプト

set -euo pipefail

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

print_usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  status         Show alerting system status"
    echo "  logs           Show Alertmanager logs"
    echo "  alerts         List active alerts"
    echo "  rules          List alert rules"
    echo "  test           Send test alert"
    echo "  silence        Create alert silence"
    echo "  reload         Reload Alertmanager configuration"
    echo ""
    echo "Options:"
    echo "  --namespace NS     Monitoring namespace (default: monitoring)"
    echo "  --alertname NAME   Alert name (for test/silence)"
    echo "  --duration TIME    Silence duration (default: 1h)"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 alerts"
    echo "  $0 test --alertname TestAlert"
    echo "  $0 silence --alertname JupyterHubDown --duration 2h"
}

show_status() {
    echo "=== Alertmanager Status ==="
    kubectl get deployment alertmanager -n "$MONITORING_NAMESPACE" -o wide
    echo ""
    echo "=== Alertmanager Pods ==="
    kubectl get pods -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=alertmanager
    echo ""
    echo "=== Alert Rules ConfigMap ==="
    kubectl get configmap prometheus-alert-rules -n "$MONITORING_NAMESPACE"
}

show_logs() {
    kubectl logs -n "$MONITORING_NAMESPACE" -l app.kubernetes.io/name=alertmanager -f
}

list_active_alerts() {
    echo "=== Active Alerts (from Prometheus) ==="
    kubectl exec -n "$MONITORING_NAMESPACE" deployment/prometheus -- \
        wget -qO- "http://localhost:9090/api/v1/alerts" 2>/dev/null | \
        python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    alerts = data.get('data', {}).get('alerts', [])
    if alerts:
        for alert in alerts:
            state = alert.get('state', 'unknown')
            name = alert.get('labels', {}).get('alertname', 'unknown')
            summary = alert.get('annotations', {}).get('summary', 'No summary')
            print(f'[{state.upper()}] {name}: {summary}')
    else:
        print('No active alerts')
except Exception as e:
    print(f'Error parsing alerts: {e}')
    " || echo "Failed to retrieve alerts"
}

list_alert_rules() {
    echo "=== Alert Rules ==="
    kubectl get configmap prometheus-alert-rules -n "$MONITORING_NAMESPACE" -o yaml | grep -A 2 "alert:"
}

send_test_alert() {
    local alertname="${1:-TestAlert}"
    
    echo "Sending test alert: $alertname"
    kubectl exec -n "$MONITORING_NAMESPACE" deployment/prometheus -- \
        wget --post-data='[{
            "labels": {
                "alertname": "'$alertname'",
                "severity": "warning",
                "instance": "test-instance",
                "job": "test-job"
            },
            "annotations": {
                "summary": "Test alert for '$alertname'",
                "description": "This is a test alert sent manually"
            },
            "generatorURL": "http://prometheus:9090/test"
        }]' \
        --header='Content-Type: application/json' \
        -qO- "http://alertmanager:9093/api/v1/alerts" || echo "Failed to send test alert"
}

create_silence() {
    local alertname="${1:-TestAlert}"
    local duration="${2:-1h}"
    
    echo "Creating silence for alert: $alertname (duration: $duration)"
    
    local end_time=$(date -d "+$duration" -u +"%Y-%m-%dT%H:%M:%S.000Z")
    
    kubectl exec -n "$MONITORING_NAMESPACE" deployment/alertmanager -- \
        wget --post-data='{
            "matchers": [
                {
                    "name": "alertname",
                    "value": "'$alertname'",
                    "isRegex": false
                }
            ],
            "startsAt": "'$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")'",
            "endsAt": "'$end_time'",
            "createdBy": "manage-alerting.sh",
            "comment": "Silenced via management script"
        }' \
        --header='Content-Type: application/json' \
        -qO- "http://localhost:9093/api/v1/silences" || echo "Failed to create silence"
}

reload_config() {
    echo "Reloading Alertmanager configuration..."
    kubectl rollout restart deployment/alertmanager -n "$MONITORING_NAMESPACE"
    kubectl rollout status deployment/alertmanager -n "$MONITORING_NAMESPACE" --timeout=300s
    echo "Alertmanager configuration reloaded"
}

case "${1:-}" in
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    alerts)
        list_active_alerts
        ;;
    rules)
        list_alert_rules
        ;;
    test)
        send_test_alert "${2:-TestAlert}"
        ;;
    silence)
        create_silence "${2:-TestAlert}" "${3:-1h}"
        ;;
    reload)
        reload_config
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
    print_status "SUCCESS" "Alerting management script created: $management_script"
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # アラートセットアッププロセス
    check_prerequisites
    create_alertmanager_config
    setup_alertmanager_storage
    create_alertmanager_deployment
    create_enhanced_alert_rules
    update_prometheus_config_for_alerting
    verify_alerting_deployment
    create_alerting_management_script
    show_access_information
    
    echo -e "\n${BLUE}=== Alerting Setup Summary ===${NC}"
    print_status "SUCCESS" "Alerting system setup completed successfully!"
    
    echo ""
    echo "🚨 Alerting Components Deployed:"
    echo "  • Alertmanager (NodePort 30903) - Alert routing and notification"
    echo "  • Enhanced Alert Rules - 25+ comprehensive alerts"
    echo "  • Email Notifications - Configured for $ALERT_EMAIL"
    echo "  • Alert Grouping & Routing - Severity-based routing"
    
    echo ""
    echo "📋 Alert Categories:"
    echo "  • Kubernetes Cluster (API server, nodes, pods)"
    echo "  • JupyterHub Application (service health, resources)"
    echo "  • Node System (CPU, memory, disk, load)"
    echo "  • Monitoring Infrastructure (Prometheus, Grafana)"
    echo "  • Storage & Network (PVs, network errors)"
    echo "  • Security (privileged containers)"
    
    echo ""
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "N/A")
    echo "🌐 Access Information:"
    echo "  Alertmanager UI: http://$node_ip:30903"
    echo "  Prometheus Alerts: http://$node_ip:30900/alerts"
    
    echo ""
    echo "⚙️  Configuration:"
    echo "  Email: $ALERT_EMAIL"
    echo "  SMTP: $SMTP_SERVER"
    if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
        echo "  Slack: Enabled"
    else
        echo "  Slack: Not configured"
    fi
    
    echo ""
    echo "Next steps:"
    echo "1. Test alerting: $SCRIPT_DIR/manage-alerting.sh test"
    echo "2. Check active alerts: $SCRIPT_DIR/manage-alerting.sh alerts"
    echo "3. Configure SMTP settings if needed"
    echo "4. Add Slack webhook URL for Slack notifications"
    
    echo ""
    echo "Management commands:"
    echo "- Check status: $SCRIPT_DIR/manage-alerting.sh status"
    echo "- View alerts: $SCRIPT_DIR/manage-alerting.sh alerts"
    echo "- Send test alert: $SCRIPT_DIR/manage-alerting.sh test --alertname TestAlert"
    echo "- Create silence: $SCRIPT_DIR/manage-alerting.sh silence --alertname AlertName --duration 2h"
    
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
        echo "  --email EMAIL           Alert notification email (default: admin@example.com)"
        echo "  --smtp-server SERVER    SMTP server (default: localhost:587)"
        echo "  --slack-webhook URL     Slack webhook URL for notifications"
        echo "  --storage-size SIZE     Alertmanager storage (default: 5Gi)"
        echo "  --alertmanager-version V Alertmanager version (default: $ALERTMANAGER_VERSION)"
        echo "  --verify-only           Only verify existing deployment"
        echo "  --status                Show alerting status"
        echo ""
        echo "Examples:"
        echo "  $0                      Setup complete alerting system"
        echo "  $0 --email ops@company.com Setup with custom email"
        echo "  $0 --slack-webhook https://hooks.slack.com/... Add Slack integration"
        echo "  $0 --status             Show current alerting status"
        exit 0
        ;;
    --namespace)
        MONITORING_NAMESPACE="${2:-$MONITORING_NAMESPACE}"
        shift 2
        ;;
    --email)
        ALERT_EMAIL="${2:-$ALERT_EMAIL}"
        shift 2
        ;;
    --smtp-server)
        SMTP_SERVER="${2:-$SMTP_SERVER}"
        shift 2
        ;;
    --slack-webhook)
        SLACK_WEBHOOK_URL="${2:-$SLACK_WEBHOOK_URL}"
        shift 2
        ;;
    --storage-size)
        ALERTMANAGER_STORAGE_SIZE="${2:-$ALERTMANAGER_STORAGE_SIZE}"
        shift 2
        ;;
    --alertmanager-version)
        ALERTMANAGER_VERSION="${2:-$ALERTMANAGER_VERSION}"
        shift 2
        ;;
    --verify-only)
        check_prerequisites
        verify_alerting_deployment
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