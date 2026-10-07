#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""body 代理（/guard）判定矩阵单测。

背景
----
「路径只在请求体里」的接口（POST /preview/api/localFile 等）无法由 nginx 的
auth_request 判定 —— 子请求在 ACCESS 阶段执行，**请求体还没被读**。
只靠来源页（Referer）判定会被绕过：攻击者先打开一个自己有权读的文件拿到合法
Referer，再 POST 别人的路径，闸门拿合法 Referer 放行，body 里的非法路径根本没被看过。
（真机已复现：无 Referer = 200，带合法 Referer = 200。）

0.5.31 起这几个接口改由 nginx **整体代理**到闸门的 /guard：
闸门读 body 取路径 → 判 ACL → 通过后**自己转发**给引擎。

本测试验证的核心命题
--------------------
    「请求体里的路径」才是判定依据，**绝不退回来源页**。

用桩引擎（返回 200 并回显收到的路径）代替真实引擎，不依赖 docker / nginx。

用法：python3 fpk/tools/test_body_guard.py
"""
import importlib.util
import json
import os
import socket
import sys
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
GATE_PY = os.path.normpath(os.path.join(
    HERE, "..", "basemetas-fileview", "app", "docker", "fv-acl-gate.py"))

PRIVATE = "/vol2/1000/别人的私有文件.docx"      # 当前用户读不到
PUBLIC = "/vol1/1001/我能读的文件.docx"          # 当前用户读得到
NOTVOL = "/opt/fileview/assets/sample.docx"     # 非存储卷（欢迎页样例）
UNKNOWN = "/vol9/1000/查不到用户.docx"           # can_read 返回 None

# 压缩包：引擎把包内文件表示成 <压缩包路径>/<包内路径>/<文件名>（复合路径，
# 文件系统上不存在）。0.5.33 就是因为直接判这个复合路径而把该功能拦死了。
ARCHIVE = "/vol1/1001/我的压缩包.zip"
ARCHIVE_SEC = "/vol2/1000/别人的压缩包.zip"
INNER_OK = ARCHIVE + "/目录/文件.docx"
INNER_SEC = ARCHIVE_SEC + "/目录/文件.docx"
GHOST = "/vol1/1001/根本不存在的包.zip/目录/文件.docx"
TRAVERSAL = ARCHIVE + "/../../vol2/1000/别人的私有文件.docx"

LOCALFILE = "/app/basemetas-fileview/preview/api/localFile"
UNLOCK = "/app/basemetas-fileview/preview/api/password/unlock"
POLL = "/app/basemetas-fileview/preview/api/status/poll"

FAILED = 0


def check(name, got, want):
    global FAILED
    ok = got == want
    if not ok:
        FAILED = 1
    print("  %s %-56s got=%s want=%s" % ("OK  " if ok else "FAIL", name, got, want))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


# ---------------------------------------------------------------------------
# 桩引擎：收到什么都回 200，并把「收到的路径 + 收到的 body」回显出来
# ---------------------------------------------------------------------------
class StubEngine(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    seen = []          # [(path, body_str, headers_dict), ...]

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n > 0 else b""
        StubEngine.seen.append((self.path, body.decode("utf-8", "replace"),
                                {k.lower(): v for k, v in self.headers.items()}))
        payload = json.dumps({"ok": True, "enginePath": self.path}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    engine_port = free_port()
    gate_port = free_port()

    eng = ThreadingHTTPServer(("127.0.0.1", engine_port), StubEngine)
    threading.Thread(target=eng.serve_forever, daemon=True).start()

    tmpdir = tempfile.mkdtemp(prefix="fv-guard-test-")
    conf = os.path.join(tmpdir, "acl.conf")
    write_conf(conf, mode="enforce", guard="enforce")

    os.environ["FV_ACL_MODE_FILE"] = conf
    os.environ["FV_ENGINE_BASE"] = "http://127.0.0.1:%d" % engine_port
    os.environ["FV_ACL_PORT"] = str(gate_port)

    spec = importlib.util.spec_from_file_location("fvgate", GATE_PY)
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)

    # 打桩 can_read：PUBLIC 与「我的压缩包」可读、PRIVATE 与「别人的压缩包」不可读、
    # UNKNOWN 无法判定
    def fake_can_read(uid, path):
        if path == UNKNOWN:
            return None
        return path in (PUBLIC, ARCHIVE)
    gate.can_read = fake_can_read

    # 打桩 is_file：只有两个压缩包在文件系统上「存在」（测试机上没有 /vol*）
    def fake_is_file(p):
        return p in (ARCHIVE, ARCHIVE_SEC)
    gate.is_file = fake_is_file

    srv = ThreadingHTTPServer(("127.0.0.1", gate_port), gate.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    base = "http://127.0.0.1:%d/guard" % gate_port

    def call(uri, body_obj, uid="1000", ref=None, raw_body=None, extra=None):
        if raw_body is not None:
            data = raw_body
        elif body_obj is None:
            data = b""
        else:
            data = json.dumps(body_obj).encode()
        req = urllib.request.Request(base, data=data, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("X-Acl-Uri", uri)
        if uid:
            req.add_header("X-Acl-Uid", uid)
        if ref:
            req.add_header("X-Acl-Ref", ref)
        for k, v in (extra or {}).items():
            req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    print("== body_guard=enforce ==")
    print("  —— 核心命题：判定依据是 body，不是 Referer ——")

    # ★ 决定性用例：Referer 是合法的（自己有权读），body 是别人的私有文件
    #   旧实现（退回 Referer）会 200；现在必须 403。
    #   注意：Referer 里的中文路径必须是百分号编码的 —— 浏览器就是这么发的，
    #   而且 HTTP 头只能是 latin-1（不编码会直接抛 UnicodeEncodeError）。
    ref_legit = ("https://nas.example.com/app/basemetas-fileview/preview/view?path="
                 + urllib.parse.quote(PUBLIC))
    code, _ = call(LOCALFILE, {"srcRelativePath": PRIVATE}, ref=ref_legit)
    check("Referer 合法 + body 私有 → 必须拒绝（旧实现会放行）", code, 403)

    code, _ = call(LOCALFILE, {"srcRelativePath": PRIVATE})
    check("无 Referer + body 私有 → 拒绝", code, 403)

    code, _ = call(UNLOCK, {"originalFilePath": PRIVATE}, ref=ref_legit)
    check("password/unlock + body 私有 → 拒绝", code, 403)

    print("  —— 正常流程不能被误伤 ——")
    StubEngine.seen.clear()
    code, body = call(LOCALFILE, {"srcRelativePath": PUBLIC}, ref=ref_legit)
    check("body 可读 → 转发给引擎（200）", code, 200)
    check("  转发到了引擎、且路径正确",
          StubEngine.seen[-1][0] if StubEngine.seen else None, "/preview/api/localFile")
    check("  请求体原样透传（引擎收到同一份 JSON）",
          json.loads(StubEngine.seen[-1][1]).get("srcRelativePath") if StubEngine.seen else None,
          PUBLIC)

    code, _ = call(UNLOCK, {"originalFilePath": PUBLIC})
    check("password/unlock + body 可读 → 转发", code, 200)

    print("  —— ★ 转发必须带上 Host 与 X-Forwarded-*（否则引擎拼出打不开的绝对地址）——")
    # 引擎的 RequestAwareBaseUrlProvider 按请求头推导 baseUrl。闸门转发时若丢掉这些头，
    # 引擎会拼出 http://fileview/... —— 浏览器打不开。典型症状：**PDF 预览失败**
    # （PDF 渲染器直接用 localFile 返回的绝对 URL 取文件，ofd/xlsx 用相对路径所以看不出来）。
    # 2026-10-06 真实踩过：0.5.32 装完 PDF 打不开，根因就是这里。
    StubEngine.seen.clear()
    code, _ = call(LOCALFILE, {"srcRelativePath": PUBLIC}, extra={
        "Host": "nas.example.com:8443",
        "X-Forwarded-Proto": "https",
        "X-Forwarded-Prefix": "/app/basemetas-fileview",
        "X-Forwarded-Host": "nas.example.com:8443",
        "X-Forwarded-Port": "8443",
    })
    hdr = StubEngine.seen[-1][2] if StubEngine.seen else {}
    check("引擎收到正确的 Host", hdr.get("host"), "nas.example.com:8443")
    check("引擎收到 X-Forwarded-Proto", hdr.get("x-forwarded-proto"), "https")
    check("引擎收到 X-Forwarded-Prefix", hdr.get("x-forwarded-prefix"),
          "/app/basemetas-fileview")
    check("引擎收到 X-Forwarded-Port", hdr.get("x-forwarded-port"), "8443")
    check("内部头 X-Acl-* 未被透给引擎",
          any(k.startswith("x-acl-") for k in hdr), False)

    print("  —— fail-open：与全站取向一致，不把应用弄坏 ——")
    code, _ = call(LOCALFILE, {"srcRelativePath": NOTVOL})
    check("非存储卷路径（欢迎页样例）→ 放行转发", code, 200)

    code, _ = call(LOCALFILE, {})
    check("body 里没有路径字段 → 放行转发", code, 200)

    code, _ = call(LOCALFILE, None, raw_body=b"not-json-at-all")
    check("body 不是 JSON → 放行转发", code, 200)

    code, _ = call(LOCALFILE, {"srcRelativePath": PRIVATE}, uid="")
    check("缺 uid → 放行转发", code, 200)

    code, _ = call(LOCALFILE, {"srcRelativePath": UNKNOWN})
    check("can_read 无法判定 → 放行转发", code, 200)

    code, _ = call(POLL, {"fileId": "abc"})
    check("不在清单里的接口 → 不判定、直接转发", code, 200)

    print("== 压缩包内文件（复合路径）==")
    # 引擎把包内文件表示成 <压缩包路径>/<包内路径>/<文件名>。这个复合路径在文件系统上
    # 不存在，直接判必然「不可读」。但引擎实际读的是**压缩包**，所以该判压缩包的 ACL。
    # ⚠️ 0.5.33 漏了这一步，把「压缩包内文件预览」拦死了（0.5.30 能用 → 回归）。
    StubEngine.seen.clear()
    code, _ = call(LOCALFILE, {"srcRelativePath": INNER_OK}, ref=ref_legit)
    check("压缩包可读 → 包内文件放行（★ 0.5.33 曾误拦）", code, 200)
    check("  转发给了引擎", StubEngine.seen[-1][0] if StubEngine.seen else None,
          "/preview/api/localFile")

    code, _ = call(LOCALFILE, {"srcRelativePath": INNER_SEC}, ref=ref_legit)
    check("压缩包不可读 → 包内文件拒绝（保护仍在）", code, 403)

    code, _ = call(LOCALFILE, {"srcRelativePath": GHOST}, ref=ref_legit)
    check("压缩包根本不存在 → 拒绝（不能凭构造放行）", code, 403)

    code, _ = call(LOCALFILE, {"srcRelativePath": TRAVERSAL}, ref=ref_legit)
    check("含 .. 的复合路径 → 拒绝（不做前缀还原）", code, 403)

    code, _ = call(LOCALFILE, {"srcRelativePath": ARCHIVE})
    check("压缩包本身（非复合路径）可读 → 放行", code, 200)

    print("== body_guard=log（单独回退这一层）==")
    write_conf(conf, mode="enforce", guard="log")
    code, _ = call(LOCALFILE, {"srcRelativePath": PRIVATE}, ref=ref_legit)
    check("body 私有 → 只记录、仍然转发（200）", code, 200)

    print("== 两个开关相互独立 ==")
    write_conf(conf, mode="log", guard="enforce")
    code, _ = call(LOCALFILE, {"srcRelativePath": PRIVATE}, ref=ref_legit)
    check("mode=log 不影响 body_guard（仍拒绝）", code, 403)

    write_conf(conf, mode="enforce", guard="enforce")

    print()
    if FAILED == 0:
        print("✅ body 代理判定矩阵全部通过")
    else:
        print("❌ 有断言失败")
    return FAILED


def write_conf(path, mode, guard):
    with open(path, "w", encoding="utf-8") as f:
        f.write("# test\nmode=%s\nbody_guard=%s\n" % (mode, guard))


if __name__ == "__main__":
    sys.exit(main())
