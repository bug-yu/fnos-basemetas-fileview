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
for f in "$BASE"/cmd/* "$BASE"/app/docker/fv-volumes.sh "$BASE"/app/docker/fv-njs-boot.sh "$BASE"/app/docker/fv-acl-probe.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then echo "  OK   $(basename "$f")"; else echo "  FAIL $(basename "$f")"; bash -n "$f"; FAILED=1; fi
done

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
echo "-- 安全收紧断言（0.5.25）--"
# 引擎镜像必须锁 digest：只写标签时上游重推同名标签会静默换内容
if grep -qE '^ *image: basemetas/fileview:1\.5\.2@sha256:[0-9a-f]{64}$' "$BASE/app/docker/docker-compose.yaml"; then
  echo "   ✅ 引擎镜像已锁 digest"
else
  echo "   ❌ 引擎镜像未锁 digest（只写标签会被上游重推换内容）"; FAILED=1
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
# api-scope 声明应已删除（未使用）
if grep -q 'api-scope' "$BASE/config/resource" 2>/dev/null; then
  echo "   ❌ config/resource 仍声明未使用的 api-scope"; FAILED=1
else
  echo "   ✅ 未使用的 api-scope 声明已删除"
fi

echo
echo "-- 安全收紧断言（0.5.26：POST body 路径判定，方案 B）--"
# ① njs 守卫脚本必须存在
if [ -f "$BASE/app/docker/body-path-guard.js" ]; then
  echo "   ✅ body-path-guard.js 存在"
else
  echo "   ❌ 缺少 app/docker/body-path-guard.js（方案 B 的核心）"; FAILED=1
fi
# ② nginx 必须加载 njs 并 js_import 守卫
if grep -q 'load_module modules/ngx_http_js_module.so;' "$BASE/app/docker/nginx.conf"; then
  echo "   ✅ nginx.conf 已 load_module njs"
else
  echo "   ❌ nginx.conf 未加载 njs 模块"; FAILED=1
fi
if grep -q 'js_import bodyguard from body-path-guard.js;' "$BASE/app/docker/nginx.conf"; then
  echo "   ✅ nginx.conf 已 js_import bodyguard"
else
  echo "   ❌ nginx.conf 未 js_import bodyguard"; FAILED=1
fi
# ③ 主 location 与 SPA location 都必须挂 js_access（否则可被绕过走另一条 location）
n_jsaccess="$(grep -c 'js_access bodyguard.guard;' "$BASE/app/docker/nginx.conf" || true)"
if [ "${n_jsaccess:-0}" -ge 2 ]; then
  echo "   ✅ js_access 已挂载（$n_jsaccess 处：主 location + SPA location）"
else
  echo "   ❌ js_access 只挂了 ${n_jsaccess:-0} 处，应至少 2 处（漏挂的 location 可被用来绕过）"; FAILED=1
fi
# ④ 闸门的 body 路径入口必须存在，且子请求 location 指向它
if grep -q 'startswith("/check-body")' "$BASE/app/docker/fv-acl-gate.py"; then
  echo "   ✅ 闸门已提供 /check-body 入口"
else
  echo "   ❌ 闸门缺少 /check-body 入口"; FAILED=1
fi
if grep -q 'proxy_pass http://aclgate/check-body;' "$BASE/app/docker/nginx.conf"; then
  echo "   ✅ nginx 子请求 location /__acl-body 指向闸门 /check-body"
else
  echo "   ❌ 缺少 location = /__acl-body"; FAILED=1
fi
# ⑤ /__acl-body 必须走 aclgate upstream（闸门挂了要 fail-open，不能硬编码 IP）
if awk '/location = \/__acl-body/,/^    }/' "$BASE/app/docker/nginx.conf" | grep -q 'proxy_pass http://aclgate/check-body;'; then
  echo "   ✅ /__acl-body 走 aclgate upstream（闸门不可用时 fail-open）"
else
  echo "   ❌ /__acl-body 未走 aclgate upstream（闸门挂掉会变成硬失败）"; FAILED=1
fi
# ⑥ 判定逻辑必须复用（_decide_body 内部调 can_read / current_mode），不能另写一套
if awk '/def _decide_body/{f=1} f{print} f && /^        return True, "不可读（当前 mode=log/{exit}' \
     "$BASE/app/docker/fv-acl-gate.py" | grep -q 'can_read('; then
  echo "   ✅ _decide_body 复用 can_read（判定单一事实来源）"
else
  echo "   ❌ _decide_body 未复用 can_read（可能另写了一套判定）"; FAILED=1
fi
# ⑦ js 语法（用 njs 或 node 任一可用的做检查；都没有就跳过）
if command -v njs >/dev/null 2>&1; then
  if njs -c "$BASE/app/docker/body-path-guard.js" >/dev/null 2>&1; then
    echo "   ✅ body-path-guard.js 语法通过（njs）"
  else
    echo "   ❌ body-path-guard.js 语法错误（njs -c）"; FAILED=1
  fi
elif command -v node >/dev/null 2>&1; then
  # node 不认 njs 的 export default 语法，包一层再检查
  if node --input-type=module -e "$(cat "$BASE/app/docker/body-path-guard.js")" --check 2>/dev/null \
     || node --check <(printf 'export default {};%s' "$(cat "$BASE/app/docker/body-path-guard.js")") 2>/dev/null; then
    echo "   ✅ body-path-guard.js 语法通过（node 近似检查）"
  else
    echo "   ⚠️  node 无法校验 njs 语法，跳过（建议在网关容器里跑 njs -c）"
  fi
else
  echo "   ⚠️  本机没有 njs/node，跳过 body-path-guard.js 语法检查"
fi

# ⑧ 降级保护：镜像没 njs 时不能让 nginx 起不来
if [ -f "$BASE/app/docker/fv-njs-boot.sh" ]; then
  echo "   ✅ fv-njs-boot.sh 存在（njs 不可用时自动降级）"
else
  echo "   ❌ 缺少 app/docker/fv-njs-boot.sh（镜像没 njs 会让 nginx 起不来 → 应用打不开）"; FAILED=1
fi
if grep -q 'fv-njs-boot.sh' "$BASE/app/docker/docker-compose.yaml"; then
  echo "   ✅ gateway 启动命令已走 fv-njs-boot.sh"
else
  echo "   ❌ gateway 未使用 fv-njs-boot.sh（缺少 njs 降级保护）"; FAILED=1
fi
# 降级脚本必须真的会剥离 js_access（否则降级后 still 引用未加载的模块 → 起不来）
if grep -q 'js_access' "$BASE/app/docker/fv-njs-boot.sh"; then
  echo "   ✅ 降级脚本会处理 js_access"
else
  echo "   ❌ 降级脚本未处理 js_access（降级后仍会引用未加载的 njs → 起不来）"; FAILED=1
fi

# ★★ 0.5.26-r2 真机事故的回归断言：绝不能用 `nginx -c <conf.d 片段>` ★★
# conf.d/nginx.conf 是 http 上下文的**片段**（第 13 行就是 `map {}`）。当主配置用会报
#   [emerg] "map" directive is not allowed here in .../nginx.conf:13
# 该错与 njs 无关 → 探测永远失败 → 必然崩 → 无限重启。必须保证：
#   ① 正常路径用不带 -c 的 `exec nginx`（复用镜像主配置的 include conf.d/*.conf）
#   ② 探测用不带 -c 的 `nginx -t`
if grep -qE "^[[:space:]]*exec nginx -g 'daemon off;'" "$BASE/app/docker/fv-njs-boot.sh"; then
  echo "   ✅ 正常路径用镜像默认主配置启动（exec nginx，不带 -c）"
else
  echo "   ❌ 正常路径没有「不带 -c 的 exec nginx」—— 0.5.26 首版就是因此无限重启！"; FAILED=1
fi
if grep -qE "^[[:space:]]*if ! nginx -t >" "$BASE/app/docker/fv-njs-boot.sh"; then
  echo '   ✅ 探测用 `nginx -t`（不带 -c），与真实启动路径一致'
else
  echo '   ❌ 探测没有用不带 -c 的 `nginx -t`（测不到真实场景，会误判）'; FAILED=1
fi
# 且绝不能把片段直接喂给 -c
if grep -qE "nginx -t -c \"?\\\$ORIG|nginx -c \"?\\\$ORIG" "$BASE/app/docker/fv-njs-boot.sh"; then
  echo "   ❌ 发现把 conf.d 片段当主配置（\$ORIG）传给 -c —— 会导致 map 报错 + 无限重启"; FAILED=1
else
  echo "   ✅ 没有把 conf.d 片段当主配置传给 -c"
fi

# njs-boot 包裹逻辑单测（含"include 展开后 map 落在 http 内"的决定性验证）
if [ -f "$(dirname "$0")/test_njs_boot.py" ]; then
  NB_PY="$(command -v python3 || command -v python || true)"
  if [ -n "$NB_PY" ] && "$NB_PY" "$(dirname "$0")/test_njs_boot.py" >/dev/null 2>&1; then
    echo "   ✅ fv-njs-boot 包裹逻辑单测通过"
  else
    echo "   ❌ fv-njs-boot 包裹逻辑单测失败（跑 $(dirname "$0")/test_njs_boot.py 看详情）"; FAILED=1
  fi
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

echo "-- 同步日志 --"
sed 's/^/   /' "$TRIM_PKGVAR/fv-volumes.log" 2>/dev/null

rm -rf "$T"

echo
if [ "$FAILED" -eq 0 ]; then echo "✅ 全部自检通过"; else echo "❌ 有自检项失败"; fi
exit "$FAILED"
