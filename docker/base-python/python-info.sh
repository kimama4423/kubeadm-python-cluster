#!/bin/bash
# python-info.sh
# Python環境情報表示スクリプト

echo "======================================"
echo "Python Environment Information"
echo "======================================"

# Python基本情報
echo "Python Version: $(python --version)"
echo "Python Executable: $(which python)"
echo "Python Path: $PYTHONPATH"

echo ""
echo "=== System Information ==="
uname -a
echo "Architecture: $(uname -m)"

echo ""
echo "=== Installed Python Packages ==="
pip list | head -20

echo ""
echo "=== Core Package Versions ==="
python -c "
try:
    import numpy as np
    print(f'NumPy: {np.__version__}')
except ImportError:
    print('NumPy: Not installed')

try:
    import pandas as pd
    print(f'Pandas: {pd.__version__}')
except ImportError:
    print('Pandas: Not installed')

try:
    import matplotlib
    print(f'Matplotlib: {matplotlib.__version__}')
except ImportError:
    print('Matplotlib: Not installed')

try:
    import jupyter
    print(f'Jupyter: {jupyter.__version__}')
except ImportError:
    print('Jupyter: Not installed')

try:
    import sklearn
    print(f'Scikit-learn: {sklearn.__version__}')
except ImportError:
    print('Scikit-learn: Not installed')
"

echo ""
echo "=== Memory Information ==="
free -h

echo ""
echo "=== Current Working Directory ==="
pwd
ls -la

echo ""
echo "=== Environment Variables ==="
env | grep -E "^(PYTHON|PATH|LANG|LC_)" | sort

echo "======================================"
echo "Python environment is ready!"
echo "======================================"