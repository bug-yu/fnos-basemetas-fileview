#!/bin/bash
# FileView 预览 —— Docker 侧只读诊断（安装/拉镜像失败时用）
#
# 专门查「Error response from daemon: layer does not exist」这类**镜像层/存储**问题。
# 这类报错发生在 docker pull 阶段，和本应用的任何脚本都无关
# （本应用只做容器级操作，从不 rmi / prune）。
#
# 全程只读，不改任何东西。用法：
#   bash tools/fv-docker-doctor.sh

PROJ="basemetas-fileview"
IMAGES="basemetas/fileview:1.5.2 nginx:alpine python:3-alpine"

hr() { printf '%s\n' "------------------------------------------------------------"; }
say() { echo; echo "== $* =="; }

say "0. 环境"
echo "  主机: $(hostname 2>/dev/null)   内核: $(uname -r 2>/dev/null)"
echo "  docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '取不到')"

say "1. Docker 数据根所在的盘（最可疑的一项）"
ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
echo "  DockerRootDir = ${ROOT:-取不到}"
if [ -n "$ROOT" ]; then
  df -h "$ROOT" 2>&1 | sed 's/^/  /'
  echo "  --- inode（用满也会让层解压失败）---"
  df -i "$ROOT" 2>&1 | sed 's/^/  /'
  echo "  --- 目录体积（可能较慢）---"
  du -sh "$ROOT" 2>/dev/null | sed 's/^/  /'
  du -sh "$ROOT"/overlay2 2>/dev/null | sed 's/^/  /'
fi

say "2. Docker 自己的空间账本"
docker system df 2>&1 | sed 's/^/  /'

say "3. 本应用要用的三个镜像在不在"
for i in $IMAGES; do
  if docker image inspect "$i" >/dev/null 2>&1; then
    sz="$(docker image inspect -f '{{.Size}}' "$i" 2>/dev/null)"
    echo "  ✅ $i （$(( sz / 1024 / 1024 )) MB）"
  else
    echo "  ❌ $i 本地不存在（→ compose 会去拉它）"
  fi
done

say "4. 有没有残缺/无标签的层（'layer does not exist' 的直接来源）"
docker image ls -a 2>&1 | sed 's/^/  /'

say "5. 容器现状（确认没被牵连）"
docker ps -a --format '  {{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1 | head -30

say "6. daemon 日志里那条错误的上下文（最关键）"
FOUND=0
if command -v journalctl >/dev/null 2>&1; then
  out="$(journalctl -u docker --no-pager -n 400 2>/dev/null | grep -iE 'layer does not exist|no space left|failed to (extract|register|pull)|overlay2|corrupt' | tail -25)"
  if [ -n "$out" ]; then echo "$out" | sed 's/^/  /'; FOUND=1; fi
fi
if [ "$FOUND" = 0 ]; then
  for f in /var/log/docker.log /var/log/trim/docker.log; do
    [ -r "$f" ] || continue
    out="$(grep -iE 'layer does not exist|no space left|failed to (extract|register|pull)' "$f" 2>/dev/null | tail -25)"
    if [ -n "$out" ]; then echo "  ---- $f ----"; echo "$out" | sed 's/^/  /'; FOUND=1; fi
  done
fi
[ "$FOUND" = 0 ] && echo "  （没抓到，用下面这条自己找： journalctl -u docker --no-pager | tail -80）"

say "7. 结论"
echo "  上面第 1 节的磁盘占用、第 2 节的 system df、第 6 节的 daemon 日志最关键。"
echo
echo "  ★ 如果第 6 节里出现这两句（哪怕只有一句），就是「镜像元数据残留」："
echo "      msg=\"not restoring image\" chainID=... err=\"layer does not exist\""
echo "      Handler for GET /v1.51/images/<名字>/json returned error: layer does not exist"
echo "    含义：镜像的 layerdb 记录还在，但它指向的层数据（overlay2/<cache-id>）已经没了。"
echo "    ⚠️ 这种情况**重拉永远不会成功** —— chainID 由内容算出，同样的内容算出同样的 ID，"
echo "       注册时又撞上那条坏记录。必须清掉残留："
echo "         bash tools/fv-docker-layerdb.sh          # 先看只读报告"
echo "         systemctl stop docker"
echo "         bash tools/fv-docker-layerdb.sh --fix    # 自动备份后再删"
echo "         systemctl start docker"
echo
echo "  其它常见成因："
echo "    a) Docker 数据根所在分区写满 / inode 用尽 → 层解压失败，留下残缺引用"
echo "    b) 某次 pull 被中断（断电、重启、磁盘满）→ 内容库里留下悬挂引用"
echo "    c) overlay2 层库损坏（上面全无效时才考虑重建数据根）"
hr
