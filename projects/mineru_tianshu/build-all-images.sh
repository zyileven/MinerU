#!/bin/bash
# ========================================
# MinerU Tianshu - Docker 镜像构建脚本
# ========================================
# 用法:
#   ./build-all-images.sh              # 快速构建(使用缓存)
#   ./build-all-images.sh --no-cache   # 完整构建(不使用缓存)

set -e

# ========================================
# 配置变量
# ========================================
IMAGE_NAME="mineru-tianshu"
IMAGE_TAG="latest"
DOCKERFILE="Dockerfile.tianshu"
OUTPUT_DIR="./docker-images"

# ========================================
# 颜色输出
# ========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "========================================="
echo "   MinerU Tianshu Docker 镜像构建"
echo "========================================="
echo ""

# ========================================
# 检查 Docker 环境
# ========================================
log_info "检查 Docker 环境..."
if ! docker info &> /dev/null; then
    log_error "Docker 未运行"
    exit 1
fi
log_success "Docker 运行正常"

# 检查 buildx
USE_BUILDX=false
if docker buildx version &> /dev/null; then
    log_info "使用 Docker Buildx 构建"
    USE_BUILDX=true
else
    log_warning "Buildx 不可用，使用传统构建方式"
fi

# ========================================
# 创建输出目录
# ========================================
mkdir -p "${OUTPUT_DIR}"

echo ""
log_info "步骤 1/3: 构建镜像"
echo ""

# 确定构建参数
BUILD_ARGS=""
if [ "$1" = "--no-cache" ]; then
    log_warning "完整构建模式(不使用缓存) - 预计 30-60 分钟"
    BUILD_ARGS="--no-cache"
else
    log_info "快速构建模式(使用缓存) - 预计 5-10 分钟"
    BUILD_ARGS=""
fi

log_info "镜像: ${IMAGE_NAME}:${IMAGE_TAG}"
log_info "平台: linux/amd64 (适用于 Linux 服务器)"
log_info "Dockerfile: ${DOCKERFILE}"
echo ""
log_warning "开始构建，请耐心等待..."
echo ""

# 记录开始时间
START_TIME=$(date +%s)

# 构建镜像
if [ "$USE_BUILDX" = true ]; then
    # 使用 buildx 构建
    docker buildx build \
        --platform linux/amd64 \
        $BUILD_ARGS \
        -t ${IMAGE_NAME}:${IMAGE_TAG} \
        -f ${DOCKERFILE} \
        --load \
        .
else
    # 使用传统 docker build
    docker build \
        --platform linux/amd64 \
        $BUILD_ARGS \
        -t ${IMAGE_NAME}:${IMAGE_TAG} \
        -f ${DOCKERFILE} \
        .
fi

# 计算耗时
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
log_success "✓ 镜像构建完成! 耗时: ${MINUTES}分${SECONDS}秒"

# ========================================
# 验证架构
# ========================================
echo ""
log_info "步骤 2/3: 验证镜像"
echo ""

ARCH=$(docker inspect ${IMAGE_NAME}:${IMAGE_TAG} --format='{{.Architecture}}')
if [ "$ARCH" = "amd64" ]; then
    log_success "✓ 架构验证通过: ${ARCH}"
else
    log_error "架构验证失败: 期望 amd64, 实际 ${ARCH}"
    exit 1
fi

# 显示镜像信息
echo ""
log_info "镜像信息:"
docker images ${IMAGE_NAME}:${IMAGE_TAG} --format "  Repository: {{.Repository}}\n  Tag: {{.Tag}}\n  Size: {{.Size}}\n  Created: {{.CreatedSince}}"

# ========================================
# 导出镜像
# ========================================
echo ""
log_info "步骤 3/3: 导出镜像"
echo ""

OUTPUT_FILE="${OUTPUT_DIR}/${IMAGE_NAME}-image.tar"

log_info "导出镜像到: ${OUTPUT_FILE}"
log_warning "请耐心等待，这可能需要几分钟..."

# 记录开始时间
EXPORT_START=$(date +%s)

# 导出镜像
docker save ${IMAGE_NAME}:${IMAGE_TAG} -o "${OUTPUT_FILE}"

# 计算耗时
EXPORT_END=$(date +%s)
EXPORT_DURATION=$((EXPORT_END - EXPORT_START))

# 获取文件大小
FILE_SIZE=$(du -h "${OUTPUT_FILE}" | cut -f1)

echo ""
log_success "✓ 镜像导出完成! 耗时: ${EXPORT_DURATION}秒"
log_info "文件: ${OUTPUT_FILE}"
log_info "大小: ${FILE_SIZE}"

# ========================================
# 复制配置文件到输出目录
# ========================================
echo ""
log_info "复制配置文件到 ${OUTPUT_DIR}..."
echo ""

# 1. 复制 docker-compose.yml
if [ -f "docker-compose.yml" ]; then
    cp docker-compose.yml "${OUTPUT_DIR}/"
    log_success "✓ docker-compose.yml"
else
    log_warning "⚠ docker-compose.yml 不存在"
fi

# 2. 复制 Dockerfile.tianshu
if [ -f "Dockerfile.tianshu" ]; then
    cp Dockerfile.tianshu "${OUTPUT_DIR}/"
    log_success "✓ Dockerfile.tianshu"
else
    log_warning "⚠ Dockerfile.tianshu 不存在"
fi

echo ""
log_success "配置文件已复制到 ${OUTPUT_DIR}/"

# ========================================
# 生成清单和辅助脚本
# ========================================
echo ""
log_info "生成部署文件..."

# 生成镜像清单
cat > "${OUTPUT_DIR}/images-manifest.txt" << EOF
# MinerU Tianshu Docker 镜像清单
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 总文件数: 1
# 总大小: ${FILE_SIZE}

$(basename ${OUTPUT_FILE})	${FILE_SIZE}	${IMAGE_NAME}:${IMAGE_TAG}
EOF

log_success "✓ 镜像清单: ${OUTPUT_DIR}/images-manifest.txt"

# ========================================
# 生成上传脚本
# ========================================
cat > "${OUTPUT_DIR}/upload-all-images.sh" << 'UPLOAD_SCRIPT'
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
        "$SCRIPT_DIR"/Dockerfile.tianshu \
        "$DESTINATION"
else
    echo "使用 scp 上传..."
    scp "$SCRIPT_DIR"/*.tar \
        "$SCRIPT_DIR"/images-manifest.txt \
        "$SCRIPT_DIR"/load-all-images.sh \
        "$SCRIPT_DIR"/docker-compose.yml \
        "$SCRIPT_DIR"/Dockerfile.tianshu \
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
UPLOAD_SCRIPT

chmod +x "${OUTPUT_DIR}/upload-all-images.sh"

# ========================================
# 生成服务器端加载脚本
# ========================================
cat > "${OUTPUT_DIR}/load-all-images.sh" << 'LOAD_SCRIPT'
#!/bin/bash
# 在服务器上加载镜像并部署

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo "  加载 MinerU Tianshu Docker 镜像"
echo "========================================="
echo ""

# 查找 .tar 文件
TAR_FILES=("$SCRIPT_DIR"/*.tar)

if [ ${#TAR_FILES[@]} -eq 0 ] || [ ! -f "${TAR_FILES[0]}" ]; then
    echo "错误: 当前目录没有找到 .tar 文件"
    exit 1
fi

echo "找到 ${#TAR_FILES[@]} 个镜像文件"
echo ""

# 加载镜像
LOADED=0
FAILED=0

for tar_file in "${TAR_FILES[@]}"; do
    filename=$(basename "$tar_file")
    echo "加载: $filename"

    if docker load -i "$tar_file"; then
        echo "  ✓ $filename"
        LOADED=$((LOADED + 1))
    else
        echo "  ✗ $filename 加载失败"
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

echo "========================================="
echo "  加载完成！"
echo "========================================="
echo "  成功: $LOADED"
echo "  失败: $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "✅ 所有镜像加载成功！"
    echo ""
    echo "已加载的镜像:"
    docker images mineru-tianshu --format "  {{.Repository}}:{{.Tag}}\t{{.Size}}"
    echo ""

    # 检查配置文件
    if [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
        echo "========================================="
        echo "  启动服务"
        echo "========================================="
        echo ""

        # 创建数据目录
        echo "创建数据目录..."
        mkdir -p ~/mineru/output

        # 询问是否启动服务
        read -p "是否立即启动服务? (yes/no): " -r
        if [[ $REPLY == "yes" ]]; then
            cd "$SCRIPT_DIR"
            docker-compose up -d
            echo ""
            echo "✅ 服务已启动！"
            echo ""
            echo "查看日志:"
            echo "  docker-compose logs -f"
            echo ""
            echo "访问 API 文档:"
            echo "  http://localhost:8100/docs"
        else
            echo ""
            echo "手动启动服务:"
            echo "  cd $SCRIPT_DIR"
            echo "  docker-compose up -d"
            echo ""
            echo "查看日志:"
            echo "  docker-compose logs -f"
            echo ""
            echo "停止服务:"
            echo "  docker-compose down"
        fi
    fi

    echo ""
    read -p "删除 .tar 文件以释放空间？(输入 yes 确认): " -r
    if [[ $REPLY == "yes" ]]; then
        rm "$SCRIPT_DIR"/*.tar 2>/dev/null || true
        echo "已删除镜像文件"
    fi
else
    echo "部分镜像加载失败，请检查日志"
    exit 1
fi
LOAD_SCRIPT

chmod +x "${OUTPUT_DIR}/load-all-images.sh"

log_success "✓ 辅助脚本已生成"

# ========================================
# 完成总结
# ========================================
echo ""
echo "========================================="
echo "  🎉 完成！"
echo "========================================="
echo ""
log_info "输出目录: ${OUTPUT_DIR}/"
log_info "文件列表:"
ls -lh "${OUTPUT_DIR}" | tail -n +2 | awk '{printf "  %s\t%s\n", $9, $5}'

echo ""
log_info "已包含的文件:"
echo "  ✓ Docker 镜像 (mineru-tianshu-image.tar)"
echo "  ✓ 镜像清单 (images-manifest.txt)"
echo "  ✓ Docker Compose 配置 (docker-compose.yml)"
echo "  ✓ Dockerfile (Dockerfile.tianshu)"
echo "  ✓ 加载脚本 (load-all-images.sh)"
echo "  ✓ 上传脚本 (upload-all-images.sh)"

echo ""
echo "========================================="
echo "  下一步"
echo "========================================="
echo ""
echo "方案 1 - 使用上传脚本（推荐）:"
echo "  cd ${OUTPUT_DIR}"
echo "  ./upload-all-images.sh root@your-server:~/mineru_tianshu/"
echo ""
echo "方案 2 - 手动上传:"
echo "  cd ${OUTPUT_DIR}"
echo "  rsync -avz --progress * root@your-server:~/mineru_tianshu/"
echo ""
echo "服务器端部署:"
echo "  ssh root@your-server"
echo "  cd ~/mineru_tianshu"
echo "  ./load-all-images.sh           # 加载镜像"
echo "  docker-compose up -d           # 启动服务"
echo "  docker-compose logs -f         # 查看日志"
echo ""
log_info "常用命令:"
echo "  docker-compose down            # 停止服务"
echo "  docker-compose restart         # 重启服务"
echo "  docker ps                      # 查看容器状态"
echo ""
log_warning "提示: 如需修改配置(Worker 数量、数据目录等),请编辑 docker-compose.yml!"
echo ""
