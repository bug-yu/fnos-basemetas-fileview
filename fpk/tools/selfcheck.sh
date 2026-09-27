#!/bin/bash
# 本地自检：语法检查 + 挂载段改写验证 + 探测并集冒烟 + 「升级后自愈」验证
set -u
BASE="$(cd "$(dirname "$0")/.." && pwd)/basemetas-fileview"
FAILED=0

echo "== bash -n 语法检查 =="
for f in "$BASE"/cmd/* "$BASE"/app/docker/fv-volumes.sh; do
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
. "$BASE/app/docker/fv-volumes.sh"

fv_prepare_fonts
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
