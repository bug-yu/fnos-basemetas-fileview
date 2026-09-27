#!/bin/bash
# FileView 预览 —— 存储卷挂载 / 容器重建的公共逻辑
#
# 由 cmd/install_callback、cmd/config_callback、cmd/upgrade_callback、cmd/main 共同 source。
# 这里的每一条判断背后都是实际踩过的坑，注释里写清楚了原因，改动前请先读。
#
# ⚠️ 为什么这个文件会放在 docker/ 目录下（而不是更合理的 lib/）：
#    fnpack 打包 app.tgz 时只收 docker/、ui/、config/ 三个目录，放在 lib/ 会被整目录丢掉，
#    装好以后脚本 source 不到、静默 exit 0，现象是「改设置没反应」，极难排查。
#    副作用：本目录会被挂进 nginx 的 conf.d，但 nginx 只 include *.conf，.sh 不会被加载。
#
# ⚠️ 一个必须记住的前提（0.5.7 的教训）：
#    ${TRIM_APPDEST}/docker/docker-compose.yaml 是「安装包里的模板文件」，
#    升级时框架会把新的 app.tgz 重新释放到 ${TRIM_APPDEST}，**这个文件会被覆盖回模板内容**
#    （挂载段是写死的 /vol1、/vol2）。所以任何「释放文件」之后都必须重新写一遍挂载段，
#    否则之前配置好的 /vol3 就凭空消失了 —— 现象就是「升级完 vol3 又预览不了」。

# 全部用 ${VAR:-} 取值：这个库会被多个回调 source，缺变量时应当是「什么都不做」，
# 而不是让脚本直接崩在 source 那一行（排查起来完全没有线索）。
FV_COMPOSE="${TRIM_APPDEST:-}/docker/docker-compose.yaml"

# 排查日志：落在应用数据目录，用于把「改了设置没反应」这类静默失败变成可查的证据。
FV_LOG=""
[ -n "${TRIM_PKGVAR:-}" ] && FV_LOG="${TRIM_PKGVAR}/fv-volumes.log"

fv_log() {
  [ -n "$FV_LOG" ] || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$FV_LOG" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# 0a. 当前用户能不能操作 Docker —— 这是本包最容易踩、也最难查的坑
# ---------------------------------------------------------------------------
# 生命周期脚本是以**应用用户**（config/privilege 里的 basemetas-fileview）身份运行的，
# 而它默认**不在 docker 组里**；/var/run/docker.sock 是 root:docker 0660，
# 于是所有 docker 操作（重建容器 / 查状态 / 停容器）会**全部静默失败**。
#
# 实测症状（就是这一条导致的）：
#   · 改了存储卷设置保存后，容器根本没重建 → 新加的卷永远挂不上
#   · cmd/main status 的 docker inspect 一直失败 → 飞牛看到的运行状态是错的
#   · 点「停用」报 Request failed, please try again later
#   验证：runuser -u basemetas-fileview -- docker ps   →  Permission denied
#
# 修法：config/privilege 里声明 join-groups: ["docker"]（0.5.8 起已加）。
# 注意：这等于把 docker socket 交给应用用户，属于较大的权限授予；
#       本应用本来就要以 root 身份在容器里跑预览引擎、只读挂载全部存储卷，
#       权限模型上没有变得更弱，但换机器部署时请知悉这一点。
fv_docker_ok() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps >/dev/null 2>&1
}

# docker 用不了时，写一条「照着做就能好」的提示，而不是静默跳过
fv_docker_denied_note() {
  local who
  who="$(id -un 2>/dev/null)"
  fv_log "错误：当前用户 ${who} 无法访问 Docker（/var/run/docker.sock 需要 docker 组权限）"
  # 只在日志里第一次出现时写用户可见提示，避免每次启动都弹一遍
  if [ -n "${TRIM_TEMP_LOGFILE:-}" ] && [ -n "$FV_LOG" ] \
     && [ "$(grep -c '无法访问 Docker' "$FV_LOG" 2>/dev/null)" = "1" ]; then
    {
      echo "本应用需要以应用用户身份操作 Docker（重建容器 / 查运行状态 / 停容器），但当前用户 ${who} 没有权限。"
      echo "后果：改了存储卷设置不会重建容器，新加的存储卷不会生效。"
      echo "修法（二选一）："
      echo "  A. 安装 0.5.8 及以后的安装包（config/privilege 已声明 join-groups: [\"docker\"]）；"
      echo "  B. 在 NAS 上手工授权： usermod -aG docker ${who}"
    } >> "$TRIM_TEMP_LOGFILE" 2>/dev/null
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 0. 设置持久化
# ---------------------------------------------------------------------------
# 为什么要落盘：
#   向导变量只在「安装 / 保存设置」那一次回调里存在；而升级回调、应用启动（cmd/main start）
#   都拿不到 wizard_volumes。不记住用户填的值，这些时机就只能瞎猜（猜错就是又回到 /vol1,/vol2）。
FV_STATE="${TRIM_PKGVAR:-}/volumes.conf"

fv_save_state() {
  [ -n "${TRIM_PKGVAR:-}" ] || return 0
  mkdir -p "$TRIM_PKGVAR" 2>/dev/null
  printf '%s\n' "$1" > "$FV_STATE" 2>/dev/null
  return 0
}

fv_load_state() {
  [ -n "${TRIM_PKGVAR:-}" ] && [ -r "$FV_STATE" ] || { echo ""; return 0; }
  tr -d '[:space:]' < "$FV_STATE" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# 1. 探测宿主机上真实存在的存储卷
# ---------------------------------------------------------------------------
# 为什么需要自动探测：
#   早期版本把默认写死成 /vol1,/vol2。用户机器上实际有 /vol1 /vol2 /vol3 三块盘，
#   安装向导默认只有前两个 → /vol3 里的文件一律「文件不存在」。
#   更糟的是卸载重装时向导又回到默认值，问题必然复现。
#   所以默认改成 auto：直接以宿主机真实挂载情况为准。
#
# 为什么是「并集」而不是「挂载点优先、探不到再退化成目录扫描」：
#   旧写法只要 /proc/mounts 里探到任意一个 /volN 就完全不走目录兜底。
#   于是「/vol1、/vol2 是独立挂载点，/vol3 却是 bind mount 或普通目录」这种混合环境下，
#   /vol3 会被静默漏掉 —— 又回到「vol3 预览不了」。两类来源取并集才是稳的。

fv_mounts_volumes() {
  [ -r /proc/mounts ] || return 0
  # 允许挂载点末尾带 "/"（手工 mount 时可能出现），统一去掉再输出
  awk '$2 ~ /^\/vol[0-9]+\/*$/ {p=$2; sub(/\/+$/, "", p); print p}' /proc/mounts 2>/dev/null
}

fv_dir_volumes() {
  local d
  # ⚠️ 只认「没有前导零」的卷号：飞牛的存储卷是 /vol1、/vol2、/vol3…
  #    实测真机上存在 /vol00 这种目录（不是存储卷），旧写法 /vol[0-9][0-9] 会把它一起收进来。
  #    用户显式填写的列表不走这里（见 fv_normalize），所以不受影响。
  for d in /vol[1-9] /vol[1-9][0-9] /vol[1-9][0-9][0-9]; do
    [ -d "$d" ] || continue
    printf '%s\n' "$d"
  done
}

fv_detect_volumes() {
  { fv_mounts_volumes; fv_dir_volumes; } 2>/dev/null \
    | awk -F'/' '/^\/vol[0-9]+$/ {n=$2; sub(/^vol/, "", n); print n "\t" $0}' \
    | sort -n -u \
    | cut -f2 \
    | tr '\n' ',' \
    | sed 's/,$//'
}

# 把用户手填的字符串规范成 /volN,的形式，顺手剔掉不合法的项
fv_normalize() {
  local raw="$1" out="" v
  local OLD_IFS="$IFS"
  IFS=','
  for v in $raw; do
    v="$(printf '%s' "$v" | tr -d '[:space:]')"
    case "$v" in
      /vol[0-9]|/vol[0-9][0-9]|/vol[0-9][0-9][0-9]) out="${out:+${out},}${v}" ;;
    esac
  done
  IFS="$OLD_IFS"
  echo "$out"
}

# 按向导取值算出最终要挂载的存储卷列表
fv_resolve_volumes() {
  local raw="$1" list
  case "$(printf '%s' "${raw:-auto}" | tr -d '[:space:]' | tr 'A-Z' 'a-z')" in
    auto|"") list="$(fv_detect_volumes)" ;;
    *)       list="$(fv_normalize "$raw")" ;;
  esac
  [ -n "$list" ] || list="/vol1"
  echo "$list"
}

# ---------------------------------------------------------------------------
# 2. 重写 docker-compose.yaml 里的挂载段
# ---------------------------------------------------------------------------
# ⚠️ 只重写 ## VOLUMES_BEGIN / ## VOLUMES_END 之间的内容，标记行本身绝不能删，
#    否则下一次回调就找不到锚点了。
# 内容没变就不落盘：避免每次启动都换一次 inode，也让「谁改的」在文件时间戳上看得清。
fv_write_volumes() {
  local list="$1" block="" v tmp
  [ -n "$list" ] || return 1
  [ -f "$FV_COMPOSE" ] || return 1

  local OLD_IFS="$IFS"
  IFS=','
  for v in $list; do
    block="${block}      - ${v}:${v}:ro
"
  done
  IFS="$OLD_IFS"

  tmp="${FV_COMPOSE}.new"
  if awk -v block="$block" '
    /## VOLUMES_BEGIN/ { print; printf "%s", block; skip=1; next }
    /## VOLUMES_END/   { skip=0 }
    skip != 1 { print }
  ' "$FV_COMPOSE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    if cmp -s "$tmp" "$FV_COMPOSE" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      return 0
    fi
    mv "$tmp" "$FV_COMPOSE"
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# ---------------------------------------------------------------------------
# 3. 写 .env —— 让命令行里手动 docker compose 也能正常工作
# ---------------------------------------------------------------------------
# 踩坑：直接在命令行 `docker compose up -d`，TRIM_APPDEST / TRIM_PKGVAR 为空，
#   compose 把 "/app/target:rw" 解析成非法挂载，报
#     invalid spec: :/app/target:rw: empty section between colons
#   这两个变量只有飞牛框架运行脚本时才注入，手工执行时没有。
#   compose 会自动读取 compose 文件同目录的 .env，写一份进去即可根治。
#
# ⚠️ 只写非空值：写进去一个空的 TRIM_PKGVAR= 反而会把 compose 里的
#    "${TRIM_PKGVAR}/fonts:..." 解析成非法挂载，比不写更糟。
fv_write_env() {
  [ -n "${TRIM_APPDEST:-}" ] || return 0
  local d="${TRIM_APPDEST}/docker"
  [ -d "$d" ] || return 0
  {
    echo "# 由应用自动生成，请勿手改。"
    echo "# docker compose 会自动读取本文件，这样在命令行手工执行"
    echo "#   docker compose up -d"
    echo "# 也不会因为 TRIM_* 变量为空而报 invalid spec。"
    [ -n "${TRIM_APPDEST:-}" ] && echo "TRIM_APPDEST=${TRIM_APPDEST}"
    [ -n "${TRIM_PKGVAR:-}" ]  && echo "TRIM_PKGVAR=${TRIM_PKGVAR}"
  } > "$d/.env" 2>/dev/null
  [ -n "${TRIM_PKGVAR:-}" ] || fv_log "警告：TRIM_PKGVAR 为空，.env 未写入该项"
  return 0
}

# ---------------------------------------------------------------------------
# 3b. 把 compose 里的 ${TRIM_*} 就地替换成真实路径
# ---------------------------------------------------------------------------
# 为什么必须做（「点停用报 Request failed」的高度嫌疑）：
#   compose 里的
#       - "${TRIM_PKGVAR}/fonts:/usr/local/share/fonts:ro"
#       - "${TRIM_APPDEST}/docker:/etc/nginx/conf.d:ro"
#   靠变量插值。而 TRIM_APPDEST / TRIM_PKGVAR **只有飞牛框架执行应用脚本时才注入**。
#   一旦框架自己那次 `docker compose`（停用 / 卸载 / 更新都会用到）没有这两个变量，
#   compose 就会把 ":/app/target:rw" 解析成非法挂载并整体失败：
#       invalid spec: :/app/target:rw: empty section between colons
#   → 界面只报一句 Request failed, please try again later，看不出真因。
#   .env 只能救「在 compose 同目录执行」这一种情况，救不了别的工作目录。
#
# 所以这里直接把变量替换成字面量，compose 从此不依赖任何环境变量：
#   升级时框架重新释放 app.tgz 会把模板（含 ${TRIM_*}）覆盖回来，我们下次回调再替换一次。
fv_materialize_env() {
  [ -f "$FV_COMPOSE" ] || return 1
  [ -n "${TRIM_APPDEST:-}" ] || return 1
  [ -n "${TRIM_PKGVAR:-}" ]  || return 1
  # 已经是字面量（没有 ${TRIM_ 了）就直接返回，保持幂等
  grep -q '\${TRIM_' "$FV_COMPOSE" 2>/dev/null || return 0

  local tmp="${FV_COMPOSE}.mat"
  sed -e "s|\${TRIM_APPDEST}|${TRIM_APPDEST}|g" \
      -e "s|\${TRIM_PKGVAR}|${TRIM_PKGVAR}|g" \
      "$FV_COMPOSE" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  if [ -s "$tmp" ]; then
    mv "$tmp" "$FV_COMPOSE"
    fv_log "已把 compose 里的 \${TRIM_*} 替换为真实路径（不再依赖框架注入环境变量）"
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# ---------------------------------------------------------------------------
# 4. 统一入口：解析 → 写挂载段 → 写 .env → 记住设置 → 核对容器
# ---------------------------------------------------------------------------
# 所有回调（安装 / 保存设置 / 升级 / 启动）都走这里，避免任何一条路径漏掉重写。
# 参数一为空时依次回退：上次保存的设置 → auto。
# 参数二 mode：
#   ensure （默认）容器里缺卷才重建 —— 用于「启动」「安装」
#   rebuild        无条件重建     —— 用于「保存设置」「升级」（挂载列表可能变少，
#                                  少了的话没有「缺卷」可检测，必须无条件重建）
#   none           只写文件，不动容器
fv_sync_volumes() {
  local raw="${1:-}" mode="${2:-ensure}" list

  [ -n "$raw" ] || raw="$(fv_load_state)"
  [ -n "$raw" ] || raw="auto"

  fv_save_state "$raw"

  # 把探测的输入也记下来：以后再遇到「某个盘没挂上」，
  # 看一眼日志就知道是「压根没探到」还是「探到了但没写进去」，不用再猜。
  case "$(printf '%s' "$raw" | tr -d '[:space:]' | tr 'A-Z' 'a-z')" in
    auto|"")
      fv_log "探测输入：mounts=[$(fv_mounts_volumes | tr '\n' ' ')] dirs=[$(fv_dir_volumes | tr '\n' ' ')]"
      ;;
  esac

  list="$(fv_resolve_volumes "$raw")"
  if fv_write_volumes "$list"; then
    fv_log "挂载段已同步：设置=${raw} 实际=${list}"
  else
    fv_log "错误：挂载段写入失败（设置=${raw} 实际=${list}），请检查 ${FV_COMPOSE} 的 VOLUMES_BEGIN/END 标记是否还在"
  fi
  fv_write_env
  fv_materialize_env

  case "$mode" in
    rebuild) fv_rebuild ;;
    ensure)  fv_ensure_mounts "$list" ;;
    *)       ;;
  esac

  echo "$list"
}

# ---------------------------------------------------------------------------
# 4a. 读出 config/resource 里声明的 compose 项目名
# ---------------------------------------------------------------------------
# 为什么必须用它，而不是「读现有容器的 project 标签」：
#   飞牛应用中心是按 config/resource 声明的名字来管这套容器的
#   （停用 / 启动 / 重建都走这个名字）。
#   一旦容器实际所属的项目名和声明的名字对不上，飞牛就**看不到这些容器**：
#     · 点「停用」→ 找不到容器 → 报 Request failed, please try again later
#     · 更新 / 重建 → 认为没有容器，不会用新配置重建 → 新加的卷永远挂不上
#   最典型的踩法：在应用目录里手工 `docker compose up -d`（README 以前还推荐过），
#   compose 默认用**目录名**（docker）当项目名，于是容器就「脱管」了。
fv_declared_project() {
  local f="${TRIM_APPDEST:-}/config/resource" n
  [ -r "$f" ] || return 0
  n="$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 \
       | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  # 只接受合法的 compose 项目名（字母/数字/./_/-），避免解析出脏值后被拿去删容器
  if [ -n "$n" ] && [ -z "${n//[a-zA-Z0-9_.-]/}" ]; then
    printf '%s' "$n"
  fi
}

# 容器当前所属的 compose 项目名
fv_current_project() {
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' \
    basemetas-fileview-engine 2>/dev/null
}

# ---------------------------------------------------------------------------
# 4c. 清掉 compose 重建被中断时残留的「临时容器」
# ---------------------------------------------------------------------------
# 名字形如 <12位十六进制>_basemetas-fileview-xxx，是 compose 用 --force-recreate
# 重建带 container_name 的容器时的中间产物：先建临时名的新容器 → 删旧的 → 再改名。
#
# ⚠️ 为什么必须清（2026-09-27 实测踩到，而且是**持续失败**不是偶发）：
#   重建一旦被中途打断（回调脚本超时被杀、进程被 kill），临时容器就留下来了。
#   它和正式容器同名同项目，此后飞牛每次停用 / 卸载都会去停它：
#       Container f355c8f78542_basemetas-fileview-engine  Stopping
#       Container basemetas-fileview-engine               Error while Stopping
#       Error response from daemon: No such container: f355c8f78542…
#   → 界面每次都是 Request failed。
#   只按正式容器名强删（0.5.7 的卸载修复）删不到它，所以必须按名字模式清。
#
# 安全：只删名字严格匹配 `<12位十六进制>_basemetas-fileview-` 的容器，不误伤其它容器。
fv_clean_orphans() {
  command -v docker >/dev/null 2>&1 || return 0
  local n
  docker ps -a --filter name=basemetas-fileview --format '{{.Names}}' 2>/dev/null \
    | grep -E '^[0-9a-f]{12}_basemetas-fileview-' \
    | while read -r n; do
        [ -n "$n" ] || continue
        fv_log "清理 compose 残留的临时容器：${n}"
        docker rm -f "$n" >/dev/null 2>&1
      done
  return 0
}

# ---------------------------------------------------------------------------
# 5. 重建容器 —— 「改了设置却不生效」的根治
# ---------------------------------------------------------------------------
# 踩坑：改完设置、compose 文件里也确实多了 /vol3，但容器不重建，
#       bind 挂载是不会自己生效的（docker restart 也不行，必须重建）。
#       而飞牛框架在保存设置后并不会重建容器，只能我们自己来。
#
# 项目名：**必须用 config/resource 里声明的名字**（框架认这个名字），
#   而不是「现有容器的标签」—— 否则会出现「容器属于 docker、框架管 basemetas-fileview」
#   这种脱管状态：框架停不掉、也不会拿新配置重建，表现就是
#   「保存设置没反应 + 点停用报 Request failed」。
#
# ⚠️ 这里以前把所有输出和退出码都吞掉了（`>/dev/null 2>&1`），
#    于是「docker compose 失败」和「一切正常」在用户看来完全一样。
#    现在失败会写日志 + 写 TRIM_TEMP_LOGFILE。
fv_rebuild() {
  [ -n "${TRIM_APPDEST:-}" ] || return 0
  command -v docker >/dev/null 2>&1 || { fv_log "跳过重建容器：找不到 docker 命令"; return 0; }
  # 没有 docker 权限就别装了 —— 明确写出来，别让它看起来像「已经重建成功」
  fv_docker_ok || { fv_docker_denied_note; return 0; }

  # 先把上次重建被打断留下的临时容器清掉，否则 compose 会因为名字冲突/残留状态失败
  fv_clean_orphans

  local d="${TRIM_APPDEST}/docker"
  [ -f "$d/docker-compose.yaml" ] || { fv_log "跳过重建容器：缺少 $d/docker-compose.yaml"; return 0; }

  # 安装阶段容器还不存在，交给框架首次创建，这里不插手
  docker inspect basemetas-fileview-engine >/dev/null 2>&1 || return 0

  local want cur out rc
  want="$(fv_declared_project)"
  cur="$(fv_current_project)"
  [ -n "$want" ] || want="$cur"
  [ -n "$want" ] || want="docker"

  # 项目名不一致 → 容器「脱管」。必须先删掉再按声明名重建，
  # 否则 compose 会因为「容器名已被占用」直接失败（Conflict: container name already in use）。
  if [ -n "$cur" ] && [ "$cur" != "$want" ]; then
    fv_log "容器当前属于 compose 项目 ${cur}，与声明的 ${want} 不一致（脱管）；先删除再按 ${want} 重建"
    docker rm -f basemetas-fileview-engine basemetas-fileview-gateway >/dev/null 2>&1
  fi

  export TRIM_APPDEST TRIM_PKGVAR
  out="$( cd "$d" && docker compose -p "$want" up -d --force-recreate --remove-orphans 2>&1 )"
  rc=$?

  if [ "$rc" -eq 0 ]; then
    fv_log "容器已重建（project=${want}${cur:+，原 ${cur}}）"
  else
    fv_log "错误：容器重建失败 rc=${rc} project=${want} :: $(printf '%s' "$out" | tr '\n' ' ')"
    if [ -n "${TRIM_TEMP_LOGFILE:-}" ]; then
      {
        echo "存储卷设置已写入，但重建容器失败，新挂载不会生效。"
        echo "docker compose 输出："
        printf '%s\n' "$out"
      } >> "$TRIM_TEMP_LOGFILE" 2>/dev/null
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 4b. 核对引擎容器里**真的**能看到这些卷，缺了就重建
# ---------------------------------------------------------------------------
# 为什么需要（实测踩到的坑）：
#   引擎容器的日志里报 `文件不存在: /vol3/1000/某目录/某文件.ofd`，而同一时刻 /vol1 的文件
#   一切正常 —— 说明请求链路没问题，是 **/vol3 根本没挂进引擎容器**。
#   而「只改 docker-compose.yaml」在两种情况下是不够的：
#     ① 飞牛框架可能在我们回调之前就用模板把容器建好了，之后未必再 `compose up`；
#     ② 老容器已经存在、compose 认为配置没变，就不会重建。
#   bind 挂载在容器创建那一刻就定死了，文件改多少次都没用，只能重建容器。
#   所以在「启动」「安装」这两个时机主动进容器核对一遍，缺卷就重建，把这一环兜住。
#
# 用 `docker exec` 而不是解析 `docker inspect`：
#   前者问的就是「引擎进程自己看得见吗」，和 FileView 报「文件不存在」是同一个判据。
#
# ⚠️ 必须区分两种病（这两种都会报「文件不存在」，但修法一样、判据不一样）：
#   ① 容器里压根没有 /vol3           → test -d 失败
#   ② 容器里有 /vol3，但是个**空目录** → test -d 通过，但内容对不上
#   ② 是真会发生的：容器创建时该卷还没挂上（机械盘挂载比系统盘慢，重启后尤其明显），
#      docker 就把**底层空目录**绑了进去；之后宿主机把盘挂上，容器里仍然是空的。
#      只测 test -d 会误判成「一切正常」。
# 把任意分隔（逗号/空格/换行）的 /volN 列表规范化成「按卷号排序的逗号串」，
# 用来比较「期望挂载的卷」和「容器实际挂载的卷」。
fv_canon_vols() {
  tr ',' '\n' | tr ' ' '\n' \
    | awk -F'/' '/^\/vol[0-9]+$/ {n=$2; sub(/^vol/, "", n); print n "\t" $0}' \
    | sort -n -u | cut -f2 | tr '\n' ',' | sed 's/,$//'
}

# 引擎容器**实际** bind 挂载了哪些 /volN
fv_container_vols() {
  docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} {{end}}{{end}}' \
    basemetas-fileview-engine 2>/dev/null | fv_canon_vols
}

fv_ensure_mounts() {
  local list="$1" v missing="" hn cn wanted_vols actual_vols
  [ -n "$list" ] || return 0
  [ -n "${TRIM_APPDEST:-}" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  fv_docker_ok || { fv_docker_denied_note; return 0; }

  # 容器没跑起来就没什么可核对的（安装阶段就是这种情况，交给框架首次创建）
  [ "$(docker inspect -f '{{.State.Status}}' basemetas-fileview-engine 2>/dev/null)" = "running" ] || return 0

  # 「脱管」检查：容器所属项目必须和 config/resource 声明的一致，
  # 否则飞牛停不掉、也不会拿新配置重建 —— 症状就是「保存设置没反应 + 停用报错」。
  local want cur
  want="$(fv_declared_project)"
  cur="$(fv_current_project)"
  if [ -n "$want" ] && [ -n "$cur" ] && [ "$want" != "$cur" ]; then
    fv_log "容器所属项目 ${cur} 与声明的 ${want} 不一致（脱管），需要按 ${want} 重建"
    fv_rebuild
    return 0
  fi

  # ── 第一关：挂载清单**双向**比对 ─────────────────────────────────────
  # 少了要重建（新加的卷没挂上）；多了也要重建（用户把某个卷从列表里去掉了）。
  # 两边一致就**不要**动容器 —— 这一点很重要：
  #   config_callback 以前无条件 --force-recreate，等于每次「保存设置」都重建一遍容器。
  #   而重建期间容器会短暂以 <hash>_<name> 的临时名存在，如果此刻飞牛正在停用/卸载，
  #   它手里的容器 ID 就失效了，报 "No such container" → 界面显示 Request failed。
  #   实际就踩到过：11:51:05 框架停容器，11:51:06 我们在重建。
  wanted_vols="$(printf '%s\n' "$list" | fv_canon_vols)"
  actual_vols="$(fv_container_vols)"
  if [ "$actual_vols" != "$wanted_vols" ]; then
    fv_log "引擎容器挂载与期望不一致（容器=${actual_vols:-无} 期望=${wanted_vols}），重建容器"
    fv_rebuild
    return 0
  fi

  # ── 第二关：名字对上了还不够，逐个确认真的可见、且不是空目录 ────────
  local OLD_IFS="$IFS"
  IFS=','
  for v in $list; do
    if ! docker exec basemetas-fileview-engine test -d "$v" >/dev/null 2>&1; then
      missing="${missing:+${missing} }${v}(容器内不存在)"
      continue
    fi
    # 宿主机有内容、容器里却空 → docker 绑到的是底层空目录
    hn="$(ls -A "$v" 2>/dev/null | head -n 1)"
    cn="$(docker exec basemetas-fileview-engine sh -c "ls -A '$v' 2>/dev/null | head -n 1" 2>/dev/null)"
    if [ -n "$hn" ] && [ -z "$cn" ]; then
      missing="${missing:+${missing} }${v}(容器内是空目录)"
    fi
  done
  IFS="$OLD_IFS"

  if [ -n "$missing" ]; then
    fv_log "引擎容器挂载不对：${missing}；应为 ${list}，强制重建容器"
    fv_rebuild
  else
    fv_log "引擎容器挂载核对通过：${list}"
  fi
  return 0
}

# 建好自定义字体目录（compose 把 ${TRIM_PKGVAR}/fonts 挂到容器 /usr/local/share/fonts）
fv_prepare_fonts() {
  [ -n "${TRIM_PKGVAR:-}" ] || return 0
  mkdir -p "${TRIM_PKGVAR}/fonts" 2>/dev/null
  return 0
}
