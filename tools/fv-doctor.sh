#!/bin/bash
#
# FileView 预览 —— 存储卷 / 挂载一键诊断（在飞牛 NAS 上用 root 执行）
#
# 目的：把「某个卷（比如 /vol3）里的文件预览不了」定位到具体是哪一环断的：
#   ① 宿主机上这个卷到底存不存在、是不是独立挂载点
#   ② 应用目录里的 docker-compose.yaml 挂载段里有没有它
#   ③ 引擎容器**实际**的挂载里有没有它（bind 挂载只在容器创建时确定）
#   ④ 引擎容器里能不能看到它、能不能读到文件
#   ⑤ 应用用户能不能操作 docker（决定「保存设置自动重建容器」是否真的生效）
#
# 用法：
#   bash fv-doctor.sh
#   bash fv-doctor.sh --file /vol3/xxx.dwg        # 额外验证某个具体文件
#   APPDEST=/vol2/@appcenter/basemetas-fileview PKGVAR=/vol2/@appdata/basemetas-fileview bash fv-doctor.sh
#
# 本脚本**只读**：不改文件、不动容器。

set -u

APPNAME="basemetas-fileview"
ENGINE="${APPNAME}-engine"
GATEWAY="${APPNAME}-gateway"
TESTFILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --file) TESTFILE="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()  { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31m[!!]\033[0m   %s\n' "$1"; }
inf() { printf '  %s\n' "$1"; }

# 自动定位应用目录：应用可能装在任意一个存储卷上（/vol{n}/@appcenter/...）
detect_path() {
  local suffix="$1" d
  for d in /vol[0-9]*/"$suffix"/"$APPNAME"; do
    [ -d "$d" ] && { echo "$d"; return; }
  done
  echo ""
}

APPDEST="${APPDEST:-$(detect_path @appcenter)}"
PKGVAR="${PKGVAR:-$(detect_path @appdata)}"
[ -n "$APPDEST" ] || APPDEST="/vol1/@appcenter/$APPNAME"
[ -n "$PKGVAR" ]  || PKGVAR="/vol1/@appdata/$APPNAME"

D="$APPDEST/docker"
COMPOSE="$D/docker-compose.yaml"

VERDICT=()

# ---------------------------------------------------------------------------
say "0. 环境"
inf "APPDEST = $APPDEST"
inf "PKGVAR  = $PKGVAR"
inf "内核    = $(uname -r 2>/dev/null)"
if command -v docker >/dev/null 2>&1; then
  ok "找到 docker 命令"
else
  bad "找不到 docker 命令（后面几节会跳过）"
fi
inf "当前执行用户：$(id -un 2>/dev/null) (uid=$(id -u 2>/dev/null))"

# ---------------------------------------------------------------------------
say "1. 宿主机上的存储卷（这是「探测」的输入）"
MNT_VOLS="$(awk '$2 ~ /^\/vol[0-9]+$/ {print $2}' /proc/mounts 2>/dev/null | sort -u | tr '\n' ' ')"
inf "/proc/mounts 里挂载点为 /volN 的：${MNT_VOLS:-（无）}"
DIR_VOLS=""
for d in /vol[0-9] /vol[0-9][0-9] /vol[0-9][0-9][0-9]; do
  [ -d "$d" ] && DIR_VOLS="${DIR_VOLS}${d} "
done
inf "文件系统上存在的 /volN 目录  ：${DIR_VOLS:-（无）}"
if [ -z "${MNT_VOLS// /}" ]; then
  bad "一个 /volN 挂载点都没探到 —— 探测逻辑会退化"
fi

say "2. 应用目录里的挂载段（这是「写入」的结果）"
if [ -f "$COMPOSE" ]; then
  ok "存在 $COMPOSE"
  sed -n '/## VOLUMES_BEGIN/,/## VOLUMES_END/p' "$COMPOSE" | sed 's/^/    /'
  N=$(sed -n '/## VOLUMES_BEGIN/,/## VOLUMES_END/p' "$COMPOSE" | grep -c '^ *- /vol')
  inf "挂载段条数：$N"
  [ "$N" -gt 0 ] || VERDICT+=("compose 挂载段是空的 —— 探测或写入环节失败")
else
  bad "找不到 $COMPOSE（应用文件不完整，先重装）"
  VERDICT+=("应用目录缺少 docker-compose.yaml")
fi
if [ -f "$D/.env" ]; then
  ok "docker/.env 存在："
  sed 's/^/    /' "$D/.env"
else
  inf "（无 docker/.env，手工 docker compose 时会报 invalid spec，但框架运行不受影响）"
fi
if [ -f "$PKGVAR/volumes.conf" ]; then
  inf "已记住的设置 ${PKGVAR}/volumes.conf = $(tr -d '[:space:]' < "$PKGVAR/volumes.conf" 2>/dev/null)"
else
  inf "（无 volumes.conf：升级到 0.5.7 之前保存过一次设置就会生成）"
fi
if [ -f "$PKGVAR/fv-volumes.log" ]; then
  say "2b. 同步日志（最近 20 行）"
  tail -n 20 "$PKGVAR/fv-volumes.log" | sed 's/^/    /'
else
  inf "（无 fv-volumes.log：0.5.7 起才会写）"
fi

say "2c. compose 是否合法（不合法会让「停用 / 重建」一起失败）"
if command -v docker >/dev/null 2>&1 && [ -f "$COMPOSE" ]; then
  if ( cd "$D" && TRIM_APPDEST="$APPDEST" TRIM_PKGVAR="$PKGVAR" \
       docker compose config >/dev/null 2>&1 ); then
    ok "docker compose config 通过"
  else
    bad "docker compose config 报错 —— 这就是「停用报 Request failed」的直接原因"
    ( cd "$D" && TRIM_APPDEST="$APPDEST" TRIM_PKGVAR="$PKGVAR" docker compose config 2>&1 ) \
      | head -20 | sed 's/^/    /'
    VERDICT+=("compose 文件不合法，docker compose 用不了")
  fi
fi

say "2d. 容器所属 compose 项目 vs config/resource 声明（对不上就是「脱管」）"
DECL="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$APPDEST/config/resource" 2>/dev/null \
        | head -1 | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//; s/"$//')"
inf "config/resource 声明：${DECL:-（未读到）}"
if command -v docker >/dev/null 2>&1; then
  for c in "$ENGINE" "$GATEWAY"; do
    curp="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null)"
    inf "$c 实际所属：${curp:-（容器不存在）}"
    if [ -n "$DECL" ] && [ -n "$curp" ] && [ "$DECL" != "$curp" ]; then
      bad "$c 脱管：飞牛按 ${DECL} 管理，容器却在 ${curp} —— 停不掉、也不会被新配置重建"
      VERDICT+=("$c 的 compose 项目名与声明不一致（脱管）")
    fi
  done
fi
inf "（最常见的踩法：在应用目录里手工 `docker compose up -d`，"
inf "  compose 默认拿目录名 docker 当项目名，容器就此脱管。）"

# ---------------------------------------------------------------------------
say "3. 容器状态"
if command -v docker >/dev/null 2>&1; then
  docker ps -a --filter "name=$APPNAME" --format '    {{.Names}}\t{{.Status}}\t{{.Image}}' 2>&1
  for c in "$ENGINE" "$GATEWAY"; do
    st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
    if [ "$st" = "running" ]; then ok "$c 正在运行"; else bad "$c 状态：${st:-不存在}"; fi
  done
fi

say "4. 引擎容器**实际**挂载了哪些 /volN（关键：bind 挂载只在创建容器时确定）"
if command -v docker >/dev/null 2>&1; then
  ACTUAL="$(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} {{end}}{{end}}' "$ENGINE" 2>/dev/null \
            | tr ' ' '\n' | grep -E '^/vol[0-9]+$' | sort -u | tr '\n' ' ')"
  inf "容器内 bind 挂载的 /volN：${ACTUAL:-（无）}"
  for v in $DIR_VOLS; do
    case " $ACTUAL " in
      *" $v "*) ok "$v 已挂进引擎容器" ;;
      *)        bad "$v **没有**挂进引擎容器 —— 这就是「该卷文件预览不了」的直接原因"
                VERDICT+=("$v 未挂进引擎容器") ;;
    esac
  done
else
  inf "（跳过：没有 docker 命令）"
fi

say "5. 引擎容器内部实测（宿主 vs 容器逐卷对比）"
if command -v docker >/dev/null 2>&1; then
  for v in $DIR_VOLS; do
    hn="$(ls -A "$v" 2>/dev/null | wc -l | tr -d ' ')"
    if docker exec "$ENGINE" test -d "$v" 2>/dev/null; then
      cn="$(docker exec "$ENGINE" sh -c "ls -A '$v' 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')"
      sample="$(docker exec "$ENGINE" sh -c "ls -A '$v' 2>/dev/null | head -3 | tr '\n' ' '" 2>/dev/null)"
      # 关键区分：容器里「看不到这个目录」和「看得到但是空目录」是两种不同的病。
      # 后者说明挂是挂了，但 docker 绑定到的是底层空目录（挂载点当时还不存在/不在同一命名空间）。
      if [ "${cn:-0}" = "0" ] && [ "${hn:-0}" -gt 0 ] 2>/dev/null; then
        bad "$v 在容器里是**空目录**（宿主机有 $hn 项）—— 卷没真正挂上，挂到的是底层空目录"
        VERDICT+=("$v 在容器里是空目录（宿主有内容）")
      else
        ok "容器内可见 $v（容器 $cn 项 / 宿主机 $hn 项；示例：${sample:-空}）"
      fi
    else
      bad "容器内看不到 $v"
      VERDICT+=("$v 在引擎容器里不存在")
    fi
  done
  if [ -n "$TESTFILE" ]; then
    say "5b. 指定文件实测：$TESTFILE"
    if docker exec "$ENGINE" test -r "$TESTFILE" 2>/dev/null; then
      ok "引擎容器可以读取它"
    else
      bad "引擎容器读不到它（卷没挂 / 路径不对 / 权限不足）"
      VERDICT+=("引擎容器读不到 $TESTFILE")
    fi
  fi
else
  inf "（跳过：没有 docker 命令）"
fi

say "6. 应用用户能不能操作 docker（决定「保存设置自动重建容器」是否真的生效）"
U="$(sed -n 's/.*"username"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$APPDEST/config/privilege" 2>/dev/null | head -1)"
[ -n "$U" ] || U="basemetas-fileview"
inf "应用用户（config/privilege）：$U"
inf "docker.sock：$(ls -l /var/run/docker.sock 2>&1)"
inf "docker 组：$(getent group docker 2>/dev/null || echo '（不存在）')"
inf "privilege 声明的附加组：$(grep -o '"join-groups"[^]]*]' "$APPDEST/config/privilege" 2>/dev/null || echo '（无）')"
if command -v runuser >/dev/null 2>&1 && id "$U" >/dev/null 2>&1; then
  if runuser -u "$U" -- docker ps >/dev/null 2>&1; then
    ok "应用用户**可以**操作 docker"
  else
    bad "应用用户**不可以**操作 docker"
    inf "  → 「保存设置自动重建容器」「停用」「状态上报」都会静默失败，"
    inf "     表现就是「改了存储卷设置不生效 / 新加的盘永远预览不了」。"
    inf "  → 修法： usermod -aG docker $U"
    inf "     （或重装 0.5.8+，config/privilege 已声明 join-groups:[\"docker\"]）"
    VERDICT+=("应用用户 $U 无 docker 权限（所有 docker 操作静默失败）")
  fi
else
  inf "（跳过：没有 runuser 或该用户不存在）"
fi
if [ -f "$PKGVAR/fv-volumes.log" ] && grep -q "无法访问 Docker\|重建容器失败" "$PKGVAR/fv-volumes.log" 2>/dev/null; then
  bad "日志里有「无法访问 Docker / 重建容器失败」的记录"
  VERDICT+=("fv-volumes.log 记录了 docker 操作失败")
fi

say "7. 网关容器最近日志（预览打不开时看这里）"
if command -v docker >/dev/null 2>&1; then
  docker logs "$GATEWAY" --tail 15 2>&1 | sed 's/^/    /'
fi

say "8. 飞牛应用中心的错误日志（「无法停用 / Request failed」的真话在这里）"
for f in /var/log/trim_app_center/error.log /var/log/trim/app_center/error.log; do
  if [ -r "$f" ]; then
    inf "---- $f （最近 30 行）----"
    tail -n 30 "$f" | sed 's/^/    /'
  fi
done
inf "（若上面没有输出，说明这两个路径都不存在；用下面这条找一下：）"
inf "  ls -la /var/log/ | grep -i -E 'trim|app'"

# ---------------------------------------------------------------------------
say "结论"
if [ "${#VERDICT[@]}" -eq 0 ]; then
  ok "没有发现挂载层面的问题。若预览仍失败，请把本脚本完整输出发出来。"
else
  for v in ${VERDICT[@]+"${VERDICT[@]}"}; do bad "$v"; done
  echo
  inf "修复："
  inf "  bash tools/fv-repair.sh          # 按宿主机真实卷重写挂载段并重建容器"
  inf "或 应用「设置」→ 存储卷填 auto → 保存（0.5.7 起会立刻重建容器）"
fi
echo
