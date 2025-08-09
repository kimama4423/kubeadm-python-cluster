# jupyter_server_config.py
# Base Jupyter Server Configuration

import os

# Server binding
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = 8888
c.ServerApp.open_browser = False

# Authentication
c.ServerApp.token = ''
c.ServerApp.password = ''

# File management
c.ServerApp.allow_origin = '*'
c.ServerApp.tornado_settings = {
    'headers': {
        'Content-Security-Policy': "frame-ancestors 'self' *;"
    }
}

# Logging
c.Application.log_level = 'INFO'