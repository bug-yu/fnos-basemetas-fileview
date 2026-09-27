#!/bin/bash
# 飞牛开放 API 预检 —— 确认「按用户校验文件权限」这条路能不能走通
#
# 由 cmd/main start 调用。**只读**：不改任何文件、不动容器，结果写进 fv-volumes.log。
#
# 为什么要预检：
#   现在 FileView 不区分用户，是因为它以外挂卷 + 容器 root 身份读文件，
#   绕过了飞牛的用户 ACL。要做到「按用户区分」，网关必须在每次请求时调用
#       trim.file.checkUserACL  { uid, path }  →  { readable, writable, deletable }
#   而这依赖三个前提，缺一个都做不成，且都只能在真机上验证：
#     ① 应用脚本能拿到 TRIM_API_TOKEN（系统注入；官方要求不得持久化到文件/配置）
#     ② 宿主机 /var/run/trim_open_gateway_apiscope.socket 存在且当前用户可访问
#     ③ 管理员已通过「授权目录」把目标目录授给应用（否则 checkUserACL 一律返回 false）
#   本脚本把这三条一次性探明，连原始响应一起写进日志，省得反复猜。
#
# 环境要求：开放 API 需要系统 ≥ 1.2.0401、App ≥ 1.34.0。本脚本会自行比对并给出结论。

FV_ACL_SOCKET="${FV_ACL_SOCKET:-/var/run/trim_open_gateway_apiscope.socket}"
FV_ACL_APPNAME="${FV_ACL_APPNAME:-basemetas-fileview}"
FV_ACL_MIN_SYSVER="1.2.0401"

# 版本号比较：fv_ver_ge 1.2.0701 1.2.0401 → 返回 0（前者不小于后者）
fv_ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    n=split(a,A,"."); m=split(b,B,".");
    k=(n>m?n:m);
    for(i=1;i<=k;i++){ x=A[i]+0; y=B[i]+0; if(x>y) exit 0; if(x<y) exit 1 }
    exit 0
  }'
}

# 调一次后端 API，把原始响应打到 stdout；失败时把原因打到 stdout 并返回 1
fv_api_call() {
  local req="$1" data="${2:-{}}"
  command -v curl >/dev/null 2>&1 || { printf 'curl 未安装（无法调用后端 API）'; return 1; }
  [ -n "${TRIM_API_TOKEN:-}" ]     || { printf 'TRIM_API_TOKEN 为空（拿不到 token）'; return 1; }
  [ -S "$FV_ACL_SOCKET" ]          || { printf 'API socket 不存在：%s' "$FV_ACL_SOCKET"; return 1; }
  curl -sS --max-time 5 --unix-socket "$FV_ACL_SOCKET" \
    -X POST "http://localhost/api/v1/trimapp" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${TRIM_API_TOKEN}" \
    -d "{\"reqId\":\"1\",\"req\":\"${req}\",\"appName\":\"${FV_ACL_APPNAME}\",\"data\":${data}}" 2>&1
}

# 从响应里粗略抠出 /vol 开头的路径（不依赖 jq）
fv_json_vol_paths() {
  printf '%s' "$1" | grep -o '"/vol[0-9][^"]*"' | tr -d '"' | sort -u
}

fv_acl_probe() {
  local from="${1:-未标注}"
  fv_log "──────── 飞牛开放 API 预检（只读）────────"
  fv_log "调用来源：${from}"
  fv_log "运行用户：$(id -un 2>/dev/null) (uid=$(id -u 2>/dev/null))"
  fv_log "系统版本：${TRIM_SYS_VERSION:-（未注入 TRIM_SYS_VERSION）}"
  if [ -n "${TRIM_SYS_VERSION:-}" ]; then
    if fv_ver_ge "$TRIM_SYS_VERSION" "$FV_ACL_MIN_SYSVER"; then
      fv_log "          ✅ 满足开放 API 要求（≥ ${FV_ACL_MIN_SYSVER}）"
    else
      fv_log "          ❌ 低于开放 API 要求（≥ ${FV_ACL_MIN_SYSVER}）—— 逐用户权限校验不可用"
    fi
  fi
  fv_log "          开放 API 要求：系统 ≥ ${FV_ACL_MIN_SYSVER}、App ≥ 1.34.0"

  # ① token
  if [ -n "${TRIM_API_TOKEN:-}" ]; then
    fv_log "① TRIM_API_TOKEN：**有**（长度 ${#TRIM_API_TOKEN}，值不记录）"
  else
    fv_log "① TRIM_API_TOKEN：**没有** —— 脚本环境里拿不到 token"
  fi

  # ② socket
  if [ -S "$FV_ACL_SOCKET" ]; then
    fv_log "② API socket：存在  $(ls -l "$FV_ACL_SOCKET" 2>/dev/null)"
    if command -v getfacl >/dev/null 2>&1; then
      fv_log "   socket ACL：$(getfacl -p "$FV_ACL_SOCKET" 2>/dev/null | tr '\n' ' ')"
    fi
  else
    fv_log "② API socket：**不存在**（$FV_ACL_SOCKET）"
  fi
  if command -v curl >/dev/null 2>&1; then
    fv_log "   curl：$(command -v curl)"
  else
    fv_log "   curl：**未安装**"
  fi

  # ②b 不管有没有 token，都**实际连一次** socket ——
  #    用来区分「应用用户连不上 socket（权限）」和「只是缺 token」，这两种修法完全不同。
  local probe_out=""
  if [ -S "$FV_ACL_SOCKET" ] && command -v curl >/dev/null 2>&1; then
    probe_out="$(curl -sS --max-time 5 --unix-socket "$FV_ACL_SOCKET" -w ' HTTP=%{http_code}' \
        -X POST "http://localhost/api/v1/trimapp" \
        -H 'Content-Type: application/json' \
        -d "{\"reqId\":\"0\",\"req\":\"trim.system.getPlatformConfig\",\"appName\":\"${FV_ACL_APPNAME}\",\"data\":{}}" 2>&1)"
    fv_log "   socket 实测（不带 token）：$(printf '%s' "$probe_out" | tr '\n' ' ')"
  fi

  # 前置不满足就别往下调了，直接给结论
  if [ -z "${TRIM_API_TOKEN:-}" ] || [ ! -S "$FV_ACL_SOCKET" ] || ! command -v curl >/dev/null 2>&1; then
    case "$probe_out" in
      *[Pp]ermission\ denied*|*[Cc]ouldn\'t\ connect*|*[Cc]onnection\ refused*|"")
        fv_log "结论：socket 也连不上（见上面实测），开放 API 这条路**当前走不通**。" ;;
      *)
        fv_log "结论：socket 本身**可连通**（上面实测有响应），**只差 TRIM_API_TOKEN**。" ;;
    esac
    fv_log "      退路：网关级用户白名单（只让管理员或指定 uid 使用本应用）。"
    fv_log "──────── 预检结束 ────────"
    return 0
  fi

  # ③ 已授权目录
  local out paths first
  out="$(fv_api_call "trim.file.getSharedAccessibleFolders" "{}")"
  fv_log "③ getSharedAccessibleFolders 原始响应："
  fv_log "   $out"
  paths="$(fv_json_vol_paths "$out")"
  if [ -n "$paths" ]; then
    fv_log "   解析出的授权目录：$(printf '%s' "$paths" | tr '\n' ' ')"
  else
    fv_log "   **没有解析到授权目录** —— 需要管理员在「应用设置 → 授权目录」里添加（例如 /vol3）"
  fi

  # ④ 拿一个授权目录 + 当前用户 uid 试一次权限检查，验证返回的是真结果还是全 false
  first="$(printf '%s' "$paths" | head -n 1)"
  if [ -n "$first" ]; then
    local uid
    uid="$(id -u 2>/dev/null)"
    out="$(fv_api_call "trim.file.checkUserACL" "{\"uid\":${uid:-1000},\"path\":\"${first}\"}")"
    fv_log "④ checkUserACL(uid=${uid:-1000}, path=${first}) 原始响应："
    fv_log "   $out"
    case "$out" in
      *'"readable":true'*|*'"readable": true'*)
        fv_log "   → 返回了**真实**权限结果（说明应用已获授权，这条路可行）" ;;
      *'"readable":false'*|*'"readable": false'*)
        fv_log "   → readable=false。若该目录确实对当前用户可读，说明**应用还没拿到该目录的授权**，" ;;
    esac
  else
    fv_log "④ 跳过：没有授权目录可测"
  fi

  fv_log "结论：把上面 ①~④ 的原文发出来，即可确定闸门要怎么做。"
  fv_log "──────── 预检结束 ────────"
  return 0
}
