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
        mkdir -p ~/mineru/output ~/mineru/uploads ~/mineru/tmp

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
