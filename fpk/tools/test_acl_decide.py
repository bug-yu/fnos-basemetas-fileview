#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fv-acl-gate.py 判定逻辑的离线单测（不碰真机）。

为什么要它：闸门是「只在确定不可读时拒绝，其余一律放行」的设计，最危险的方向是
**误拦**（挡掉合法访问），次危险是**漏拦**（旁路）。这两件事光靠肉眼看代码不够，
必须把判定矩阵钉住。

做法：import 闸门模块，把 can_read / current_mode / headers 全部打桩，直接调
Handler._decide，断言每条用例的「放行/拒绝 + 判定用的路径」。

用法（Windows 托管 Python）：
    "C:/Users/yang/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe" \
        fpk/tools/test_acl_decide.py

放行标志：L = 放行（allow=True），B = 拦截（allow=False）。
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.normpath(os.path.join(HERE, "..", "basemetas-fileview", "app", "docker", "fv-acl-gate.py"))


def load_module():
    """按路径加载（文件名带连字符，不能普通 import）。"""
    spec = importlib.util.spec_from_file_location("fv_acl_gate", GATE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeHandler:
    """只提供 _decide 需要的东西：_decode / _from_qs / headers。"""

    def __init__(self, mod, headers):
        self._mod = mod
        self.headers = headers
        self.SKIP_EXT = mod.Handler.SKIP_EXT

    _decode = staticmethod(lambda v: __import__("urllib.parse", fromlist=["parse"]).parse.unquote(v) if v and "%" in v else v)

    def _from_qs(self, qs):
        return self._mod.Handler._from_qs(qs)

    def _decide(self, uid, uri, ref):
        return self._mod.Handler._decide(self, uid, uri, ref)


class FakeHeaders:
    def __init__(self, d):
        self._d = {k.lower(): v for k, v in d.items()}

    def get(self, k, default=""):
        return self._d.get(k.lower(), default)


def run():
    mod = load_module()

    # 打桩：can_read 只认「可读表」里的路径；current_mode 固定 enforce
    readable = {"/vol1/ok.docx"}

    def fake_can_read(uid, path):
        if path in readable:
            return True
        return False

    mod.can_read = fake_can_read
    mod.current_mode = lambda: "enforce"

    cases = [
        # (说明, uid, uri, headers, ref, 期望 allow, 期望判定路径)
        ("正确的路径预览请求 → 可读放行",
         "1000", "/preview/view?path=/vol1/ok.docx", {}, "", True, "/vol1/ok.docx"),

        ("正确的路径预览请求 → 不可读拦截（核心保护）",
         "1000", "/preview/view?path=/vol2/secret.docx", {}, "", False, "/vol2/secret.docx"),

        ("普通静态资源（不带路径）→ 放行",
         "1000", "/preview/static/app.css", {}, "", True, None),

        ("★ 旁路尝试：.css 后缀但带 /vol 路径 → 必须落到判定，不可读则拦截",
         "1000", "/preview/api/file.css?filePath=/vol2/secret.docx", {}, "", False, "/vol2/secret.docx"),

        ("★ 旁路尝试：.css 后缀 + /vol 路径，但该文件可读 → 放行（不误拦）",
         "1000", "/preview/api/file.css?filePath=/vol1/ok.docx", {}, "", True, "/vol1/ok.docx"),

        ("★ 旁路尝试：.png 后缀 + 路径头带 /vol → 必须判定",
         "1000", "/preview/api/file.png", {"X-Acl-Path": "/vol2/secret.docx"}, "", False, "/vol2/secret.docx"),

        ("转换产物路径（非 /vol）+ 来源页是 /vol 不可读 → 拦截",
         "1000", "/preview/api/file?filePath=/opt/fileview/data/preview/x.pdf", {},
         "/preview/view?path=/vol2/secret.docx", False, "/vol2/secret.docx"),

        ("转换产物路径 + 来源页 /vol 可读 → 放行",
         "1000", "/preview/api/file?filePath=/opt/fileview/data/preview/x.pdf", {},
         "/preview/view?path=/vol1/ok.docx", True, "/vol1/ok.docx"),

        ("非 /vol 路径且来源页也没有 → 放行（网络 url= 等）",
         "1000", "/preview/view?url=http://10.0.0.1/a.png", {}, "", True, None),

        ("缺 uid → 放行（默认安全方向：不因取不到身份而拦人）",
         "", "/preview/view?path=/vol2/secret.docx", {}, "", True, "/vol2/secret.docx"),

        ("uid 非数字 → 放行",
         "abc", "/preview/view?path=/vol2/secret.docx", {}, "", True, "/vol2/secret.docx"),

        ("路径经 URL 编码（%2F）→ 解码后仍判定",
         "1000", "/preview/view?path=%2Fvol2%2Fsecret.docx", {}, "", False, "/vol2/secret.docx"),
    ]

    failed = 0
    for desc, uid, uri, hdrs, ref, want_allow, want_path in cases:
        h = FakeHandler(mod, FakeHeaders(hdrs))
        allow, why, path = h._decide(uid, uri, ref)
        ok = (allow == want_allow) and (path == want_path)
        mark = "OK " if ok else "FAIL"
        if not ok:
            failed += 1
        print("  %s  %s" % (mark, desc))
        print("        -> %s | path=%s | %s" % ("放行" if allow else "拦截", path, why))
        if not ok:
            print("        ❌ 期望 allow=%s path=%s" % (want_allow, want_path))

    print()
    if failed == 0:
        print("✅ 闸门判定矩阵全部通过（%d 条）" % len(cases))
    else:
        print("❌ 有 %d 条判定不符" % failed)
    return failed


if __name__ == "__main__":
    sys.exit(run())
