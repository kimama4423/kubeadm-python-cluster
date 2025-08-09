#!/bin/bash
# scripts/setup-logging.sh
# EFK (Elasticsearch + Fluentd + Kibana) ログ集約スタックセットアップ

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
LOG_FILE="$SCRIPT_DIR/logging-setup.log"
EXIT_CODE=0

# EFK設定
ELASTICSEARCH_VERSION="${ELASTICSEARCH_VERSION:-8.11.3}"
KIBANA_VERSION="${KIBANA_VERSION:-8.11.3}"
FLUENTD_VERSION="${FLUENTD_VERSION:-1.16.5}"
LOGGING_NAMESPACE="${LOGGING_NAMESPACE:-logging}"
ELASTICSEARCH_STORAGE_SIZE="${ELASTICSEARCH_STORAGE_SIZE:-30Gi}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}EFK Logging Stack Setup${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting EFK logging stack setup"
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
    print_status "INFO" "Checking prerequisites for EFK logging setup..."
    
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
    
    # システムリソース確認
    local total_memory=$(kubectl top nodes 2>/dev/null | awk 'NR>1 {sum+=$4} END {print sum}' | sed 's/Mi//g' || echo "0")
    if [[ ${total_memory:-0} -lt 4096 ]]; then
        print_status "WARNING" "Low memory available. Elasticsearch may require more resources"
    fi
    
    print_status "SUCCESS" "Prerequisites check completed"
}

# ログ集約用名前空間作成
create_logging_namespace() {
    print_status "INFO" "Creating logging namespace..."
    
    local namespace_manifest="$PROJECT_ROOT/k8s-manifests/logging-namespace.yaml"
    
    cat > "$namespace_manifest" <<EOF
---
# Logging Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: $LOGGING_NAMESPACE
  labels:
    name: $LOGGING_NAMESPACE
    app.kubernetes.io/name: logging
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: namespace
spec: {}

---
# Logging ConfigMap for global configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: logging-config
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: logging
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: config
data:
  cluster-name: "kubeadm-python-cluster"
  log-retention-days: "$LOG_RETENTION_DAYS"
  elasticsearch-replicas: "1"
  log-level: "info"
EOF

    if kubectl apply -f "$namespace_manifest"; then
        print_status "SUCCESS" "Logging namespace created"
    else
        print_status "ERROR" "Failed to create logging namespace"
        return 1
    fi
    
    # 名前空間ラベル追加
    kubectl label namespace "$LOGGING_NAMESPACE" logging=enabled --overwrite
    
    print_status "SUCCESS" "Logging namespace configured"
}

# Elasticsearch セットアップ
setup_elasticsearch() {
    print_status "INFO" "Setting up Elasticsearch..."
    
    local elasticsearch_manifest="$PROJECT_ROOT/k8s-manifests/elasticsearch.yaml"
    
    cat > "$elasticsearch_manifest" <<EOF
---
# Elasticsearch Storage Class
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: elasticsearch-storage
  labels:
    app.kubernetes.io/name: elasticsearch
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain

---
# Elasticsearch Persistent Volume
apiVersion: v1
kind: PersistentVolume
metadata:
  name: elasticsearch-pv
  labels:
    app.kubernetes.io/name: elasticsearch
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: storage
spec:
  capacity:
    storage: $ELASTICSEARCH_STORAGE_SIZE
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: elasticsearch-storage
  hostPath:
    path: /opt/elasticsearch-data
    type: DirectoryOrCreate

---
# Elasticsearch Persistent Volume Claim
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: elasticsearch-pvc
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: elasticsearch
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: storage
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: $ELASTICSEARCH_STORAGE_SIZE
  storageClassName: elasticsearch-storage

---
# Elasticsearch ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: elasticsearch
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: elasticsearch
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: service-account

---
# Elasticsearch ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: elasticsearch-config
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: elasticsearch
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: config
data:
  elasticsearch.yml: |
    cluster.name: kubeadm-python-cluster
    node.name: elasticsearch-node
    path.data: /usr/share/elasticsearch/data
    path.logs: /usr/share/elasticsearch/logs
    network.host: 0.0.0.0
    http.port: 9200
    transport.port: 9300
    
    # Security settings (disabled for simplicity)
    xpack.security.enabled: false
    xpack.security.transport.ssl.enabled: false
    xpack.security.http.ssl.enabled: false
    
    # Single node cluster
    discovery.type: single-node
    
    # Memory settings
    bootstrap.memory_lock: false
    
    # Index settings
    action.auto_create_index: true
    action.destructive_requires_name: true
    
    # Log retention
    indices.lifecycle.poll_interval: 10m
    
  jvm.options: |
    # JVM heap size
    -Xms1g
    -Xmx1g
    
    # GC settings
    -XX:+UseG1GC
    -XX:G1HeapRegionSize=16m
    -XX:+UnlockExperimentalVMOptions
    -XX:+UseCGroupMemoryLimitForHeap
    
    # Error handling
    -XX:+ExitOnOutOfMemoryError
    
    # Logging
    -Djava.util.logging.manager=org.apache.logging.log4j.jul.LogManager
    
  log4j2.properties: |
    status = error
    appender.console.type = Console
    appender.console.name = console
    appender.console.layout.type = PatternLayout
    appender.console.layout.pattern = [%d{ISO8601}][%-5p][%-25c{1.}] [%node_name]%marker %m%n
    rootLogger.level = info
    rootLogger.appenderRef.console.ref = console

---
# Elasticsearch StatefulSet
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: elasticsearch
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: elasticsearch
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: search
    app.kubernetes.io/version: "$ELASTICSEARCH_VERSION"
spec:
  serviceName: elasticsearch
  replicas: 1
  updateStrategy:
    type: RollingUpdate
  selector:
    matchLabels:
      app.kubernetes.io/name: elasticsearch
      app.kubernetes.io/component: search
  template:
    metadata:
      labels:
        app.kubernetes.io/name: elasticsearch
        app.kubernetes.io/instance: kubeadm-python-cluster
        app.kubernetes.io/component: search
    spec:
      serviceAccountName: elasticsearch
      securityContext:
        fsGroup: 1000
        runAsUser: 1000
        runAsGroup: 1000
        runAsNonRoot: true
      initContainers:
      - name: increase-vm-max-map
        image: busybox:1.36.1
        imagePullPolicy: IfNotPresent
        command: ['sysctl', '-w', 'vm.max_map_count=262144']
        securityContext:
          privileged: true
      - name: increase-fd-ulimit
        image: busybox:1.36.1
        imagePullPolicy: IfNotPresent
        command: ['sh', '-c', 'ulimit -n 65536']
        securityContext:
          privileged: true
      - name: fix-permissions
        image: busybox:1.36.1
        imagePullPolicy: IfNotPresent
        command: ['sh', '-c', 'chown -R 1000:1000 /usr/share/elasticsearch/data']
        securityContext:
          privileged: true
        volumeMounts:
        - name: data
          mountPath: /usr/share/elasticsearch/data
      containers:
      - name: elasticsearch
        image: docker.elastic.co/elasticsearch/elasticsearch:$ELASTICSEARCH_VERSION
        imagePullPolicy: IfNotPresent
        ports:
        - name: http
          containerPort: 9200
          protocol: TCP
        - name: transport
          containerPort: 9300
          protocol: TCP
        env:
        - name: ES_JAVA_OPTS
          value: "-Xms1g -Xmx1g"
        - name: discovery.type
          value: single-node
        resources:
          requests:
            memory: "2Gi"
            cpu: "1000m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
        volumeMounts:
        - name: config
          mountPath: /usr/share/elasticsearch/config/elasticsearch.yml
          subPath: elasticsearch.yml
          readOnly: true
        - name: config
          mountPath: /usr/share/elasticsearch/config/jvm.options
          subPath: jvm.options
          readOnly: true
        - name: config
          mountPath: /usr/share/elasticsearch/config/log4j2.properties
          subPath: log4j2.properties
          readOnly: true
        - name: data
          mountPath: /usr/share/elasticsearch/data
        readinessProbe:
          httpGet:
            path: /_cluster/health
            port: http
          initialDelaySeconds: 90
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /_cluster/health
            port: http
          initialDelaySeconds: 120
          periodSeconds: 20
          timeoutSeconds: 10
          failureThreshold: 3
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          runAsNonRoot: true
          runAsUser: 1000
          runAsGroup: 1000
          capabilities:
            drop:
            - ALL
      volumes:
      - name: config
        configMap:
          name: elasticsearch-config
          defaultMode: 0644
      - name: data
        persistentVolumeClaim:
          claimName: elasticsearch-pvc
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
      - effect: NoSchedule
        operator: Exists

---
# Elasticsearch Service
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: elasticsearch
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: search
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9200"
    prometheus.io/path: "/_prometheus/metrics"
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 9200
    targetPort: http
    protocol: TCP
  - name: transport
    port: 9300
    targetPort: transport
    protocol: TCP
  selector:
    app.kubernetes.io/name: elasticsearch
    app.kubernetes.io/component: search

---
# Elasticsearch NodePort Service (for external access)
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch-nodeport
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: elasticsearch
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: search-external
spec:
  type: NodePort
  ports:
  - name: http
    port: 9200
    targetPort: http
    protocol: TCP
    nodePort: 30920
  selector:
    app.kubernetes.io/name: elasticsearch
    app.kubernetes.io/component: search
EOF

    if kubectl apply -f "$elasticsearch_manifest"; then
        print_status "SUCCESS" "Elasticsearch setup completed"
    else
        print_status "ERROR" "Failed to setup Elasticsearch"
        return 1
    fi
    
    print_status "SUCCESS" "Elasticsearch configuration applied"
}

# Kibana セットアップ
setup_kibana() {
    print_status "INFO" "Setting up Kibana..."
    
    local kibana_manifest="$PROJECT_ROOT/k8s-manifests/kibana.yaml"
    
    cat > "$kibana_manifest" <<EOF
---
# Kibana ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kibana
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: kibana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: service-account

---
# Kibana ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: kibana-config
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: kibana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: config
data:
  kibana.yml: |
    server.name: kibana
    server.host: 0.0.0.0
    server.port: 5601
    server.basePath: ""
    server.rewriteBasePath: false
    
    # Elasticsearch configuration
    elasticsearch.hosts: ["http://elasticsearch.$LOGGING_NAMESPACE.svc.cluster.local:9200"]
    elasticsearch.pingTimeout: 1500
    elasticsearch.requestTimeout: 30000
    elasticsearch.requestHeadersWhitelist: ["authorization"]
    
    # Security (disabled)
    xpack.security.enabled: false
    xpack.encryptedSavedObjects.encryptionKey: "kubeadm-python-cluster-kibana-key-32-chars"
    
    # Monitoring
    monitoring.enabled: false
    
    # Logging
    logging.appenders.file.type: file
    logging.appenders.file.fileName: /var/log/kibana.log
    logging.appenders.file.layout.type: json
    logging.root.appenders: [default, file]
    logging.root.level: info
    
    # Index patterns
    kibana.index: ".kibana"
    kibana.defaultAppId: "discover"
    
    # Advanced settings
    newsfeed.enabled: false
    telemetry.enabled: false
    telemetry.optIn: false

---
# Kibana Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kibana
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: kibana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: visualization
    app.kubernetes.io/version: "$KIBANA_VERSION"
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: kibana
      app.kubernetes.io/component: visualization
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kibana
        app.kubernetes.io/instance: kubeadm-python-cluster
        app.kubernetes.io/component: visualization
    spec:
      serviceAccountName: kibana
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        runAsNonRoot: true
      containers:
      - name: kibana
        image: docker.elastic.co/kibana/kibana:$KIBANA_VERSION
        imagePullPolicy: IfNotPresent
        ports:
        - name: http
          containerPort: 5601
          protocol: TCP
        env:
        - name: ELASTICSEARCH_HOSTS
          value: "http://elasticsearch.$LOGGING_NAMESPACE.svc.cluster.local:9200"
        - name: SERVER_NAME
          value: "kibana"
        - name: SERVER_HOST
          value: "0.0.0.0"
        - name: XPACK_SECURITY_ENABLED
          value: "false"
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
        volumeMounts:
        - name: config
          mountPath: /usr/share/kibana/config/kibana.yml
          subPath: kibana.yml
          readOnly: true
        - name: logs
          mountPath: /var/log
        readinessProbe:
          httpGet:
            path: /api/status
            port: http
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /api/status
            port: http
          initialDelaySeconds: 90
          periodSeconds: 20
          timeoutSeconds: 10
          failureThreshold: 3
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          runAsNonRoot: true
          runAsUser: 1000
          runAsGroup: 1000
          capabilities:
            drop:
            - ALL
      volumes:
      - name: config
        configMap:
          name: kibana-config
          defaultMode: 0644
      - name: logs
        emptyDir: {}
      nodeSelector:
        kubernetes.io/os: linux

---
# Kibana Service
apiVersion: v1
kind: Service
metadata:
  name: kibana
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: kibana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: visualization
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "5601"
    prometheus.io/path: "/api/stats"
spec:
  type: NodePort
  ports:
  - name: http
    port: 5601
    targetPort: http
    protocol: TCP
    nodePort: 30561
  selector:
    app.kubernetes.io/name: kibana
    app.kubernetes.io/component: visualization

---
# Kibana Internal Service
apiVersion: v1
kind: Service
metadata:
  name: kibana-internal
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: kibana
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: visualization-internal
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 5601
    targetPort: http
    protocol: TCP
  selector:
    app.kubernetes.io/name: kibana
    app.kubernetes.io/component: visualization
EOF

    if kubectl apply -f "$kibana_manifest"; then
        print_status "SUCCESS" "Kibana setup completed"
    else
        print_status "ERROR" "Failed to setup Kibana"
        return 1
    fi
    
    print_status "SUCCESS" "Kibana configuration applied"
}

# Fluentd セットアップ
setup_fluentd() {
    print_status "INFO" "Setting up Fluentd..."
    
    local fluentd_manifest="$PROJECT_ROOT/k8s-manifests/fluentd.yaml"
    
    cat > "$fluentd_manifest" <<EOF
---
# Fluentd ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluentd
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: fluentd
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: service-account

---
# Fluentd ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluentd
  labels:
    app.kubernetes.io/name: fluentd
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: log-collector
rules:
- apiGroups: [""]
  resources:
  - pods
  - namespaces
  verbs: ["get", "list", "watch"]

---
# Fluentd ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluentd
  labels:
    app.kubernetes.io/name: fluentd
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: log-collector
roleRef:
  kind: ClusterRole
  name: fluentd
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: fluentd
  namespace: $LOGGING_NAMESPACE

---
# Fluentd ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluentd-config
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: fluentd
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: config
data:
  fluent.conf: |
    # Fluentd Configuration for kubeadm-python-cluster
    
    # Input configuration for container logs
    <source>
      @type tail
      @id in_tail_container_logs
      path /var/log/containers/*.log
      pos_file /var/log/fluentd-containers.log.pos
      tag kubernetes.*
      read_from_head true
      <parse>
        @type multi_format
        <pattern>
          format json
          time_key timestamp
          time_format %Y-%m-%dT%H:%M:%S.%N%z
        </pattern>
        <pattern>
          format /^(?<timestamp>[^ ]* [^ ,]*) (?<stream>stdout|stderr) [^ ]* (?<message>.*)$/
          time_format %Y-%m-%dT%H:%M:%S.%N%z
        </pattern>
      </parse>
    </source>

    # Input configuration for kubelet logs
    <source>
      @type tail
      @id in_tail_kubelet
      path /var/log/kubelet.log
      pos_file /var/log/fluentd-kubelet.log.pos
      tag kubelet
      <parse>
        @type kubernetes
      </parse>
    </source>

    # Input configuration for Docker daemon logs
    <source>
      @type tail
      @id in_tail_docker
      path /var/log/docker.log
      pos_file /var/log/fluentd-docker.log.pos
      tag docker
      <parse>
        @type json
        time_key timestamp
        time_format %Y-%m-%dT%H:%M:%S.%N%z
      </parse>
    </source>

    # Add Kubernetes metadata
    <filter kubernetes.**>
      @type kubernetes_metadata
      @id filter_kube_metadata
      kubernetes_url "#{ENV['FLUENT_FILTER_KUBERNETES_URL'] || 'https://' + ENV.fetch('KUBERNETES_SERVICE_HOST') + ':' + ENV.fetch('KUBERNETES_SERVICE_PORT') + '/api'}"
      verify_ssl "#{ENV['KUBERNETES_VERIFY_SSL'] || true}"
      ca_file "#{ENV['KUBERNETES_CA_FILE']}"
      skip_labels false
      skip_container_metadata false
      skip_master_url false
      skip_namespace_metadata false
    </filter>

    # JupyterHub specific log processing
    <filter kubernetes.var.log.containers.jupyterhub**>
      @type record_transformer
      @id filter_jupyterhub
      <record>
        application jupyterhub
        component hub
        cluster kubeadm-python-cluster
      </record>
    </filter>

    # Single-user server log processing
    <filter kubernetes.var.log.containers.jupyter**>
      @type record_transformer
      @id filter_jupyter_users
      <record>
        application jupyterhub
        component singleuser
        cluster kubeadm-python-cluster
      </record>
    </filter>

    # System log processing
    <filter kubelet docker>
      @type record_transformer
      @id filter_system
      <record>
        application system
        component \${tag}
        cluster kubeadm-python-cluster
      </record>
    </filter>

    # Output to Elasticsearch
    <match **>
      @type elasticsearch
      @id out_es
      @log_level info
      include_tag_key true
      host elasticsearch.$LOGGING_NAMESPACE.svc.cluster.local
      port 9200
      logstash_format true
      logstash_prefix logstash
      logstash_dateformat %Y.%m.%d
      include_timestamp true
      type_name _doc
      suppress_type_name true
      
      # Buffer configuration
      <buffer>
        @type file
        path /var/log/fluentd-buffers/kubernetes.system.buffer
        flush_mode interval
        retry_type exponential_backoff
        flush_thread_count 2
        flush_interval 5s
        retry_forever
        retry_max_interval 30
        chunk_limit_size 2M
        queue_limit_length 8
        overflow_action block
      </buffer>
    </match>

  prometheus.conf: |
    # Prometheus monitoring for Fluentd
    <source>
      @type prometheus
      bind 0.0.0.0
      port 24231
      metrics_path /metrics
    </source>
    
    <source>
      @type prometheus_output_monitor
      interval 10
      <labels>
        hostname \${hostname}
      </labels>
    </source>

---
# Fluentd DaemonSet
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluentd
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: fluentd
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: log-collector
    app.kubernetes.io/version: "$FLUENTD_VERSION"
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: fluentd
      app.kubernetes.io/component: log-collector
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fluentd
        app.kubernetes.io/instance: kubeadm-python-cluster
        app.kubernetes.io/component: log-collector
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "24231"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: fluentd
      tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: fluentd
        image: fluent/fluentd-kubernetes-daemonset:v$FLUENTD_VERSION-debian-elasticsearch7-1.0
        imagePullPolicy: IfNotPresent
        env:
        - name: FLUENT_CONTAINER_TAIL_EXCLUDE_PATH
          value: /var/log/containers/fluent*
        - name: FLUENT_CONTAINER_TAIL_PARSER_TYPE
          value: /^(?<time>.+) (?<stream>stdout|stderr)( (?<logtag>.))? (?<log>.*)$/
        - name: FLUENT_ELASTICSEARCH_HOST
          value: "elasticsearch.$LOGGING_NAMESPACE.svc.cluster.local"
        - name: FLUENT_ELASTICSEARCH_PORT
          value: "9200"
        - name: FLUENT_ELASTICSEARCH_SCHEME
          value: "http"
        - name: FLUENT_UID
          value: "0"
        resources:
          limits:
            memory: 512Mi
            cpu: 200m
          requests:
            cpu: 100m
            memory: 256Mi
        ports:
        - name: prometheus
          containerPort: 24231
          protocol: TCP
        volumeMounts:
        - name: config
          mountPath: /fluentd/etc/fluent.conf
          subPath: fluent.conf
          readOnly: true
        - name: config
          mountPath: /fluentd/etc/prometheus.conf
          subPath: prometheus.conf
          readOnly: true
        - name: varlog
          mountPath: /var/log
        - name: varlibdockercontainers
          mountPath: /var/lib/docker/containers
          readOnly: true
        - name: buffer
          mountPath: /var/log/fluentd-buffers
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          runAsUser: 0
          capabilities:
            drop:
            - ALL
            add:
            - DAC_OVERRIDE
            - SETGID
            - SETUID
      terminationGracePeriodSeconds: 30
      volumes:
      - name: config
        configMap:
          name: fluentd-config
          defaultMode: 0644
      - name: varlog
        hostPath:
          path: /var/log
      - name: varlibdockercontainers
        hostPath:
          path: /var/lib/docker/containers
      - name: buffer
        emptyDir: {}
      nodeSelector:
        kubernetes.io/os: linux

---
# Fluentd Service (for Prometheus scraping)
apiVersion: v1
kind: Service
metadata:
  name: fluentd
  namespace: $LOGGING_NAMESPACE
  labels:
    app.kubernetes.io/name: fluentd
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: log-collector
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "24231"
    prometheus.io/path: "/metrics"
spec:
  type: ClusterIP
  clusterIP: None
  ports:
  - name: prometheus
    port: 24231
    targetPort: prometheus
    protocol: TCP
  selector:
    app.kubernetes.io/name: fluentd
    app.kubernetes.io/component: log-collector
EOF

    if kubectl apply -f "$fluentd_manifest"; then
        print_status "SUCCESS" "Fluentd setup completed"
    else
        print_status "ERROR" "Failed to setup Fluentd"
        return 1
    fi
    
    print_status "SUCCESS" "Fluentd configuration applied"
}

# Index Lifecycle Management設定
setup_elasticsearch_ilm() {
    print_status "INFO" "Setting up Elasticsearch Index Lifecycle Management..."
    
    local ilm_script="$SCRIPT_DIR/setup-elasticsearch-ilm.sh"
    
    cat > "$ilm_script" <<EOF
#!/bin/bash
# scripts/setup-elasticsearch-ilm.sh
# Elasticsearch Index Lifecycle Management設定

set -euo pipefail

LOGGING_NAMESPACE="$LOGGING_NAMESPACE"
RETENTION_DAYS="$LOG_RETENTION_DAYS"

wait_for_elasticsearch() {
    echo "Waiting for Elasticsearch to be ready..."
    
    local timeout=300
    local interval=10
    local elapsed=0
    
    while [[ \$elapsed -lt \$timeout ]]; do
        if kubectl exec -n "\$LOGGING_NAMESPACE" statefulset/elasticsearch -- curl -f -s "http://localhost:9200/_cluster/health" >/dev/null 2>&1; then
            echo "Elasticsearch is ready"
            return 0
        fi
        
        echo "Waiting for Elasticsearch... (\$elapsed/\${timeout}s)"
        sleep \$interval
        elapsed=\$((elapsed + interval))
    done
    
    echo "Timeout waiting for Elasticsearch"
    return 1
}

setup_ilm_policy() {
    echo "Creating ILM policy for log retention..."
    
    kubectl exec -n "\$LOGGING_NAMESPACE" statefulset/elasticsearch -- curl -X PUT "localhost:9200/_ilm/policy/logstash-policy" -H 'Content-Type: application/json' -d "
    {
      \"policy\": {
        \"phases\": {
          \"hot\": {
            \"min_age\": \"0ms\",
            \"actions\": {
              \"rollover\": {
                \"max_size\": \"5gb\",
                \"max_age\": \"1d\"
              }
            }
          },
          \"warm\": {
            \"min_age\": \"2d\",
            \"actions\": {
              \"shrink\": {
                \"number_of_shards\": 1
              },
              \"forcemerge\": {
                \"max_num_segments\": 1
              }
            }
          },
          \"delete\": {
            \"min_age\": \"\${RETENTION_DAYS}d\",
            \"actions\": {
              \"delete\": {}
            }
          }
        }
      }
    }"
}

setup_index_template() {
    echo "Creating index template..."
    
    kubectl exec -n "\$LOGGING_NAMESPACE" statefulset/elasticsearch -- curl -X PUT "localhost:9200/_index_template/logstash-template" -H 'Content-Type: application/json' -d "
    {
      \"index_patterns\": [\"logstash-*\"],
      \"template\": {
        \"settings\": {
          \"number_of_shards\": 1,
          \"number_of_replicas\": 0,
          \"index.lifecycle.name\": \"logstash-policy\",
          \"index.lifecycle.rollover_alias\": \"logstash\"
        },
        \"mappings\": {
          \"properties\": {
            \"@timestamp\": {
              \"type\": \"date\"
            },
            \"message\": {
              \"type\": \"text\"
            },
            \"kubernetes\": {
              \"properties\": {
                \"pod_name\": {
                  \"type\": \"keyword\"
                },
                \"namespace_name\": {
                  \"type\": \"keyword\"
                },
                \"container_name\": {
                  \"type\": \"keyword\"
                }
              }
            }
          }
        }
      }
    }"
}

create_initial_index() {
    echo "Creating initial index..."
    
    kubectl exec -n "\$LOGGING_NAMESPACE" statefulset/elasticsearch -- curl -X PUT "localhost:9200/logstash-000001" -H 'Content-Type: application/json' -d "
    {
      \"aliases\": {
        \"logstash\": {
          \"is_write_index\": true
        }
      }
    }"
}

main() {
    wait_for_elasticsearch
    setup_ilm_policy
    setup_index_template
    create_initial_index
    echo "Elasticsearch ILM setup completed"
}

main "\$@"
EOF

    chmod +x "$ilm_script"
    print_status "SUCCESS" "Elasticsearch ILM script created: $ilm_script"
}

# EFKデプロイメント確認
verify_efk_deployment() {
    print_status "INFO" "Verifying EFK stack deployment..."
    
    local timeout=600
    local interval=15
    local elapsed=0
    
    # Elasticsearch確認
    print_status "INFO" "Checking Elasticsearch..."
    while [[ $elapsed -lt $timeout ]]; do
        if kubectl get pods -n "$LOGGING_NAMESPACE" -l app.kubernetes.io/name=elasticsearch | grep -q "Running"; then
            print_status "SUCCESS" "Elasticsearch is running"
            break
        fi
        
        print_status "INFO" "Waiting for Elasticsearch... ($elapsed/${timeout}s)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    # Kibana確認
    print_status "INFO" "Checking Kibana..."
    elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if kubectl get pods -n "$LOGGING_NAMESPACE" -l app.kubernetes.io/name=kibana | grep -q "Running"; then
            print_status "SUCCESS" "Kibana is running"
            break
        fi
        
        print_status "INFO" "Waiting for Kibana... ($elapsed/${timeout}s)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    # Fluentd確認
    print_status "INFO" "Checking Fluentd..."
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    local ready_fluentd=0
    
    elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        ready_fluentd=$(kubectl get ds -n "$LOGGING_NAMESPACE" fluentd -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
        
        if [[ "$ready_fluentd" == "$node_count" ]]; then
            print_status "SUCCESS" "Fluentd running on all nodes ($ready_fluentd/$node_count)"
            break
        fi
        
        print_status "INFO" "Waiting for Fluentd on all nodes... ($ready_fluentd/$node_count ready)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    print_status "SUCCESS" "EFK stack deployment verification completed"
}

# アクセス情報表示
show_access_information() {
    print_status "INFO" "EFK stack access information:"
    
    local node_ip
    if node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); then
        echo ""
        echo "=== EFK Stack Access URLs ==="
        echo "Kibana UI: http://$node_ip:30561"
        echo "Elasticsearch API: http://$node_ip:30920"
        echo ""
        echo "=== Internal Service URLs ==="
        echo "Elasticsearch: http://elasticsearch.$LOGGING_NAMESPACE.svc.cluster.local:9200"
        echo "Kibana: http://kibana.$LOGGING_NAMESPACE.svc.cluster.local:5601"
        echo ""
        echo "=== EFK Stack Status ==="
        kubectl get all -n "$LOGGING_NAMESPACE"
        echo ""
        echo "=== Storage Usage ==="
        kubectl get pvc -n "$LOGGING_NAMESPACE"
        echo ""
        echo "=== Sample Kibana Index Patterns ==="
        echo "• logstash-* (All application logs)"
        echo "• kubernetes.* (Container logs)"
        echo "• kubelet (Kubelet logs)"
        echo "• docker (Docker daemon logs)"
    else
        print_status "WARNING" "Unable to determine node IP address"
    fi
}

# ログ管理スクリプト作成
create_logging_management_script() {
    print_status "INFO" "Creating logging management script..."
    
    local management_script="$SCRIPT_DIR/manage-logging.sh"
    
    cat > "$management_script" <<'EOF'
#!/bin/bash
# scripts/manage-logging.sh
# EFK Stack管理スクリプト

set -euo pipefail

LOGGING_NAMESPACE="${LOGGING_NAMESPACE:-logging}"

print_usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  status         Show EFK stack status"
    echo "  logs           Show component logs"
    echo "  cleanup        Clean old indices"
    echo "  backup         Backup Elasticsearch data"
    echo "  restart        Restart EFK components"
    echo "  indices        List Elasticsearch indices"
    echo "  index-stats    Show index statistics"
    echo ""
    echo "Options:"
    echo "  --namespace NS     Logging namespace (default: logging)"
    echo "  --component NAME   Component name (elasticsearch|kibana|fluentd)"
    echo "  --days N          Days to keep (for cleanup)"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 logs --component elasticsearch"
    echo "  $0 cleanup --days 7"
    echo "  $0 indices"
}

show_status() {
    echo "=== EFK Stack Status ==="
    kubectl get all -n "$LOGGING_NAMESPACE"
    echo ""
    echo "=== Storage Status ==="
    kubectl get pvc -n "$LOGGING_NAMESPACE"
    echo ""
    echo "=== Elasticsearch Health ==="
    kubectl exec -n "$LOGGING_NAMESPACE" statefulset/elasticsearch -- curl -s "localhost:9200/_cluster/health?pretty" || echo "Elasticsearch not accessible"
}

show_logs() {
    local component="${1:-elasticsearch}"
    
    case $component in
        elasticsearch)
            kubectl logs -n "$LOGGING_NAMESPACE" statefulset/elasticsearch -f
            ;;
        kibana)
            kubectl logs -n "$LOGGING_NAMESPACE" deployment/kibana -f
            ;;
        fluentd)
            kubectl logs -n "$LOGGING_NAMESPACE" daemonset/fluentd -f --max-log-requests=10
            ;;
        *)
            echo "Unknown component: $component"
            return 1
            ;;
    esac
}

list_indices() {
    echo "=== Elasticsearch Indices ==="
    kubectl exec -n "$LOGGING_NAMESPACE" statefulset/elasticsearch -- curl -s "localhost:9200/_cat/indices?v&s=index" || echo "Elasticsearch not accessible"
}

show_index_stats() {
    echo "=== Index Statistics ==="
    kubectl exec -n "$LOGGING_NAMESPACE" statefulset/elasticsearch -- curl -s "localhost:9200/_stats?pretty" || echo "Elasticsearch not accessible"
}

cleanup_indices() {
    local days="${1:-7}"
    echo "Cleaning up indices older than $days days..."
    
    kubectl exec -n "$LOGGING_NAMESPACE" statefulset/elasticsearch -- curl -X DELETE "localhost:9200/logstash-*" -H 'Content-Type: application/json' -d "{
      \"query\": {
        \"range\": {
          \"@timestamp\": {
            \"lte\": \"now-${days}d\"
          }
        }
      }
    }" || echo "Cleanup failed"
}

case "${1:-}" in
    status)
        show_status
        ;;
    logs)
        show_logs "${2:-elasticsearch}"
        ;;
    cleanup)
        cleanup_indices "${2:-7}"
        ;;
    indices)
        list_indices
        ;;
    index-stats)
        show_index_stats
        ;;
    restart)
        component="${2:-all}"
        if [[ "$component" == "all" ]]; then
            kubectl rollout restart statefulset/elasticsearch -n "$LOGGING_NAMESPACE"
            kubectl rollout restart deployment/kibana -n "$LOGGING_NAMESPACE"
            kubectl rollout restart daemonset/fluentd -n "$LOGGING_NAMESPACE"
        else
            kubectl rollout restart "$component" -n "$LOGGING_NAMESPACE"
        fi
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
    print_status "SUCCESS" "Logging management script created: $management_script"
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # EFKログ集約スタックセットアッププロセス
    check_prerequisites
    create_logging_namespace
    setup_elasticsearch
    setup_kibana
    setup_fluentd
    setup_elasticsearch_ilm
    verify_efk_deployment
    create_logging_management_script
    show_access_information
    
    echo -e "\n${BLUE}=== EFK Logging Stack Summary ===${NC}"
    print_status "SUCCESS" "EFK logging stack setup completed successfully!"
    
    echo ""
    echo "📊 EFK Components Deployed:"
    echo "  • Elasticsearch (NodePort 30920) - Search and analytics engine"
    echo "  • Fluentd (DaemonSet) - Log collector on all nodes"
    echo "  • Kibana (NodePort 30561) - Data visualization dashboard"
    echo "  • Index Lifecycle Management - Automated log retention"
    
    echo ""
    echo "🔍 Logging Features:"
    echo "  • Container log collection (all namespaces)"
    echo "  • System log collection (kubelet, docker)"
    echo "  • JupyterHub application log aggregation"
    echo "  • Kubernetes metadata enrichment"
    echo "  • Log retention: $LOG_RETENTION_DAYS days"
    
    echo ""
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "N/A")
    echo "🌐 Access Information:"
    echo "  Kibana Dashboard: http://$node_ip:30561"
    echo "  Elasticsearch API: http://$node_ip:30920"
    
    echo ""
    echo "Next steps:"
    echo "1. Access Kibana to create index patterns (logstash-*)"
    echo "2. Setup log retention policies if needed"
    echo "3. Configure alerting based on log patterns"
    echo "4. Run ILM setup: $SCRIPT_DIR/setup-elasticsearch-ilm.sh"
    
    echo ""
    echo "Management commands:"
    echo "- Check status: $SCRIPT_DIR/manage-logging.sh status"
    echo "- View logs: $SCRIPT_DIR/manage-logging.sh logs --component elasticsearch"
    echo "- List indices: $SCRIPT_DIR/manage-logging.sh indices"
    echo "- Cleanup old logs: $SCRIPT_DIR/manage-logging.sh cleanup --days 7"
    
    exit 0
}

# 引数処理
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  -h, --help                Show this help message"
        echo "  --namespace NS            Logging namespace (default: logging)"
        echo "  --elasticsearch-version V Elasticsearch version (default: $ELASTICSEARCH_VERSION)"
        echo "  --kibana-version V        Kibana version (default: $KIBANA_VERSION)"
        echo "  --fluentd-version V       Fluentd version (default: $FLUENTD_VERSION)"
        echo "  --storage-size SIZE       Elasticsearch storage (default: $ELASTICSEARCH_STORAGE_SIZE)"
        echo "  --retention-days N        Log retention days (default: $LOG_RETENTION_DAYS)"
        echo "  --verify-only             Only verify existing deployment"
        echo "  --status                  Show EFK stack status"
        echo ""
        echo "Examples:"
        echo "  $0                        Setup complete EFK logging stack"
        echo "  $0 --retention-days 14    Setup with 14-day log retention"
        echo "  $0 --status               Show current logging status"
        exit 0
        ;;
    --namespace)
        LOGGING_NAMESPACE="${2:-$LOGGING_NAMESPACE}"
        shift 2
        ;;
    --elasticsearch-version)
        ELASTICSEARCH_VERSION="${2:-$ELASTICSEARCH_VERSION}"
        shift 2
        ;;
    --kibana-version)
        KIBANA_VERSION="${2:-$KIBANA_VERSION}"
        shift 2
        ;;
    --fluentd-version)
        FLUENTD_VERSION="${2:-$FLUENTD_VERSION}"
        shift 2
        ;;
    --storage-size)
        ELASTICSEARCH_STORAGE_SIZE="${2:-$ELASTICSEARCH_STORAGE_SIZE}"
        shift 2
        ;;
    --retention-days)
        LOG_RETENTION_DAYS="${2:-$LOG_RETENTION_DAYS}"
        shift 2
        ;;
    --verify-only)
        check_prerequisites
        verify_efk_deployment
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