#!/bin/bash
# 本地自检：语法检查 + 挂载段改写逻辑验证
BASE="$(cd "$(dirname "$0")/.." && pwd)/basemetas-fileview"

echo "== bash -n 语法检查 =="
for f in "$BASE"/cmd/* "$BASE"/app/docker/fv-volumes.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then echo "  OK   $(basename "$f")"; else echo "  FAIL $(basename "$f")"; bash -n "$f"; fi
done

echo
echo "== 挂载段改写验证 =="
WORK="$(mktemp -d)"
sed -n '/## VOLUMES_BEGIN/,/## VOLUMES_END/p' "$BASE/app/docker/docker-compose.yaml" > /dev/null
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

echo
echo "== fv_resolve_volumes / fv_detect_volumes 冒烟 =="
. "$BASE/app/docker/fv-volumes.sh"
echo "  detect   -> [$(fv_detect_volumes)]"
echo "  auto     -> [$(fv_resolve_volumes auto)]"
echo "  /vol2    -> [$(fv_resolve_volumes /vol2)]"
echo "  '/vol1, /vol9 ' -> [$(fv_resolve_volumes '/vol1, /vol9 ')]"
echo "  空       -> [$(fv_resolve_volumes '')]"
rm -rf "$WORK"
