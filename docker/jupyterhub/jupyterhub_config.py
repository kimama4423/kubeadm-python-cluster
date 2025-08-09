# jupyterhub_config.py
# JupyterHub Configuration for kubeadm-python-cluster

import os
import logging
from jupyterhub.spawner import Spawner
from kubespawner import KubeSpawner
from kubernetes import client, config
from datetime import datetime

# ================================================
# Basic JupyterHub Configuration
# ================================================

# JupyterHub server configuration
c.JupyterHub.hub_ip = '0.0.0.0'
c.JupyterHub.hub_port = 8081
c.JupyterHub.port = 8000

# Database configuration
c.JupyterHub.db_url = os.environ.get('JUPYTERHUB_DB_URL', 'sqlite:///jupyterhub.sqlite')

# Cookie secret (should be set via environment variable in production)
c.JupyterHub.cookie_secret_file = '/srv/jupyterhub/jupyterhub_cookie_secret'

# Admin users
c.Authenticator.admin_users = set(os.environ.get('JUPYTERHUB_ADMIN_USERS', 'admin').split(','))

# ================================================
# Kubernetes Integration
# ================================================

# Use KubeSpawner
c.JupyterHub.spawner_class = KubeSpawner

# Kubernetes configuration
c.KubeSpawner.namespace = os.environ.get('JUPYTERHUB_NAMESPACE', 'jupyterhub')
c.KubeSpawner.service_account = 'jupyterhub'

# Container image configuration
c.KubeSpawner.image_spec = os.environ.get('JUPYTERHUB_SINGLEUSER_IMAGE', 'kubeadm-python-cluster/jupyterlab:3.11')

# CPU and memory limits
c.KubeSpawner.cpu_limit = float(os.environ.get('JUPYTERHUB_CPU_LIMIT', '1.0'))
c.KubeSpawner.mem_limit = os.environ.get('JUPYTERHUB_MEM_LIMIT', '2G')
c.KubeSpawner.cpu_guarantee = float(os.environ.get('JUPYTERHUB_CPU_GUARANTEE', '0.5'))
c.KubeSpawner.mem_guarantee = os.environ.get('JUPYTERHUB_MEM_GUARANTEE', '1G')

# Storage configuration
c.KubeSpawner.pvc_name_template = 'jupyterhub-user-{username}'
c.KubeSpawner.volume_mounts = [
    {
        'name': 'home',
        'mountPath': '/home/jovyan',
        'subPath': 'home/{username}'
    }
]
c.KubeSpawner.volumes = [
    {
        'name': 'home',
        'persistentVolumeClaim': {
            'claimName': c.KubeSpawner.pvc_name_template
        }
    }
]

# PVC configuration
c.KubeSpawner.storage_capacity = os.environ.get('JUPYTERHUB_STORAGE_CAPACITY', '5Gi')
c.KubeSpawner.storage_class = os.environ.get('JUPYTERHUB_STORAGE_CLASS', 'standard')

# Environment variables for single-user servers
c.KubeSpawner.environment = {
    'JUPYTER_ENABLE_LAB': '1',
    'GRANT_SUDO': 'yes',
    'NB_UID': '1000',
    'NB_GID': '1000',
    'CHOWN_HOME': 'yes',
    'PYTHONPATH': '/usr/local/lib/python3.11/site-packages',
}

# Security context
c.KubeSpawner.security_context = {
    'runAsUser': 1000,
    'runAsGroup': 1000,
    'fsGroup': 1000,
}

# ================================================
# Authentication Configuration
# ================================================

# Use native authenticator (can be changed to LDAP, OAuth, etc.)
from jupyterhub.auth import Authenticator

# Native authenticator for simple setup
c.JupyterHub.authenticator_class = 'nativeauthenticator.NativeAuthenticator'
c.NativeAuthenticator.create_users = True
c.NativeAuthenticator.enable_signup = os.environ.get('JUPYTERHUB_ENABLE_SIGNUP', 'True').lower() == 'true'

# Optional: LDAP Authentication
# Uncomment and configure if LDAP is available
# c.JupyterHub.authenticator_class = 'ldapauthenticator.LDAPAuthenticator'
# c.LDAPAuthenticator.server_hosts = ['ldap://ldap.example.com:389']
# c.LDAPAuthenticator.bind_dn_template = 'uid={username},ou=users,dc=example,dc=com'

# ================================================
# Profile Configuration (Multi-Python Support)
# ================================================

# Profile list for different Python versions
c.KubeSpawner.profile_list = [
    {
        'display_name': 'Python 3.11 (Default)',
        'description': 'Latest Python with modern libraries',
        'default': True,
        'kubespawner_override': {
            'image_spec': 'kubeadm-python-cluster/jupyterlab:3.11',
            'cpu_limit': 1.0,
            'mem_limit': '2G',
            'cpu_guarantee': 0.5,
            'mem_guarantee': '1G',
        }
    },
    {
        'display_name': 'Python 3.10',
        'description': 'Python 3.10 with stable libraries',
        'kubespawner_override': {
            'image_spec': 'kubeadm-python-cluster/jupyterlab:3.10',
            'cpu_limit': 1.0,
            'mem_limit': '2G',
            'cpu_guarantee': 0.5,
            'mem_guarantee': '1G',
        }
    },
    {
        'display_name': 'Python 3.9',
        'description': 'Python 3.9 with compatible libraries',
        'kubespawner_override': {
            'image_spec': 'kubeadm-python-cluster/jupyterlab:3.9',
            'cpu_limit': 1.0,
            'mem_limit': '2G',
            'cpu_guarantee': 0.5,
            'mem_guarantee': '1G',
        }
    },
    {
        'display_name': 'Python 3.8 (Legacy)',
        'description': 'Python 3.8 for legacy compatibility',
        'kubespawner_override': {
            'image_spec': 'kubeadm-python-cluster/jupyterlab:3.8',
            'cpu_limit': 0.8,
            'mem_limit': '1.5G',
            'cpu_guarantee': 0.3,
            'mem_guarantee': '0.5G',
        }
    },
    {
        'display_name': 'High-Performance Computing',
        'description': 'Python 3.11 with extended resources for compute-intensive tasks',
        'kubespawner_override': {
            'image_spec': 'kubeadm-python-cluster/jupyterlab:3.11',
            'cpu_limit': 2.0,
            'mem_limit': '4G',
            'cpu_guarantee': 1.0,
            'mem_guarantee': '2G',
            'environment': {
                'JUPYTER_ENABLE_LAB': '1',
                'GRANT_SUDO': 'yes',
                'OMP_NUM_THREADS': '2',
                'NUMBA_NUM_THREADS': '2',
            }
        }
    }
]

# ================================================
# Logging Configuration
# ================================================

c.JupyterHub.log_level = logging.INFO
c.JupyterHub.log_format = '[%(levelname)s %(asctime)s.%(msecs)03d %(name)s %(module)s:%(lineno)d] %(message)s'

# Application log file
c.JupyterHub.extra_log_file = '/var/log/jupyterhub/jupyterhub.log'

# ================================================
# Service Configuration
# ================================================

# Idle server culling
c.JupyterHub.services = [
    {
        'name': 'idle-culler',
        'command': [
            'python3', '-m', 'jupyterhub_idle_culler',
            '--timeout=3600',  # 1 hour timeout
            '--max-age=7200',  # 2 hours max age
            '--remove-named-servers',
            '--cull-users',
        ],
        'admin': True,
    }
]

# ================================================
# UI Customization
# ================================================

c.JupyterHub.logo_file = '/etc/jupyterhub/static/logo.png'
c.JupyterHub.template_paths = ['/etc/jupyterhub/templates']

# Custom page template variables
c.JupyterHub.template_vars = {
    'announcement': os.environ.get('JUPYTERHUB_ANNOUNCEMENT', ''),
    'org_name': 'kubeadm-python-cluster',
    'org_url': '#',
}

# ================================================
# Network and Proxy Configuration
# ================================================

# Proxy configuration
c.JupyterHub.cleanup_servers = True
c.JupyterHub.cleanup_proxy = True

# Hub activity check interval (seconds)
c.JupyterHub.activity_resolution = 30

# ================================================
# Security Configuration
# ================================================

# Redirect to HTTPS (if SSL is configured)
if os.environ.get('JUPYTERHUB_SSL_CERT'):
    c.JupyterHub.ssl_cert = os.environ.get('JUPYTERHUB_SSL_CERT')
    c.JupyterHub.ssl_key = os.environ.get('JUPYTERHUB_SSL_KEY')
    c.JupyterHub.redirect_to_server = False

# CSRF protection
c.JupyterHub.tornado_settings = {
    'headers': {
        'Content-Security-Policy': "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval'"
    }
}

# ================================================
# Custom Hooks and Events
# ================================================

def pre_spawn_hook(spawner):
    """
    Custom pre-spawn hook to set up user environment
    """
    username = spawner.user.name
    spawner.log.info(f"Pre-spawn hook for user: {username}")
    
    # Add custom environment variables based on user
    if username in c.Authenticator.admin_users:
        spawner.environment['JUPYTER_ADMIN'] = '1'
    
    # Log spawn event
    spawner.log.info(f"Starting server for {username} at {datetime.now()}")

def post_stop_hook(spawner):
    """
    Custom post-stop hook for cleanup
    """
    username = spawner.user.name
    spawner.log.info(f"Server stopped for {username} at {datetime.now()}")

c.KubeSpawner.pre_spawn_hook = pre_spawn_hook
c.KubeSpawner.post_stop_hook = post_stop_hook

# ================================================
# Development and Debugging
# ================================================

# Enable debug mode in development
if os.environ.get('JUPYTERHUB_DEBUG', 'False').lower() == 'true':
    c.JupyterHub.log_level = logging.DEBUG
    c.Application.log_level = logging.DEBUG
    
# Startup message
c.JupyterHub.log.info("JupyterHub for kubeadm-python-cluster starting up...")
c.JupyterHub.log.info(f"Using spawner: {c.JupyterHub.spawner_class}")
c.JupyterHub.log.info(f"Database URL: {c.JupyterHub.db_url}")
c.JupyterHub.log.info(f"Kubernetes namespace: {c.KubeSpawner.namespace}")

# ================================================
# Health Check Configuration
# ================================================

# Health check service
c.JupyterHub.services.append({
    'name': 'health-check',
    'url': 'http://0.0.0.0:8082',
    'command': ['python3', '-c', '''
import json
import tornado.web
import tornado.ioloop
from tornado.httpserver import HTTPServer

class HealthHandler(tornado.web.RequestHandler):
    def get(self):
        self.write({"status": "ok", "timestamp": "2025-01-09"})

app = tornado.web.Application([
    (r"/health", HealthHandler),
])

if __name__ == "__main__":
    server = HTTPServer(app)
    server.listen(8082)
    tornado.ioloop.IOLoop.current().start()
'''],
    'admin': False,
})