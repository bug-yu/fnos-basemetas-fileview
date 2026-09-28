#!/bin/bash
# FileView 预览 —— Docker 镜像元数据（layerdb）残留清理
#
# 解决什么：
#   dockerd 启动时打
#     level=error msg="not restoring image" chainID="sha256:xxxx" err="layer does not exist"
#   之后任何用到那个镜像的操作（`docker images` 列不出、`docker rmi` 说 No such image、
#   `docker pull` 显示成功却依然不在、`docker compose up` 报
#   `unable to get image 'X': layer does not exist`）全都失败。
#
#   原因：镜像的 layerdb 记录还在，但它指向的层数据（overlay2/<cache-id>）已经没了。
#   ★ 重拉是**不可能**成功的 —— 镜像 chainID 由内容算出，同样的内容算出同样的 ID，
#     注册时又撞上那条坏记录。必须先把残留记录清掉。
#
# 本脚本只删「cache-id 指向的目录确实不存在」的条目 —— 那部分数据已经丢了，
# 元数据是垃圾；删掉不会影响任何还能用的镜像。
#
# 用法：
#   bash tools/fv-docker-layerdb.sh                  # 只读报告（docker 跑着也能用）
#   bash tools/fv-docker-layerdb.sh --fix            # 真正清理（必须先停 docker！）
#   FV_DOCKER_ROOT=/vol1/docker bash ... --fix       # 手动指定数据根（docker 停着时用）
#
# 推荐流程：
#   bash tools/fv-docker-layerdb.sh          # 1. 先看报告，确认只有那几条残留
#   systemctl stop docker                    # 2. 停 daemon
#   bash tools/fv-docker-layerdb.sh --fix    # 3. 清理（会自动备份 layerdb）
#   systemctl start docker                   # 4. 起 daemon
#   docker pull nginx:alpine                 # 5. 现在应该能拉下来了

set -u

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

ROOT="${FV_DOCKER_ROOT:-}"
[ -n "$ROOT" ] || ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "取不到 Docker 数据根。请显式指定："
  echo "  FV_DOCKER_ROOT=/vol1/docker bash $0 $*"
  exit 2
fi

LAYERDB="$ROOT/image/overlay2/layerdb/sha256"
OVERLAY="$ROOT/overlay2"
echo "Docker 数据根：$ROOT"
echo "层数据库：    $LAYERDB"
[ -d "$LAYERDB" ] || { echo "找不到 layerdb 目录，确认数据根是否正确。"; exit 2; }
echo

# ---------------------------------------------------------------------------
# 1. 扫描残留条目
# ---------------------------------------------------------------------------
total=0
stale_list=""
echo "== 扫描 layerdb =="
for d in "$LAYERDB"/*/; do
  [ -d "$d" ] || continue
  total=$((total + 1))
  id="$(basename "$d")"
  cid="$(cat "$d/cache-id" 2>/dev/null)"
  if [ -z "$cid" ]; then
    echo "  ⚠️  无 cache-id      chainID=$id"
    stale_list="${stale_list}${id}
"
  elif [ ! -d "$OVERLAY/$cid" ]; then
    echo "  ❌ 层数据缺失        chainID=$id  cache-id=$cid"
    stale_list="${stale_list}${id}
"
  fi
done
stale_n="$(printf '%s' "$stale_list" | grep -c . 2>/dev/null || echo 0)"
echo "  共 $total 条，其中**残留 $stale_n 条**"
echo

# ---------------------------------------------------------------------------
# 2. 交叉核对：dockerd 日志里那几条 chainID
# ---------------------------------------------------------------------------
echo "== dockerd 日志里的 chainID（最近 500 行）=="
if command -v journalctl >/dev/null 2>&1; then
  journalctl -u docker --no-pager -n 500 2>/dev/null \
    | grep -oE 'chainID="sha256:[0-9a-f]{64}"' | sort -u | sed 's/^/  /' \
    || echo "  （没有）"
else
  echo "  （没有 journalctl）"
fi
echo

# ---------------------------------------------------------------------------
# 3. 现状概览
# ---------------------------------------------------------------------------
echo "== 镜像 / 容器概览 =="
if docker info >/dev/null 2>&1; then
  echo "  镜像数：$(docker images -q 2>/dev/null | wc -l)"
  echo "  容器数：$(docker ps -aq 2>/dev/null | wc -l)（运行中 $(docker ps -q 2>/dev/null | wc -l)）"
  echo "  --- 本应用要用的三个 ---"
  for i in nginx:alpine python:3-alpine basemetas/fileview:1.5.2; do
    if docker image inspect "$i" >/dev/null 2>&1; then
      echo "    ✅ $i"
    else
      echo "    ❌ $i（inspect 失败：不存在，或记录已坏）"
    fi
  done
else
  echo "  （docker 未运行，跳过）"
fi
echo

# ---------------------------------------------------------------------------
# 4. 清理
# ---------------------------------------------------------------------------
if [ "$FIX" -eq 0 ]; then
  echo "以上为只读报告。确认残留条数符合预期后，按下面流程清理："
  echo "  systemctl stop docker"
  echo "  bash $0 --fix"
  echo "  systemctl start docker"
  echo "  docker pull nginx:alpine"
  exit 0
fi

if docker info >/dev/null 2>&1; then
  echo "❌ 检测到 docker 仍在运行。改 layerdb 必须在 daemon 停止时做："
  echo "   systemctl stop docker"
  exit 3
fi

if [ "$stale_n" -eq 0 ]; then
  echo "没有残留条目，无需清理。"
  exit 0
fi

BAK="$ROOT/image/layerdb.bak.$(date +%Y%m%d%H%M%S).tar.gz"
echo "== 备份 layerdb =="
tar czf "$BAK" -C "$ROOT/image" overlay2/layerdb 2>/dev/null \
  && echo "  已备份：$BAK" \
  || { echo "  ❌ 备份失败，中止（不做任何修改）"; exit 4; }
echo

echo "== 清理残留条目 =="
printf '%s' "$stale_list" | while IFS= read -r id; do
  [ -n "$id" ] || continue
  rm -rf "$LAYERDB/$id" && echo "  已删除 $id"
done
echo
echo "完成。接下来："
echo "  systemctl start docker"
echo "  docker pull nginx:alpine"
echo "  docker pull python:3-alpine"
echo "  docker pull basemetas/fileview:1.5.2"
echo
echo "若还有镜像拉不下来，说明它的记录也没被清干净，把新的 dockerd 日志发出来。"
