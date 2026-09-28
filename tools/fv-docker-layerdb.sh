#!/bin/bash
# FileView 预览 —— Docker 镜像元数据（layerdb）残留检查 / 清理
#
# 解决什么：
#   dockerd 启动时打
#     level=error msg="not restoring image" chainID="sha256:xxxx" err="layer does not exist"
#   之后任何用到那个镜像的操作（`docker images` 列不出、`docker rmi` 说 No such image、
#   `docker pull` 显示成功却依然不在、`docker compose up` 报
#   `unable to get image 'X': layer does not exist`）全都失败。
#
# 两种成因，本脚本针对**第二种**：
#   ① daemon 自己的索引状态不一致（断电/异常重启后常见）
#      → **先试「干净地停一次再起」**：systemctl stop docker（等它真的停完，确认没有
#        残留 docker-proxy）→ systemctl start docker → docker pull <镜像>
#        实测：这一步就恢复了，而且 `docker pull` 会回 `Image is up to date`（镜像本来就在）
#   ② layerdb 里真有残留条目（指向的层数据 / 父层条目没了）
#      → 本脚本的 `--fix` 处理
#
# ⚠️ 别把 ① 当成 ②：2026-09-28 实测过一次 ①，698 条 layerdb **一条残留都没有**，
#    纯粹是 daemon 状态不一致，干净 stop+start 就好了。
#    另外 `systemctl restart docker` 在系统状态本来就乱时**可能修不好**
#    （日志里会看到 `docker-proxy remains running after unit stopped` /
#      `unclean termination of a previous run`）—— 用 stop + 确认停干净 + start。
#
# 本脚本只删「cache-id 指向的层数据目录不存在」或「parent 父层条目不存在」的条目，
# 删掉不会影响任何还能用的镜像；`--fix` 前会自动打包备份 layerdb。
#
# 用法：
#   bash tools/fv-docker-layerdb.sh                  # 只读报告（docker 跑着也能用）
#   bash tools/fv-docker-layerdb.sh --fix            # 真正清理（必须先停 docker！）
#   FV_DOCKER_ROOT=/vol1/docker bash ... --fix       # 手动指定数据根（停着时也能自动探测）
#
# 推荐流程：
#   systemctl stop docker && systemctl start docker   # 1. 先试干净的停/起（多数情况够了）
#   docker pull <镜像>                                # 2. 还不行再往下
#   bash tools/fv-docker-layerdb.sh                   # 3. 只读报告，看有没有残留
#   systemctl stop docker                             # 4. 停 daemon
#   bash tools/fv-docker-layerdb.sh --fix             # 5. 清理（会自动备份）
#   systemctl start docker && docker pull <镜像>      # 6. 重拉

set -u

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

ROOT="${FV_DOCKER_ROOT:-}"
# daemon 停着时 docker info 取不到，按常见路径自动探测（fnOS 上是 /vol1/docker）
if [ -z "$ROOT" ] && docker info >/dev/null 2>&1; then
  ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
fi
if [ -z "$ROOT" ]; then
  for c in /vol1/docker /vol2/docker /vol3/docker /var/lib/docker; do
    if [ -d "$c/image/overlay2/layerdb/sha256" ]; then ROOT="$c"; break; fi
  done
fi
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
# 查两件事：
#   ① cache-id 指向的层数据目录（overlay2/<cache-id>）还在不在
#   ② parent 指向的父层条目还在不在（父层丢了同样会让整条链「layer does not exist」）
total=0
stale_list=""
echo "== 扫描 layerdb =="
for d in "$LAYERDB"/*/; do
  [ -d "$d" ] || continue
  total=$((total + 1))
  id="$(basename "$d")"
  bad=""
  cid="$(cat "$d/cache-id" 2>/dev/null)"
  if [ -z "$cid" ]; then
    bad="无 cache-id"
  elif [ ! -d "$OVERLAY/$cid" ]; then
    bad="层数据缺失(cache-id=$cid)"
  fi
  if [ -z "$bad" ]; then
    par="$(cat "$d/parent" 2>/dev/null)"
    if [ -n "$par" ] && [ ! -d "$LAYERDB/$par" ]; then
      bad="父层条目缺失(parent=$par)"
    fi
  fi
  if [ -n "$bad" ]; then
    echo "  ❌ $bad"
    echo "     chainID=$id"
    stale_list="${stale_list}${id}
"
  fi
done
stale_n="$(printf '%s' "$stale_list" | grep -c . 2>/dev/null)"
[ -n "$stale_n" ] || stale_n=0
echo "  共 $total 条，其中残留 **$stale_n** 条"
echo

# ---------------------------------------------------------------------------
# 2. 交叉核对：dockerd 日志里那几条 chainID 到底缺什么
# ---------------------------------------------------------------------------
# 这一步是重点 —— 它直接回答「daemon 说 layer does not exist，到底是哪一层缺了」。
echo "== dockerd 日志里的 chainID 逐条核对（最近 800 行）=="
LOGS=""
if command -v journalctl >/dev/null 2>&1; then
  LOGS="$(journalctl -u docker --no-pager -n 800 2>/dev/null)"
fi

# 2a. 顺带把「点名了哪个镜像」的错误行打出来
named="$(printf '%s\n' "$LOGS" | grep -oE 'images/[^/]+/json returned error: [^"]*' | sort -u)"
if [ -n "$named" ]; then
  echo "  --- 日志里点名失败的镜像 ---"
  printf '%s\n' "$named" | sed 's/^/    /'
fi

ids="$(printf '%s\n' "$LOGS" | grep -oE 'chainID="sha256:[0-9a-f]{64}"' \
       | sed 's/.*sha256://; s/"$//' | sort -u)"
if [ -z "$ids" ]; then
  echo "  （日志里没抓到 chainID）"
  echo "  若确实报过 layer does not exist，把这条的输出发出来："
  echo "    journalctl -u docker --no-pager | grep -E 'layer does not exist' | tail -20"
else
  for id in $ids; do
    d="$LAYERDB/$id"
    echo "  chainID=$id"
    if [ ! -d "$d" ]; then
      echo "     ❌ layerdb 里**没有**这个条目 —— 这就是原因"
      continue
    fi
    cid="$(cat "$d/cache-id" 2>/dev/null)"
    par="$(cat "$d/parent" 2>/dev/null)"
    echo "     cache-id=${cid:-（无）}"
    echo "     parent  =${par:-（无）}"
    if [ -z "$cid" ]; then
      echo "     ❌ 缺 cache-id"
    elif [ ! -d "$OVERLAY/$cid" ]; then
      echo "     ❌ 层数据目录不存在：$OVERLAY/$cid"
    else
      echo "     ✅ 层目录在：$OVERLAY/$cid"
      for f in diff link; do
        if [ -e "$OVERLAY/$cid/$f" ]; then echo "        ✅ $f"; else echo "        ❌ 缺 $f"; fi
      done
    fi
    if [ -n "$par" ] && [ ! -d "$LAYERDB/$par" ]; then
      echo "     ❌ 父层条目不存在：$par"
    fi
  done
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
