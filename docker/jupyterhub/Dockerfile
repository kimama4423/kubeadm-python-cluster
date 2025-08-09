# Dockerfile
# JupyterHub専用イメージ for kubeadm-python-cluster

FROM kubeadm-python-cluster/base-python:3.11

# メタデータ
LABEL maintainer="kubeadm-python-cluster"
LABEL application="JupyterHub"
LABEL version="4.0.2"
LABEL image.type="jupyterhub"
LABEL build.date="2025-01-09"

# 環境変数設定
ENV JUPYTERHUB_VERSION=4.0.2
ENV JUPYTERHUB_PORT=8000
ENV JUPYTERHUB_HUB_PORT=8081
ENV JUPYTERHUB_CONFIG_DIR=/etc/jupyterhub
ENV JUPYTERHUB_DATA_DIR=/srv/jupyterhub
ENV JUPYTERHUB_LOG_LEVEL=INFO

# rootユーザーに戻る（JupyterHubのセットアップに必要）
USER root

# 作業ディレクトリ設定
WORKDIR /srv/jupyterhub

# JupyterHub設定ディレクトリ作成
RUN mkdir -p $JUPYTERHUB_CONFIG_DIR $JUPYTERHUB_DATA_DIR \
    && chown -R pythonuser:pythonuser $JUPYTERHUB_CONFIG_DIR $JUPYTERHUB_DATA_DIR

# Node.js インストール（configurable-http-proxyに必要）
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g configurable-http-proxy@^4.5.4 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# JupyterHub関連パッケージインストール
COPY requirements-jupyterhub.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements-jupyterhub.txt \
    && rm /tmp/requirements-jupyterhub.txt

# JupyterHub設定ファイル
COPY jupyterhub_config.py $JUPYTERHUB_CONFIG_DIR/
COPY templates/ $JUPYTERHUB_CONFIG_DIR/templates/
COPY static/ $JUPYTERHUB_CONFIG_DIR/static/

# 起動スクリプト
COPY start-jupyterhub.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/start-jupyterhub.sh

# JupyterHub用ユーザー作成
RUN useradd -r -s /bin/bash -d $JUPYTERHUB_DATA_DIR jupyterhub \
    && mkdir -p $JUPYTERHUB_DATA_DIR \
    && chown -R jupyterhub:jupyterhub $JUPYTERHUB_DATA_DIR

# SSL証明書ディレクトリ準備
RUN mkdir -p /etc/jupyterhub/ssl \
    && chown -R jupyterhub:jupyterhub /etc/jupyterhub/ssl

# ログディレクトリ準備
RUN mkdir -p /var/log/jupyterhub \
    && chown -R jupyterhub:jupyterhub /var/log/jupyterhub

# パーミッション設定
RUN chown -R jupyterhub:jupyterhub $JUPYTERHUB_CONFIG_DIR \
    && chmod -R 755 $JUPYTERHUB_CONFIG_DIR

# ポート公開
EXPOSE $JUPYTERHUB_PORT $JUPYTERHUB_HUB_PORT

# ヘルスチェック
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:$JUPYTERHUB_PORT/hub/health || exit 1

# jupyterhubユーザーに切り替え
USER jupyterhub

# デフォルトコマンド
CMD ["/usr/local/bin/start-jupyterhub.sh"]