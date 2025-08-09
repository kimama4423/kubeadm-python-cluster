# kubeadm Python Cluster デプロイメントガイド

本格的な JupyterHub システムを kubeadm ベースの Kubernetes クラスター上で構築するための詳細なデプロイメントガイドです。

## 📋 前提条件

### システム要件

| コンポーネント | 最小要件 | 推奨要件 |
|--------------|---------|---------|
| CPU | 4コア | 8コア以上 |
| メモリ | 8GB | 16GB以上 |
| ストレージ | 100GB | 500GB以上 (SSD) |
| ネットワーク | インターネット接続 | 高速インターネット |

### サポート OS

- Ubuntu 20.04/22.04 LTS
- CentOS 8+
- RHEL 8+
- Debian 11+

## 🚀 Phase 1: インフラストラクチャセットアップ

### 1.1 システム準備

```bash
# プロジェクトクローン
git clone <repository-url>
cd kubeadm-python-cluster

# システム権限確認
sudo -v

# 必要パッケージ更新
sudo apt update && sudo apt upgrade -y  # Ubuntu/Debian
sudo yum update -y                       # CentOS/RHEL
```

### 1.2 システム要件チェック

```bash
# 自動チェック実行
sudo ./setup/check-prerequisites.sh

# 期待される出力:
# ✅ CPU: 8 cores (minimum: 4)
# ✅ Memory: 16384 MB (minimum: 8192)
# ✅ Disk Space: 512 GB (minimum: 100)
# ✅ Internet connectivity: Available
# ✅ System architecture: x86_64
```

### 1.3 Docker インストール

```bash
# Docker インストール
sudo ./setup/install-docker.sh

# インストール確認
sudo docker --version
sudo docker run hello-world

# Docker サービス確認
sudo systemctl status docker
```

### 1.4 Kubernetes インストール

```bash
# Kubernetes コンポーネントインストール
sudo ./setup/install-kubernetes.sh

# バージョン確認
kubectl version --client
kubeadm version
kubelet --version
```

### 1.5 クラスター初期化

```bash
# kubeadm クラスター初期化
sudo ./setup/init-cluster.sh

# 期待される出力:
# ✅ kubeadm init completed successfully
# ✅ kubectl configuration created
# ✅ Control plane ready

# クラスター状態確認
kubectl cluster-info
kubectl get nodes
```

### 1.6 ネットワーク設定

```bash
# CNI (Flannel) セットアップ
sudo ./setup/setup-networking.sh

# ネットワーク確認
kubectl get pods -n kube-system
kubectl get nodes -o wide
```

## 🐳 Phase 2: コンテナイメージ作成

### 2.1 コンテナレジストリセットアップ

```bash
# ローカルレジストリセットアップ
sudo ./scripts/setup-registry.sh

# レジストリ動作確認
curl -X GET http://localhost:5000/v2/_catalog
docker ps | grep registry
```

### 2.2 Python 基盤イメージ作成

```bash
# Python 基盤イメージビルド
cd docker/base-python
sudo ./build-images.sh

# イメージ確認
docker images | grep python
curl http://localhost:5000/v2/_catalog
```

**構築されるイメージ:**
- `localhost:5000/python-base:3.8`
- `localhost:5000/python-base:3.9`
- `localhost:5000/python-base:3.10`
- `localhost:5000/python-base:3.11`

### 2.3 JupyterHub イメージ作成

```bash
# JupyterHub イメージビルド
cd ../jupyterhub
sudo docker build -t localhost:5000/jupyterhub:4.0.2 .
sudo docker push localhost:5000/jupyterhub:4.0.2

# JupyterLab 拡張イメージ
cd ../jupyterlab
for version in 3.8 3.9 3.10 3.11; do
    sudo docker build -f Dockerfile.python${version} \
        -t localhost:5000/jupyterlab-python:${version} .
    sudo docker push localhost:5000/jupyterlab-python:${version}
done
```

## ⚙️ Phase 3: Kubernetes デプロイメント

### 3.1 ストレージ設定

```bash
# ストレージクラスとPV設定
kubectl apply -f k8s-manifests/storage.yaml

# ストレージ確認
kubectl get storageclass
kubectl get pv
```

### 3.2 RBAC 設定

```bash
# 名前空間作成
kubectl apply -f k8s-manifests/namespace.yaml

# RBAC設定適用
kubectl apply -f k8s-manifests/rbac.yaml

# RBAC確認
kubectl get serviceaccount -n jupyterhub
kubectl get role,rolebinding -n jupyterhub
```

### 3.3 設定とシークレット

```bash
# ConfigMap とSecret適用
kubectl apply -f k8s-manifests/configmap.yaml
kubectl apply -f k8s-manifests/secret.yaml

# 設定確認
kubectl get configmap -n jupyterhub
kubectl get secret -n jupyterhub
```

### 3.4 JupyterHub デプロイ

```bash
# JupyterHub本体デプロイ
kubectl apply -f k8s-manifests/jupyterhub-deployment.yaml
kubectl apply -f k8s-manifests/service.yaml

# デプロイ状況確認
kubectl get pods -n jupyterhub -w
kubectl get svc -n jupyterhub
```

### 3.5 セキュリティポリシー適用

```bash
# ネットワークポリシーとセキュリティコンテキスト
kubectl apply -f k8s-manifests/network-policies.yaml
kubectl apply -f k8s-manifests/security-context.yaml

# セキュリティ設定確認
kubectl get networkpolicies -n jupyterhub
kubectl describe pod -n jupyterhub
```

## 📈 Phase 4: 監視・ログシステム

### 4.1 Prometheus 監視

```bash
# Prometheus セットアップ
./scripts/setup-prometheus.sh

# 監視確認
kubectl get pods -n monitoring
curl http://localhost:9090/api/v1/query?query=up
```

### 4.2 Grafana ダッシュボード

```bash
# Grafana セットアップ
./scripts/setup-grafana.sh

# アクセス情報
echo "Grafana URL: http://localhost:3000"
echo "初期認証: admin/admin"
```

### 4.3 ログ管理 (EFK Stack)

```bash
# EFK スタックセットアップ
./scripts/setup-logging.sh

# ログシステム確認
kubectl get pods -n logging
curl http://localhost:5601/api/status
```

### 4.4 アラート設定

```bash
# Alertmanager セットアップ
./scripts/setup-alerting.sh

# アラート確認
kubectl get pods -n monitoring | grep alert
curl http://localhost:9093/api/v1/alerts
```

## 🔒 Phase 5: セキュリティ強化

### 5.1 SSL/TLS 設定

```bash
# SSL証明書セットアップ
./scripts/setup-ssl.sh

# TLS設定確認
kubectl get secret tls-secret -n jupyterhub
openssl x509 -in /tmp/server.crt -text -noout
```

### 5.2 セキュリティスキャン

```bash
# セキュリティスキャン実行
./scripts/security-scan.sh

# セキュリティ状況確認
kubectl get networkpolicies --all-namespaces
kubectl get podsecuritypolicies
```

## 🧪 Phase 6: テスト・検証

### 6.1 統合テスト実行

```bash
# 全テストスイート実行
./tests/infrastructure-tests.sh
./tests/jupyterhub-tests.sh
./tests/performance-tests.sh
./tests/security-tests.sh

# テストレポート確認
ls -la tests/*-report.html
```

### 6.2 機能検証

```bash
# JupyterHub アクセステスト
curl -k https://localhost:8443/hub/health

# Prometheus メトリクス確認
curl http://localhost:9090/api/v1/label/__name__/values

# Grafana ダッシュボード確認
curl -u admin:admin http://localhost:3000/api/health
```

## 🎯 デプロイ後の運用

### アクセス情報

| サービス | URL | 認証情報 |
|---------|-----|---------|
| JupyterHub | https://localhost:8443/hub | OAuth設定による |
| Grafana | http://localhost:3000 | admin/admin |
| Prometheus | http://localhost:9090 | 認証なし |
| Kibana | http://localhost:5601 | 認証なし |
| Alertmanager | http://localhost:9093 | 認証なし |

### 日常運用コマンド

```bash
# システム状況確認
kubectl get pods --all-namespaces
kubectl top nodes
kubectl top pods --all-namespaces

# JupyterHub 管理
kubectl logs -f deployment/jupyterhub -n jupyterhub
kubectl scale deployment jupyterhub --replicas=2 -n jupyterhub

# リソース使用量監視
kubectl describe node
kubectl get events --sort-by='.lastTimestamp'
```

## 🔧 カスタマイゼーション

### JupyterHub 設定変更

```bash
# 設定ファイル編集
kubectl edit configmap jupyterhub-config -n jupyterhub

# 変更適用
kubectl rollout restart deployment/jupyterhub -n jupyterhub
```

### Python 環境カスタマイズ

1. `docker/base-python/requirements-*.txt` 編集
2. イメージ再ビルド
3. レジストリにプッシュ
4. デプロイメント更新

## 🚨 トラブルシューティング

### よくある問題と対処法

#### Pod が起動しない

```bash
# 詳細確認
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>

# リソース不足の場合
kubectl top nodes
kubectl get nodes -o wide
```

#### イメージプルエラー

```bash
# レジストリ確認
curl http://localhost:5000/v2/_catalog
docker ps | grep registry

# レジストリ再起動
docker restart registry
```

#### ネットワーク問題

```bash
# CNI 状況確認
kubectl get pods -n kube-system | grep flannel
kubectl describe node | grep PodCIDR

# DNS 確認
kubectl run test --image=busybox -it --rm -- nslookup kubernetes.default
```

#### ストレージ問題

```bash
# PV/PVC 状況
kubectl get pv,pvc --all-namespaces
kubectl describe pv <volume-name>

# ディスク容量確認
df -h
```

## 📊 パフォーマンスチューニング

### リソース調整

```yaml
# jupyterhub-deployment.yaml
resources:
  requests:
    memory: "2Gi"
    cpu: "1000m"
  limits:
    memory: "4Gi"
    cpu: "2000m"
```

### スケーリング設定

```bash
# 水平スケーリング
kubectl autoscale deployment jupyterhub --cpu-percent=70 --min=1 --max=3 -n jupyterhub

# 垂直スケーリング
kubectl patch deployment jupyterhub -p '{"spec":{"template":{"spec":{"containers":[{"name":"jupyterhub","resources":{"requests":{"memory":"4Gi"}}}]}}}}' -n jupyterhub
```

## 🔄 アップデート・メンテナンス

### 定期メンテナンス

```bash
# システム更新
sudo apt update && sudo apt upgrade -y
sudo kubeadm upgrade plan

# イメージ更新
docker pull <image>:latest
kubectl set image deployment/<name> <container>=<image>:latest
```

### バックアップ

```bash
# etcd バックアップ
sudo ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-$(date +%Y%m%d-%H%M%S).db

# PV データバックアップ
kubectl get pv -o yaml > pv-backup.yaml
```

## 📞 サポート

問題が解決しない場合は、以下の情報と共にサポートにご連絡ください：

- OS バージョンとアーキテクチャ
- Kubernetes バージョン
- エラーメッセージとログ
- 実行したコマンドとその出力
- システムリソース使用状況

---

**成功を祈ります！** 🎉

このガイドに従うことで、本格的な kubeadm Python Cluster 環境を構築できます。