#!/bin/bash

# --- 配置部分 ---
FONT_DIR="/root/docker/firefox_fonts"
FONT_FILE="NotoSansSC-Regular.otf"
FONT_DOWNLOAD_URL="https://github.com/notofonts/noto-cjk/raw/main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf"
CONTAINER_NAME="FireFox"
DISPLAY_WIDTH="1024"
DISPLAY_HEIGHT="768"
TZ="Asia/Shanghai"
CONFIG_VOLUME_PATH="/root/docker/firefox"
VNC_PORT="5900"  # 固定5900，不用交互了
# --- 配置部分结束 ---

generate_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9@#%^&*_+-=' < /dev/urandom | head -c 16
}

echo "--- Firefox Docker 1.5G内存专用版 ---"

# 1. 检查Docker
if ! command -v docker &> /dev/null; then
    echo "错误: Docker未安装，先装Docker"
    exit 1
fi

# 2. 设置VNC密码
echo ""
read -p "请输入 VNC 密码 (留空自动生成16位): " VNC_PASSWORD_INPUT
if [ -z "$VNC_PASSWORD_INPUT" ]; then
    VNC_PASSWORD_INPUT=$(generate_password)
    echo "自动生成 VNC 密码: $VNC_PASSWORD_INPUT"
fi

# 3. 删掉旧容器
if docker inspect "$CONTAINER_NAME" &>/dev/null; then
    echo "删除旧容器..."
    docker stop "$CONTAINER_NAME" &>/dev/null
    docker rm "$CONTAINER_NAME" &>/dev/null
fi

# 4. 创建目录
mkdir -p "$CONFIG_VOLUME_PATH"
mkdir -p "$FONT_DIR"

# 5. 启动容器，注意这里写成一行，避免续行符出问题
echo "正在启动容器..."
docker run -d --name "$CONTAINER_NAME" --shm-size=512m --memory=800m --memory-swap=1g --cpu-shares=512 -p ${VNC_PORT}:5900 -e TZ="$TZ" -e VNC_PASSWORD="$VNC_PASSWORD_INPUT" -e DISPLAY_WIDTH="$DISPLAY_WIDTH" -e DISPLAY_HEIGHT="$DISPLAY_HEIGHT" -e ENABLE_AUDIO=0 -e ENABLE_WEB_AUDIO=0 -e ENABLE_WEB_UI=0 -e DARK_MODE=1 -v "$CONFIG_VOLUME_PATH":/config:rw --restart unless-stopped jlesage/firefox:latest

if [ $? -ne 0 ]; then
    echo "错误: 容器启动失败"
    exit 1
fi
echo "容器启动成功"

# 6. 装中文字体
echo "正在下载字体..."
if [ ! -f "$FONT_DIR/$FONT_FILE" ]; then
    wget -O "$FONT_DIR/$FONT_FILE" "$FONT_DOWNLOAD_URL"
fi

echo "正在复制字体到容器..."
docker exec "$CONTAINER_NAME" mkdir -p /usr/share/fonts/opentype/noto/
docker cp "$FONT_DIR/$FONT_FILE" "$CONTAINER_NAME":/usr/share/fonts/opentype/noto/
docker exec "$CONTAINER_NAME" fc-cache -f -v

echo "重启容器使字体生效..."
docker restart "$CONTAINER_NAME"

echo ""
echo "=== 全部完成 ==="
echo "VNC地址: 你的服务器IP:$VNC_PORT"
echo "VNC密码: $VNC_PASSWORD_INPUT"
echo "防火墙记得放行: ufw allow $VNC_PORT/tcp"
