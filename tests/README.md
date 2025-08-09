# テストスイート

このディレクトリには、kubeadm-python-cluster環境の包括的なテストスイートが含まれています。

## テストディレクトリ構成

```
tests/
├── infrastructure/     # インフラ統合テスト
├── jupyterhub/        # JupyterHub機能テスト
├── performance/       # パフォーマンステスト
├── security/          # セキュリティテスト
├── e2e/              # エンドツーエンドテスト
└── fixtures/         # テストデータ・設定
```

## テスト実行

### 全テスト実行
```bash
./run-all-tests.sh
```

### カテゴリ別テスト実行
```bash
# インフラテスト
cd infrastructure/
./test-runner.sh

# JupyterHubテスト
cd jupyterhub/
python -m pytest test_suite.py

# セキュリティテスト
cd security/
./security-scan.sh
```

## テスト要件

- Python 3.8+ (テストスクリプト用)
- pytest (Python テスト)
- selenium (WebUIテスト)
- kubectl (Kubernetesテスト)

## カバレッジ目標

- インフラ機能: 95%
- セキュリティポリシー: 100%
- JupyterHub機能: 90%