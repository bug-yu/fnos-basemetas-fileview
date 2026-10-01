#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
网关主配置/片段结构 + fv-njs-boot.sh 逻辑的离线验证（本机无 Docker / nginx）。

背景：0.5.26 连续两轮翻车，根因分别是
  ① 把 conf.d 片段当主配置传给 nginx -c  → "map" directive is not allowed here
  ② 把 load_module 写在 conf.d 片段里      → "load_module" directive is not allowed here
两个错误都**与镜像带不带 njs 无关**，却都被误判成"镜像不含 njs"而走了降级。

本脚本静态守住这些结构性约束（真机 nginx -t 仍是最终判据）。
"""
import re
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent / "basemetas-fileview" / "app" / "docker"
FRAG = BASE / "nginx.conf"          # conf.d 片段（http 上下文）
MAIN = BASE / "fv-main.main"        # 我们的主配置（main 上下文）
BOOT = BASE / "fv-njs-boot.sh"

# 只能出现在 main 上下文的指令
MAIN_ONLY = ("load_module", "worker_processes", "pid", "user", "events", "http")
# 属于 http 上下文的指令
HTTP_CTX = ("map", "upstream", "server", "js_path", "js_import", "log_format")

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


frag = FRAG.read_text(encoding="utf-8")
main = MAIN.read_text(encoding="utf-8")
boot = BOOT.read_text(encoding="utf-8")

print("① conf.d 片段（nginx.conf）里绝不能有 main-only 指令")
d, w = top_level_words(frag)
check(d == 0, "片段花括号配平", "片段花括号不配平 depth=%d" % d)
bad = [x for x in w if x in ("load_module", "worker_processes", "pid", "user")]
check(not bad, "片段里没有 load_module/worker_processes/pid/user ✅（第②次翻车点）",
      "片段里出现了 main-only 指令：%s ★ 必报 '... is not allowed here'" % bad)
check("map" in w or "upstream" in w or "server" in w or "js_import" in w,
      "片段确实是 http 上下文内容（含 map/server/js_import 等）",
      "片段看起来不像 http 上下文内容，结构可能变了")
check("js_import" in w, "片段保留 js_import（http 上下文，合法）",
      "片段缺少 js_import")

print()
print("② 主配置（fv-main.main）必须是 main 上下文，且含 load_module")
dm, wm = top_level_words(main)
check(dm == 0, "主配置花括号配平", "主配置花括号不配平 depth=%d" % dm)
check("load_module" in wm, "load_module 在 main 层 ✅（第②次翻车点的修复）",
      "主配置顶层没有 load_module")
check("events" in wm, "有 events 块", "缺 events 块")
check("http" in wm, "有 http 块", "缺 http 块")
check("worker_processes" in wm, "有 worker_processes", "缺 worker_processes")
# 主配置里不该出现 http 上下文指令在顶层
badm = [x for x in wm if x in ("map", "server", "upstream", "js_import", "js_path")]
check(not badm, "主配置顶层没有 http 上下文指令（它们应在片段里）",
      "主配置顶层出现 http 上下文指令：%s" % badm)
check("include /etc/nginx/conf.d/*.conf;" in main,
      "主配置 include conf.d/*.conf（把片段放进 http 内）",
      "主配置没有 include conf.d/*.conf")

print()
print("③ 模拟 include 展开：map/server 应落在 http 内，load_module 在 main 层")
exp_lines = []
for line in main.splitlines():
    if line.strip().startswith("include /etc/nginx/conf.d/"):
        exp_lines.extend("    " + x for x in frag.rstrip().splitlines())
    else:
        exp_lines.append(line)
ed, ew = top_level_words("\n".join(exp_lines))
check(ed == 0, "展开后花括号配平", "展开后花括号不配平")
check("map" not in ew, "展开后 map 落在 http 内 ✅", "展开后 map 跑到顶层")
check("server" not in ew, "展开后 server 落在 http 内 ✅", "展开后 server 跑到顶层")
check("load_module" in ew, "展开后 load_module 仍在 main 层 ✅", "展开后 load_module 位置异常")

print()
print("④ fv-njs-boot.sh：探测与启动都要用主配置（-c fv-main.main），不能指片段")
check(bool(re.search(r'MAIN_SRC="\$CONF_DIR/fv-main\.main"', boot)),
      "指向 fv-main.main 作为主配置来源", "没有把 fv-main.main 当作主配置来源")
check("nginx -t -c \"$MAIN\"" in boot, "探测用 -c \"$MAIN\"（主配置）",
      "探测没有用主配置做 -t")
# 绝不能 -c 指片段
badc = re.findall(r'nginx[^\n]*-c\s+"?\$?(?:ORIG|CONF_DIR/nginx\.conf)', boot)
check(not badc, "没有把 conf.d 片段传给 -c ✅（第①次翻车点）",
      "发现把片段传给 -c：%s" % badc)

print()
print("⑤ 降级判据：只在「模块文件缺失」时才降级，不掩盖配置错误")
check(re.search(r"grep -qiE '[^']*dlopen", boot) is not None,
      "降级判据检查 dlopen / not binary compatible 等「文件缺失」特征",
      "降级判据没有检查 dlopen 等文件缺失特征")
check("load_module\" directive is not allowed here" in boot
      or "directive is not allowed here" in boot,
      "提示里明确区分了「位置非法」与「文件缺失」",
      "没有区分位置非法与文件缺失的提示")

print()
print("⑤b 分类逻辑：必须区分「模块缺失」与「模块在但版本旧」（2026-10-01 真机翻车点）")
# ★ 从脚本里把 is_load_failure 抽出来用**真实函数**测（不是重新实现一遍正则）
_fm = re.search(r"is_load_failure\(\)\s*\{(.*?)\n\}", boot, re.S)
check(_fm is not None, "脚本里有 is_load_failure 函数",
      "缺少 is_load_failure 函数")
_func = _fm.group(1) if _fm else ""
_pm = re.search(r"grep -qiE '([^']+)'", _func)
check(_pm is not None, "能取出「文件缺失」特征正则", "取不出特征正则")
_pat = _pm.group(1) if _pm else r"(?!x)x"


def _is_load_failure(t):
    return re.search(_pat, t, re.I) is not None


# 真机日志原样序列（前 4 条：模块加载成功、卡在 js_access；后 3 条：兜底假路径 dlopen 失败）
_real = [
    '[emerg] unknown directive "js_access" in /tmp/fv-conf.d/nginx.conf:211',
    '[emerg] unknown directive "js_access" in /tmp/fv-conf.d/nginx.conf:211',
    '[emerg] unknown directive "js_access" in /tmp/fv-conf.d/nginx.conf:211',
    '[emerg] unknown directive "js_access" in /tmp/fv-conf.d/nginx.conf:211',
    '[emerg] dlopen() "/usr/share/nginx/modules/ngx_http_js_module.so" failed'
    ' (No such file or directory)',
    '[emerg] dlopen() "/usr/local/nginx/modules/ngx_http_js_module.so" failed'
    ' (No such file or directory)',
    '[emerg] dlopen() "/usr/local/lib/nginx/modules/ngx_http_js_module.so" failed'
    ' (No such file or directory)',
]
check(any(not _is_load_failure(x) for x in _real),
      "真机日志序列 → 判定「模块存在」（不再误报缺模块）✅",
      "真机日志序列仍被误判成「缺模块」❌")

# 旧 bug 回归：旧逻辑只看**最后一条**，而它恰好是 dlopen 失败 → 必然误判
check(_is_load_failure(_real[-1]),
      "（回归）最后一条日志确实是 dlopen 失败 —— 这正是旧逻辑必然降级的原因",
      "最后一条日志不是 dlopen 失败，本测试前提已变")

# 反向：镜像真的没有 njs 时，全部都是 dlopen → 仍应判「缺模块」（不能误伤）
_absent = ['[emerg] dlopen() "/x/y.so" failed (No such file or directory)'] * 7
check(not any(not _is_load_failure(x) for x in _absent),
      "镜像真没 njs 时 → 仍判「缺模块」（不误伤）✅",
      "镜像真没 njs 时被误判成「模块存在」❌")

# 脚本必须把「是否加载成功过」累积下来，而不是只看最后一份日志
check("SAW_LOADED" in boot,
      "脚本累积「是否成功加载过」的证据（SAW_LOADED）",
      "脚本没有累积证据，仍可能只看最后一份日志")
check("unknown directive" in boot or "js_access" in boot,
      "脚本对 js_access 版本问题给了专门诊断",
      "脚本没有针对 js_access 的诊断")

print()
print("⑥ 探测 .so 真实路径（相对前缀不可靠，逐个候选试）")
check("JS_SO_CANDIDATES" in boot, "有候选路径清单 JS_SO_CANDIDATES",
      "没有探测 .so 路径的逻辑")
check("try_with_so" in boot, "有 try_with_so 逐个试加载",
      "没有逐个试加载的逻辑")
check("/usr/lib/nginx/modules/ngx_http_js_module.so" in boot,
      "候选里含 /usr/lib/nginx/modules/（Debian 系常见位置）",
      "候选里没有 /usr/lib/nginx/modules/")
check("/etc/nginx/modules/ngx_http_js_module.so" in boot,
      "候选里含 /etc/nginx/modules/（官方镜像前缀位置）",
      "候选里没有 /etc/nginx/modules/")
check("modules/ngx_http_js_module.so" in boot,
      "候选里保留了裸相对路径（让 nginx 按自身 prefix 解析）",
      "候选里没有裸相对路径")

print()
print("⑥b 主配置的 include 必须指向可写副本（否则降级剥的副本读不到）")
check(re.search(r"include\s+\$\{?WORK\}?/\*\.conf", boot) is not None
      or "include ${WORK}/*.conf" in boot or "include $WORK/*.conf" in boot,
      "脚本会把 include 重写到副本目录（否则降级等于没做）",
      "include 没有重写到副本目录 —— 降级时改动不会生效")

print()
print("⑦ 降级时 njs 4 类指令一起去掉（否则 js_import 报 unknown directive）")
check(boot.count("js_path") >= 1 and boot.count("js_import") >= 1
      and boot.count("js_access") >= 1 and boot.count("load_module") >= 1,
      "降级 sed 覆盖 load_module / js_path / js_import / js_access",
      "降级 sed 漏了某类 njs 指令")

print()
print("⑧ 本机可做的真实 sed 验证：降级后 njs 指令应全部失效")
# ⚠️ 路径用 Windows 形式：Windows 原生 Python 不认 Git Bash 的 /tmp。
import tempfile
import os
work = os.path.join(tempfile.gettempdir(), "_t_frag.conf")
subprocess.run(["bash", "-c",
                "sed -e 's|^\\([[:space:]]*\\)js_path[[:space:]].*|\\1#RM|' "
                "-e 's|^\\([[:space:]]*\\)js_import[[:space:]].*|\\1#RM|' "
                "-e 's|^\\([[:space:]]*\\)js_access[[:space:]].*|\\1#RM|' "
                "'%s' > '%s'" % (FRAG, work)], check=True)
out = Path(work).read_text(encoding="utf-8")
for k in ("js_path", "js_import", "js_access"):
    live = [l for l in out.splitlines()
            if l.strip().startswith(k + " ") or l.strip().startswith(k + "\t")]
    check(not live, "降级后 %s 已无有效指令" % k, "降级后仍有有效 %s：%s" % (k, live))
Path(work).unlink(missing_ok=True)

print()
if fails:
    print("❌ %d 项未通过：" % len(fails))
    for f in fails:
        print("   - " + f)
    sys.exit(1)
print("✅ 主配置/片段结构 + fv-njs-boot 逻辑静态验证通过")
