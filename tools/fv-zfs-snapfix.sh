#!/bin/bash
#
# FileView 预览 —— ZFS 快照被容器命名空间「占用」的一键修复（在飞牛 NAS 上用 root 执行）
#
# 现象：
#   · 飞牛「文件快照」里删除 ZFS 快照，点删除后提示「系统繁忙」，日志里是
#       「将存储空间 N 的快照清空。成功数量：0，失败数量：1」
#   · 手工 zfs destroy 报
#       cannot destroy snapshot <pool>@<snap>: dataset is busy
#     而 zfs holds 是空的、zfs get clones 也是空的、宿主的 mount 里也看不到这条快照。
#
# 真因（实测确认，2026-10-31）：
#   ZFS 的快照被访问后，会挂到 <卷>/.zfs/snapshot/<快照名> 下面。而 Docker 的 bind
#   挂载是**递归的（rbind）** —— 本应用容器创建的那一刻，宿主上所有已挂载的快照会被
#   一并**复制进容器自己的 mount namespace**。这份副本从此一直存在（除非容器重建），
#   内核据此认为快照仍然「被挂载」→ zfs destroy 一律 EBUSY。
#
#   所以用宿主视角怎么查都查不到：
#     · mount | grep .zfs/snapshot   → 卸干净了，看不出来
#     · lsof / fuser                 → 没有进程打开快照里的文件
#     · zfs holds / clones           → 全空
#   引用藏在**别的 mount namespace** 里，要 grep /proc/*/mountinfo 才看得见。
#
# 修法：
#   卸载宿主上的 .zfs/snapshot 挂载 → 重建本应用容器 → 新容器的 namespace 里不再有
#   副本 → 快照即可正常删除。
#
# 用法：
#   bash fv-zfs-snapfix.sh            # 检测 + 卸载 + 重建容器 + 复验
#   bash fv-zfs-snapfix.sh --check    # 只读诊断，不改任何东西
#   APPDEST=/vol2/@appcenter/basemetas-fileview bash fv-zfs-snapfix.sh
#
# ⚠️ 副作用（可接受，但要先知道）：
#   · 卸载快照挂载的瞬间，正在浏览「以前的版本」的 SMB 客户端可能报一次错误，
#     ZFS 会在下次访问时按需重新挂载。
#   · 重建容器 = 应用中断几秒（网关 + 引擎 + 闸门）。
#
# ⚠️ 治本（不做的话还会复发）：
#   · 若不用 Windows「以前的版本」，去飞牛 SMB 设置停用影子副本 / 以前的版本 ——
#     smbd 就不会去挂快照，宿主永远是干净的，本脚本也不必再跑。
#   · 快照保留策略别按小时无限攒（几百条时飞牛那个「清空」按钮本身就会超时）。

set -u

MODE="fix"
for a in "$@"; do
  case "$a" in
    --check)          MODE="check" ;;
    --help|-h)        MODE="help" ;;
    *)                ;;
  esac
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31m[!!]\033[0m   %s\n' "$1"; }
warn() { printf '  \033[33m[--]\033[0m   %s\n' "$1"; }
inf()  { printf '  %s\n' "$1"; }

if [ "$MODE" = "help" ]; then
  sed -n '3,50p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# ---------------------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------------------
say "0. 前置检查"

if [ "$(id -u 2>/dev/null)" != "0" ]; then
  bad "必须以 root 执行（要 umount 宿主的 ZFS 快照挂载）"
  inf "  → sudo bash $0   或直接 root 登录"
  exit 1
fi
ok "以 root 运行"

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
ENGINE="basemetas-fileview-engine"

inf "APPDEST = $APPDEST"
inf "PKGVAR  = $PKGVAR"

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
  HAVE_DOCKER=1
  ok "docker 可用"
else
  warn "docker 不可用或没权限 —— 只能做「卸载宿主挂载」，无法重建容器（副本仍在，修不干净）"
fi

# ---------------------------------------------------------------------------
# 1. 宿主侧：.zfs/snapshot 挂载
# ---------------------------------------------------------------------------
say "1. 宿主上已挂载的 ZFS 快照（<卷>/.zfs/snapshot/*）"

# /proc/mounts 第 3 列是挂载点。只认 /.zfs/snapshot/ 下的，别误伤 /volN 主挂载。
host_snap_mounts() {
  awk '$3 ~ /\/\.zfs\/snapshot\// {print $3}' /proc/mounts 2>/dev/null
}

HOST_CNT="$(host_snap_mounts | wc -l | tr -d ' ')"
inf "数量：${HOST_CNT}"
if [ "${HOST_CNT:-0}" -gt 0 ] && [ "${HOST_CNT:-0}" -le 5 ]; then
  host_snap_mounts | sed 's/^/    /'
elif [ "${HOST_CNT:-0}" -gt 5 ]; then
  host_snap_mounts | head -n 5 | sed 's/^/    /'
  inf "    …（其余 $((HOST_CNT - 5)) 条省略）"
fi
if [ "${HOST_CNT:-0}" -eq 0 ]; then
  ok "宿主上没有快照挂载（要么本来就没有，要么已经卸干净了）"
fi

# ---------------------------------------------------------------------------
# 2. 命名空间侧：谁把快照挂载「带走」了
# ---------------------------------------------------------------------------
# ⚠️ 这一步才是关键。宿主 mount 看不见的东西，/proc/<pid>/mountinfo 看得见。
say "2. 哪些进程的 mount namespace 里带着 .zfs 快照挂载"

NS_FILES="$(grep -l "zfs/snapshot" /proc/[0-9]*/mountinfo 2>/dev/null || true)"
NS_CNT=0
if [ -n "$NS_FILES" ]; then
  NS_CNT="$(printf '%s\n' "$NS_FILES" | wc -l | tr -d ' ')"
fi
inf "进程数：${NS_CNT}"

if [ "${NS_CNT:-0}" -gt 0 ]; then
  bad "有进程的命名空间里带着快照挂载副本 —— 这就是 zfs destroy 报 dataset is busy 的原因"
  # 按 namespace 去重，只报前几个，避免刷屏
  printf '%s\n' "$NS_FILES" | while read -r p; do
    pid="${p#/proc/}"; pid="${pid%/mountinfo}"
    ns="$(readlink "/proc/$pid/ns/mnt" 2>/dev/null)"
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
    printf '%s\t%s\t%s\n' "$ns" "$pid" "$comm"
  done | sort -u | head -n 12 | sed 's/^/    /'
else
  ok "没有进程的命名空间里带快照挂载"
fi

# ---------------------------------------------------------------------------
# 3. 容器侧：引擎容器的命名空间里到底有几个副本
# ---------------------------------------------------------------------------
# 判据取「容器自己看得到的挂载数」：非 0 就说明副本进了容器，会一直 pin 住快照。
container_snap_cnt() {
  [ "$HAVE_DOCKER" = "1" ] || { echo ""; return 0; }
  docker exec "$ENGINE" sh -c "cat /proc/self/mounts 2>/dev/null | grep -c '\.zfs/snapshot'" \
    2>/dev/null | tr -d ' '
}

CONTAINER_CNT=""
if [ "$HAVE_DOCKER" = "1" ]; then
  say "3. 引擎容器的命名空间里有多少快照挂载副本"
  CONTAINER_CNT="$(container_snap_cnt)"
  if [ -z "$CONTAINER_CNT" ]; then
    warn "读不到（容器没在运行，或 exec 失败）"
  elif [ "$CONTAINER_CNT" = "0" ]; then
    ok "容器里没有快照挂载副本（正常）"
  else
    bad "容器里带着 ${CONTAINER_CNT} 个快照挂载副本 —— 快照删不掉就是它造成的"
  fi
fi

# ---------------------------------------------------------------------------
# 4. --check：到此为止
# ---------------------------------------------------------------------------
say "结论"
DIRTY=0
[ "${HOST_CNT:-0}" -gt 0 ] && DIRTY=1
[ "${NS_CNT:-0}"   -gt 0 ] && DIRTY=1
case "${CONTAINER_CNT:-0}" in
  ""|0) ;;
  *) DIRTY=1 ;;
esac

if [ "$DIRTY" = "0" ]; then
  ok "干净：没有快照挂载副本，ZFS 快照可以正常删除"
  inf "  若飞牛里删除仍报「系统繁忙」，那不是这个问题 —— 去看"
  inf "    zfs list -t snapshot、zfs holds、dmesg | grep -i zfs"
  echo
  exit 0
fi

if [ "$MODE" = "check" ]; then
  bad "发现问题（本次为 --check 只读模式，没有做任何改动）"
  inf "  修法： bash $0"
  echo
  # 只读模式也用退出码表达结论（0=干净，1=有问题），方便脚本化调用
  exit 1
fi

bad "发现问题，进入修复：先卸宿主快照挂载，再重建容器"
inf "（重建期间应用会中断几秒；正在浏览「以前的版本」的 SMB 客户端可能闪一次错误）"

# ---------------------------------------------------------------------------
# 5. 卸载宿主上的快照挂载
# ---------------------------------------------------------------------------
say "5. 卸载宿主上的快照挂载"
# 先普通卸载；卸不掉（有进程 cwd / 打开的文件）再上 -l 做惰性卸载。
# 两种都不影响 /volN 主挂载，也不会动数据。
UNM_OK=0
UNM_FAIL=0
while read -r m; do
  [ -n "$m" ] || continue
  if umount "$m" 2>/dev/null; then
    UNM_OK=$((UNM_OK + 1))
  elif umount -l "$m" 2>/dev/null; then
    UNM_OK=$((UNM_OK + 1))
  else
    UNM_FAIL=$((UNM_FAIL + 1))
    warn "卸不掉：$m"
  fi
done <<EOF
$(host_snap_mounts)
EOF

inf "已卸载：${UNM_OK}    失败：${UNM_FAIL}"
LEFT="$(host_snap_mounts | wc -l | tr -d ' ')"
if [ "${LEFT:-0}" -eq 0 ]; then
  ok "宿主上已无快照挂载"
else
  warn "宿主上还剩 ${LEFT} 个（多半被 SMB 会话或进程 cwd 占着，见下面「若仍然失败」）"
fi

# ---------------------------------------------------------------------------
# 6. 重建容器（让新 namespace 干净）
# ---------------------------------------------------------------------------
say "6. 重建本应用容器"
if [ "$HAVE_DOCKER" != "1" ]; then
  bad "docker 不可用，跳过重建 —— 副本还在容器里，快照仍然删不掉"
  inf "  修好 docker 权限后重跑： bash $0"
  echo
  exit 1
fi
if [ ! -f "$COMPOSE" ]; then
  bad "找不到 $COMPOSE（可用 APPDEST=... 指定应用目录）"
  exit 1
fi

# 项目名必须以 config/resource 声明的为准 —— 飞牛就是按这个名字管这套容器的。
# 对不上就是「脱管」：飞牛停不掉、也不会用新配置重建。这里和 fv-repair.sh 同一套处理。
WANT="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$APPDEST/config/resource" 2>/dev/null \
        | head -1 | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//; s/"$//')"
CUR="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$ENGINE" 2>/dev/null)"
[ -n "$WANT" ] || WANT="$CUR"
[ -n "$WANT" ] || WANT="docker"
inf "config/resource 声明：$WANT    容器实际所属：${CUR:-（容器不存在）}"
if [ -n "$CUR" ] && [ "$CUR" != "$WANT" ]; then
  warn "不一致（脱管）：先删除现有容器，再按 $WANT 重建"
  docker rm -f "$ENGINE" basemetas-fileview-gateway >/dev/null 2>&1
fi

export TRIM_APPDEST="$APPDEST"
export TRIM_PKGVAR="$PKGVAR"
REBUILD_OK=0
# 最多两轮：万一 smbd 在「卸载」和「重建」之间又把快照挂回来了，
# 新容器会把副本再带进去 —— 那时再卸一次、再重建一次即可。
for ROUND in 1 2; do
  [ "$ROUND" = "2" ] && say "6b. 第 2 轮（容器里仍有副本，重试一次）"

  ( cd "$D" && docker compose -p "$WANT" up -d --force-recreate --remove-orphans ) 2>&1 \
    | sed 's/^/    /'

  sleep 3
  ST="$(docker inspect -f '{{.State.Status}}' "$ENGINE" 2>/dev/null)"
  if [ "$ST" != "running" ]; then
    bad "引擎容器状态异常：${ST:-不存在}"
    inf "  看日志： docker logs $ENGINE --tail 40"
    exit 1
  fi
  ok "引擎容器运行中"

  NOW_CNT="$(container_snap_cnt)"
  if [ "${NOW_CNT:-0}" = "0" ]; then
    REBUILD_OK=1
    ok "容器命名空间里已无快照挂载副本"
    break
  fi
  warn "容器里仍有 ${NOW_CNT:-?} 个副本"
  # 再卸一次宿主上的挂载，然后进下一轮
  while read -r m; do
    [ -n "$m" ] && { umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null; }
  done <<EOF
$(host_snap_mounts)
EOF
done

# ---------------------------------------------------------------------------
# 7. 收尾
# ---------------------------------------------------------------------------
say "复验"
HOST_LEFT="$(host_snap_mounts | wc -l | tr -d ' ')"
NS_LEFT_N="$(grep -l "zfs/snapshot" /proc/[0-9]*/mountinfo 2>/dev/null | wc -l | tr -d ' ')"
inf "宿主快照挂载：${HOST_LEFT}"
inf "带副本的进程：${NS_LEFT_N}"
C_FINAL="$(container_snap_cnt)"
inf "容器内副本：${C_FINAL:-读不到}"

echo
if [ "$REBUILD_OK" = "1" ] && [ "${NS_LEFT_N:-0}" -eq 0 ]; then
  ok "修好了 —— 现在回飞牛「文件快照」删一次试试"
  echo
  inf "若删除仍失败，先确认这条快照本身有没有别的占用："
  inf "  zfs holds '池名@快照名'"
  inf "  zfs get -H -o value clones '池名@快照名'"
  echo
  inf "⚠️ 不治本的话会复发，建议顺手做两件事："
  inf "  1) 不用 Windows「以前的版本」就去飞牛 SMB 设置里停用影子副本 ——"
  inf "     smbd 不挂快照，宿主始终干净，本脚本也不必再跑。"
  inf "  2) 快照保留策略别按小时无限攒：几百条时飞牛那个「清空」按钮自己就会超时，"
  inf "     而容器一旦持有副本，逐条 zfs destroy 也会全部报 dataset is busy。"
else
  warn "没修干净。常见原因："
  inf "  · smbd 在卸载和重建之间又把快照挂回去了 → 临时停 SMB 再来一次："
  inf "      systemctl stop smbd && bash $0 && systemctl start smbd"
  inf "  · 有进程 cwd/fd 还卡在快照里 → 查："
  inf "      grep -l 'zfs/snapshot' /proc/[0-9]*/mountinfo"
  inf "      对每个 pid： readlink /proc/<pid>/cwd"
  inf "  · 还有别的容器递归 bind 了同一个卷 → docker restart 那个容器后再跑本脚本"
  exit 1
fi
echo
