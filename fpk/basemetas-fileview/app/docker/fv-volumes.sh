#!/bin/bash
# FileView 预览 —— 存储卷挂载 / 容器重建的公共逻辑
#
# 由 cmd/install_callback 与 cmd/config_callback 共同 source。
# 这里的每一条判断背后都是 2026-09-26 实际踩过的坑，注释里写清楚了原因，改动前请先读。
#
# ⚠️ 为什么这个文件会放在 docker/ 目录下（而不是更合理的 lib/）：
#    fnpack 打包 app.tgz 时只收 docker/、ui/、config/ 三个目录，放在 lib/ 会被整目录丢掉，
#    装好以后脚本 source 不到、静默 exit 0，现象是「改设置没反应」，极难排查。
#    副作用：本目录会被挂进 nginx 的 conf.d，但 nginx 只 include *.conf，.sh 不会被加载。

FV_COMPOSE="${TRIM_APPDEST}/docker/docker-compose.yaml"

# ---------------------------------------------------------------------------
# 1. 探测宿主机上真实存在的存储卷
# ---------------------------------------------------------------------------
# 为什么需要自动探测：
#   早期版本把默认写死成 /vol1,/vol2。用户机器上实际有 /vol1 /vol2 /vol3 三块盘，
#   安装向导默认只有前两个 → /vol3 里的文件一律「文件不存在」。
#   更糟的是卸载重装时向导又回到默认值，问题必然复现。
#   所以默认改成 auto：直接以宿主机真实挂载情况为准。
fv_detect_volumes() {
  local list="" d

  # 以 /proc/mounts 为准，只认挂载点是 /volN 的（避免把普通目录误判成存储卷）
  if [ -r /proc/mounts ]; then
    list="$(awk '$2 ~ /^\/vol[0-9]+$/ {print $2}' /proc/mounts 2>/dev/null \
            | sort -u | tr '\n' ',' | sed 's/,$//')"
  fi

  # 兜底：个别环境 /volN 不是独立挂载点，退化为目录探测
  if [ -z "$list" ]; then
    for d in /vol[0-9] /vol[0-9][0-9]; do
      [ -d "$d" ] || continue
      list="${list:+${list},}${d}"
    done
  fi

  echo "$list"
}

# 把用户手填的字符串规范成 /volN,的形式，顺手剔掉不合法的项
fv_normalize() {
  local raw="$1" out="" v
  local OLD_IFS="$IFS"
  IFS=','
  for v in $raw; do
    v="$(printf '%s' "$v" | tr -d '[:space:]')"
    case "$v" in
      /vol[0-9]*) out="${out:+${out},}${v}" ;;
    esac
  done
  IFS="$OLD_IFS"
  echo "$out"
}

# ---------------------------------------------------------------------------
# 2. 重写 docker-compose.yaml 里的挂载段
# ---------------------------------------------------------------------------
# ⚠️ 只重写 ## VOLUMES_BEGIN / ## VOLUMES_END 之间的内容，标记行本身绝不能删，
#    否则下一次回调就找不到锚点了。
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
fv_write_env() {
  [ -n "${TRIM_APPDEST:-}" ] || return 0
  local d="${TRIM_APPDEST}/docker"
  [ -d "$d" ] || return 0
  {
    echo "# 由应用自动生成，请勿手改。"
    echo "# docker compose 会自动读取本文件，这样在命令行手工执行"
    echo "#   docker compose up -d"
    echo "# 也不会因为 TRIM_* 变量为空而报 invalid spec。"
    echo "TRIM_APPDEST=${TRIM_APPDEST}"
    echo "TRIM_PKGVAR=${TRIM_PKGVAR}"
  } > "$d/.env" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 4. 重建容器 —— 「改了设置却不生效」的根治
# ---------------------------------------------------------------------------
# 踩坑：改完设置、compose 文件里也确实多了 /vol3，但容器不重建，
#       bind 挂载是不会自己生效的（docker restart 也不行，必须重建）。
#       而飞牛框架在保存设置后并不会重建容器，只能我们自己来。
#
# 项目名必须沿用现有容器的 com.docker.compose.project 标签：
#   若与飞牛自己那次 up 用的项目名不一致，compose 会认为容器是「别的项目的」，
#   转头去新建同名容器 → Conflict. The container name already in use。
fv_rebuild() {
  [ -n "${TRIM_APPDEST:-}" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0

  local d="${TRIM_APPDEST}/docker"
  [ -f "$d/docker-compose.yaml" ] || return 0

  # 安装阶段容器还不存在，交给框架首次创建，这里不插手
  docker inspect basemetas-fileview-engine >/dev/null 2>&1 || return 0

  local proj
  proj="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' \
          basemetas-fileview-engine 2>/dev/null)"
  [ -n "$proj" ] || proj="docker"

  export TRIM_APPDEST TRIM_PKGVAR
  ( cd "$d" && docker compose -p "$proj" up -d --force-recreate --remove-orphans ) >/dev/null 2>&1
  return 0
}

# 建好自定义字体目录（compose 把 ${TRIM_PKGVAR}/fonts 挂到容器 /usr/local/share/fonts）
fv_prepare_fonts() {
  [ -n "${TRIM_PKGVAR:-}" ] || return 0
  mkdir -p "${TRIM_PKGVAR}/fonts" 2>/dev/null
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
