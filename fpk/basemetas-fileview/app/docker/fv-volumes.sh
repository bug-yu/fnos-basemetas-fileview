#!/bin/bash
# FileView 预览 —— 存储卷挂载 / 单文件大小上限 / 容器重建的公共逻辑。
# 由 cmd/install_callback、cmd/config_callback、cmd/upgrade_callback、cmd/main 共同 source。
#
# ⚠️ 本文件必须放在 docker/ 目录下：fnpack 打包 app.tgz 时只收 docker/、ui/、config/，
#    放到别处（如 lib/）会被整目录丢掉，装好后脚本 source 不到、静默 exit 0。
#    副作用：本目录会挂进 nginx 的 conf.d，但 nginx 只 include *.conf，.sh 不会被加载。
#
# ⚠️ 前提：${TRIM_APPDEST}/docker/docker-compose.yaml 是安装包里的模板文件，
#    升级时框架重新释放 app.tgz 会把它覆盖回模板内容。所以任何「释放文件」之后的
#    时机都必须重新写一遍挂载段，否则之前的配置会凭空消失。

# 全部用 ${VAR:-} 取值：本库会被多个回调 source，缺变量时应当什么都不做，而不是崩掉。
FV_COMPOSE="${TRIM_APPDEST:-}/docker/docker-compose.yaml"

# 排查日志，落在应用数据目录
FV_LOG=""
[ -n "${TRIM_PKGVAR:-}" ] && FV_LOG="${TRIM_PKGVAR}/fv-volumes.log"

fv_log() {
  [ -n "$FV_LOG" ] || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$FV_LOG" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# 0a. Docker 可用性
# ---------------------------------------------------------------------------
# 生命周期脚本以应用用户身份运行，该用户必须在 docker 组里，否则所有 docker 操作
# 静默失败（config/privilege 已声明 join-groups: ["docker"]）。
fv_docker_ok() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps >/dev/null 2>&1
}

# docker 用不了时写一条照着做就好的提示。
# 只在日志里第一次出现时写，避免每次启动都刷一遍。
fv_docker_denied_note() {
  local who
  who="$(id -un 2>/dev/null)"
  fv_log "错误：当前用户 ${who} 无法访问 Docker（/var/run/docker.sock 需要 docker 组权限）"
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
# 向导变量只在「安装 / 保存设置」那一次回调里存在；升级回调和 cmd/main start
# 都拿不到 wizard_volumes，必须落盘记住用户填的值。
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
# 默认 auto：以宿主机真实挂载情况为准，不写死 /vol1,/vol2（写死会让新加的盘永远预览不了，
# 卸载重装还会再次踩到）。
# 取「挂载点 ∪ 目录」的并集：存储卷不一定都是独立挂载点，只看 /proc/mounts
# 会静默漏掉那些只是普通目录或 bind mount 的卷。

fv_mounts_volumes() {
  [ -r /proc/mounts ] || return 0
  # 挂载点末尾可能带 "/"，统一去掉再输出
  awk '$2 ~ /^\/vol[0-9]+\/*$/ {p=$2; sub(/\/+$/, "", p); print p}' /proc/mounts 2>/dev/null
}

fv_dir_volumes() {
  local d
  # ⚠️⚠️ 卷号**必须允许前导零** —— 真机反馈（2026-10-09）：
  #   飞牛的「远程挂载 / 外接存储」落在 **/vol0X** 这种带前导零的命名空间下，
  #   路径形如 `/vol02/1000-0-d0b6b52b`；而存储空间是不带前导零的 /vol1、/vol2…。
  #
  #   旧写法只列 `/vol[1-9]` `/vol[1-9][0-9]` `/vol[1-9][0-9][0-9]`
  #   （注释里还写着「/vol00 这类目录不是」—— 那个判断是错的 ✗）
  #   → `/vol02` 这类目录**根本探测不到** → 不会出现在 compose 的挂载段里
  #   → 容器里看不到这个路径 → 远程挂载/外接存储的文件**必然预览失败** ✗
  #
  #   用户显式填写的列表同样允许前导零（见 fv_normalize）。
  for d in /vol[0-9] /vol[0-9][0-9] /vol[0-9][0-9][0-9]; do
    [ -d "$d" ] || continue
    printf '%s\n' "$d"
  done
}

fv_detect_volumes() {
  # ⚠️ 去重**必须按「数字 + 完整路径」两个键**，不能只用 `sort -n -u`：
  #    `/vol2` 与 `/vol02` 的数字键都是 2，`sort -n -u` 会把它俩当成重复
  #    → **`/vol02` 被静默吃掉** ✗（实测：输入 /vol1,/vol2,/vol02,/vol3
  #      输出只剩 /vol1,/vol2,/vol3）。而 `/vol02` 正是远程挂载的父目录。
  #    改成 `-k1,1n -k2,2 -u`：数字键相同时再比完整路径 → 两个都保留 ✓
  { fv_mounts_volumes; fv_dir_volumes; } 2>/dev/null \
    | awk -F'/' '/^\/vol[0-9]+$/ {n=$2; sub(/^vol/, "", n); print n "\t" $0}' \
    | sort -k1,1n -k2,2 -u \
    | cut -f2 \
    | tr '\n' ',' \
    | sed 's/,$//'
}

# 把用户手填的字符串规范成 /volN, 的形式，顺手剔掉不合法的项
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
# 内容没变就不落盘，保持幂等。
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
  # 同时重写两处：引擎的挂载段，以及权限闸门容器的挂载段
  # （闸门必须在与引擎相同的文件系统视图上做判定，两份卷清单必须一致）
  if awk -v block="$block" '
    /## VOLUMES_BEGIN/     { print; printf "%s", block; skip=1; next }
    /## VOLUMES_END/       { skip=0 }
    /## VOLUMES_ACL_BEGIN/ { print; printf "%s", block; skip=1; next }
    /## VOLUMES_ACL_END/   { skip=0 }
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
# 2b. 单文件预览大小上限（FILEVIEW_PREVIEW_STORAGE_MAXFILESIZEMB）
# ---------------------------------------------------------------------------
# 引擎预览服务有个硬门槛 fileview.preview.storage.max-file-size-mb，默认 100（MB）。
# 超过它的文件在**转换之前**就被直接拒绝，接口返回 HTTP 413，前端把状态码显示成
# 「文件转换失败 413」—— 看起来像转换器故障，其实和转换器、nginx、网络都无关。
#
# 用环境变量覆盖：StorageConfig 是 @ConfigurationProperties(prefix="fileview.preview.storage")，
# Spring Boot 里环境变量的优先级高于包内 application.yml，也不用去猜镜像里配置文件的位置
# （挂错路径会被 docker 建成空目录，容器直接起不来）。
# 变量名按 Spring Boot 规则换算：点→下划线、去掉连字符、转大写。
#
# ⚠️ 目标字段是 int：写进非数字或空值会让 Spring 绑定失败、**引擎容器起不来**，
#    比不设这个开关严重得多。所以只接受纯数字，其余一律回退。
FV_MAXSIZE_DEFAULT=1024
FV_MAXSIZE_MAX=102400          # 100 GB，防手滑的上限，不是技术上限
FV_MAXSIZE_STATE="${TRIM_PKGVAR:-}/maxfilesize.conf"

# 把任意输入规范成纯数字 MB；不合法返回空串（由调用方决定回退值）
fv_normalize_maxsize() {
  local n
  n="$(printf '%s' "${1:-}" | tr -d '[:space:]')"
  [ -n "$n" ] || { echo ""; return 0; }
  # 出现任何非数字字符就整个不采信，避免「1e3 被截成 13」这种看似成功的误写
  case "$n" in
    *[!0-9]*) echo ""; return 0 ;;
  esac
  n="$(printf '%s' "$n" | sed 's/^0*//')"        # 去前导零；全是 0 会变成空串
  [ -n "$n" ] || { echo ""; return 0; }
  [ "${#n}" -le 6 ] || { echo "$FV_MAXSIZE_MAX"; return 0; }   # 位数过多，别交给 $(( )) 冒溢出的险
  n=$((10#$n))                                   # 10# 前缀：避免 0100 被当八进制
  [ "$n" -ge 1 ] || { echo ""; return 0; }
  [ "$n" -le "$FV_MAXSIZE_MAX" ] || n="$FV_MAXSIZE_MAX"
  echo "$n"
}

fv_save_maxsize_state() {
  [ -n "${TRIM_PKGVAR:-}" ] || return 0
  mkdir -p "$TRIM_PKGVAR" 2>/dev/null
  printf '%s\n' "$1" > "$FV_MAXSIZE_STATE" 2>/dev/null
  return 0
}

fv_load_maxsize_state() {
  [ -n "${TRIM_PKGVAR:-}" ] && [ -r "$FV_MAXSIZE_STATE" ] || { echo ""; return 0; }
  tr -cd '0-9' < "$FV_MAXSIZE_STATE" 2>/dev/null
  return 0
}

# 重写 compose 里 MAXSIZE 标记块内的那一行
fv_write_maxsize() {
  local n="$1" tmp
  [ -n "$n" ] || return 1
  [ -f "$FV_COMPOSE" ] || return 1
  if ! grep -q '## MAXSIZE_BEGIN' "$FV_COMPOSE" 2>/dev/null; then
    fv_log "警告：compose 里找不到 MAXSIZE_BEGIN 标记，单文件大小上限未写入"
    return 1
  fi

  tmp="${FV_COMPOSE}.ms"
  if awk -v n="$n" '
    /## MAXSIZE_BEGIN/ { print; printf "      - FILEVIEW_PREVIEW_STORAGE_MAXFILESIZEMB=%s\n", n; skip=1; next }
    /## MAXSIZE_END/   { skip=0 }
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

# 从 compose 里读出「期望的」大小上限（用于和容器实际 env 比对）
fv_compose_maxsize() {
  sed -n 's/.*FILEVIEW_PREVIEW_STORAGE_MAXFILESIZEMB=\([0-9]\{1,\}\).*/\1/p' \
    "$FV_COMPOSE" 2>/dev/null | head -n 1
}

# 从容器里读出「实际生效的」大小上限
fv_container_maxsize() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
    basemetas-fileview-engine 2>/dev/null \
    | sed -n 's/^FILEVIEW_PREVIEW_STORAGE_MAXFILESIZEMB=\([0-9]\{1,\}\)$/\1/p' | head -n 1
}

# ---------------------------------------------------------------------------
# 2c. 压缩包内单个文件的解压上限（FILEVIEW_ARCHIVE_MAXFILESIZE）
# ---------------------------------------------------------------------------
# 引擎还有**另一道独立**的闸门：解压压缩包时，包内**单个文件**超过
# fileview.archive.max-file-size 就被跳过（默认 104857600 字节 = 100 MB）。
# 它和上面的「单文件预览上限」互不影响 —— 「压缩包能打开、但里面某个大文件点不开」
# 撞到的就是这一道。
#
# 依据（引擎开源，读了源码）：fileview-preview 的 ArchiveExtractService 里
#   @Value("${fileview.archive.max-file-size:104857600}") private long maxFileSize;
# ⚠️ **单位是字节**（不是 MB）：向导里按 MB 填，这里换算后写进 compose。
#    引擎侧是 long，写非数字同样会让容器起不来 —— 所以也只接受纯数字。
FV_ARCHIVE_DEFAULT=100         # MB，等于引擎默认值（不填就不改变现状）
FV_ARCHIVE_MAX=10240           # 10 GB，防手滑的上限
FV_ARCHIVE_STATE="${TRIM_PKGVAR:-}/archivemaxsize.conf"

# 复用上面那套「纯数字规范化」，再按归档场景的上限收一道
fv_normalize_archivemax() {
  local n
  n="$(fv_normalize_maxsize "${1:-}")"
  [ -n "$n" ] || { echo ""; return 0; }
  [ "$n" -le "$FV_ARCHIVE_MAX" ] || n="$FV_ARCHIVE_MAX"
  echo "$n"
}
fv_save_archivemax_state() {
  [ -n "${TRIM_PKGVAR:-}" ] || return 0
  mkdir -p "$TRIM_PKGVAR" 2>/dev/null
  printf '%s\n' "$1" > "$FV_ARCHIVE_STATE" 2>/dev/null
  return 0
}
fv_load_archivemax_state() {
  [ -n "${TRIM_PKGVAR:-}" ] && [ -r "$FV_ARCHIVE_STATE" ] || { echo ""; return 0; }
  sed -n '1{s/[^0-9]//g;p;}' "$FV_ARCHIVE_STATE" 2>/dev/null | head -n 1
}
# 把 MB 换算成字节，写进 compose 的 ARCHIVEMAX 段
fv_write_archivemax() {
  local mb="$1" bytes tmp
  [ -n "$mb" ] || return 1
  [ -f "$FV_COMPOSE" ] || return 1
  if ! grep -q '## ARCHIVEMAX_BEGIN' "$FV_COMPOSE" 2>/dev/null; then
    fv_log "警告：compose 里找不到 ARCHIVEMAX_BEGIN 标记，压缩包内文件上限未写入"
    return 1
  fi
  bytes=$(( mb * 1048576 ))
  tmp="${FV_COMPOSE}.ams"
  if awk -v n="$bytes" '
    /## ARCHIVEMAX_BEGIN/ { print; printf "      - FILEVIEW_ARCHIVE_MAXFILESIZE=%s\n", n; skip=1; next }
    /## ARCHIVEMAX_END/   { skip=0 }
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
fv_compose_archivemax() {
  sed -n 's/.*FILEVIEW_ARCHIVE_MAXFILESIZE=\([0-9]\{1,\}\).*/\1/p' "$FV_COMPOSE" 2>/dev/null | head -n 1
}
fv_container_archivemax() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
    basemetas-fileview-engine 2>/dev/null \
    | sed -n 's/^FILEVIEW_ARCHIVE_MAXFILESIZE=\([0-9]\{1,\}\)$/\1/p' | head -n 1
}

# ---------------------------------------------------------------------------
# 3. 写 .env —— 让命令行里手动 docker compose 也能正常工作
# ---------------------------------------------------------------------------
# 手工执行时 TRIM_APPDEST / TRIM_PKGVAR 为空，compose 会把 ":/app/target:rw"
# 解析成非法挂载并整体失败。compose 会自动读取同目录的 .env，写一份即可。
# ⚠️ 只写非空值：写进去一个空的 TRIM_PKGVAR= 反而会把挂载解析得更糟。
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
# TRIM_APPDEST / TRIM_PKGVAR 只有飞牛框架执行应用脚本时才注入。框架自己那次
# docker compose（停用 / 卸载 / 更新都会用到）拿不到它们，会整体失败，而界面只报
# 一句 Request failed。替换成字面量后，compose 不再依赖任何环境变量。
# 升级时框架重新释放 app.tgz 会把模板（含 ${TRIM_*}）覆盖回来，下次回调再替换一次。
fv_materialize_env() {
  [ -f "$FV_COMPOSE" ] || return 1
  [ -n "${TRIM_APPDEST:-}" ] || return 1
  [ -n "${TRIM_PKGVAR:-}" ]  || return 1
  # 已经是字面量就直接返回，保持幂等
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
# 4d. 写逐用户权限闸门的开关
# ---------------------------------------------------------------------------
# mode=enforce 不可读的文件直接 403（默认）；mode=log 只记录不拦截（误拦时的应急开关）。
# 闸门每次请求现读这个文件，所以改完立即生效，不用重启容器。
# ⚠️ 只在文件不存在时写入默认值；已存在的值不覆盖，以免冲掉手工改的应急设置。
fv_write_acl_conf() {
  [ -n "${TRIM_PKGVAR:-}" ] || return 0
  local conf="${TRIM_PKGVAR}/acl.conf" mode="${1:-}" guard="" fidguard=""
  if [ -r "$conf" ]; then
    # 手工改过的值必须留住 —— 这个文件是**应急开关**，被覆盖就失去意义了。
    [ -n "$mode" ] || mode="$(sed -n 's/^mode=//p' "$conf" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
    guard="$(sed -n 's/^body_guard=//p' "$conf" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
    fidguard="$(sed -n 's/^fileid_guard=//p' "$conf" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
  fi
  case "$mode"     in log) ;; *) mode="enforce" ;; esac
  case "$guard"    in log) ;; *) guard="enforce" ;; esac
  # ⚠️ fileid_guard 默认 **log**（不是 enforce）：合法流程里 /files/{fileId}/page/{n}
  #    与 /pages 没有日志样本，盲切 enforce 有误伤风险。先观察，确认日志里没有合法
  #    请求被记，再手工改成 enforce。详见 fv-acl-gate.py 头部注释。
  case "$fidguard" in enforce) ;; *) fidguard="log" ;; esac

  mkdir -p "$TRIM_PKGVAR" 2>/dev/null
  {
    echo "# FileView 逐用户权限闸门开关（由应用写入，改完立即生效，不必重启容器）"
    echo "# 看判定过程： docker logs basemetas-fileview-acl"
    echo "#"
    echo "# mode —— 总体开关"
    echo "#   enforce 不可读的文件直接返回 403（默认）"
    echo "#   log     只记录判定结果，不拦截（出现误拦时的应急开关）"
    echo "mode=${mode}"
    echo "#"
    echo "# body_guard —— 只管「路径只在请求体里」的接口那一层"
    echo "#   （POST /preview/api/localFile、/preview/api/password/unlock）"
    echo "#   这些接口的路径 nginx 的 auth_request 看不到，改由闸门读 body 判定后再转发；"
    echo "#   enforce 判定不过就 403（默认）"
    echo "#   log     只记录、仍然转发（单独回退这一层用，不影响 mode）"
    echo "body_guard=${guard}"
    echo "#"
    echo "# fileid_guard —— 只管 fileId 系接口（/preview/api/files/<fileId>）"
    echo "#   fileId 是**原始路径的 md5 前 16 位**，不具备保密性；而这类请求里没有路径参数，"
    echo "#   闸门天然判不到，引擎会用缓存里的原始路径把文件吐出来 —— 构成绕过。"
    echo "#   对策：要求请求自带 filePath。"
    echo "#   log      只记录「不带 filePath」的请求（**出厂默认**，先观察）"
    echo "#   enforce  直接拒绝这类请求（观察确认无误伤后再改）"
    echo "fileid_guard=${fidguard}"
  } > "$conf" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# 4. 统一入口：解析 → 写挂载段 → 写 .env → 写上限 → 核对容器
# ---------------------------------------------------------------------------
# 所有回调（安装 / 保存设置 / 升级 / 启动）都走这里，避免任何一条路径漏掉重写。
# 参数一为空时依次回退：上次保存的设置 → auto。
# 参数二 mode：
#   ensure （默认）容器里缺卷才重建 —— 用于「启动」「安装」
#   rebuild        无条件重建     —— 用于「保存设置」「升级」（挂载列表可能变少，
#                                  少了的话没有「缺卷」可检测，必须无条件重建）
#   none           只写文件，不动容器
fv_sync_volumes() {
  local raw="${1:-}" mode="${2:-ensure}" list ms

  [ -n "$raw" ] || raw="$(fv_load_state)"
  [ -n "$raw" ] || raw="auto"

  fv_save_state "$raw"

  # 把探测的输入也记下来，便于区分「压根没探到」和「探到了但没写进去」
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
  # 单文件大小上限：向导里填了就用向导值，没填（或填了非法值）就沿用上次保存的
  # （main start 这类时机拿不到向导变量，只能读状态文件）
  ms="$(fv_normalize_maxsize "${wizard_max_file_mb:-}")"
  [ -n "$ms" ] || ms="$(fv_load_maxsize_state)"
  ms="$(fv_normalize_maxsize "$ms")"      # 状态文件被手工改坏也要挡住
  [ -n "$ms" ] || ms="$FV_MAXSIZE_DEFAULT"
  fv_save_maxsize_state "$ms"
  if fv_write_maxsize "$ms"; then
    fv_log "单文件大小上限已同步：${ms} MB"
  fi
  # 压缩包内**单个文件**的解压上限：逻辑同上（向导值 → 上次保存的 → 默认值）
  am="$(fv_normalize_archivemax "${wizard_archive_max_file_mb:-}")"
  [ -n "$am" ] || am="$(fv_load_archivemax_state)"
  am="$(fv_normalize_archivemax "$am")"
  [ -n "$am" ] || am="$FV_ARCHIVE_DEFAULT"
  fv_save_archivemax_state "$am"
  if fv_write_archivemax "$am"; then
    fv_log "压缩包内文件上限已同步：${am} MB"
  fi
  # 闸门开关：向导里填了就用向导值，没填就保持现值
  fv_write_acl_conf "${wizard_acl_gate:-}"

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
# 飞牛应用中心按这个名字管理容器（停用 / 启动 / 重建都走它）。一旦容器实际所属的
# 项目名与声明的对不上（脱管），飞牛就看不到这些容器：停用报 Request failed，
# 也不会用新配置重建容器。
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
# 名字形如 <12位十六进制>_basemetas-fileview-xxx，是 --force-recreate 重建带
# container_name 的容器时的中间产物（先建临时名的新容器 → 删旧的 → 再改名）。
# 重建被中途打断就会留下它；它与正式容器同名同项目，此后飞牛每次停用 / 卸载
# 都会去停它并报 No such container，界面显示 Request failed。
#
# 安全：只删名字严格匹配该模式的容器，不误伤其它容器。
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
# 5. 重建容器 —— 让配置改动真正生效
# ---------------------------------------------------------------------------
# bind 挂载和容器环境变量都在容器创建那一刻定死，改完 compose 必须重建容器
# （docker restart 也不行）；而飞牛框架保存设置后不会重建，只能自己来。
# 项目名必须用 config/resource 里声明的那个，否则容器会脱管。
# 重建失败要写日志 + 写 TRIM_TEMP_LOGFILE，不能让失败看起来和成功一样。
fv_rebuild() {
  [ -n "${TRIM_APPDEST:-}" ] || return 0
  command -v docker >/dev/null 2>&1 || { fv_log "跳过重建容器：找不到 docker 命令"; return 0; }
  # 没有 docker 权限就别装了 —— 明确写出来，别让它看起来像「已经重建成功」
  fv_docker_ok || { fv_docker_denied_note; return 0; }

  # 先清掉上次重建被打断留下的临时容器，否则 compose 会因为名字冲突 / 残留状态失败
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

  # 项目名不一致 → 容器脱管。必须先删掉再按声明名重建，
  # 否则 compose 会因为「容器名已被占用」直接失败。
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
# 4b. 核对引擎容器里真的能看到这些卷，缺了就重建
# ---------------------------------------------------------------------------
# 用 docker exec test -d 而不是解析 docker inspect：判据是「引擎进程自己看得见吗」，
# 与引擎报「文件不存在」是同一个判据。
#
# ⚠️ 必须区分两种病，它们都会报「文件不存在」，但只测 test -d 会把第二种误判成正常：
#   ① 容器里压根没有该卷
#   ② 容器里有该卷，但是个空目录 —— 容器创建时盘还没挂上（机械盘比系统盘慢，
#      重启后尤其明显），docker 绑到的是底层空目录，之后宿主机挂上盘，容器里仍然空。
#
# 把任意分隔（逗号/空格/换行）的 /volN 列表规范化成「按卷号排序的逗号串」，用于比对。
# ⚠️ 去重同样必须用「数字 + 完整路径」两个键 —— 只用 `sort -n -u` 会把
#    `/vol2` 与 `/vol02` 当成同一个（数字键都是 2）→ 两边都被规范化成同一个串
#    → **容器少了 /vol02 也照样判定「一致」** ✗ 于是「远程挂载预览不了」
#    在自检里完全看不出来（这正是 2026-10-09 那个 bug 的隐蔽之处）。
fv_canon_vols() {
  tr ',' '\n' | tr ' ' '\n' \
    | awk -F'/' '/^\/vol[0-9]+$/ {n=$2; sub(/^vol/, "", n); print n "\t" $0}' \
    | sort -k1,1n -k2,2 -u | cut -f2 | tr '\n' ',' | sed 's/,$//'
}

# 引擎容器实际 bind 挂载了哪些 /volN
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

  # 脱管检查：容器所属项目必须和 config/resource 声明的一致
  local want cur
  want="$(fv_declared_project)"
  cur="$(fv_current_project)"
  if [ -n "$want" ] && [ -n "$cur" ] && [ "$want" != "$cur" ]; then
    fv_log "容器所属项目 ${cur} 与声明的 ${want} 不一致（脱管），需要按 ${want} 重建"
    fv_rebuild
    return 0
  fi

  # ── 第一关：挂载清单**双向**比对 ─────────────────────────────────────
  # 少了要重建（新加的卷没挂上），多了也要重建（用户把某个卷从列表里去掉了）。
  # 两边一致就**不要**动容器 —— 无谓的重建会让容器短暂以 <hash>_<name> 的临时名存在，
  # 若此刻飞牛正在停用 / 卸载，它手里的容器 ID 就失效了，界面会报 Request failed。
  wanted_vols="$(printf '%s\n' "$list" | fv_canon_vols)"
  actual_vols="$(fv_container_vols)"
  if [ "$actual_vols" != "$wanted_vols" ]; then
    fv_log "引擎容器挂载与期望不一致（容器=${actual_vols:-无} 期望=${wanted_vols}），重建容器"
    fv_rebuild
    return 0
  fi

  # ── 第一关之二：环境变量也要对得上 ───────────────────────────────────
  # 单文件大小上限是通过环境变量注入的，和 bind 挂载一样只在容器创建那一刻定死。
  # 这一关顺带把「安装时框架先建容器、回调后写 compose」的时序差也兜住。
  local want_ms actual_ms
  want_ms="$(fv_compose_maxsize)"
  actual_ms="$(fv_container_maxsize)"
  if [ -n "$want_ms" ] && [ "$want_ms" != "$actual_ms" ]; then
    fv_log "单文件大小上限不一致（容器=${actual_ms:-无} 期望=${want_ms}），重建容器"
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

# 建好宿主侧的挂载目录（compose 把它们挂进容器）：
#   fonts → /usr/local/share/fonts（自定义字体，见 README）
#   data  → /opt/fileview/data   （转换产物 / 临时文件 / LibreOffice、CAD 工作目录）
#   logs  → /opt/fileview/logs   （preview 与 convert 的文件日志）
#
# ⚠️ 必须**在容器创建之前**建好，否则 docker 会拿 root 身份把它们建成 0755，
#    万一容器里的进程不是 root 就写不进去（表现为预览失败，且日志里看不出原因）。
#
# 权限 0700：这三个目录只给 root。引擎容器**实测以 uid=0(root) 运行**
# （docker exec basemetas-fileview-engine id → uid=0(root)），root 无视权限位，
# 所以收紧到 0700 不影响引擎读写；同时把「任何本地非 root 用户 / 其它容器」挡在外面
# —— data/logs 里会出现转换产物（含被预览文件的内容片段）与文件日志，不是纯公开数据。
# 早先用 0777 是为了不假设容器用户；既然已实测是 root，就没有理由再开着全局可写。
fv_prepare_dirs() {
  [ -n "${TRIM_PKGVAR:-}" ] || return 0
  mkdir -p "${TRIM_PKGVAR}/fonts" "${TRIM_PKGVAR}/data" "${TRIM_PKGVAR}/logs" 2>/dev/null
  chmod 0700 "${TRIM_PKGVAR}/fonts" "${TRIM_PKGVAR}/data" "${TRIM_PKGVAR}/logs" 2>/dev/null
  return 0
}
