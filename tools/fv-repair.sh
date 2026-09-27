#!/bin/bash
#
# FileView 预览 —— 一键修复脚本（在飞牛 NAS 上用 root 执行）
#
# 解决两类问题：
#   1) 网关容器 Restarting 崩溃循环
#      真因：/app/target 是宿主机目录的 bind 挂载，app.sock 会跨容器重启残留，
#            nginx 不会自己清理已存在的 unix socket，启动时
#              bind() to unix:/app/target/app.sock failed (98: Address already in use)
#            配合 restart: unless-stopped 就变成无限重启。
#      修法：启动前先删掉残留 socket。
#
#   2) 新加的存储卷（如 /vol3）预览报「文件不存在」
#      真因：改了设置但容器没重建，bind 挂载不会在运行中的容器里生效。
#      修法：按宿主机真实挂载情况重写挂载段，再强制重建容器。
#
# 用法：
#   bash fv-repair.sh
# 可选：APPDEST 不在默认位置时
#   APPDEST=/vol2/@appcenter/basemetas-fileview bash fv-repair.sh

set -u

APPDEST="${APPDEST:-/vol1/@appcenter/basemetas-fileview}"
PKGVAR="${PKGVAR:-/vol1/@appdata/basemetas-fileview}"
D="$APPDEST/docker"
COMPOSE="$D/docker-compose.yaml"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

say "0. 前置检查"
[ -f "$COMPOSE" ] || { echo "找不到 $COMPOSE，请确认 APPDEST 路径。"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "找不到 docker 命令。"; exit 1; }
mkdir -p "$PKGVAR/fonts" 2>/dev/null
echo "  APPDEST = $APPDEST"
echo "  PKGVAR  = $PKGVAR"

say "1. 探测宿主机存储卷"
VOLS="$(awk '$2 ~ /^\/vol[0-9]+$/ {print $2}' /proc/mounts 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')"
[ -n "$VOLS" ] || VOLS="/vol1"
echo "  检测到：$VOLS"

say "2. 重写挂载段"
BLOCK=""
OLD_IFS="$IFS"; IFS=','
for v in $VOLS; do
  BLOCK="${BLOCK}      - ${v}:${v}:ro
"
done
IFS="$OLD_IFS"
TMP="$COMPOSE.new"
if awk -v block="$BLOCK" '
  /## VOLUMES_BEGIN/ { print; printf "%s", block; skip=1; next }
  /## VOLUMES_END/   { skip=0 }
  skip != 1 { print }
' "$COMPOSE" > "$TMP" 2>/dev/null && [ -s "$TMP" ]; then
  mv "$TMP" "$COMPOSE"
  echo "  已写入："
  sed -n '/## VOLUMES_BEGIN/,/## VOLUMES_END/p' "$COMPOSE" | sed 's/^/    /'
else
  rm -f "$TMP" 2>/dev/null
  echo "  ⚠️ 重写失败，保留原挂载段（请检查 VOLUMES_BEGIN/END 标记是否还在）"
fi

say "3. 写 .env（让手工 docker compose 也能跑）"
cat > "$D/.env" <<EOF
TRIM_APPDEST=$APPDEST
TRIM_PKGVAR=$PKGVAR
EOF
echo "  已写入 $D/.env"

say "4. 清理残留 socket（网关崩溃循环的根因）"
rm -f "$APPDEST/app.sock"
echo "  已删除 $APPDEST/app.sock（若原本不存在则无影响）"

say "5. 重建容器"
PROJ="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' basemetas-fileview-engine 2>/dev/null)"
[ -n "$PROJ" ] || PROJ="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' basemetas-fileview-gateway 2>/dev/null)"
[ -n "$PROJ" ] || PROJ="docker"
echo "  compose 项目名：$PROJ"

export TRIM_APPDEST="$APPDEST"
export TRIM_PKGVAR="$PKGVAR"
cd "$D" || exit 1
docker compose -p "$PROJ" up -d --force-recreate --remove-orphans

say "6. 等待 8 秒后检查状态"
sleep 8
docker ps -a --filter name=basemetas-fileview \
  --format 'table {{.Names}}\t{{.Status}}'

GW="$(docker inspect -f '{{.State.Status}}' basemetas-fileview-gateway 2>/dev/null)"
if [ "$GW" != "running" ]; then
  say "⚠️ 网关仍未运行，以下是它的日志（把它发我）"
  docker logs basemetas-fileview-gateway --tail 40 2>&1
  exit 1
fi

say "7. 验证挂载是否真的进了容器"
for v in $(echo "$VOLS" | tr ',' ' '); do
  if docker exec basemetas-fileview-engine test -d "$v" 2>/dev/null; then
    echo "  ✅ 容器内可见 $v"
  else
    echo "  ❌ 容器内看不到 $v"
  fi
done

echo
echo "完成。回到飞牛文件管理器，随便开一个 /vol3 里的文件试试。"
echo "若预览页仍异常，浏览器强刷一次（Ctrl+F5）清掉旧的 JS 缓存。"
