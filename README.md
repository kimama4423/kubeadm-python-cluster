# kubeadm Python Cluster

Production-ready JupyterHub システムを kubeadm ベースの Kubernetes クラスター上で構築するための包括的なソリューション

## 🎯 プロジェクト概要

このプロジェクトは、既存の k3s ベース JupyterHub システムを kubeadm ベースの Kubernetes クラスターに移行し、マルチ Python バージョン（3.8, 3.9, 3.10, 3.11）をサポートする本格的な機械学習・データサイエンス環境を提供します。

### 主な機能

- 🐍 **マルチ Python バージョンサポート** - Python 3.8, 3.9, 3.10, 3.11
- 🏗️ **kubeadm Kubernetes クラスター** - 本格的な Kubernetes 環境
- 📊 **JupyterHub 4.0.2** - 最新版による多人数ノートブック環境
- 🔒 **Enterprise セキュリティ** - RBAC, Network Policies, Pod Security
- 📈 **包括的監視** - Prometheus + Grafana + Alertmanager
- 📝 **統合ログ管理** - EFK Stack (Elasticsearch + Fluentd + Kibana)
- 🧪 **包括的テストスイート** - インフラ、機能、パフォーマンス、セキュリティテスト

## 📋 システム要件

### ハードウェア要件
- **CPU**: 最小 4コア、推奨 8コア以上
- **メモリ**: 最小 8GB、推奨 16GB以上
- **ストレージ**: 最小 100GB、推奨 500GB以上（SSD推奨）
- **ネットワーク**: インターネット接続必須

### ソフトウェア要件
- **OS**: Ubuntu 20.04/22.04 LTS, CentOS 8+, RHEL 8+
- **アーキテクチャ**: x86_64/amd64

## 🚀 クイックスタート

### 1. システム準備

```bash
# プロジェクトクローン
git clone <repository-url>
cd kubeadm-python-cluster

# システム要件チェック
sudo ./setup/check-prerequisites.sh
```

### 2. インフラストラクチャセットアップ

```bash
# Docker インストール
sudo ./setup/install-docker.sh

# Kubernetes インストール
sudo ./setup/install-kubernetes.sh

# クラスター初期化
sudo ./setup/init-cluster.sh

# CNI セットアップ
sudo ./setup/setup-networking.sh
```

### 3. コンテナイメージ構築

```bash
# コンテナレジストリセットアップ
sudo ./scripts/setup-registry.sh

# Python イメージ作成
cd docker/base-python
sudo ./build-images.sh

# JupyterHub イメージ作成
cd ../jupyterhub
sudo docker build -t localhost:5000/jupyterhub:latest .
```

### 4. JupyterHub デプロイ

```bash
# Kubernetes リソースデプロイ
kubectl apply -f k8s-manifests/

# デプロイ状況確認
kubectl get pods -n jupyterhub
```

### 5. 監視・ログシステムセットアップ

```bash
# Prometheus 監視
./scripts/setup-prometheus.sh

# Grafana ダッシュボード
./scripts/setup-grafana.sh

# EFK ログシステム
./scripts/setup-logging.sh

# アラート設定
./scripts/setup-alerting.sh
```

## 📁 プロジェクト構造

```
kubeadm-python-cluster/
├── setup/                   # システムセットアップスクリプト
│   ├── check-prerequisites.sh
│   ├── install-docker.sh
│   ├── install-kubernetes.sh
│   ├── init-cluster.sh
│   └── setup-networking.sh
├── config/                  # クラスター設定ファイル
│   └── kubeadm-config.yaml
├── scripts/                 # 運用・管理スクリプト
│   ├── deploy-jupyterhub.sh
│   ├── manage-deployment.sh
│   ├── security-scan.sh
│   ├── setup-prometheus.sh
│   ├── setup-grafana.sh
│   ├── setup-logging.sh
│   ├── setup-alerting.sh
│   ├── setup-registry.sh
│   └── setup-ssl.sh
├── docker/                  # コンテナイメージ定義
│   ├── base-python/         # Python基盤イメージ
│   ├── jupyterhub/         # JupyterHub イメージ
│   └── jupyterlab/         # JupyterLab拡張イメージ
├── k8s-manifests/          # Kubernetes マニフェスト
│   ├── namespace.yaml
│   ├── rbac.yaml
│   ├── storage.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── jupyterhub-deployment.yaml
│   ├── service.yaml
│   ├── network-policies.yaml
│   └── security-context.yaml
├── tests/                  # テストスイート
│   ├── infrastructure-tests.sh
│   ├── jupyterhub-tests.sh
│   ├── performance-tests.sh
│   └── security-tests.sh
└── docs/                   # プロジェクトドキュメント
    ├── deployment-guide.md
    ├── configuration-guide.md
    ├── troubleshooting.md
    └── security-guide.md
```

## 🔧 設定

### JupyterHub 設定

主要な設定は `docker/jupyterhub/jupyterhub_config.py` で管理されます：

```python
# マルチ Python バージョンサポート
c.KubeSpawner.profile_list = [
    {
        'display_name': 'Python 3.11 (Latest)',
        'kubespawner_override': {
            'image': 'localhost:5000/jupyter-python:3.11'
        }
    },
    # ... その他のバージョン
]

# セキュリティ設定
c.KubeSpawner.security_context = {
    'runAsUser': 1000,
    'runAsGroup': 100,
    'fsGroup': 100,
    'runAsNonRoot': True
}
```

## 🧪 テスト

### 統合テスト実行

```bash
# インフラストラクチャテスト
./tests/infrastructure-tests.sh

# JupyterHub 機能テスト
./tests/jupyterhub-tests.sh

# パフォーマンステスト
./tests/performance-tests.sh

# セキュリティテスト
./tests/security-tests.sh
```

### テストレポート

各テストは HTML レポートを生成：
- `tests/infrastructure-test-report.html`
- `tests/jupyterhub-test-report.html`
- `tests/performance-test-report.html`
- `tests/security-test-report.html`

## 📊 監視・アラート

### アクセス情報

| サービス | URL | 認証 |
|----------|-----|------|
| JupyterHub | https://localhost:8443/hub | OAuth/LDAP設定による |
| Grafana | http://localhost:3000 | admin/admin (初期) |
| Prometheus | http://localhost:9090 | 認証なし |
| Kibana | http://localhost:5601 | 認証なし |

### 主要メトリクス

- **クラスター健全性**: ノード状態、Pod 状況、リソース使用率
- **JupyterHub**: ユーザーセッション、スポーン時間、リソース消費
- **パフォーマンス**: API レスポンス時間、ストレージ I/O、ネットワーク遅延
- **セキュリティ**: 不正アクセス試行、コンプライアンス状況

## 🔒 セキュリティ

### セキュリティ機能

- **RBAC**: 最小権限の原則に基づく役割ベースアクセス制御
- **Network Policies**: マイクロセグメンテーションによるネットワーク分離
- **Pod Security**: 非特権実行、読み取り専用ファイルシステム
- **TLS/SSL**: 全通信の暗号化
- **CIS Compliance**: CIS Kubernetes Benchmark 準拠

### セキュリティテスト

```bash
# セキュリティ評価実行
./tests/security-tests.sh

# レポート確認
firefox tests/security-test-report.html
```

## 🚨 トラブルシューティング

### よくある問題

#### 1. Pod が起動しない
```bash
# Pod の状態確認
kubectl describe pod <pod-name> -n <namespace>

# ログ確認
kubectl logs <pod-name> -n <namespace>
```

#### 2. イメージプルエラー
```bash
# レジストリ接続確認
curl -f http://localhost:5000/v2/_catalog

# レジストリ再起動
docker restart registry
```

#### 3. ストレージ問題
```bash
# PVC 状態確認
kubectl get pvc --all-namespaces

# StorageClass 確認
kubectl get storageclass
```

## 📚 詳細ドキュメント

- 📖 [実装ログ](docs/IMPLEMENTATION_LOG.md) - 開発進捗と技術的決定事項
- ⚙️ [設定ガイド] - カスタマイズ方法（開発中）
- 🔧 [トラブルシューティング] - 問題解決方法（開発中）
- 🛡️ [セキュリティガイド] - セキュリティベストプラクティス（開発中）

## 🤝 貢献

プロジェクトへの貢献を歓迎します：

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📄 ライセンス

このプロジェクトは MIT ライセンスの下で公開されています。

---

**🎉 Happy Coding with kubeadm Python Cluster!**

本プロジェクトは、現代的なコンテナオーケストレーション技術を活用した、スケーラブルで安全なデータサイエンス環境の構築を目指しています。