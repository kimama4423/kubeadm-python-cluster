# 運用スクリプト

このディレクトリには、クラスター運用のためのスクリプトが含まれています。

## スクリプト一覧

- `backup-data.sh` - ユーザーデータバックアップ
- `restore-data.sh` - データ復旧
- `monitor-cluster.sh` - クラスター監視
- `cleanup-resources.sh` - リソース清理
- `update-images.sh` - コンテナイメージ更新

## バックアップ・復旧

### バックアップ
```bash
./backup-data.sh
```

### 復旧
```bash
./restore-data.sh /path/to/backup
```

## 監視
```bash
./monitor-cluster.sh
```