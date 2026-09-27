#!/bin/bash
# FileView 卸载状态修复脚本
#
# 适用场景：飞牛应用中心点"卸载"提示 "Request failed, please try again later"，
#           但 `docker ps -a` 里看容器其实已经没了。
#
# 原因：手动 `docker compose up -d` 时未指定 -p basemetas-fileview，
#       容器脱离了飞牛的 compose project 管理，应用中心按自己的 project 名 down 失败。
#
# 用法：在 NAS 上 root 执行。

set +e

PROJ="basemetas-fileview"
TS=$(date +%Y%m%d%H%M%S)
REMOVE_BASE="/vol1/@apphome/_removed"

# 支持 TRIM_APPDEST 优先；否则用默认应用中心路径
APP_BASE="${TRIM_APPDEST:-/vol1/@appcenter/$PROJ}"

echo "=== FileView 卸载状态修复 ==="
echo "应用目录：$APP_BASE"
echo

# 1. 按容器名强删（幂等）
echo "1. 删除可能脱离管理的同名容器..."
docker rm -f "$PROJ-engine" "$PROJ-gateway" 2>/dev/null || true

# 2. 按项目名 docker compose down（忽略错误）
echo "2. 按项目名清理 compose 工程..."
if [ -f "$APP_BASE/docker/docker-compose.yaml" ]; then
  docker compose -p "$PROJ" -f "$APP_BASE/docker/docker-compose.yaml" down --remove-orphans 2>/dev/null || true
fi

# 3. 清残留 socket / .env
echo "3. 清理残留 socket / 环境文件..."
rm -f "$APP_BASE/app.sock" 2>/dev/null || true
rm -f "$APP_BASE/docker/.env" 2>/dev/null || true

# 4. 备份并移除飞牛应用目录（不永久删除，便于排查）
echo "4. 备份应用元数据目录..."
mkdir -p "$REMOVE_BASE"
for d in "/vol1/@appcenter/$PROJ" "/vol1/@appconf/$PROJ" "/vol1/@apptemp/$PROJ"; do
  if [ -d "$d" ]; then
    dest="$REMOVE_BASE/$(basename $d)-$PROJ-$TS"
    mv "$d" "$dest" && echo "  已备份：$d -> $dest"
  fi
done

# @appdata 里可能有用户上传的字体，单独备份并提示
if [ -d "/vol1/@appdata/$PROJ" ]; then
  dest="$REMOVE_BASE/@appdata-$PROJ-$TS"
  mv "/vol1/@appdata/$PROJ" "$dest" && echo "  已备份字体目录：/vol1/@appdata/$PROJ -> $dest"
  echo "  若以后不再重装，可手动删除 $dest 以释放空间。"
fi

# 5. 重启应用中心服务，让 UI 状态刷新
echo "5. 重启应用中心服务..."
if systemctl restart trim_app_center 2>/dev/null; then
  echo "  trim_app_center 已重启"
elif systemctl restart fnos-app-center 2>/dev/null; then
  echo "  fnos-app-center 已重启"
else
  echo "  未能自动识别服务名，请手动重启应用中心相关服务。"
fi

echo
echo "=== 完成 ==="
echo "请刷新飞牛应用中心页面，应用卡片应该已经消失。"
echo "如果仍然出现，请把以下命令的输出贴出来："
echo "  docker ps -a | grep $PROJ"
echo "  ls -la /vol1/@appcenter/$PROJ"
echo "  cat /var/log/trim_app_center/error.log | tail -20"
