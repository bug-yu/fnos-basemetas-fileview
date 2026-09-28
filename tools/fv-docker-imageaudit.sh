#!/bin/bash
# FileView 预览 —— Docker 镜像记录健康审计（只读）
#
# 用途：`layer does not exist` 之后，搞清楚**影响面**——
#   哪些镜像记录坏了、分别被哪些容器引用、重启后会起不来的有哪些。
#
# 为什么不能只看 `docker images`：
#   坏掉的镜像**根本列不出来**（记录加载失败），所以必须直接枚举磁盘上的
#   image/overlay2/imagedb/content/sha256/* 记录，逐个试 `docker image inspect`。
#
# 全程只读。用法： bash tools/fv-docker-imageaudit.sh

set -u

ROOT="${FV_DOCKER_ROOT:-}"
if [ -z "$ROOT" ] && docker info >/dev/null 2>&1; then
  ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
fi
if [ -z "$ROOT" ]; then
  for c in /vol1/docker /vol2/docker /vol3/docker /var/lib/docker; do
    [ -d "$c/image/overlay2/imagedb/content/sha256" ] && { ROOT="$c"; break; }
  done
fi
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "取不到 Docker 数据根（可加 FV_DOCKER_ROOT=...）"; exit 2; }

IMAGEDB="$ROOT/image/overlay2/imagedb/content/sha256"
REPOJSON="$ROOT/image/overlay2/repositories.json"
echo "Docker 数据根：$ROOT"
echo

if ! docker info >/dev/null 2>&1; then
  echo "⚠️ docker 未运行，无法逐个 inspect。先 systemctl start docker 再跑本脚本。"
  echo "   （磁盘上的镜像记录数：$(ls -1 "$IMAGEDB" 2>/dev/null | wc -l)）"
  exit 3
fi

# ---------------------------------------------------------------------------
# 1. 逐个镜像记录做健康检查
# ---------------------------------------------------------------------------
echo "== 1. 逐个镜像记录做健康检查 =="
total=0
broken_ids=""
for f in "$IMAGEDB"/*; do
  [ -f "$f" ] || continue
  total=$((total + 1))
  id="sha256:$(basename "$f")"
  if ! docker image inspect "$id" >/dev/null 2>&1; then
    broken_ids="${broken_ids}${id}
"
  fi
done
broken_n="$(printf '%s' "$broken_ids" | grep -c . 2>/dev/null)"
[ -n "$broken_n" ] || broken_n=0
echo "  镜像记录共 $total 条，其中**坏的 $broken_n 条**"
echo

# ---------------------------------------------------------------------------
# 2. 坏记录对应哪些「名字」（从 repositories.json 反查）
# ---------------------------------------------------------------------------
echo "== 2. 坏记录对应哪些名字 =="
if [ "$broken_n" -eq 0 ]; then
  echo "  （没有坏记录）"
else
  # repositories.json 里形如  "nginx:alpine":"sha256:abc…"
  pairs="$(grep -oE '"[^"]*:[^"]*"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]{64}"' "$REPOJSON" 2>/dev/null \
           | sed 's/^"//; s/"[[:space:]]*:[[:space:]]*"/ /; s/"$//')"
  printf '%s' "$broken_ids" | while IFS= read -r id; do
    [ -n "$id" ] || continue
    names="$(printf '%s\n' "$pairs" | awk -v id="$id" '$2==id {print $1}' | tr '\n' ' ')"
    echo "  $id"
    echo "     名字：${names:-（无 —— 已是无标签的悬挂记录）}"
  done
fi
echo

# ---------------------------------------------------------------------------
# 3. 哪些容器引用了坏记录 → 这些就是「重启会起不来」的应用
# ---------------------------------------------------------------------------
echo "== 3. 受影响的容器（重启后会起不来）=="
if [ "$broken_n" -eq 0 ]; then
  echo "  （没有）"
else
  hit=0
  printf '%s' "$broken_ids" | while IFS= read -r id; do
    [ -n "$id" ] || continue
    short="$(printf '%s' "$id" | sed 's/^sha256://' | cut -c1-12)"
    out="$(docker ps -a --no-trunc --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
           | grep -E "sha256:${short}|${short}" || true)"
    if [ -n "$out" ]; then
      echo "  $id"
      printf '%s\n' "$out" | sed 's/^/     /'
      hit=1
    fi
  done
  # 再按「容器用的镜像名」兜一遍：名字可能已被 tag 覆盖，但容器仍指着旧 ID
  echo "  --- 按镜像名交叉核对（更直观）---"
  docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null | while IFS=$'\t' read -r n img; do
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      echo "     ❌ $n  →  $img"
    fi
  done
fi
echo

# ---------------------------------------------------------------------------
# 4. 参考信息
# ---------------------------------------------------------------------------
echo "== 4. 参考 =="
echo "  镜像总数（能列出来的）：$(docker images -q 2>/dev/null | wc -l)"
echo "  无标签的悬挂镜像：$(docker images -f dangling=true -q 2>/dev/null | wc -l)"
echo "  容器总数：$(docker ps -aq 2>/dev/null | wc -l)（运行中 $(docker ps -q 2>/dev/null | wc -l)）"
echo "  --- dockerd 最近报告的恢复失败 ---"
journalctl -u docker --no-pager -n 300 2>/dev/null \
  | grep -E 'not restoring image|layer does not exist' | tail -10 | sed 's/^/    /' \
  || echo "    （没有）"
echo
echo "结论怎么用："
echo "  · 坏记录「无名字」且没被容器引用 → 直接 docker image prune -f 清掉即可"
echo "  · 坏记录被某个容器引用 → 那个容器重建/重启时会失败，需要先给它换个能用的镜像"
echo "  · 想彻底重建镜像存储（代价：所有应用都要重新拉镜像）见 README"
