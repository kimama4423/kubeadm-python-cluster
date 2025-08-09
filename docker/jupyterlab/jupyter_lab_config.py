# jupyter_lab_config.py
# JupyterLab Configuration for Single-User Servers

import os
from pathlib import Path

# ================================================
# Basic JupyterLab Configuration
# ================================================

# Server configuration
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = int(os.environ.get('JUPYTER_PORT', 8888))
c.ServerApp.open_browser = False
c.ServerApp.allow_root = False

# Base URL configuration
c.ServerApp.base_url = os.environ.get('JUPYTER_BASE_URL', '/')

# Token and password configuration
c.ServerApp.token = os.environ.get('JUPYTER_TOKEN', '')
c.ServerApp.password = os.environ.get('JUPYTER_PASSWORD', '')

# Disable authentication for JupyterHub managed sessions
if os.environ.get('JUPYTERHUB_API_TOKEN'):
    c.ServerApp.disable_check_xsrf = True

# ================================================
# File and Directory Configuration
# ================================================

# Root directory for notebooks
c.ServerApp.root_dir = os.environ.get('JUPYTER_ROOT_DIR', '/home/jovyan')

# Allow hidden files
c.ContentsManager.allow_hidden = True

# File save hooks
c.FileContentsManager.pre_save_hook = lambda model, **kwargs: None

# ================================================
# Security Configuration
# ================================================

# CORS settings for JupyterHub
c.ServerApp.allow_origin = '*'
c.ServerApp.allow_credentials = True

# Content Security Policy
c.ServerApp.tornado_settings = {
    'headers': {
        'Content-Security-Policy': "frame-ancestors 'self' *"
    }
}

# ================================================
# Kernel Configuration
# ================================================

# Kernel timeout settings
c.MappingKernelManager.cull_idle_timeout = int(os.environ.get('JUPYTER_KERNEL_TIMEOUT', 3600))
c.MappingKernelManager.cull_interval = 300
c.MappingKernelManager.cull_connected = True

# ================================================
# JupyterLab Specific Settings
# ================================================

# Default interface (Lab vs Notebook)
c.ServerApp.default_url = '/lab'

# Extension configuration
c.LabApp.check_for_updates_class = 'jupyterlab.NeverCheckForUpdate'

# Workspace settings
c.LabApp.user_settings_dir = os.path.join(c.ServerApp.root_dir, '.jupyter/lab/user-settings')
c.LabApp.workspaces_dir = os.path.join(c.ServerApp.root_dir, '.jupyter/lab/workspaces')

# ================================================
# Performance Settings
# ================================================

# Memory limits
c.ResourceUseDisplay.mem_limit = int(os.environ.get('MEM_LIMIT', 2147483648))  # 2GB default

# CPU monitoring
c.ResourceUseDisplay.track_cpu_percent = True

# ================================================
# Logging Configuration
# ================================================

# Log level
c.Application.log_level = os.environ.get('JUPYTER_LOG_LEVEL', 'INFO')

# Log format
c.Application.log_format = '[%(levelname)1.1s %(asctime)s.%(msecs).03d %(name)s] %(message)s'

# ================================================
# Extension and Plugin Settings
# ================================================

# Git extension settings
c.GitConfig.git_dir = c.ServerApp.root_dir

# Table of contents settings
c.LabApp.toc_extensions = ['markdown', 'python']

# ================================================
# User Interface Customization
# ================================================

# Theme settings
c.LabApp.default_theme = os.environ.get('JUPYTER_LAB_THEME', 'JupyterLab Light')

# Shutdown behavior
c.ServerApp.shutdown_no_activity_timeout = int(os.environ.get('JUPYTER_SHUTDOWN_TIMEOUT', 0))

# ================================================
# Collaborative Features
# ================================================

if os.environ.get('JUPYTER_ENABLE_COLLABORATION', 'false').lower() == 'true':
    c.LabApp.collaborative = True
    c.YDocExtension.ystore_class = 'jupyter_collaboration.stores.SQLiteYStore'

# ================================================
# Development and Debug Settings
# ================================================

# Debug mode
if os.environ.get('JUPYTER_DEBUG', 'false').lower() == 'true':
    c.Application.log_level = 'DEBUG'
    c.ServerApp.allow_remote_access = True

# ================================================
# Notebook Configuration
# ================================================

# Notebook settings
c.NotebookNotary.db_file = os.path.join(c.ServerApp.root_dir, '.jupyter/nbsignatures.db')

# Autosave settings
c.ContentsManager.autosave_interval = 120  # seconds

# ================================================
# Custom Hooks and Startup
# ================================================

def setup_user_environment():
    """
    Set up user environment on startup
    """
    user_home = Path.home()
    
    # Create common directories
    directories = [
        user_home / 'notebooks',
        user_home / 'data',
        user_home / 'projects',
        user_home / '.jupyter/custom'
    ]
    
    for directory in directories:
        directory.mkdir(parents=True, exist_ok=True)
    
    # Create sample notebook if it doesn't exist
    sample_notebook = user_home / 'notebooks' / 'Welcome.ipynb'
    if not sample_notebook.exists():
        import json
        welcome_content = {
            "cells": [
                {
                    "cell_type": "markdown",
                    "metadata": {},
                    "source": [
                        "# Welcome to kubeadm-python-cluster JupyterLab!\n\n",
                        "This is your personal Jupyter environment running on Kubernetes.\n\n",
                        "## Getting Started\n\n",
                        "- This notebook is running Python " + os.environ.get('PYTHON_VERSION', '3.11') + "\n",
                        "- Your home directory: `" + str(user_home) + "`\n",
                        "- Available libraries: numpy, pandas, matplotlib, scikit-learn, and many more!\n\n",
                        "## Directories\n\n",
                        "- `notebooks/` - Store your Jupyter notebooks here\n",
                        "- `data/` - Store datasets and data files\n",
                        "- `projects/` - Organize your code projects\n\n",
                        "Happy coding! 🚀"
                    ]
                },
                {
                    "cell_type": "code",
                    "execution_count": None,
                    "metadata": {},
                    "outputs": [],
                    "source": [
                        "# Quick environment check\n",
                        "import sys\n",
                        "import numpy as np\n",
                        "import pandas as pd\n",
                        "import matplotlib.pyplot as plt\n",
                        "\n",
                        "print(f\"Python version: {sys.version}\")\n",
                        "print(f\"NumPy version: {np.__version__}\")\n",
                        "print(f\"Pandas version: {pd.__version__}\")\n",
                        "print(\"\\nEnvironment is ready! 🎉\")"
                    ]
                }
            ],
            "metadata": {
                "kernelspec": {
                    "display_name": f"Python {os.environ.get('PYTHON_VERSION', '3.11')}",
                    "language": "python",
                    "name": "python3"
                },
                "language_info": {
                    "name": "python",
                    "version": os.environ.get('PYTHON_VERSION', '3.11')
                }
            },
            "nbformat": 4,
            "nbformat_minor": 4
        }
        
        with open(sample_notebook, 'w') as f:
            json.dump(welcome_content, f, indent=2)

# Execute setup on startup
try:
    setup_user_environment()
except Exception as e:
    print(f"Warning: Could not set up user environment: {e}")

# ================================================
# Startup Message
# ================================================

print("=" * 50)
print("JupyterLab for kubeadm-python-cluster")
print(f"Python version: {os.environ.get('PYTHON_VERSION', 'Unknown')}")
print(f"User: {os.environ.get('NB_USER', 'jovyan')}")
print(f"Home directory: {c.ServerApp.root_dir}")
print("=" * 50)