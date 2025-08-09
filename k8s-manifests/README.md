# Kubernetesマニフェスト

このディレクトリには、JupyterHub環境をKubernetes上にデプロイするためのマニフェストファイルが含まれています。

## ディレクトリ構成

```
k8s-manifests/
├── namespace.yaml              # 名前空間定義
├── rbac.yaml                   # RBAC設定
├── storage-class.yaml          # ストレージクラス
├── persistent-volumes.yaml     # 永続ボリューム
├── secrets.yaml               # 機密情報
├── jupyterhub-hub.yaml        # JupyterHub Hub
├── jupyterhub-proxy.yaml      # JupyterHub Proxy
├── network-policies.yaml      # ネットワークポリシー
├── monitoring/                # 監視システム
│   ├── prometheus.yaml
│   └── grafana.yaml
└── logging/                   # ログ集約
    └── fluent-bit.yaml
```

## デプロイ手順

1. 名前空間とRBACの作成
```bash
kubectl apply -f namespace.yaml
kubectl apply -f rbac.yaml
```

2. ストレージ設定
```bash
kubectl apply -f storage-class.yaml
kubectl apply -f persistent-volumes.yaml
```

3. JupyterHubデプロイ
```bash
kubectl apply -f secrets.yaml
kubectl apply -f jupyterhub-hub.yaml
kubectl apply -f jupyterhub-proxy.yaml
```

4. セキュリティポリシー
```bash
kubectl apply -f network-policies.yaml
```