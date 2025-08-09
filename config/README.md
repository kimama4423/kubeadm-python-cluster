# 設定ファイル

このディレクトリには、Kubernetesクラスターの設定ファイルが含まれています。

## ファイル一覧

- `kubeadm-config.yaml` - kubeadmクラスター初期化設定
- `jupyterhub-config.yaml` - JupyterHub設定
- `network-policies.yaml` - ネットワークセキュリティポリシー
- `storage-config.yaml` - ストレージクラス設定

## 設定の概要

### kubeadm設定
- Pod CIDR: 10.244.0.0/16 (Flannel用)
- Service CIDR: 10.96.0.0/12
- Kubernetes バージョン: 1.28.x

### JupyterHub設定
- 複数Pythonバージョンサポート (3.8, 3.9, 3.10, 3.11)
- ユーザー環境分離
- リソース制限設定