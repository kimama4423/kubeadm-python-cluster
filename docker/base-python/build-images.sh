#!/bin/bash
# build-images.sh
# ベースPythonイメージビルドスクリプト

set -euo pipefail

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# グローバル変数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/build-images.log"
REGISTRY_PREFIX="${REGISTRY_PREFIX:-kubeadm-python-cluster}"
BUILD_ARGS="${BUILD_ARGS:-}"
NO_CACHE="${NO_CACHE:-false}"

# Pythonバージョン定義
PYTHON_VERSIONS=(
    "3.8:3.8.18"
    "3.9:3.9.18"
    "3.10:3.10.13"
    "3.11:3.11.7"
)

# ログ関数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}Base Python Images Build Script${NC}"
    echo -e "${BLUE}kubeadm-python-cluster${NC}"
    echo -e "${BLUE}================================${NC}"
    log "Starting base Python images build process"
}

print_status() {
    local status=$1
    local message=$2
    
    case $status in
        "INFO")
            echo -e "ℹ️  ${BLUE}$message${NC}"
            log "INFO: $message"
            ;;
        "SUCCESS")
            echo -e "✅ ${GREEN}$message${NC}"
            log "SUCCESS: $message"
            ;;
        "WARNING")
            echo -e "⚠️  ${YELLOW}$message${NC}"
            log "WARNING: $message"
            ;;
        "ERROR")
            echo -e "❌ ${RED}$message${NC}"
            log "ERROR: $message"
            ;;
    esac
}

# Docker環境チェック
check_docker() {
    print_status "INFO" "Checking Docker environment..."
    
    if ! command -v docker >/dev/null 2>&1; then
        print_status "ERROR" "Docker not found. Please install Docker first"
        exit 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        print_status "ERROR" "Docker daemon is not running"
        exit 1
    fi
    
    local docker_version=$(docker --version | awk '{print $3}' | sed 's/,//')
    print_status "SUCCESS" "Docker found: $docker_version"
}

# 必要ファイル確認
check_build_files() {
    print_status "INFO" "Checking build files..."
    
    local missing_files=()
    
    for version_info in "${PYTHON_VERSIONS[@]}"; do
        local version=$(echo "$version_info" | cut -d: -f1)
        local dockerfile="Dockerfile.python$version"
        local requirements="requirements-base-python${version//./}.txt"
        
        if [[ ! -f "$SCRIPT_DIR/$dockerfile" ]]; then
            missing_files+=("$dockerfile")
        fi
        
        if [[ ! -f "$SCRIPT_DIR/$requirements" ]]; then
            missing_files+=("$requirements")
        fi
    done
    
    if [[ ! -f "$SCRIPT_DIR/python-info.sh" ]]; then
        missing_files+=("python-info.sh")
    fi
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        print_status "ERROR" "Missing required files:"
        for file in "${missing_files[@]}"; do
            echo "  - $file"
        done
        exit 1
    fi
    
    print_status "SUCCESS" "All required build files found"
}

# 単一イメージビルド
build_image() {
    local version=$1
    local full_version=$2
    local dockerfile="Dockerfile.python$version"
    local image_name="$REGISTRY_PREFIX/base-python:$version"
    local image_name_full="$REGISTRY_PREFIX/base-python:$full_version"
    
    print_status "INFO" "Building Python $version image..."
    log "Building image: $image_name"
    log "Using dockerfile: $dockerfile"
    
    # ビルド引数の準備
    local build_cmd="docker build"
    
    if [[ "$NO_CACHE" == "true" ]]; then
        build_cmd="$build_cmd --no-cache"
    fi
    
    if [[ -n "$BUILD_ARGS" ]]; then
        build_cmd="$build_cmd $BUILD_ARGS"
    fi
    
    # タグ設定
    build_cmd="$build_cmd -t $image_name -t $image_name_full"
    build_cmd="$build_cmd -f $dockerfile ."
    
    # ビルド実行
    local start_time=$(date +%s)
    if eval "$build_cmd" 2>&1 | tee -a "$LOG_FILE"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        print_status "SUCCESS" "Python $version image built successfully (${duration}s)"
        
        # イメージサイズ確認
        local image_size=$(docker images "$image_name" --format "{{.Size}}" | head -1)
        log "Image size: $image_size"
        
        return 0
    else
        print_status "ERROR" "Failed to build Python $version image"
        return 1
    fi
}

# イメージテスト
test_image() {
    local version=$1
    local image_name="$REGISTRY_PREFIX/base-python:$version"
    
    print_status "INFO" "Testing Python $version image..."
    
    # 基本的な動作テスト
    if docker run --rm "$image_name" python -c "import sys; print(f'Python {sys.version}')" >/dev/null 2>&1; then
        print_status "SUCCESS" "Python $version image test passed"
        return 0
    else
        print_status "ERROR" "Python $version image test failed"
        return 1
    fi
}

# 全イメージビルド
build_all_images() {
    print_status "INFO" "Building all Python base images..."
    
    local successful_builds=()
    local failed_builds=()
    
    for version_info in "${PYTHON_VERSIONS[@]}"; do
        local version=$(echo "$version_info" | cut -d: -f1)
        local full_version=$(echo "$version_info" | cut -d: -f2)
        
        echo ""
        echo -e "${BLUE}=== Building Python $version ===${NC}"
        
        if build_image "$version" "$full_version"; then
            if test_image "$version"; then
                successful_builds+=("$version")
            else
                failed_builds+=("$version (build success, test failed)")
            fi
        else
            failed_builds+=("$version")
        fi
    done
    
    echo ""
    echo -e "${BLUE}=== Build Summary ===${NC}"
    
    if [[ ${#successful_builds[@]} -gt 0 ]]; then
        print_status "SUCCESS" "Successfully built images:"
        for version in "${successful_builds[@]}"; do
            echo "  ✅ Python $version"
        done
    fi
    
    if [[ ${#failed_builds[@]} -gt 0 ]]; then
        print_status "ERROR" "Failed to build images:"
        for version in "${failed_builds[@]}"; do
            echo "  ❌ Python $version"
        done
        return 1
    fi
    
    return 0
}

# イメージリスト表示
list_images() {
    print_status "INFO" "Built Python base images:"
    docker images | grep "$REGISTRY_PREFIX/base-python" | sort
}

# イメージクリーンアップ
cleanup_images() {
    print_status "INFO" "Cleaning up old Python base images..."
    
    # <none>タグのイメージを削除
    local dangling_images=$(docker images -f "dangling=true" -q)
    if [[ -n "$dangling_images" ]]; then
        docker rmi $dangling_images >/dev/null 2>&1 || true
        print_status "SUCCESS" "Removed dangling images"
    fi
    
    # ビルドキャッシュクリーンアップ
    docker builder prune -f >/dev/null 2>&1 || true
    print_status "SUCCESS" "Build cache cleaned up"
}

# イメージプッシュ
push_images() {
    local registry_url=${1:-}
    
    if [[ -z "$registry_url" ]]; then
        print_status "ERROR" "Registry URL required for push operation"
        return 1
    fi
    
    print_status "INFO" "Pushing images to registry: $registry_url"
    
    for version_info in "${PYTHON_VERSIONS[@]}"; do
        local version=$(echo "$version_info" | cut -d: -f1)
        local image_name="$REGISTRY_PREFIX/base-python:$version"
        local remote_name="$registry_url/$REGISTRY_PREFIX/base-python:$version"
        
        print_status "INFO" "Pushing Python $version image..."
        
        if docker tag "$image_name" "$remote_name" && docker push "$remote_name"; then
            print_status "SUCCESS" "Python $version image pushed successfully"
        else
            print_status "ERROR" "Failed to push Python $version image"
        fi
    done
}

# メイン実行関数
main() {
    # ログファイル初期化
    > "$LOG_FILE"
    
    print_header
    
    check_docker
    check_build_files
    
    if build_all_images; then
        echo ""
        list_images
        cleanup_images
        
        echo ""
        print_status "SUCCESS" "All Python base images built successfully!"
        
        echo ""
        echo "Usage examples:"
        echo "  docker run --rm $REGISTRY_PREFIX/base-python:3.11"
        echo "  docker run -it $REGISTRY_PREFIX/base-python:3.10 bash"
        
        echo ""
        echo "Next steps:"
        echo "1. Test images in your development environment"
        echo "2. Push to your container registry if needed"
        echo "3. Use these base images for JupyterHub containers"
        
    else
        print_status "ERROR" "Some images failed to build. Check logs: $LOG_FILE"
        exit 1
    fi
}

# 引数処理
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [OPTIONS] [COMMAND]"
        echo ""
        echo "Commands:"
        echo "  build       Build all Python base images (default)"
        echo "  list        List built images"
        echo "  clean       Clean up old images and build cache"
        echo "  push URL    Push images to registry"
        echo ""
        echo "Options:"
        echo "  -h, --help              Show this help message"
        echo "  --no-cache             Build without using cache"
        echo "  --registry-prefix PREFIX Set registry prefix (default: kubeadm-python-cluster)"
        echo ""
        echo "Environment Variables:"
        echo "  REGISTRY_PREFIX        Container registry prefix"
        echo "  BUILD_ARGS            Additional build arguments"
        echo "  NO_CACHE              Set to 'true' to disable build cache"
        exit 0
        ;;
    build|"")
        main
        ;;
    list)
        list_images
        ;;
    clean)
        cleanup_images
        ;;
    push)
        if [[ -n "${2:-}" ]]; then
            push_images "$2"
        else
            echo "Error: Registry URL required for push command"
            echo "Usage: $0 push <registry-url>"
            exit 1
        fi
        ;;
    --no-cache)
        NO_CACHE=true
        main
        ;;
    --registry-prefix)
        REGISTRY_PREFIX="${2:-$REGISTRY_PREFIX}"
        shift 2
        main "$@"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use '$0 --help' for usage information"
        exit 1
        ;;
esac