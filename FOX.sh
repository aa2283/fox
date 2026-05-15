#!/bin/bash

# --- 配置部分 ---
FONT_DIR="/root/docker/firefox_fonts" # 宿主机上存放字体的目录
FONT_FILE="NotoSansSC-Regular.otf" # 字体文件名，请确保与下载的字体文件匹配
# 稳定且直接指向思源黑体简体中文常规体 .otf 格式的下载链接
FONT_DOWNLOAD_URL="https://github.com/notofonts/noto-cjk/raw/main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf" 
CONTAINER_NAME="FireFox" # 您的 Docker 容器名称
DISPLAY_WIDTH="1920" # 显示宽度
DISPLAY_HEIGHT="1080" # 显示高度
TZ="Asia/Shanghai" # 时区
CONFIG_VOLUME_PATH="/root/docker/firefox" # 容器配置持久化路径
# --- 配置部分结束 ---

# --- 辅助函数：生成随机密码 ---
generate_password() {
    # 修正 tr 命令，确保字符集正确并限制输出长度
    # LC_ALL=C 确保 tr 在 POSIX locale 下运行，避免字符集问题
    # tr -dc 'A-Za-z0-9@#%^&*_+-=' 转义了所有特殊字符，确保它们被视为字面字符
    # head -c 16 截断为16个字符
    LC_ALL=C tr -dc 'A-Za-z0-9@#%^&*_+-=' < /dev/urandom | head -c 16
}

# --- 辅助函数：查找可用端口 ---
find_available_port() {
    local start_port=15800
    local end_port=16000 # 查找范围
    for (( port=start_port; port<=end_port; ++port ))
    do
        # 检查端口是否被占用 (tcp)
        # lsof 可能需要安装 (sudo apt install lsof)
        if ! lsof -i tcp:"$port" &>/dev/null; then
            # 检查端口是否被占用 (udp)
            if ! lsof -i udp:"$port" &>/dev/null; then
                echo "$port"
                return 0
            fi
        fi
    done
    return 1 # 未找到可用端口
}

echo "--- Firefox Docker 容器智能管理脚本 ---"

# --- 0. 检查 Docker 是否安装 ---
echo ""
echo "--- 检查 Docker 安装 ---"
if ! command -v docker &> /dev/null; then
    echo "警告: Docker 未安装。请按照以下步骤安装 Docker CE："
    echo "1. 更新软件包列表: sudo apt update"
    echo "2. 安装 Docker 依赖: sudo apt install apt-transport-https ca-certificates curl software-properties-common -y"
    echo "3. 添加 Docker 官方 GPG 密钥: curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg"
    echo "4. 添加 Docker 稳定版仓库: echo \"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null"
    echo "5. 再次更新软件包列表: sudo apt update"
    echo "6. 安装 Docker CE: sudo apt install docker-ce docker-ce-cli containerd.io -y"
    echo "7. (可选) 将当前用户添加到 docker 组: sudo usermod -aG docker \$USER && newgrp docker"
    echo "请安装 Docker 后重新运行此脚本。"
    exit 1
else
    echo "Docker 已安装。"
fi

# --- 1. 交互式设置 VNC 密码 ---
echo ""
echo "--- 设置 VNC 连接密码 ---"
while true; do
    read -p "请输入 VNC 连接密码 (至少6个字符，或留空自动生成): " VNC_PASSWORD_INPUT
    if [ -z "$VNC_PASSWORD_INPUT" ]; then
        VNC_PASSWORD_INPUT=$(generate_password)
        echo "自动生成 VNC 密码: $VNC_PASSWORD_INPUT"
        break
    elif [ ${#VNC_PASSWORD_INPUT} -lt 6 ]; then
        echo "密码长度小于6个字符，安全性较低。请重新输入更安全的密码。"
    else
        break
    fi
done

# --- 2. 交互式设置 Web VNC 端口 ---
echo ""
echo "--- 设置 Web VNC 端口 ---"
while true; do
    read -p "请输入 Web VNC 监听端口 (默认: 15800，或留空自动查找可用端口): " WEB_LISTENING_PORT_INPUT
    if [ -z "$WEB_LISTENING_PORT_INPUT" ]; then
        WEB_LISTENING_PORT=$(find_available_port)
        if [ $? -eq 0 ]; then
            echo "自动查找可用端口: $WEB_LISTENING_PORT"
            break
        else
            echo "错误: 未能在 15800-16000 范围内找到可用端口。请手动指定一个端口。"
        fi
    elif [[ "$WEB_LISTENING_PORT_INPUT" =~ ^[0-9]+$ ]] && [ "$WEB_LISTENING_PORT_INPUT" -ge 1024 ] && [ "$WEB_LISTENING_PORT_INPUT" -le 65535 ]; then
        WEB_LISTENING_PORT="$WEB_LISTENING_PORT_INPUT"
        # 验证手动输入的端口是否可用
        if lsof -i tcp:"$WEB_LISTENING_PORT" &>/dev/null || lsof -i udp:"$WEB_LISTENING_PORT" &>/dev/null; then
            echo "警告: 端口 $WEB_LISTENING_PORT 似乎已被占用。请选择其他端口。"
        else
            break
        fi
    else
        echo "无效的端口号。请输入一个 1024 到 65535 之间的整数。"
    fi
done

# --- 3. 容器管理逻辑 ---
echo ""
echo "--- 容器管理 ---"
if docker inspect "$CONTAINER_NAME" &>/dev/null; then
    echo "检测到容器 '$CONTAINER_NAME' 已存在。"
    if [ "$(docker ps -q -f name=$CONTAINER_NAME)" ]; then
        echo "容器 '$CONTAINER_NAME' 正在运行。"
        read -p "容器 '$CONTAINER_NAME' 正在运行。是否要卸载它 (停止并删除容器及数据)? (y/N): " UNINSTALL_CHOICE
        UNINSTALL_CHOICE=${UNINSTALL_CHOICE,,} # 转换为小写
        if [[ "$UNINSTALL_CHOICE" == "y" ]]; then
            echo "正在停止并删除容器 '$CONTAINER_NAME'..."
            docker stop "$CONTAINER_NAME" &>/dev/null
            docker rm "$CONTAINER_NAME" &>/dev/null
            if [ -d "$CONFIG_VOLUME_PATH" ]; then
                read -p "是否删除容器持久化配置目录 '$CONFIG_VOLUME_PATH'? (y/N): " DELETE_CONFIG_CHOICE
                DELETE_CONFIG_CHOICE=${DELETE_CONFIG_CHOICE,,}
                if [[ "$DELETE_CONFIG_CHOICE" == "y" ]]; then
                    echo "正在删除配置目录 '$CONFIG_VOLUME_PATH'..."
                    rm -rf "$CONFIG_VOLUME_PATH"
                    echo "配置目录已删除。"
                fi
            fi
            echo "容器 '$CONTAINER_NAME' 已卸载。"
            echo "请重新运行脚本以进行全新安装。"
            exit 0
        else
            echo "您选择不卸载。脚本将退出。如果要更新密码或端口，请先卸载容器。"
            exit 0
        fi
    else
        echo "容器 '$CONTAINER_NAME' 已存在但未运行，尝试启动并更新配置..."
        docker start "$CONTAINER_NAME"
        if [ $? -ne 0 ]; then
            echo "错误: 容器 '$CONTAINER_NAME' 启动失败。请手动检查。"
            exit 1
        fi
        echo "容器 '$CONTAINER_NAME' 启动成功。"

        # 更新 VNC 密码和 Web 端口
        echo "尝试更新容器 '$CONTAINER_NAME' の VNC 密码和 Web 端口..."
        docker exec "$CONTAINER_NAME" bash -c "sed -i 's/^VNC_PASSWORD=.*/VNC_PASSWORD=$VNC_PASSWORD_INPUT/' /etc/cont-init.d/00-set-env"
        docker exec "$CONTAINER_NAME" bash -c "sed -i 's/^WEB_LISTENING_PORT=.*/WEB_LISTENING_PORT=$WEB_LISTENING_PORT/' /etc/cont-init.d/00-set-env"
        docker restart "$CONTAINER_NAME" # 重启以应用新密码和端口
        echo "容器 '$CONTAINER_NAME' 已重启，VNC 密码和 Web 端口已更新。"
    fi
else
    echo "容器 '$CONTAINER_NAME' 不存在，正在创建并启动..."
    mkdir -p "$CONFIG_VOLUME_PATH" # 确保宿主机配置目录存在
    
    # ==================== 修改后的核心部分 ====================
    docker run -d \
      --name "$CONTAINER_NAME" \
      -p "$WEB_LISTENING_PORT":5800 \
      --shm-size=256m \
      --memory=512m \
      --memory-reservation=256m \
      --cpu-shares=256 \
      --restart=always \
      -e TZ="$TZ" \
      -e VNC_PASSWORD="$VNC_PASSWORD_INPUT" \
      -e DISPLAY_WIDTH="$DISPLAY_WIDTH" \
      -e DISPLAY_HEIGHT="$DISPLAY_HEIGHT" \
      -e CLEAN_TMP_FILES=1 \
      -v "$CONFIG_VOLUME_PATH":/config:rw \
      jlesage/firefox:v25.02.2
    # ========================================================
    
    if [ $? -ne 0 ]; then
        echo "错误: Docker 容器启动失败。请检查 Docker 服务或端口占用情况。"
        exit 1
    fi
    echo "容器 '$CONTAINER_NAME' 已成功启动。"
fi

echo ""
echo "Firefox 容器访问地址: http://{您的服务器IP}:$WEB_LISTENING_PORT"
echo "您的 VNC 密码是: $VNC_PASSWORD_INPUT" # 再次显示密码，方便用户查看

# --- 4. 配置防火墙 ---
echo ""
echo "--- 配置防火墙 (UFW) ---"
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "inactive"; then
        echo "UFW 防火墙当前处于非活动状态。建议启用防火墙。"
        read -p "是否启用 UFW 防火墙并放行端口 $WEB_LISTENING_PORT? (y/N): " UFW_ENABLE_CHOICE
        UFW_ENABLE_CHOICE=${UFW_ENABLE_CHOICE,,}
        if [[ "$UFW_ENABLE_CHOICE" == "y" ]]; then
            echo "正在启用 UFW 并放行端口 $WEB_LISTENING_PORT..."
            sudo ufw allow "$WEB_LISTENING_PORT"/tcp comment "Allow Web VNC for Firefox Docker"
            sudo ufw enable <<<'y'
            echo "UFW 已启用并放行端口 $WEB_LISTENING_PORT。"
        else
            echo "UFW 未启用。请手动放行端口 $WEB_LISTENING_PORT。"
        fi
    else
        echo "UFW 防火墙已启用。正在检查端口 $WEB_LISTENING_PORT 的规则..."
        if ! sudo ufw status | grep -q "ALLOW .* $WEB_LISTENING_PORT/tcp"; then
            read -p "端口 $WEB_LISTENING_PORT 在 UFW 中未放行。是否放行? (y/N): " UFW_ALLOW_CHOICE
            UFW_ALLOW_CHOICE=${UFW_ALLOW_CHOICE,,}
            if [[ "$UFW_ALLOW_CHOICE" == "y" ]]; then
                echo "正在放行端口 $WEB_LISTENING_PORT..."
                sudo ufw allow "$WEB_LISTENING_PORT"/tcp comment "Allow Web VNC for Firefox Docker"
                echo "端口 $WEB_LISTENING_PORT 已在 UFW 中放行。"
            else
                echo "端口 $WEB_LISTENING_PORT 未在 UFW 中放行。请手动检查。"
            fi
        else
            echo "端口 $WEB_LISTENING_PORT 已在 UFW 中放行。"
        fi
    fi
else
    echo "警告: 未检测到 UFW (Uncomplicated Firewall)。请手动检查并放行服务器防火墙中的 $WEB_LISTENING_PORT 端口。"
fi

echo "--- 5. 准备字体文件 ---"
mkdir -p "$FONT_DIR"

if [ ! -f "$FONT_DIR/$FONT_FILE" ]; then
  echo "正在下载字体文件：$FONT_FILE 到 $FONT_DIR..."
  wget -O "$FONT_DIR/$FONT_FILE" "$FONT_DOWNLOAD_URL"
  if [ $? -ne 0 ]; then
    echo "错误：字体下载失败。请检查下载链接或网络连接。"
    exit 1
  fi
  echo "字体下载完成。"
else
  echo "字体文件 $FONT_FILE 已存在于 $FONT_DIR，跳过下载。"
fi

echo "--- 6. 将字体复制到容器并更新缓存 ---"
echo "正在容器内部创建字体目录：/usr/share/fonts/opentype/noto/..."
docker exec "$CONTAINER_NAME" mkdir -p /usr/share/fonts/opentype/noto/
if [ $? -ne 0 ]; then
    echo "错误：无法在容器内部创建字体目录。请检查容器状态或权限。"
    exit 1
fi
echo "容器内部字体目录创建成功。"

echo "正在将字体复制到容器中..."
docker cp "$FONT_DIR/$FONT_FILE" "$CONTAINER_NAME":/usr/share/fonts/opentype/noto/

if [ $? -eq 0 ]; then
  echo "字体复制成功。正在更新容器中的字体缓存..."
  docker exec "$CONTAINER_NAME" fc-cache -f -v
  echo "字体缓存更新完成。"

  echo "--- 7. 重启 Firefox 容器 (确保所有更改生效) ---"
  echo "正在重启容器 '$CONTAINER_NAME' 以使所有配置和字体生效..."
  docker restart "$CONTAINER_NAME"
  if [ $? -eq 0 ]; then
    echo "容器 '$CONTAINER_NAME' 重启成功。"
    echo "中文乱码问题应该已解决。请访问 http://{您的服务器IP}:$WEB_LISTENING_PORT 确认。"
  else
    echo "错误：容器 '$CONTAINER_NAME' 重启失败。"
  fi
else
  echo "错误：字体复制到容器失败。可能是权限问题或容器状态异常。"
fi

echo ""
echo "脚本执行完毕。"
