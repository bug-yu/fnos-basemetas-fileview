#!/bin/bash
# 阴性对照测试：验证 selfcheck.sh 里那段 CAD 断言**在缺陷存在时真的会报错**。
#
# 为什么需要它（本项目的既定纪律）：检查逻辑"看起来对"不等于"能抓到问题"。
# 曾经有过「为了快而改写检查，结果假阴性、坏包差点发出去」的事故。
# 所以每加一组断言，都要拿**含已知缺陷的样本**验一遍：必须报错。
#
# 做法：从 selfcheck.sh 里**原样抽出**那段断言（不复制，避免两份实现漂移），
# 指向被故意改坏的 nginx.conf / fv-acl-gate.py，跑一遍看是否 FAILED=1。
#
# 用法： bash fpk/tools/negtest_cad_assert.sh
#
# ⚠️ **故意不接进 selfcheck.sh**，这是**开发期手动跑**的工具：
#    改了 selfcheck.sh 里那组 CAD 断言之后，手动跑一次确认
#    「未改动的配置放行 + 7 类缺陷全部被报出」。
#    不自动跑的原因（2026-10-08 实测，两条都踩过）：
#      ① 本机执行环境会拦截对临时目录的删除，**并连带把调用方 SIGTERM 掉** ——
#         一旦被 selfcheck 调用，selfcheck 会在那一步静默退出（连总结都不打印）。
#         所以本脚本改成「固定目录 + 每次覆盖，不删除」，见下面的 T。
#      ② 8 个用例要跑上百次 grep/awk 子进程，Git Bash 上要 1~2 分钟，容易被环境掐断。
#         一个「时灵时不灵」的检查项比没有更糟 —— 它会给出假的失败。
#    （这两条都是「检查器自身必须先验过」那条纪律的产物：写检查器时不验它，等于没写。）
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SC="$HERE/selfcheck.sh"
BASE="$(cd "$HERE/.." && pwd)/basemetas-fileview"
REAL_NGX="$BASE/app/docker/nginx.conf"
REAL_GATE="$BASE/app/docker/fv-acl-gate.py"

# 抽出 CAD 断言块（含末尾换行；范围由两个唯一标记界定）
BLOCK="$(awk '/^# ---- CAD 预览页/,/^# 闸门判定矩阵单测/' "$SC" | sed '$d')"
if [ -z "$BLOCK" ]; then
  echo "❌ 抽不到 CAD 断言块（selfcheck.sh 的标记被改了？）"; exit 1
fi

# 改坏样本的落地目录。
# ⚠️ **固定路径 + 每次覆盖，不做删除** —— 这是有意为之：
#    实测（2026-10-08）本机执行环境会拦截对临时目录的删除（`rm -rf`、`find -delete`、
#    连 `rm -f` + `rmdir` 都触发），而且**把调用方一起 SIGTERM 掉** ——
#    单独跑看不出问题，一旦被 selfcheck.sh 调用就会把 selfcheck 带走
#    （跑到一半静默退出、连最后的总结都不打印）。
#    所以这里干脆不清理：目录固定，文件每次被 cp/sed 覆盖，不会累积。
#    （又是「检查器自身必须先验过」那条纪律 —— 这个坑是跑对照测试时才暴露的。）
T="${TMPDIR:-/tmp}/negtest-cad"
mkdir -p "$T" 2>/dev/null
if [ ! -d "$T" ]; then
  echo "❌ 建不出临时目录：$T"; exit 1
fi

run_case() {
  # $1=描述 $2=期望(0=应通过 / 1=应报错) $3=nginx.conf $4=gate.py
  local desc="$1" want="$2" ngx="$3" gate="$4" rc
  FAILED=0; NGX="$ngx"; GATE="$gate"
  # ⚠️ 不能用 out="$(eval ...)" —— 命令替换会开子 shell，里面设的 FAILED 传不出来，
  #    结果**缺陷明明被报出来了、rc 却仍是 0**，整个对照测试变成假阴性。
  #    （本脚本第一版就是这么错的，靠"阴性用例必须失败"这条自检抓出来的。）
  #    改成重定向到文件，让断言在**当前 shell**里执行。
  eval "$BLOCK" > "$T/out.txt" 2>&1
  rc="$FAILED"
  if [ "$rc" -eq "$want" ]; then
    echo "  ✅ $desc（FAILED=$rc，符合预期）"
    return 0
  fi
  echo "  ❌ $desc（FAILED=$rc，期望 $want）"
  sed 's/^/        /' "$T/out.txt"
  return 1
}

BAD=0

echo "== 阳性对照：未改动的原始文件必须全部通过 =="
run_case "原始 nginx.conf + 原始闸门" 0 "$REAL_NGX" "$REAL_GATE" || BAD=1

echo
echo "== 阴性对照：注入已知缺陷，必须被报出来 =="

# ① types 里漏掉 application/wasm（本页最容易踩的部署坑）
cp "$REAL_NGX" "$T/no-wasm.conf"
sed -i '/application\/wasm *wasm;/d' "$T/no-wasm.conf"
run_case "types 缺 application/wasm" 1 "$T/no-wasm.conf" "$REAL_GATE" || BAD=1

# ② /cad/api/raw 直连引擎（= 任意文件读取后门）
cp "$REAL_NGX" "$T/raw-direct.conf"
sed -i 's#proxy_pass http://aclgate/raw;#proxy_pass http://fileview:80/;#' "$T/raw-direct.conf"
run_case "/cad/api/raw 直连引擎" 1 "$T/raw-direct.conf" "$REAL_GATE" || BAD=1

# ③ /cad/api/raw 改成前缀匹配（会被前缀 location 吞掉，退化成只做 auth_request）
cp "$REAL_NGX" "$T/raw-prefix.conf"
sed -i 's#location = /app/basemetas-fileview/cad/api/raw#location /app/basemetas-fileview/cad/api/raw#' "$T/raw-prefix.conf"
run_case "/cad/api/raw 不是精确匹配" 1 "$T/raw-prefix.conf" "$REAL_GATE" || BAD=1

# ④ /cad/ 静态资源被误挂 auth_request
cp "$REAL_NGX" "$T/static-auth.conf"
sed -i 's#alias /etc/nginx/conf.d/cad/;#auth_request /__acl;\n        alias /etc/nginx/conf.d/cad/;#' "$T/static-auth.conf"
run_case "CAD 静态资源误挂 auth_request" 1 "$T/static-auth.conf" "$REAL_GATE" || BAD=1

# ⑤ 闸门不再解码路径（0.5.57 修的 HTTP 400 会复现）
cp "$REAL_GATE" "$T/no-unquote.py"
sed -i 's#urllib.parse.unquote(raw)#raw#' "$T/no-unquote.py"
run_case "闸门 /raw 不解码路径" 1 "$REAL_NGX" "$T/no-unquote.py" || BAD=1

# ⑥ /raw 不再 fail-closed（拿不到身份也放行）
cp "$REAL_GATE" "$T/open-raw.py"
sed -i 's#return self._plain(403, "no identity")#return self._raw_allow_all()#' "$T/open-raw.py"
run_case "/raw 不再 fail-closed" 1 "$REAL_NGX" "$T/open-raw.py" || BAD=1

# ⑦ 闸门丢掉 do_GET 的 /raw 路由
cp "$REAL_GATE" "$T/no-route.py"
sed -i 's#elif self.path.startswith("/raw"):#elif False:#' "$T/no-route.py"
run_case "闸门 do_GET 未路由 /raw" 1 "$REAL_NGX" "$T/no-route.py" || BAD=1

echo
if [ "$BAD" -eq 0 ]; then
  echo "✅ 阳性/阴性对照全部符合预期（断言既能放行正常配置，也能抓出 7 类缺陷）"
else
  echo "❌ 有对照用例不符合预期 —— 断言本身可能失效"
fi
exit "$BAD"
