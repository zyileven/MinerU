#!/bin/bash
# 上传镜像到服务器

set -e

if [ -z "$1" ]; then
    echo "用法: $0 user@server:/path/to/destination/"
    echo "示例: $0 root@192.168.1.100:/root/mineru_tianshu/"
    exit 1
fi

DESTINATION=$1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SERVER=$(echo "$DESTINATION" | cut -d: -f1)
REMOTE_PATH=$(echo "$DESTINATION" | cut -d: -f2)

echo "========================================="
echo "  上传 MinerU Tianshu Docker 镜像"
echo "========================================="
echo ""
echo "源目录: $SCRIPT_DIR"
echo "目标: $DESTINATION"
echo ""

# 创建远程目录
echo "创建远程目录..."
ssh "$SERVER" "mkdir -p '$REMOTE_PATH'"

# 上传所有部署文件
echo ""
echo "上传文件..."
if command -v rsync &> /dev/null; then
    echo "使用 rsync 上传（支持断点续传）..."
    rsync -avz --progress \
        "$SCRIPT_DIR"/*.tar \
        "$SCRIPT_DIR"/images-manifest.txt \
        "$SCRIPT_DIR"/load-all-images.sh \
        "$SCRIPT_DIR"/docker-compose.yml \
        "$SCRIPT_DIR"/Dockerfile \
        "$DESTINATION" 2>/dev/null || true
else
    echo "使用 scp 上传..."
    scp "$SCRIPT_DIR"/*.tar \
        "$SCRIPT_DIR"/images-manifest.txt \
        "$SCRIPT_DIR"/load-all-images.sh \
        "$SCRIPT_DIR"/docker-compose.yml \
        "$SCRIPT_DIR"/Dockerfile \
        "$DESTINATION"
fi

echo ""
echo "========================================="
echo "  ✅ 上传完成！"
echo "========================================="
echo ""
echo "接下来在服务器上执行:"
echo "  ssh $SERVER"
echo "  cd ${REMOTE_PATH%/}"
echo "  ./load-all-images.sh"
echo ""
