# Dockerイメージ

このディレクトリには、JupyterHub環境用のDockerイメージ定義が含まれています。

## イメージ構成

### python-base/
複数のPythonバージョン（3.8, 3.9, 3.10, 3.11）を含むベースイメージ

### jupyterhub-hub/
JupyterHub Hub用のカスタマイズされたイメージ

### jupyter-python3.x/
各Pythonバージョン用のJupyterLabユーザー環境イメージ
- jupyter-python3.8/
- jupyter-python3.9/
- jupyter-python3.10/
- jupyter-python3.11/

## ビルド手順

```bash
# ベースイメージのビルド
cd python-base/
docker build -t kubeadm-python-cluster/python-base:latest .

# JupyterHub Hubイメージのビルド
cd ../jupyterhub-hub/
docker build -t kubeadm-python-cluster/jupyterhub-hub:latest .

# ユーザー環境イメージのビルド
cd ../jupyter-python3.10/
docker build -t kubeadm-python-cluster/jupyter-python3.10:latest .
```