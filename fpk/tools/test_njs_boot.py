#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fv-njs-boot.sh 的逻辑离线验证（本机无 Docker / nginx）。

验证目标（都是 0.5.26 首版翻车的根因）：
  1. 片段（conf.d/nginx.conf）顶层是 **http 上下文** 指令（map/upstream/server/load_module…），
     绝不能直接当主配置传给 nginx -c —— 否则必报
         "map" directive is not allowed here
  2. 正常路径必须**不传 -c**（复用镜像默认主配置）—— 这是零风险的路径
  3. 降级主配置把片段**包在 http{} 里**，且剥掉了 4 类 njs 指令
  4. 降级只在"错误确实是 njs 引起"时才发生（不掩盖真正的语法错）

本脚本做结构推演，不能替代真机 nginx -t，但足以拦住"上下文放错"这类错误。
"""
import re
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent / "basemetas-fileview" / "app" / "docker"
FRAG = BASE / "nginx.conf"
BOOT = BASE / "fv-njs-boot.sh"

HTTP_CTX_DIRECTIVES = (
    "map", "upstream", "server", "load_module", "js_path", "js_import",
    "include", "log_format", "proxy_cache_path", "geo", "split_clients",
)
MAIN_CTX_DIRECTIVES = ("events", "http", "worker_processes", "pid", "user", "error_log")

fails = []


def check(cond, ok_msg, bad_msg):
    if cond:
        print("  OK   " + ok_msg)
    else:
        print("  FAIL " + bad_msg)
        fails.append(bad_msg)


def top_level_words(text):
    """返回 (最终深度, 出现在花括号深度 0 的行首词)。"""
    depth = 0
    out = []
    for line in text.splitlines():
        s = line.split("#", 1)[0].strip()
        if depth == 0 and s:
            w = re.split(r"[\s;{]", s, maxsplit=1)[0]
            if w:
                out.append(w)
        depth += s.count("{") - s.count("}")
    return depth, out


frag_text = FRAG.read_text(encoding="utf-8")
boot_text = BOOT.read_text(encoding="utf-8")

print("① 片段（nginx.conf）顶层指令必须全部属于 http 上下文")
depth, words = top_level_words(frag_text)
check(depth == 0, "花括号配平", "花括号不配平 depth=%d" % depth)
bad = [w for w in words if w in MAIN_CTX_DIRECTIVES]
check(not bad, "没有主配置专属指令（events/http/worker_processes…）",
      "片段里出现主配置专属指令：%s" % bad)
has_http_ctx = [w for w in words if w in HTTP_CTX_DIRECTIVES]
check(bool(has_http_ctx), "含 http 上下文指令：%s" % sorted(set(has_http_ctx)),
      "没发现任何 http 上下文指令（片段结构可能变了）")
check("map" in words, "顶层含 map（这正是首版报错的那条）", "顶层居然没有 map")

print()
print("② 反证：首版把片段直接当主配置 → map 落到深度 0 → 必炸")
check("map" in words,
      "与真机 \"map is not allowed here in .../nginx.conf:13\" 完全吻合",
      "反证不成立")

print()
print("③ 正常路径：必须不传 -c（复用镜像默认主配置的 include conf.d/*.conf）")
exec_lines = re.findall(r"^\s*exec nginx\b.*$", boot_text, re.M)
check(bool(exec_lines), "找到 exec nginx 启动行", "没找到任何 exec nginx")
normal = [l for l in exec_lines if "-c" not in l]
check(bool(normal), "存在**不传 -c** 的启动路径（正常路径，零风险）：%s"
      % (normal[0].strip() if normal else "-"),
      "所有启动路径都传了 -c —— 正常路径没有复用镜像主配置")
check(any("nginx -t" in l and "-c" not in l for l in boot_text.splitlines()),
      "探测用的是 `nginx -t`（不带 -c），覆盖真实启动路径",
      "探测没有用不带 -c 的 nginx -t（那测不到真实场景）")

print()
print("④ 降级路径：临时主配置必须把片段包进 http{}")
m = re.search(r"cat > \"\$MAIN_FB\" <<EOF\n(.*?)\nEOF", boot_text, re.S)
if not m:
    fails.append("没能从脚本里提取降级主配置模板")
    print("  FAIL 没能提取降级主配置模板")
else:
    tmpl = m.group(1)
    check("events {" in tmpl, "模板有 events 块", "模板缺 events 块")
    check("http {" in tmpl, "模板有 http 块", "模板缺 http 块")
    check("include $WORK/*.conf;" in tmpl,
          "模板 include 降级副本目录（$WORK/*.conf）",
          "模板没有 include 降级副本目录")
    check("load_module" not in tmpl,
          "模板自身不含 load_module（njs 由片段提供）",
          "模板里出现了 load_module")

    # 模拟 include 展开：把副本片段的（已剥 njs 版）内容放进 http
    print()
    print("④b 模拟降级 include 展开：map/server 应落在 http 内")
    sed_frag = subprocess.run(
        ["bash", "-c",
         "sed -e 's|^\\([[:space:]]*\\)load_module[[:space:]].*|\\1#RM|' "
         "-e 's|^\\([[:space:]]*\\)js_path[[:space:]].*|\\1#RM|' "
         "-e 's|^\\([[:space:]]*\\)js_import[[:space:]].*|\\1#RM|' "
         "-e 's|^\\([[:space:]]*\\)js_access[[:space:]].*|\\1#RM|' \"%s\"" % FRAG],
        capture_output=True, text=True).stdout
    exp_lines = []
    for line in tmpl.splitlines():
        if line.strip().startswith("include $WORK/"):
            exp_lines.extend("    " + x for x in sed_frag.rstrip().splitlines())
        else:
            exp_lines.append(line)
    edepth, ewords = top_level_words("\n".join(exp_lines))
    check(edepth == 0, "展开后花括号配平", "展开后花括号不配平")
    check("map" not in ewords,
          "展开后 map 落在 http 块内 ✅（首版翻车点已修复）",
          "展开后 map 仍在顶层 —— 修复无效")
    check("server" not in ewords, "展开后 server 在 http 块内",
          "展开后 server 在顶层")

print()
print("⑤ 降级触发条件：只在错误确实与 njs 有关时才降级")
check("grep -qiE" in boot_text and "js_module" in boot_text,
      "有「失败原因是否与 njs 相关」的判断（避免掩盖真正的语法错）",
      "没有区分「njs 问题」与「其它语法错」，可能把真错误降级掩盖掉")

print()
print("⑥ 降级 sed 是否精确注释掉 4 类 njs 指令")
script = """
sed -e 's|^\\([[:space:]]*\\)load_module[[:space:]].*|\\1# RM|' \\
    -e 's|^\\([[:space:]]*\\)js_path[[:space:]].*|\\1# RM|' \\
    -e 's|^\\([[:space:]]*\\)js_import[[:space:]].*|\\1# RM|' \\
    -e 's|^\\([[:space:]]*\\)js_access[[:space:]].*|\\1# RM|' \\
    "%s"
""" % FRAG
out = subprocess.run(["bash", "-c", script], capture_output=True, text=True).stdout
for d in ("load_module", "js_path", "js_import", "js_access"):
    live = [l for l in out.splitlines()
            if l.strip().startswith(d + " ") or l.strip().startswith(d + "\t")]
    check(not live, "降级后 %s 已无有效指令" % d, "降级后仍有有效 %s：%s" % (d, live))
removed = out.count("# RM")
check(removed >= 4, "共注释掉 %d 行（≥4）" % removed, "注释行数不足：%d" % removed)
d2, _ = top_level_words(out)
check(d2 == 0, "降级片段花括号仍配平", "降级片段花括号不配平")

print()
if fails:
    print("❌ %d 项未通过：" % len(fails))
    for f in fails:
        print("   - " + f)
    sys.exit(1)
print("✅ fv-njs-boot 逻辑静态验证通过")
