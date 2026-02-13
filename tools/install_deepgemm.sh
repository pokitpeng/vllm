#!/bin/bash
# Script to build and/or install DeepGEMM from source
# Default: build and install immediately
# Optional: build wheels to a directory for later installation (useful in multi-stage builds)
set -e

# ================================================================================================================
# 1. 自动寻找 Python 环境中所有 nvidia 组件的 include 目录并拼接到 CPATH
export CPATH=$(find /usr/local/lib/python3.12/dist-packages/nvidia -name include -type d | tr '\n' ':' | sed 's/:$//'):$CPATH

# 2. 同样的，把库文件路径也加上，防止下一步链接报错
export LD_LIBRARY_PATH=$(find /usr/local/lib/python3.12/dist-packages/nvidia -name lib -type d | tr '\n' ':' | sed 's/:$//'):$LD_LIBRARY_PATH

# 1. 自动寻找 Python 环境中所有 nvidia 组件的 lib 目录，并拼接到 LD_LIBRARY_PATH 和 LIBRARY_PATH
# LIBRARY_PATH 是给编译链接阶段用的，LD_LIBRARY_PATH 是给运行阶段用的
export NV_LIBS=$(find /usr/local/lib/python3.12/dist-packages/nvidia -name lib -type d | tr '\n' ':' | sed 's/:$//')

export LIBRARY_PATH=$NV_LIBS:$LIBRARY_PATH
export LD_LIBRARY_PATH=$NV_LIBS:$LD_LIBRARY_PATH

# 2. 补一个软链接（保险起见，有些脚本硬编码了 /usr/local/cuda/lib64）
mkdir -p /usr/local/cuda/lib64
ln -sf /usr/local/lib/python3.12/dist-packages/nvidia/nvrtc/lib/libnvrtc.so.12 /usr/local/cuda/lib64/libnvrtc.so


# 1. 定义路径（根据你刚才 find 的结果）
NVRTC_DIR=/usr/local/lib/python3.12/dist-packages/nvidia/cuda_nvrtc/lib

# 2. 创建一个不带版本号的软链接，这是链接器能识别 `-lnvrtc` 的关键
ln -sf $NVRTC_DIR/libnvrtc.so.12 $NVRTC_DIR/libnvrtc.so

# 3. 将该路径加入到链接器的搜索优先级中
export LIBRARY_PATH=$NVRTC_DIR:$LIBRARY_PATH
export LD_LIBRARY_PATH=$NVRTC_DIR:$LD_LIBRARY_PATH

# 4. (预防性措施) 顺便检查下 cudart 是否也有同样问题
CUDART_DIR=/usr/local/lib/python3.12/dist-packages/nvidia/cuda_runtime/lib
if [ -d "$CUDART_DIR" ]; then
    ln -sf $CUDART_DIR/libcudart.so.12 $CUDART_DIR/libcudart.so
    export LIBRARY_PATH=$CUDART_DIR:$LIBRARY_PATH
    export LD_LIBRARY_PATH=$CUDART_DIR:$LD_LIBRARY_PATH
fi
# ================================================================================================================

# Default values
DEEPGEMM_GIT_REPO="https://github.com/deepseek-ai/DeepGEMM.git"
DEEPGEMM_GIT_REF="477618cd51baffca09c4b0b87e97c03fe827ef03"
WHEEL_DIR=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --ref)
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo "Error: --ref requires an argument." >&2
                exit 1
            fi
            DEEPGEMM_GIT_REF="$2"
            shift 2
            ;;
        --cuda-version)
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo "Error: --cuda-version requires an argument." >&2
                exit 1
            fi
            CUDA_VERSION="$2"
            shift 2
            ;;
        --wheel-dir)
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo "Error: --wheel-dir requires a directory path." >&2
                exit 1
            fi
            WHEEL_DIR="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --ref REF          Git reference to checkout (default: $DEEPGEMM_GIT_REF)"
            echo "  --cuda-version VER CUDA version (auto-detected if not provided)"
            echo "  --wheel-dir PATH   If set, build wheel into PATH but do not install"
            echo "  -h, --help         Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Auto-detect CUDA version if not provided
if [ -z "$CUDA_VERSION" ]; then
    if command -v nvcc >/dev/null 2>&1; then
        CUDA_VERSION=$(nvcc --version | grep "release" | sed -n 's/.*release \([0-9]\+\.[0-9]\+\).*/\1/p')
        echo "Auto-detected CUDA version: $CUDA_VERSION"
    else
        echo "Warning: Could not auto-detect CUDA version. Please specify with --cuda-version"
        exit 1
    fi
fi

# Extract major and minor version numbers
CUDA_MAJOR="${CUDA_VERSION%%.*}"
CUDA_MINOR="${CUDA_VERSION#${CUDA_MAJOR}.}"
CUDA_MINOR="${CUDA_MINOR%%.*}"
echo "CUDA version: $CUDA_VERSION (major: $CUDA_MAJOR, minor: $CUDA_MINOR)"

# Check CUDA version requirement
if [ "$CUDA_MAJOR" -lt 12 ] || { [ "$CUDA_MAJOR" -eq 12 ] && [ "$CUDA_MINOR" -lt 8 ]; }; then
    echo "Skipping DeepGEMM build/installation (requires CUDA 12.8+ but got ${CUDA_VERSION})"
    exit 0
fi

echo "Preparing DeepGEMM build..."
echo "Repository: $DEEPGEMM_GIT_REPO"
echo "Reference: $DEEPGEMM_GIT_REF"

# Create a temporary directory for the build
INSTALL_DIR=$(mktemp -d)
trap 'rm -rf "$INSTALL_DIR"' EXIT

# Clone the repository
git clone --recursive --shallow-submodules "$DEEPGEMM_GIT_REPO" "$INSTALL_DIR/deepgemm"
pushd "$INSTALL_DIR/deepgemm"

# Checkout the specific reference
git checkout "$DEEPGEMM_GIT_REF"

# Clean previous build artifacts
# (Based on https://github.com/deepseek-ai/DeepGEMM/blob/main/install.sh)
rm -rf build dist *.egg-info

# Build wheel
echo "🏗️  Building DeepGEMM wheel..."
python3 setup.py bdist_wheel

# If --wheel-dir was specified, copy wheels there and exit
if [ -n "$WHEEL_DIR" ]; then
    mkdir -p "$WHEEL_DIR"
    cp dist/*.whl "$WHEEL_DIR"/
    echo "✅ Wheel built and copied to $WHEEL_DIR"
    popd
    exit 0
fi

echo "Installing DeepGEMM wheel using pip..."
python3 -m pip install dist/*.whl

popd
echo "✅ DeepGEMM installation completed successfully"
