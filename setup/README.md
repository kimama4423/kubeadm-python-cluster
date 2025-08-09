# セットアップスクリプト

このディレクトリには、kubeadm-python-cluster環境の自動セットアップスクリプトが含まれています。

## スクリプト一覧

- `check-prerequisites.sh` - システム要件チェック
- `install-docker.sh` - Docker自動インストール
- `install-kubernetes.sh` - Kubernetes (kubeadm, kubectl) インストール
- `init-cluster.sh` - Kubernetesクラスター初期化
- `setup-networking.sh` - CNIネットワーク設定
- `setup-ingress.sh` - Ingressコントローラー設定
- `setup-registry.sh` - コンテナレジストリ設定

## 実行順序

1. `check-prerequisites.sh` - システム要件確認
2. `install-docker.sh` - Docker環境構築
3. `install-kubernetes.sh` - Kubernetes環境構築
4. `init-cluster.sh` - クラスター初期化
5. `setup-networking.sh` - ネットワーク設定
6. その他のスクリプトを必要に応じて実行

## 使用方法

```bash
cd setup/
chmod +x *.sh
./check-prerequisites.sh
```