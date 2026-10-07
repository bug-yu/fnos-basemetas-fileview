#!/bin/bash
# 本地自检：语法检查 + 挂载段改写验证 + 探测并集冒烟 + 「升级后自愈」验证
set -u
BASE="$(cd "$(dirname "$0")/.." && pwd)/basemetas-fileview"
FAILED=0

echo "== 行尾检查（CRLF 会让脚本在 Linux 上静默失效）=="
if bash "$(dirname "$0")/check_eol.sh" "$BASE"; then
  :
else
  FAILED=1
fi

echo
echo "== bash -n 语法检查 =="
for f in "$BASE"/cmd/* "$BASE"/app/docker/fv-volumes.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then echo "  OK   $(basename "$f")"; else echo "  FAIL $(basename "$f")"; bash -n "$f"; FAILED=1; fi
done

echo
echo "== nginx.conf 解析层自检（本地没有 docker 时的替代手段）=="
# ⚠️ 这一步以前**没接进自检** —— 0.5.31 首版就是因为缺它才翻车：
#    把 `proxy_pass http://aclbody/guard;` 写进了 regex location，
#    nginx 启动期 emerg（"proxy_pass" cannot have URI part in location given by
#    regular expression...）→ 网关容器无限重启，而本地自检全绿。
#    教训：**检查器存在 ≠ 检查器在跑**。凡是有 check_*.py 的，都要接进自检。
PY_NGX="$(command -v python3 || command -v python)"
if [ -z "$PY_NGX" ]; then
  echo "   ⚠️  本机没有 python，跳过 nginx 解析层自检"
else
  NGX_OUT="$("$PY_NGX" "$(dirname "$0")/check_nginx_conf.py" "$BASE/app/docker/nginx.conf" 2>&1)"
  if [ $? -eq 0 ]; then
    echo "   ✅ nginx.conf 解析层自检通过（花括号/引号/语句结尾/指令名/正则/proxy_pass URI）"
  else
    echo "   ❌ nginx.conf 解析层自检失败："
    printf '%s\n' "$NGX_OUT" | sed 's/^/      /'
    FAILED=1
  fi
  MAP_OUT="$("$PY_NGX" "$(dirname "$0")/check_nginx_map.py" 2>&1)"
  if [ $? -eq 0 ]; then
    echo "   ✅ nginx map 求值仿真通过"
  else
    echo "   ❌ nginx map 求值仿真失败："
    printf '%s\n' "$MAP_OUT" | sed 's/^/      /'
    FAILED=1
  fi
fi

echo
echo "== 挂载段改写验证 =="
WORK="$(mktemp -d)"
cp "$BASE/app/docker/docker-compose.yaml" "$WORK/docker-compose.yaml"

list="/vol1,/vol2,/vol3"
block=""
OLD_IFS="$IFS"; IFS=','
for v in $list; do block="${block}      - ${v}:${v}:ro
"; done
IFS="$OLD_IFS"

awk -v block="$block" '
  /## VOLUMES_BEGIN/ { print; printf "%s", block; skip=1; next }
  /## VOLUMES_END/   { skip=0 }
  skip != 1 { print }
' "$WORK/docker-compose.yaml" > "$WORK/new.yaml"

echo "-- 改写后的挂载段 --"
sed -n '/## VOLUMES_BEGIN/,/## VOLUMES_END/p' "$WORK/new.yaml" | sed 's/^/   /'
echo "-- 其余内容行数：原 $(wc -l < "$WORK/docker-compose.yaml") / 新 $(wc -l < "$WORK/new.yaml") --"
rm -rf "$WORK"

echo
echo "== 探测逻辑（挂载点 ∪ 目录）冒烟 =="
. "$BASE/app/docker/fv-volumes.sh"
# 混合环境：/vol1、/vol2 是独立挂载点，/vol3 只是目录（bind mount 或普通目录）
# —— 旧写法「探到挂载点就不看目录」会漏掉 /vol3，这正是本次修的一个点
fv_mounts_volumes() { printf '/vol1\n/vol2\n'; }
fv_dir_volumes()    { printf '/vol1\n/vol2\n/vol3\n'; }
DET="$(fv_detect_volumes)"
echo "  detect          -> [$DET]   期望 [/vol1,/vol2,/vol3]"
[ "$DET" = "/vol1,/vol2,/vol3" ] || { echo "  ❌ 探测结果不符"; FAILED=1; }

# 还原真实实现，再冒烟 normalize / resolve
. "$BASE/app/docker/fv-volumes.sh"
echo "  auto            -> [$(fv_resolve_volumes auto)]"
echo "  /vol2           -> [$(fv_resolve_volumes /vol2)]"
echo "  '/vol1, /vol9 ' -> [$(fv_resolve_volumes '/vol1, /vol9 ')]   期望 [/vol1,/vol9]"
[ "$(fv_resolve_volumes '/vol1, /vol9 ')" = "/vol1,/vol9" ] || { echo "  ❌ 规范化结果不符"; FAILED=1; }
echo "  '/vol1/1000'    -> [$(fv_resolve_volumes '/vol1/1000')]   期望回落到默认卷"
echo "  空              -> [$(fv_resolve_volumes '')]"

echo
echo "== 同步 + 「升级后自愈」验证 =="
T="$(mktemp -d)"
export TRIM_APPDEST="$T/@appcenter/basemetas-fileview"
export TRIM_PKGVAR="$T/@appdata/basemetas-fileview"
mkdir -p "$TRIM_APPDEST/docker" "$TRIM_PKGVAR"
cp "$BASE/app/docker/docker-compose.yaml" "$TRIM_APPDEST/docker/docker-compose.yaml"

# ── docker 打桩 ─────────────────────────────────────────────────────────────
# 本自检只验「文件层面的逻辑」（改写挂载段、写 .env、幂等、状态持久化），
# **不需要真的碰 docker**；而 fv_ensure_mounts / fv_rebuild 里有 `docker inspect`
# 之类的调用，在没有 daemon 的机器上会卡住不返回。把 docker 换成一个立刻返回失败的
# 空壳：`command -v docker` 仍为真（走正常分支），但所有 `docker ps/inspect` 都失败
# → 函数按「容器不可用」提前 return，逻辑照验不误。
#
# ⚠️ Git Bash 的 mktemp -d 会返回带反斜杠的 Windows 路径（\Users\…），
#    直接拼 "$T/bin" 会得到一个非法路径。这里统一转成 /c/… 形式再用。
if command -v cygpath >/dev/null 2>&1; then T="$(cygpath -u "$T" 2>/dev/null || printf '%s' "$T")"; fi
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'SHIM'
#!/bin/sh
# 自检用空壳：一律失败，且瞬间返回，绝不连接任何 socket
exit 1
SHIM
chmod +x "$T/bin/docker" 2>/dev/null
PATH="$T/bin:$PATH"
export PATH

. "$BASE/app/docker/fv-volumes.sh"

fv_prepare_dirs
echo "-- 宿主侧挂载目录与网络预览开关 --"
for d in fonts data logs; do
  [ -d "$TRIM_PKGVAR/$d" ] && echo "   ✅ 目录已建：$d" || { echo "   ❌ 未建：$d"; FAILED=1; }
done
for m in '/fonts:/usr/local/share/fonts:ro' '/data:/opt/fileview/data' '/logs:/opt/fileview/logs'; do
  if grep -qF -- "- \"\${TRIM_PKGVAR}${m}\"" "$BASE/app/docker/docker-compose.yaml"; then
    echo "   ✅ compose 挂载：${m}"
  else
    echo "   ❌ compose 缺少挂载：${m}"; FAILED=1
  fi
done
if grep -qF 'FILEVIEW_NETWORK_SECURITY_TRUSTED_SITES=none.invalid' "$BASE/app/docker/docker-compose.yaml"; then
  echo "   ✅ 网络文件预览已关闭（trusted-sites 配成永不匹配）"
else
  echo "   ❌ 未配置 FILEVIEW_NETWORK_SECURITY_TRUSTED_SITES"; FAILED=1
fi
# 挂载必须在 VOLUMES 标记块**之外**，否则会被卷列表重写冲掉
if awk '/## VOLUMES_BEGIN/,/## VOLUMES_END/' "$BASE/app/docker/docker-compose.yaml" | grep -q 'opt/fileview'; then
  echo "   ❌ data/logs 挂载落在 VOLUMES 标记块内，会被重写冲掉"; FAILED=1
else
  echo "   ✅ 挂载在标记块之外（升级重写不会冲掉）"
fi

echo
echo "-- 安全收紧断言（0.5.25 起）--"
# 三个镜像都必须锁 digest：只写标签时上游重推同名标签会静默换内容
# （引擎镜像 0.5.25 起锁；nginx / python 两个基础镜像 0.5.30 起补上）
COMPOSE="$BASE/app/docker/docker-compose.yaml"
UNPINNED="$(grep -E '^[[:space:]]*image:[[:space:]]' "$COMPOSE" | grep -vE '@sha256:[0-9a-f]{64}[[:space:]]*$' || true)"
if [ -n "$UNPINNED" ]; then
  echo "   ❌ 有镜像未锁 digest（只写标签会被上游重推换内容）："
  printf '%s\n' "$UNPINNED" | sed 's/^/        /'
  FAILED=1
else
  echo "   ✅ 全部镜像已锁 digest（共 $(grep -cE '^[[:space:]]*image:[[:space:]]' "$COMPOSE") 个）"
fi
# 目录权限不得再出现 0777
if grep -rn 'chmod 0777' "$BASE/cmd" "$BASE/app" >/dev/null 2>&1; then
  echo "   ❌ 仍有 chmod 0777（应统一为 0700）"; FAILED=1
else
  echo "   ✅ 目录权限已统一为 0700"
fi
# 扩展名短路必须带 /vol 保护，不能回到「只看后缀就放行」
if grep -q 'own and own.startswith("/vol")' "$BASE/app/docker/fv-acl-gate.py"; then
  echo "   ✅ 闸门扩展名短路已带 /vol 保护"
else
  echo "   ❌ 闸门扩展名短路缺少 /vol 保护（旁路风险）"; FAILED=1
fi
# api-scope 必须声明，且必须覆盖预检脚本实际调用的每个开放接口。
# ⚠️ 0.5.25 的审计把 api-scope 判为「未使用」删掉了，而预检从 0.5.9 起就在调这三个接口
#    → 请求一律 403/200003，探针还会把结论误报成「没有授权目录」。0.5.30 恢复并加此断言，
#    防止再被当成「未使用」删掉。
RES="$BASE/config/resource"
PROBE="$BASE/app/docker/fv-acl-probe.sh"
if [ ! -f "$RES" ]; then
  echo "   ❌ config/resource 不存在"; FAILED=1
else
  NEEDED=""
  for req in $(grep -oE 'trim\.[a-zA-Z.]+' "$PROBE" 2>/dev/null | sort -u); do
    case "$req" in
      trim.file.getSharedAccessibleFolders|trim.file.delSharedAccessibleFolder) sc="trim.file.sharedAccess" ;;
      trim.file.getUserAccessibleFolders)  sc="trim.file.userAccess" ;;
      trim.file.checkUserACL)              sc="trim.file.userAcl" ;;
      trim.file.convertPath)               sc="trim.file.path" ;;
      trim.system.getPlatformConfig)       sc="trim.system.getPlatformConfig" ;;
      *) continue ;;
    esac
    NEEDED="$NEEDED $sc"
  done
  NEEDED="$(printf '%s\n' $NEEDED | sort -u | tr '\n' ' ')"
  BAD=""
  for sc in $NEEDED; do
    grep -qF "\"$sc\"" "$RES" || BAD="$BAD $sc"
  done
  if [ -n "$BAD" ]; then
    echo "   ❌ config/resource 缺少预检脚本需要的 api-scope：$BAD"; FAILED=1
  else
    echo "   ✅ api-scope 已声明，覆盖预检脚本调用的全部开放接口（$(printf '%s' "$NEEDED" | wc -w) 个）"
  fi
fi
# ---- body 代理（POST body 路径绕过）断言 ----
# 背景：路径只在请求体里的接口无法由 auth_request 判定（子请求在 ACCESS 阶段执行，
# 请求体还没被读），只靠 Referer 会被「合法 Referer 掩护非法 body」绕过。
# 0.5.31 起这几个接口改由 nginx 整体代理到闸门的 /guard。以下断言盯着这条链路别被改坏。
NGX="$BASE/app/docker/nginx.conf"
GATE="$BASE/app/docker/fv-acl-gate.py"

if grep -qE '^upstream aclbody \{' "$NGX"; then
  echo "   ✅ body 代理 upstream（aclbody）存在"
else
  echo "   ❌ 缺少 upstream aclbody"; FAILED=1
fi

# ⚠️ 必须用 location =（精确匹配）。regex / 命名 location 里 proxy_pass 不允许带
#    字面量 URI 部分 —— nginx 会 emerg 起不来（0.5.31 首版就是这么翻的车：
#    "proxy_pass" cannot have URI part in location given by regular expression ...）。
#    语法层面的通用检查见下面的 check_nginx_conf.py（第 6 条规则）。
for ep in 'preview/api/localFile' 'preview/api/password/unlock'; do
  if grep -qE "^ *location = /app/basemetas-fileview/$ep \{" "$NGX"; then
    echo "   ✅ $ep 用精确匹配（location =）"
  else
    echo "   ❌ $ep 必须是 location = 精确匹配（regex 里 proxy_pass 不能带 URI）"; FAILED=1
  fi
done

if grep -qE 'proxy_pass http://aclbody/guard;' "$NGX"; then
  echo "   ✅ body-path 接口已交给闸门代理（/guard）"
else
  echo "   ❌ 未把 body-path 接口交给闸门代理"; FAILED=1
fi

if grep -qE '^ *location @fv_guard_direct \{' "$NGX"; then
  echo "   ✅ body 代理的 fail-open 落点（@fv_guard_direct）存在"
else
  echo "   ❌ 缺少 @fv_guard_direct（闸门挂掉时 POST 会直接 502）"; FAILED=1
fi

# fail-open 要能触发：error_page 只处理 nginx 自己产生的错误，
# **上游（闸门）返回的** 502 必须靠 proxy_intercept_errors on 才拦得下来。
if awk '/location = \/app\/basemetas-fileview\/preview\/api\/localFile/,/^    }/' "$NGX" \
     | grep -qE '^ *proxy_intercept_errors on;'; then
  echo "   ✅ body 代理已开 proxy_intercept_errors（上游 502 才能触发 fail-open）"
else
  echo "   ❌ body 代理缺少 proxy_intercept_errors on（上游 502 不会触发 fail-open）"; FAILED=1
fi

# srvFile 必须封禁；password/unlock 改为走闸门（**不**封禁）
if grep -qE "^ *location = /app/basemetas-fileview/convert/api/srvFile \{" "$NGX"; then
  echo "   ✅ 已封禁 /convert/api/srvFile（root 写）"
else
  echo "   ❌ 未封禁 /convert/api/srvFile"; FAILED=1
fi
if grep -qE "^ *location = /app/basemetas-fileview/preview/api/password/unlock \{[^}]*return 403" "$NGX"; then
  echo "   ❌ password/unlock 被整条封禁了 —— 应改为走闸门（否则加密压缩包解锁功能失效）"; FAILED=1
else
  echo "   ✅ password/unlock 未被封禁（走闸门判定，功能保留）"
fi

# 闸门的接口清单必须覆盖 nginx 代理的那两个接口
GATE_BLOCK="$(sed -n '/^BODY_PATH_FIELDS = {/,/^}/p' "$GATE")"
GATE_OK=1
for ep in 'localFile' 'password/unlock'; do
  printf '%s' "$GATE_BLOCK" | grep -qF "/preview/api/$ep" || GATE_OK=0
done
if [ "$GATE_OK" -eq 1 ]; then
  echo "   ✅ 闸门 BODY_PATH_FIELDS 覆盖 nginx 代理的两个接口"
else
  echo "   ❌ 闸门 BODY_PATH_FIELDS 与 nginx 代理的接口不一致"; FAILED=1
fi

# ---- fileId 系接口校验（0.5.34）----
# fileId = "preview_" + md5(原始路径)[:16]，不具备保密性；而 /files/{fileId} 的 path
# 参数可选，缺省时引擎会用缓存的原始路径把文件吐出来 → 绕过闸门。对策：要求自带 filePath。
if grep -qE '^FILEID_RE = re\.compile' "$GATE"; then
  echo "   ✅ 闸门有 fileId 识别正则（FILEID_RE）"
else
  echo "   ❌ 闸门缺少 FILEID_RE"; FAILED=1
fi
if grep -qE '^def current_fileid_guard\(\)' "$GATE"; then
  echo "   ✅ 闸门有 fileid_guard 开关"
else
  echo "   ❌ 闸门缺少 current_fileid_guard"; FAILED=1
fi
if grep -q '防 fileId 推导绕过' "$GATE"; then
  echo "   ✅ 闸门对「不带 filePath 的 fileId 请求」有拒绝分支"
else
  echo "   ❌ 闸门缺少 fileId 拒绝分支"; FAILED=1
fi
# ⚠️ 出厂必须是 log（不是 enforce）—— 合法流程里 /page/{n} 与 /pages 没有日志样本，
#    盲切 enforce 有误伤风险。这条断言防止有人"顺手"把它改成 enforce。
if grep -qE '^DEFAULT_FILEID_GUARD = "log"' "$GATE"; then
  echo "   ✅ fileid_guard 出厂默认 log（先观察，符合既定节奏）"
else
  echo "   ❌ fileid_guard 出厂默认必须是 log（先观察再切 enforce）"; FAILED=1
fi

# ---- 压缩包内文件（复合路径）必须能被正确还原 ----
# 引擎把包内文件表示成 <压缩包路径>/<包内路径>/<文件名>，该复合路径在文件系统上不存在。
# 若不还原成压缩包再判，包内文件会被一律拦死（0.5.33 就是这样把该功能弄坏的）。
if grep -qE '^def resolve_archive_prefix\(' "$GATE"; then
  echo "   ✅ 闸门有压缩包复合路径还原（resolve_archive_prefix）"
else
  echo "   ❌ 闸门缺少 resolve_archive_prefix —— 压缩包内文件会被误拦"; FAILED=1
fi
if grep -qE '^def is_file\(' "$GATE"; then
  echo "   ✅ 存在性探测已抽成 is_file（便于单测打桩）"
else
  echo "   ❌ 缺少 is_file"; FAILED=1
fi
if grep -q '压缩包内文件：按压缩包判定' "$GATE"; then
  echo "   ✅ 压缩包内文件按压缩包判 ACL（不是退回来源页）"
else
  echo "   ❌ 缺少压缩包内文件的判定分支"; FAILED=1
fi
if grep -qE '^ *echo "fileid_guard=' "$BASE/app/docker/fv-volumes.sh"; then
  echo "   ✅ acl.conf 模板写出 fileid_guard"
else
  echo "   ❌ acl.conf 模板缺少 fileid_guard"; FAILED=1
fi

# 重定向必须发相对 Location，否则在 unix socket + 网关去端口时会丢外部端
口
if grep -qE '^[[:space:]]*absolute_redirect[[:space:]]+off[[:space:]]*;' "$BASE/app/docker/nginx.conf"; then
  echo "   ✅ 已关闭 absolute_redirect（重定向发相对 Location，端口不会丢）"
else
  echo "   ❌ nginx.conf 缺少 absolute_redirect off —— 302 会拼成无端口的绝对地址"; FAILED=1
fi
# 闸门判定矩阵单测
if command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
  PY="$(command -v python3 || command -v python)"
  if "$PY" "$(dirname "$0")/test_acl_decide.py" >/dev/null 2>&1; then
    echo "   ✅ 闸门判定矩阵单测通过"
  else
    echo "   ❌ 闸门判定矩阵单测失败（跑 $(dirname "$0")/test_acl_decide.py 看详情）"; FAILED=1
  fi
else
  echo "   ⚠️  本机没有 python，跳过闸门判定矩阵单测"
fi
# body 代理判定矩阵单测（用桩引擎，不依赖 docker）
if [ -n "${PY:-}" ]; then
  if "$PY" "$(dirname "$0")/test_body_guard.py" >/dev/null 2>&1; then
    echo "   ✅ body 代理判定矩阵单测通过（含「合法 Referer + 私有 body → 403」）"
  else
    echo "   ❌ body 代理判定矩阵失败（跑 $(dirname "$0")/test_body_guard.py 看详情）"; FAILED=1
  fi
else
  echo "   ⚠️  本机没有 python，跳过 body 代理判定矩阵"
fi
# 浏览器端补丁的逻辑测试（用桩 DOM 在 node 里跑，不需要浏览器）
# 覆盖：触摸滚动兜底必须「页面不可滚 + 表格区域内」才生效 —— 否则会与 PDF.js 叠加成双滚动
if command -v node >/dev/null 2>&1; then
  if node "$(dirname "$0")/test_web_patch.js" >/dev/null 2>&1; then
    echo "   ✅ 浏览器端补丁逻辑测试通过（触摸滚动兜底的作用域与方向）"
  else
    echo "   ❌ 浏览器端补丁逻辑测试失败（跑 $(dirname "$0")/test_web_patch.js 看详情）"; FAILED=1
  fi
else
  echo "   ⚠️  本机没有 node，跳过浏览器端补丁逻辑测试"
fi
# 「应用中心点打开 → 欢迎页」重定向的判定矩阵
# （风险在误伤：写宽了会把真正的文件预览也转到欢迎页）
if [ -n "${PY:-}" ]; then
  if "$PY" "$(dirname "$0")/test_welcome_redirect.py" >/dev/null 2>&1; then
    echo "   ✅ 欢迎页重定向判定矩阵通过"
  else
    echo "   ❌ 欢迎页重定向判定矩阵失败（跑 $(dirname "$0")/test_welcome_redirect.py 看详情）"; FAILED=1
  fi
else
  echo "   ⚠️  本机没有 python，跳过欢迎页重定向判定矩阵"
fi

fv_sync_volumes "/vol1,/vol3" >/dev/null
echo "-- 保存设置 /vol1,/vol3 之后 --"
sed -n '/## VOLUMES_BEGIN/,/## VOLUMES_END/p' "$TRIM_APPDEST/docker/docker-compose.yaml" | sed 's/^/   /'
echo "   记住的设置 -> [$(fv_load_state)]"
grep -q '^ *- /vol3:/vol3:ro' "$TRIM_APPDEST/docker/docker-compose.yaml" || { echo "   ❌ 设置未写入"; FAILED=1; }
[ "$(fv_load_state)" = "/vol1,/vol3" ] || { echo "   ❌ 设置未持久化"; FAILED=1; }
[ -f "$TRIM_APPDEST/docker/.env" ] || { echo "   ❌ .env 未生成"; FAILED=1; }

echo
echo "-- 模拟升级：框架把 app.tgz 重新释放，compose 被模板覆盖 --"
cp "$BASE/app/docker/docker-compose.yaml" "$TRIM_APPDEST/docker/docker-compose.yaml"
sed -n '/## VOLUMES_BEGIN/,/## VOLUMES_END/p' "$TRIM_APPDEST/docker/docker-compose.yaml" | sed 's/^/   /'

echo "-- 升级回调（fv_sync_volumes 无参，走持久化设置）之后 --"
fv_sync_volumes "" >/dev/null
sed -n '/## VOLUMES_BEGIN/,/## VOLUMES_END/p' "$TRIM_APPDEST/docker/docker-compose.yaml" | sed 's/^/   /'
grep -q '^ *- /vol3:/vol3:ro' "$TRIM_APPDEST/docker/docker-compose.yaml" \
  && echo "   ✅ 升级后 /vol3 挂载段已自动恢复" \
  || { echo "   ❌ 升级后 /vol3 仍然丢失"; FAILED=1; }

echo "-- 幂等性：再同步一次，文件内容不应变化 --"
before="$(md5sum "$TRIM_APPDEST/docker/docker-compose.yaml" | cut -d' ' -f1)"
fv_sync_volumes "" >/dev/null
after="$(md5sum "$TRIM_APPDEST/docker/docker-compose.yaml" | cut -d' ' -f1)"
[ "$before" = "$after" ] && echo "   ✅ 幂等" || { echo "   ❌ 非幂等"; FAILED=1; }

echo
echo "== 单文件大小上限（MAXSIZE 标记块）验证 =="
wizard_max_file_mb=""
echo "  模板默认值 -> [$(fv_compose_maxsize)]   期望 [1024]"
[ "$(fv_compose_maxsize)" = "1024" ] || { echo "   ❌ 模板默认值不对"; FAILED=1; }

echo "-- 向导填 512 保存 --"
wizard_max_file_mb=512
fv_sync_volumes "/vol1,/vol3" >/dev/null
sed -n '/## MAXSIZE_BEGIN/,/## MAXSIZE_END/p' "$TRIM_APPDEST/docker/docker-compose.yaml" | sed 's/^/   /'
[ "$(fv_compose_maxsize)" = "512" ] || { echo "   ❌ 向导值未写入"; FAILED=1; }
[ "$(fv_load_maxsize_state)" = "512" ] || { echo "   ❌ 上限未持久化"; FAILED=1; }

echo "-- 模拟升级（compose 被模板覆盖）+ 升级回调（拿不到向导变量）--"
wizard_max_file_mb=""
cp "$BASE/app/docker/docker-compose.yaml" "$TRIM_APPDEST/docker/docker-compose.yaml"
fv_sync_volumes "" >/dev/null
[ "$(fv_compose_maxsize)" = "512" ] \
  && echo "   ✅ 升级后上限已按持久化设置恢复为 512" \
  || { echo "   ❌ 升级后上限被覆盖成 $(fv_compose_maxsize)"; FAILED=1; }

echo "-- 非法输入应回退上次保存的值（关键是绝不能写出非数字，否则引擎容器起不来）--"
for bad in abc "" 0 "1e3" "-5" "102401" "999999999"; do
  wizard_max_file_mb="$bad"
  fv_sync_volumes "" >/dev/null
  got="$(fv_compose_maxsize)"
  case "$got" in
    ''|*[!0-9]*) echo "   ❌ 输入 [$bad] 写出了非数字 [$got]"; FAILED=1 ;;
    *) echo "   输入 [${bad:-空}] -> [$got]  OK" ;;
  esac
done
wizard_max_file_mb=""
fv_sync_volumes "" >/dev/null

echo
echo "== 压缩包内单个文件上限（ARCHIVEMAX 标记块）验证 =="
# 引擎另有一道独立闸门 fileview.archive.max-file-size（**单位字节**，默认 100MB）。
# 依据：fileview-backend 的 ArchiveExtractService 里
#   @Value("${fileview.archive.max-file-size:104857600}") private long maxFileSize;
wizard_archive_max_file_mb=""
echo "  模板默认值 -> [$(fv_compose_archivemax)]   期望 [104857600]（= 100 MB，引擎默认）"
[ "$(fv_compose_archivemax)" = "104857600" ] || { echo "   ❌ 模板默认值不对"; FAILED=1; }

echo "-- 向导填 300（MB）保存（应换算成字节）--"
wizard_archive_max_file_mb=300
fv_sync_volumes "/vol1,/vol3" >/dev/null
sed -n '/## ARCHIVEMAX_BEGIN/,/## ARCHIVEMAX_END/p' "$TRIM_APPDEST/docker/docker-compose.yaml" | sed 's/^/   /'
[ "$(fv_compose_archivemax)" = "314572800" ] \
  && echo "   ✅ 300 MB → 314572800 字节" \
  || { echo "   ❌ 换算不对，得到 [$(fv_compose_archivemax)]"; FAILED=1; }
[ "$(fv_load_archivemax_state)" = "300" ] || { echo "   ❌ 上限未持久化"; FAILED=1; }

echo "-- 模拟升级（compose 被模板覆盖）+ 升级回调（拿不到向导变量）--"
wizard_archive_max_file_mb=""
cp "$BASE/app/docker/docker-compose.yaml" "$TRIM_APPDEST/docker/docker-compose.yaml"
fv_sync_volumes "" >/dev/null
[ "$(fv_compose_archivemax)" = "314572800" ] \
  && echo "   ✅ 升级后已按持久化设置恢复" \
  || { echo "   ❌ 升级后被覆盖成 [$(fv_compose_archivemax)]"; FAILED=1; }

echo "-- 非法输入绝不能写出非数字（引擎侧是 long，写坏会让容器起不来）--"
for bad in abc "" 0 "1e3" "-5" "999999"; do
  wizard_archive_max_file_mb="$bad"
  fv_sync_volumes "" >/dev/null
  got="$(fv_compose_archivemax)"
  case "$got" in
    ''|*[!0-9]*) echo "   ❌ 输入 [$bad] 写出了非数字 [$got]"; FAILED=1 ;;
    *) echo "   输入 [${bad:-空}] -> [$got]  OK" ;;
  esac
done
wizard_archive_max_file_mb=""
fv_sync_volumes "" >/dev/null

echo "-- 同步日志 --"
sed 's/^/   /' "$TRIM_PKGVAR/fv-volumes.log" 2>/dev/null

rm -rf "$T"

echo
if [ "$FAILED" -eq 0 ]; then echo "✅ 全部自检通过"; else echo "❌ 有自检项失败"; fi
exit "$FAILED"
