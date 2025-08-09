#!/bin/bash
# scripts/setup-ssl.sh
# SSL/TLS証明書設定スクリプト for JupyterHub

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
CERT_DIR="$PROJECT_ROOT/certs"
LOG_FILE="$SCRIPT_DIR/ssl-setup.log"
EXIT_CODE=0

# SSL設定
DOMAIN="${SSL_DOMAIN:-localhost}"
NAMESPACE="${NAMESPACE:-jupyterhub}"
CERT_VALIDITY_DAYS="${CERT_VALIDITY_DAYS:-365}"

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}SSL/TLS Certificate Setup${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting SSL/TLS certificate setup"
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
    print_status "INFO" "Checking prerequisites for SSL setup..."
    
    # OpenSSL確認
    if ! command -v openssl >/dev/null 2>&1; then
        print_status "ERROR" "OpenSSL not found. Please install openssl"
        return 1
    fi
    
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
    
    # JupyterHub名前空間確認
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        print_status "WARNING" "Namespace '$NAMESPACE' not found. Will be created if needed."
    fi
    
    print_status "SUCCESS" "Prerequisites check passed"
}

# 証明書ディレクトリ準備
prepare_cert_directory() {
    print_status "INFO" "Preparing certificate directory..."
    
    # 証明書ディレクトリ作成
    mkdir -p "$CERT_DIR"
    chmod 700 "$CERT_DIR"
    
    # 既存証明書チェック
    if [[ -f "$CERT_DIR/tls.crt" && -f "$CERT_DIR/tls.key" ]]; then
        print_status "WARNING" "Existing certificates found in: $CERT_DIR"
        
        # 証明書情報表示
        local cert_subject=$(openssl x509 -in "$CERT_DIR/tls.crt" -noout -subject 2>/dev/null | sed 's/subject=//')
        local cert_expiry=$(openssl x509 -in "$CERT_DIR/tls.crt" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        
        print_status "INFO" "Current certificate subject: $cert_subject"
        print_status "INFO" "Current certificate expiry: $cert_expiry"
        
        echo ""
        echo "Options:"
        echo "1) Generate new certificates (replace existing)"
        echo "2) Use existing certificates"
        echo "3) Exit"
        
        read -p "Choose option [1-3]: " choice
        case $choice in
            1)
                print_status "INFO" "Generating new certificates"
                backup_existing_certs
                ;;
            2)
                print_status "INFO" "Using existing certificates"
                return 1
                ;;
            3)
                print_status "INFO" "Certificate setup cancelled"
                exit 0
                ;;
            *)
                print_status "WARNING" "Invalid choice, generating new certificates"
                backup_existing_certs
                ;;
        esac
    else
        print_status "SUCCESS" "Certificate directory prepared: $CERT_DIR"
    fi
}

# 既存証明書バックアップ
backup_existing_certs() {
    local backup_dir="$CERT_DIR/backup-$(date +%Y%m%d_%H%M%S)"
    
    print_status "INFO" "Backing up existing certificates..."
    mkdir -p "$backup_dir"
    
    # 既存ファイルをバックアップ
    for file in tls.crt tls.key ca.crt ca.key; do
        if [[ -f "$CERT_DIR/$file" ]]; then
            mv "$CERT_DIR/$file" "$backup_dir/"
            log "Backed up: $file"
        fi
    done
    
    print_status "SUCCESS" "Certificates backed up to: $backup_dir"
}

# CA証明書生成
generate_ca_certificate() {
    print_status "INFO" "Generating Certificate Authority (CA)..."
    
    # CA秘密鍵生成
    openssl genrsa -out "$CERT_DIR/ca.key" 4096
    chmod 600 "$CERT_DIR/ca.key"
    
    # CA証明書生成
    openssl req -new -x509 -key "$CERT_DIR/ca.key" -sha256 -subj "/C=US/ST=CA/L=San Francisco/O=kubeadm-python-cluster/CN=kubeadm-python-cluster-ca" -days "$CERT_VALIDITY_DAYS" -out "$CERT_DIR/ca.crt"
    
    print_status "SUCCESS" "CA certificate generated"
}

# サーバー証明書生成
generate_server_certificate() {
    print_status "INFO" "Generating server certificate for domain: $DOMAIN"
    
    # サーバー秘密鍵生成
    openssl genrsa -out "$CERT_DIR/tls.key" 4096
    chmod 600 "$CERT_DIR/tls.key"
    
    # CSR生成
    openssl req -new -key "$CERT_DIR/tls.key" -out "$CERT_DIR/server.csr" -subj "/C=US/ST=CA/L=San Francisco/O=kubeadm-python-cluster/CN=$DOMAIN"
    
    # Subject Alternative Names設定
    local san_config="$CERT_DIR/san.conf"
    cat > "$san_config" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = CA
L = San Francisco
O = kubeadm-python-cluster
CN = $DOMAIN

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
DNS.2 = localhost
DNS.3 = jupyterhub
DNS.4 = jupyterhub.$NAMESPACE
DNS.5 = jupyterhub.$NAMESPACE.svc
DNS.6 = jupyterhub.$NAMESPACE.svc.cluster.local
IP.1 = 127.0.0.1
EOF
    
    # ノードIPを追加
    local node_ip
    if node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); then
        echo "IP.2 = $node_ip" >> "$san_config"
        log "Added node IP to SAN: $node_ip"
    fi
    
    # サーバー証明書生成
    openssl x509 -req -in "$CERT_DIR/server.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/tls.crt" -days "$CERT_VALIDITY_DAYS" -extensions v3_req -extfile "$san_config"
    
    # 一時ファイル削除
    rm -f "$CERT_DIR/server.csr" "$san_config"
    
    print_status "SUCCESS" "Server certificate generated"
}

# 証明書検証
verify_certificates() {
    print_status "INFO" "Verifying generated certificates..."
    
    # CA証明書情報
    local ca_subject=$(openssl x509 -in "$CERT_DIR/ca.crt" -noout -subject | sed 's/subject=//')
    local ca_expiry=$(openssl x509 -in "$CERT_DIR/ca.crt" -noout -enddate | sed 's/notAfter=//')
    
    print_status "INFO" "CA Certificate:"
    print_status "INFO" "  Subject: $ca_subject"
    print_status "INFO" "  Expiry: $ca_expiry"
    
    # サーバー証明書情報
    local server_subject=$(openssl x509 -in "$CERT_DIR/tls.crt" -noout -subject | sed 's/subject=//')
    local server_expiry=$(openssl x509 -in "$CERT_DIR/tls.crt" -noout -enddate | sed 's/notAfter=//')
    
    print_status "INFO" "Server Certificate:"
    print_status "INFO" "  Subject: $server_subject"
    print_status "INFO" "  Expiry: $server_expiry"
    
    # SAN確認
    print_status "INFO" "Subject Alternative Names:"
    openssl x509 -in "$CERT_DIR/tls.crt" -noout -text | grep -A 10 "Subject Alternative Name" | tail -n +2 | sed 's/^[ ]*/    /' || true
    
    # 証明書チェーンの検証
    if openssl verify -CAfile "$CERT_DIR/ca.crt" "$CERT_DIR/tls.crt" >/dev/null 2>&1; then
        print_status "SUCCESS" "Certificate chain verification passed"
    else
        print_status "ERROR" "Certificate chain verification failed"
        return 1
    fi
    
    # 秘密鍵と証明書の一致確認
    local cert_md5=$(openssl x509 -noout -modulus -in "$CERT_DIR/tls.crt" | openssl md5)
    local key_md5=$(openssl rsa -noout -modulus -in "$CERT_DIR/tls.key" | openssl md5)
    
    if [[ "$cert_md5" == "$key_md5" ]]; then
        print_status "SUCCESS" "Certificate and private key match"
    else
        print_status "ERROR" "Certificate and private key do not match"
        return 1
    fi
    
    print_status "SUCCESS" "Certificate verification completed"
}

# KubernetesシークレットにTLS証明書を追加
create_tls_secret() {
    print_status "INFO" "Creating TLS secret in Kubernetes..."
    
    # 名前空間が存在しない場合は作成
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        kubectl create namespace "$NAMESPACE"
        print_status "SUCCESS" "Created namespace: $NAMESPACE"
    fi
    
    # 既存のTLSシークレットを削除
    kubectl delete secret jupyterhub-tls -n "$NAMESPACE" --ignore-not-found=true
    
    # TLSシークレット作成
    if kubectl create secret tls jupyterhub-tls \
        --cert="$CERT_DIR/tls.crt" \
        --key="$CERT_DIR/tls.key" \
        -n "$NAMESPACE"; then
        print_status "SUCCESS" "TLS secret created: jupyterhub-tls"
    else
        print_status "ERROR" "Failed to create TLS secret"
        return 1
    fi
    
    # CA証明書シークレット作成
    kubectl delete secret jupyterhub-ca -n "$NAMESPACE" --ignore-not-found=true
    
    if kubectl create secret generic jupyterhub-ca \
        --from-file=ca.crt="$CERT_DIR/ca.crt" \
        -n "$NAMESPACE"; then
        print_status "SUCCESS" "CA secret created: jupyterhub-ca"
    else
        print_status "ERROR" "Failed to create CA secret"
        return 1
    fi
    
    # シークレットにラベル追加
    kubectl label secret jupyterhub-tls -n "$NAMESPACE" \
        app.kubernetes.io/name=jupyterhub \
        app.kubernetes.io/component=tls \
        app.kubernetes.io/instance=kubeadm-python-cluster
    
    kubectl label secret jupyterhub-ca -n "$NAMESPACE" \
        app.kubernetes.io/name=jupyterhub \
        app.kubernetes.io/component=ca \
        app.kubernetes.io/instance=kubeadm-python-cluster
    
    print_status "SUCCESS" "TLS secrets created in Kubernetes"
}

# JupyterHub設定更新 (HTTPS対応)
update_jupyterhub_config() {
    print_status "INFO" "Updating JupyterHub configuration for HTTPS..."
    
    local config_dir="$PROJECT_ROOT/k8s-manifests"
    local configmap_file="$config_dir/configmap-https.yaml"
    
    # HTTPS対応のConfigMap作成
    cat > "$configmap_file" <<EOF
---
# JupyterHub Configuration ConfigMap (HTTPS Enabled)
apiVersion: v1
kind: ConfigMap
metadata:
  name: jupyterhub-config
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: jupyterhub
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: config
data:
  jupyterhub_config.py: |
    # JupyterHub Configuration for Kubernetes Deployment with HTTPS
    import os
    from kubespawner import KubeSpawner
    
    # ================================================
    # Basic JupyterHub Configuration
    # ================================================
    
    c.JupyterHub.hub_ip = '0.0.0.0'
    c.JupyterHub.hub_port = 8081
    c.JupyterHub.port = 8443
    
    # SSL Configuration
    c.JupyterHub.ssl_cert = '/etc/jupyterhub/ssl/tls.crt'
    c.JupyterHub.ssl_key = '/etc/jupyterhub/ssl/tls.key'
    
    # Database configuration
    c.JupyterHub.db_url = 'sqlite:///jupyterhub.sqlite'
    
    # Admin users
    c.Authenticator.admin_users = {'admin'}
    
    # ================================================
    # Kubernetes Integration
    # ================================================
    
    c.JupyterHub.spawner_class = KubeSpawner
    c.KubeSpawner.namespace = '$NAMESPACE'
    c.KubeSpawner.service_account = 'jupyterhub-singleuser'
    
    # Container images
    c.KubeSpawner.image_spec = 'localhost:5000/kubeadm-python-cluster/jupyterlab:3.11'
    
    # Resource limits
    c.KubeSpawner.cpu_limit = 1.0
    c.KubeSpawner.mem_limit = '2G'
    c.KubeSpawner.cpu_guarantee = 0.5
    c.KubeSpawner.mem_guarantee = '1G'
    
    # Storage configuration
    c.KubeSpawner.pvc_name_template = 'jupyterhub-user-{username}'
    c.KubeSpawner.storage_capacity = '5Gi'
    c.KubeSpawner.storage_class = 'jupyterhub-user-storage'
    
    # Volume mounts
    c.KubeSpawner.volume_mounts = [
        {
            'name': 'home',
            'mountPath': '/home/jovyan',
            'subPath': 'home/{username}'
        },
        {
            'name': 'shared',
            'mountPath': '/home/jovyan/shared',
            'readOnly': False
        }
    ]
    
    c.KubeSpawner.volumes = [
        {
            'name': 'home',
            'persistentVolumeClaim': {
                'claimName': c.KubeSpawner.pvc_name_template
            }
        },
        {
            'name': 'shared',
            'persistentVolumeClaim': {
                'claimName': 'jupyterhub-shared-data-pvc'
            }
        }
    ]
    
    # Environment variables
    c.KubeSpawner.environment = {
        'JUPYTER_ENABLE_LAB': '1',
        'GRANT_SUDO': 'yes',
        'NB_UID': '1000',
        'NB_GID': '1000',
        'CHOWN_HOME': 'yes',
    }
    
    # Security context
    c.KubeSpawner.security_context = {
        'runAsUser': 1000,
        'runAsGroup': 1000,
        'fsGroup': 1000,
    }
    
    # Profile list for different Python versions
    c.KubeSpawner.profile_list = [
        {
            'display_name': 'Python 3.11 (Default)',
            'description': 'Latest Python with modern libraries',
            'default': True,
            'kubespawner_override': {
                'image_spec': 'localhost:5000/kubeadm-python-cluster/jupyterlab:3.11',
                'cpu_limit': 1.0,
                'mem_limit': '2G',
            }
        },
        {
            'display_name': 'Python 3.10',
            'description': 'Python 3.10 with stable libraries',
            'kubespawner_override': {
                'image_spec': 'localhost:5000/kubeadm-python-cluster/jupyterlab:3.10',
                'cpu_limit': 1.0,
                'mem_limit': '2G',
            }
        },
        {
            'display_name': 'Python 3.9',
            'description': 'Python 3.9 with compatible libraries',
            'kubespawner_override': {
                'image_spec': 'localhost:5000/kubeadm-python-cluster/jupyterlab:3.9',
                'cpu_limit': 1.0,
                'mem_limit': '2G',
            }
        },
        {
            'display_name': 'Python 3.8 (Legacy)',
            'description': 'Python 3.8 for legacy compatibility',
            'kubespawner_override': {
                'image_spec': 'localhost:5000/kubeadm-python-cluster/jupyterlab:3.8',
                'cpu_limit': 0.8,
                'mem_limit': '1.5G',
            }
        },
    ]
    
    # ================================================
    # Authentication
    # ================================================
    
    c.JupyterHub.authenticator_class = 'nativeauthenticator.NativeAuthenticator'
    c.NativeAuthenticator.create_users = True
    c.NativeAuthenticator.enable_signup = True
    
    # ================================================
    # Services
    # ================================================
    
    c.JupyterHub.services = [
        {
            'name': 'idle-culler',
            'command': [
                'python3', '-m', 'jupyterhub_idle_culler',
                '--timeout=3600',
                '--max-age=7200',
                '--remove-named-servers',
                '--cull-users',
            ],
            'admin': True,
        }
    ]
    
    # ================================================
    # Security Settings
    # ================================================
    
    # CSRF protection
    c.JupyterHub.tornado_settings = {
        'headers': {
            'Content-Security-Policy': "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval'",
            'X-Frame-Options': 'DENY',
            'X-Content-Type-Options': 'nosniff',
            'Strict-Transport-Security': 'max-age=31536000; includeSubDomains'
        }
    }
    
    # ================================================
    # Logging and Debug
    # ================================================
    
    c.JupyterHub.log_level = 'INFO'
    c.Application.log_level = 'INFO'
EOF
    
    # ConfigMap適用
    if kubectl apply -f "$configmap_file"; then
        print_status "SUCCESS" "JupyterHub HTTPS configuration updated"
    else
        print_status "ERROR" "Failed to update JupyterHub configuration"
        return 1
    fi
    
    print_status "SUCCESS" "JupyterHub configuration updated for HTTPS"
}

# HTTPS対応デプロイメント更新
update_deployment_for_https() {
    print_status "INFO" "Updating JupyterHub deployment for HTTPS..."
    
    local deployment_file="$PROJECT_ROOT/k8s-manifests/jupyterhub-deployment-https.yaml"
    
    # HTTPS対応デプロイメント作成
    cat > "$deployment_file" <<EOF
---
# JupyterHub Deployment (HTTPS Enabled)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jupyterhub
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: jupyterhub
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: hub
    app.kubernetes.io/version: "4.0.2"
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: jupyterhub
      app.kubernetes.io/component: hub
  template:
    metadata:
      labels:
        app.kubernetes.io/name: jupyterhub
        app.kubernetes.io/instance: kubeadm-python-cluster
        app.kubernetes.io/component: hub
    spec:
      serviceAccountName: jupyterhub
      securityContext:
        fsGroup: 1000
        runAsUser: 1000
        runAsGroup: 1000
      containers:
      - name: jupyterhub
        image: localhost:5000/kubeadm-python-cluster/jupyterhub:latest
        imagePullPolicy: IfNotPresent
        ports:
        - name: https
          containerPort: 8443
          protocol: TCP
        - name: hub
          containerPort: 8081
          protocol: TCP
        env:
        # SSL Configuration
        - name: JUPYTERHUB_SSL_CERT
          value: "/etc/jupyterhub/ssl/tls.crt"
        - name: JUPYTERHUB_SSL_KEY
          value: "/etc/jupyterhub/ssl/tls.key"
        
        # Basic configuration
        - name: JUPYTERHUB_NAMESPACE
          value: "$NAMESPACE"
        - name: JUPYTERHUB_SERVICE_ACCOUNT
          value: "jupyterhub-singleuser"
        - name: JUPYTERHUB_LOG_LEVEL
          value: "INFO"
        - name: JUPYTERHUB_DB_URL
          value: "sqlite:///jupyterhub.sqlite"
        
        # Container registry
        - name: CONTAINER_REGISTRY
          value: "localhost:5000"
        
        # Secrets
        - name: JUPYTERHUB_COOKIE_SECRET
          valueFrom:
            secretKeyRef:
              name: jupyterhub-secret
              key: cookie-secret
        - name: JUPYTERHUB_CRYPTO_KEY
          valueFrom:
            secretKeyRef:
              name: jupyterhub-secret
              key: crypto-key
        
        # Kubernetes API access
        - name: KUBERNETES_SERVICE_HOST
          value: kubernetes.default.svc.cluster.local
        - name: KUBERNETES_SERVICE_PORT
          value: "443"
        
        volumeMounts:
        - name: config
          mountPath: /etc/jupyterhub/jupyterhub_config.py
          subPath: jupyterhub_config.py
          readOnly: true
        - name: hub-data
          mountPath: /srv/jupyterhub
        - name: shared-data
          mountPath: /srv/jupyterhub/shared
        - name: ssl-certs
          mountPath: /etc/jupyterhub/ssl
          readOnly: true
        
        resources:
          requests:
            memory: "512Mi"
            cpu: "0.5"
          limits:
            memory: "1Gi"
            cpu: "1"
        
        livenessProbe:
          httpGet:
            path: /hub/health
            port: https
            scheme: HTTPS
          initialDelaySeconds: 30
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 3
        
        readinessProbe:
          httpGet:
            path: /hub/health
            port: https
            scheme: HTTPS
          initialDelaySeconds: 15
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
      
      volumes:
      - name: config
        configMap:
          name: jupyterhub-config
          defaultMode: 0644
      - name: hub-data
        persistentVolumeClaim:
          claimName: jupyterhub-hub-pvc
      - name: shared-data
        persistentVolumeClaim:
          claimName: jupyterhub-shared-data-pvc
      - name: ssl-certs
        secret:
          secretName: jupyterhub-tls
          defaultMode: 0600
      
      imagePullSecrets:
      - name: registry-credentials
      
      nodeSelector:
        kubernetes.io/os: linux
      
      tolerations: []
      
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 1
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app.kubernetes.io/name
                  operator: In
                  values:
                  - jupyterhub
              topologyKey: kubernetes.io/hostname
EOF
    
    print_status "SUCCESS" "HTTPS deployment configuration created"
}

# HTTPS対応サービス更新
update_service_for_https() {
    print_status "INFO" "Updating service for HTTPS..."
    
    local service_file="$PROJECT_ROOT/k8s-manifests/service-https.yaml"
    
    # HTTPS対応サービス作成
    cat > "$service_file" <<EOF
---
# JupyterHub Service (HTTPS)
apiVersion: v1
kind: Service
metadata:
  name: jupyterhub
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: jupyterhub
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: hub
spec:
  type: NodePort
  ports:
  - name: https
    port: 443
    targetPort: https
    protocol: TCP
    nodePort: 30443
  - name: hub
    port: 8081
    targetPort: hub
    protocol: TCP
    nodePort: 30081
  selector:
    app.kubernetes.io/name: jupyterhub
    app.kubernetes.io/component: hub

---
# JupyterHub Headless Service (for internal communication)
apiVersion: v1
kind: Service
metadata:
  name: jupyterhub-internal
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: jupyterhub
    app.kubernetes.io/instance: kubeadm-python-cluster
    app.kubernetes.io/component: hub-internal
spec:
  type: ClusterIP
  clusterIP: None
  ports:
  - name: https
    port: 8443
    targetPort: https
    protocol: TCP
  - name: hub
    port: 8081
    targetPort: hub
    protocol: TCP
  selector:
    app.kubernetes.io/name: jupyterhub
    app.kubernetes.io/component: hub
EOF
    
    print_status "SUCCESS" "HTTPS service configuration created"
}

# SSL設定のテスト
test_ssl_configuration() {
    print_status "INFO" "Testing SSL configuration..."
    
    # 証明書検証テスト
    local node_ip
    if node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); then
        print_status "INFO" "Node IP: $node_ip"
        
        # SSL接続テスト（JupyterHubがデプロイされている場合）
        if kubectl get deployment -n "$NAMESPACE" jupyterhub >/dev/null 2>&1; then
            print_status "INFO" "Testing SSL connection to JupyterHub..."
            
            # ヘルスチェックテスト
            local timeout=30
            local count=0
            
            while [[ $count -lt $timeout ]]; do
                if curl -k -f -s "https://$node_ip:30443/hub/health" >/dev/null 2>&1; then
                    print_status "SUCCESS" "HTTPS health check passed"
                    break
                fi
                
                sleep 2
                ((count+=2))
            done
            
            if [[ $count -ge $timeout ]]; then
                print_status "WARNING" "HTTPS health check timeout (deployment may not be ready)"
            fi
        else
            print_status "INFO" "JupyterHub deployment not found, skipping live SSL test"
        fi
    fi
    
    print_status "SUCCESS" "SSL configuration test completed"
}

# 証明書情報表示
show_certificate_info() {
    print_status "INFO" "SSL Certificate Information:"
    
    echo ""
    echo "=== Generated Certificates ==="
    echo "CA Certificate: $CERT_DIR/ca.crt"
    echo "Server Certificate: $CERT_DIR/tls.crt"
    echo "Server Private Key: $CERT_DIR/tls.key"
    
    echo ""
    echo "=== Certificate Details ==="
    openssl x509 -in "$CERT_DIR/tls.crt" -noout -text | grep -E "(Subject:|Not After|DNS:|IP Address:)" || true
    
    echo ""
    echo "=== Kubernetes Secrets ==="
    kubectl get secrets -n "$NAMESPACE" | grep -E "(jupyterhub-tls|jupyterhub-ca)" || true
    
    echo ""
    echo "=== Access Information ==="
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "N/A")
    echo "HTTPS URL: https://$node_ip:30443"
    echo "Certificate file for client: $CERT_DIR/ca.crt"
    
    echo ""
    echo "=== Installation Instructions ==="
    echo "To trust the CA certificate on this system:"
    echo "  sudo cp $CERT_DIR/ca.crt /usr/local/share/ca-certificates/kubeadm-python-cluster-ca.crt"
    echo "  sudo update-ca-certificates"
    
    echo ""
    echo "For browsers, import the CA certificate ($CERT_DIR/ca.crt) as a trusted root certificate."
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    # SSL証明書セットアッププロセス
    check_prerequisites
    prepare_cert_directory || {
        print_status "INFO" "Using existing certificates"
        create_tls_secret
        update_jupyterhub_config
        update_deployment_for_https
        update_service_for_https
        test_ssl_configuration
        show_certificate_info
        exit 0
    }
    
    generate_ca_certificate
    generate_server_certificate
    verify_certificates
    create_tls_secret
    update_jupyterhub_config
    update_deployment_for_https
    update_service_for_https
    test_ssl_configuration
    show_certificate_info
    
    echo -e "\n${BLUE}=== SSL Setup Summary ===${NC}"
    print_status "SUCCESS" "SSL/TLS certificate setup completed successfully!"
    
    echo ""
    echo "🔒 SSL/TLS Configuration Complete!"
    echo "📁 Certificates location: $CERT_DIR"
    echo "🔑 Kubernetes secrets created in namespace: $NAMESPACE"
    
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "N/A")
    echo "🌐 HTTPS Access URL: https://$node_ip:30443"
    
    echo ""
    echo "Next steps:"
    echo "1. Apply HTTPS configuration: kubectl apply -f $PROJECT_ROOT/k8s-manifests/configmap-https.yaml"
    echo "2. Update deployment: kubectl apply -f $PROJECT_ROOT/k8s-manifests/jupyterhub-deployment-https.yaml"
    echo "3. Update service: kubectl apply -f $PROJECT_ROOT/k8s-manifests/service-https.yaml"
    echo "4. Install CA certificate for trusted access"
    
    echo ""
    echo "Management commands:"
    echo "- View certificates: openssl x509 -in $CERT_DIR/tls.crt -noout -text"
    echo "- Test HTTPS: curl -k https://$node_ip:30443/hub/health"
    echo "- Renew certificates: $0 --renew"
    
    exit 0
}

# 引数処理
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  -h, --help         Show this help message"
        echo "  --domain DOMAIN    Domain name for certificate (default: localhost)"
        echo "  --namespace NS     Kubernetes namespace (default: jupyterhub)"
        echo "  --days N           Certificate validity in days (default: 365)"
        echo "  --renew            Renew existing certificates"
        echo "  --info             Show certificate information"
        echo "  --test             Test SSL configuration"
        exit 0
        ;;
    --domain)
        DOMAIN="${2:-$DOMAIN}"
        shift 2
        ;;
    --namespace)
        NAMESPACE="${2:-$NAMESPACE}"
        shift 2
        ;;
    --days)
        CERT_VALIDITY_DAYS="${2:-$CERT_VALIDITY_DAYS}"
        shift 2
        ;;
    --renew)
        print_status "INFO" "Renewing certificates..."
        rm -f "$CERT_DIR/tls.crt" "$CERT_DIR/tls.key" "$CERT_DIR/ca.crt" "$CERT_DIR/ca.key"
        ;;
    --info)
        check_prerequisites
        show_certificate_info
        exit 0
        ;;
    --test)
        check_prerequisites
        test_ssl_configuration
        exit 0
        ;;
esac

# メイン実行
main "$@"