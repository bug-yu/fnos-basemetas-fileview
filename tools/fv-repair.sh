#!/bin/bash
#
# FileView 预览 —— 一键修复脚本（在飞牛 NAS 上用 root 执行）
#
# 解决三类问题：
#   1) 网关容器 Restarting 崩溃循环
#      真因：/app/target 是宿主机目录的 bind 挂载，app.sock 会跨容器重启残留，
#            nginx 不会自己清理已存在的 unix socket，启动时
#              bind() to unix:/app/target/app.sock failed (98: Address already in use)
#            配合 restart: unless-stopped 就变成无限重启。
#      修法：启动前先删掉残留 socket。
#
#   2) 某个存储卷（如 /vol3）里的文件预览报「文件不存在」
#      真因：该卷没被挂进引擎容器（bind 挂载在容器创建时定死，改配置不重建容器不会生效）。
#      修法：按宿主机真实挂载情况重写挂载段，再强制重建容器。
#
#   3) 想临时验证「手工指定卷列表能不能解决」
#      用法：VOLS="/vol1,/vol2,/vol3" bash fv-repair.sh
#
# 用法：
#   bash fv-repair.sh
#   VOLS="/vol1,/vol2,/vol3" bash fv-repair.sh          # 手工指定要挂的卷
#   APPDEST=/vol2/@appcenter/basemetas-fileview bash fv-repair.sh
#
# 只做「重写挂载段 + 重建容器 + 清理 socket」，不动其它文件。

set -u

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------------------
# 应用可能装在任意一个存储卷上（/vol{n}/@appcenter/...），自动定位
detect_path() {
  local suffix="$1" d
  for d in /vol[0-9]*/"$suffix"/basemetas-fileview; do
    [ -d "$d" ] && { echo "$d"; return; }
  done
  echo ""
}

APPDEST="${APPDEST:-$(detect_path @appcenter)}"
PKGVAR="${PKGVAR:-$(detect_path @appdata)}"
[ -n "$APPDEST" ] || APPDEST="/vol1/@appcenter/basemetas-fileview"
[ -n "$PKGVAR" ]  || PKGVAR="/vol1/@appdata/basemetas-fileview"
D="$APPDEST/docker"
COMPOSE="$D/docker-compose.yaml"

say "0. 前置检查"
[ -f "$COMPOSE" ] || { echo "找不到 $COMPOSE，请确认 APPDEST 路径。"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "找不到 docker 命令。"; exit 1; }
mkdir -p "$PKGVAR/fonts" 2>/dev/null
echo "  APPDEST = $APPDEST"
echo "  PKGVAR  = $PKGVAR"

say "0b. 应用用户能否操作 docker"
# 「保存设置自动重建容器」「停用」「状态上报」都靠应用用户执行 docker，
# 而它默认不在 docker 组里 —— 不加这一项，那些动作会全部静默失败。
U="$(sed -n 's/.*"username"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$APPDEST/config/privilege" 2>/dev/null | head -1)"
[ -n "$U" ] || U="basemetas-fileview"
if id "$U" >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
  if runuser -u "$U" -- docker ps >/dev/null 2>&1; then
    echo "  ✅ 应用用户 $U 可以操作 docker"
  else
    echo "  ⚠️ 应用用户 $U **不可以**操作 docker"
    echo "     修法： usermod -aG docker $U"
    echo "     （0.5.8 起的安装包已在 config/privilege 声明 join-groups:[\"docker\"]，重装即可）"
  fi
else
  echo "  （跳过：用户 $U 不存在或没有 runuser）"
fi

# ---------------------------------------------------------------------------
# 1. 探测宿主机存储卷（挂载点 ∪ /volN 目录，取并集）
# ---------------------------------------------------------------------------
# ⚠️ 不要退回「只看 /proc/mounts」：只要探到任意一个挂载点就完全不走目录兜底，
#    遇到「/vol1、/vol2 是独立挂载点，/vol3 只是目录」的环境就会漏掉 /vol3。
say "1. 探测宿主机存储卷"
MNT="$(awk '$2 ~ /^\/vol[0-9]+\/*$/ {p=$2; sub(/\/+$/, "", p); print p}' /proc/mounts 2>/dev/null | sort -u | tr '\n' ' ')"
DIRS=""
for d in /vol[0-9] /vol[0-9][0-9] /vol[0-9][0-9][0-9]; do
  [ -d "$d" ] && DIRS="$DIRS$d "
done
echo "  挂载点(/proc/mounts)：${MNT:-（无）}"
echo "  目录(/volN)        ：${DIRS:-（无）}"

if [ -n "${VOLS:-}" ]; then
  echo "  使用手工指定的卷列表（VOLS）：$VOLS"
else
  VOLS="$( { printf '%s\n' $MNT; printf '%s\n' $DIRS; } 2>/dev/null \
           | awk -F'/' '/^\/vol[0-9]+$/ {n=$2; sub(/^vol/, "", n); print n "\t" $0}' \
           | sort -n -u | cut -f2 | tr '\n' ',' | sed 's/,$//' )"
fi
[ -n "$VOLS" ] || VOLS="/vol1"
echo "  最终要挂载：$VOLS"

# ---------------------------------------------------------------------------
# 2. 重写挂载段
# ---------------------------------------------------------------------------
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

say "5. 校验 compose（不合法会让「停用 / 重建」一起失败）"
export TRIM_APPDEST="$APPDEST"
export TRIM_PKGVAR="$PKGVAR"
if ( cd "$D" && docker compose config >/dev/null 2>&1 ); then
  echo "  ✅ docker compose config 通过"
else
  echo "  ⚠️ docker compose config 报错，内容如下："
  ( cd "$D" && docker compose config 2>&1 ) | head -15 | sed 's/^/    /'
fi

say "6. 重建容器"
# ⚠️ 项目名以 config/resource **声明**的为准 —— 飞牛就是按这个名字管这套容器的。
#    如果容器实际属于别的项目（最典型：在应用目录里手工跑过 `docker compose up -d`，
#    compose 默认拿目录名 "docker" 当项目名），飞牛就「看不到」这些容器：
#      · 点停用 → 报 Request failed, please try again later
#      · 更新/重建 → 认为没有容器，不会用新配置重建 → 新加的卷永远挂不上
#    所以这里先把脱管的容器删掉，再按声明的名字重建（否则会撞容器名）。
WANT="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$APPDEST/config/resource" 2>/dev/null \
        | head -1 | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//; s/"$//')"
CUR="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' basemetas-fileview-engine 2>/dev/null)"
[ -n "$WANT" ] || WANT="$CUR"
[ -n "$WANT" ] || WANT="docker"
echo "  config/resource 声明：$WANT    容器实际所属：${CUR:-（容器不存在）}"
if [ -n "$CUR" ] && [ "$CUR" != "$WANT" ]; then
  echo "  ⚠️ 不一致（脱管）：先删除现有容器，再按 $WANT 重建"
  docker rm -f basemetas-fileview-engine basemetas-fileview-gateway >/dev/null 2>&1
fi

cd "$D" || exit 1
docker compose -p "$WANT" up -d --force-recreate --remove-orphans

say "7. 等待 8 秒后检查状态"
sleep 8
docker ps -a --filter name=basemetas-fileview \
  --format 'table {{.Names}}\t{{.Status}}'

GW="$(docker inspect -f '{{.State.Status}}' basemetas-fileview-gateway 2>/dev/null)"
if [ "$GW" != "running" ]; then
  say "⚠️ 网关仍未运行，以下是它的日志（把它发我）"
  docker logs basemetas-fileview-gateway --tail 40 2>&1
  exit 1
fi

say "8. 验证挂载是否真的进了容器"
for v in $(echo "$VOLS" | tr ',' ' '); do
  if docker exec basemetas-fileview-engine test -d "$v" 2>/dev/null; then
    n="$(docker exec basemetas-fileview-engine sh -c "ls -A '$v' 2>/dev/null | head -n 1" 2>/dev/null)"
    if [ -n "$n" ]; then
      echo "  ✅ 容器内可见 $v 且有内容"
    else
      echo "  ❌ 容器内 $v 是空目录（宿主机内容：$(ls -A "$v" 2>/dev/null | head -n 1)）"
    fi
  else
    echo "  ❌ 容器内看不到 $v"
  fi
done

echo
echo "完成。回到飞牛文件管理器，随便开一个 /vol3 里的文件试试。"
echo "若预览页仍异常，浏览器强刷一次（Ctrl+F5）清掉旧的 JS 缓存。"
echo "还有问题就跑 bash tools/fv-doctor.sh 把输出发出来。"
