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
import hashlib
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
    # fileId 系接口的档位（出厂默认 log，可切 enforce）
    fid_state = {"v": "log"}
    mod.current_fileid_guard = lambda: fid_state["v"]

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
    print("  —— fileId 系接口（0.5.34 新增校验）——")
    # fileId = "preview_" + md5(原始绝对路径)[:16]（已用真机数据验证），
    # 所以知道路径就能算出来；而这类请求里没有路径参数 → 闸门判不到 →
    # 引擎在 path 缺省时会用缓存里的**原始路径**把文件吐出来 → 绕过 ACL。
    # 对策：要求请求自带 filePath；fileid_guard=enforce 时拒绝「不带」的请求。
    ok_path = "/vol1/ok.docx"
    sec_path = "/vol2/secret.docx"
    ok_fid = "preview_" + hashlib.md5(ok_path.encode()).hexdigest()[:16]
    sec_fid = "preview_" + hashlib.md5(sec_path.encode()).hexdigest()[:16]

    # 捕获闸门日志：用来断言「md5 一致时不应产生『观察』记录」
    # （曾经踩过：拿带 `preview_` 前缀的 fileId 去比不带前缀的 md5 → 永远不一致）
    logs = []
    mod.log = lambda m: logs.append(m)

    fid_cases = [
        # (说明, uid, uri, headers, ref, guard, 期望 allow, 期望判定路径, 期望出现「观察」记录)
        ("[log] 不带 filePath → 放行并记录（出厂默认档，不误伤）",
         "1000", "/preview/api/files/%s" % sec_fid, {}, "", "log", True, None, False),

        ("[log] 带一致的 filePath + 可读 → 放行，且**不应**报 md5 不一致",
         "1000", "/preview/api/files/%s?filePath=%s" % (ok_fid, ok_path),
         {}, "", "log", True, ok_path, False),

        ("[log] 带一致的 filePath + 不可读 → 仍拦截（正常保护不受影响）",
         "1000", "/preview/api/files/%s?filePath=%s" % (sec_fid, sec_path),
         {}, "", "log", False, sec_path, False),

        ("★ [log] 带**自己的** filePath + **别人的** fileId → 按自己的路径判 → 放行，并报不一致",
         "1000", "/preview/api/files/%s?filePath=%s" % (sec_fid, ok_path),
         {}, "", "log", True, ok_path, True),

        ("★ [enforce] 不带 filePath → 拦截（堵住绕过）",
         "1000", "/preview/api/files/%s" % sec_fid, {}, "", "enforce", False, None, False),

        ("[enforce] 带一致的 filePath + 可读 → 放行（不误伤正常流程）",
         "1000", "/preview/api/files/%s?filePath=%s" % (ok_fid, ok_path),
         {}, "", "enforce", True, ok_path, False),

        ("★ [enforce] /page/N 不带 filePath → 拦截",
         "1000", "/preview/api/files/%s/page/2" % sec_fid, {}, "", "enforce", False, None, False),

        ("★ [enforce] /pages 不带 filePath → 拦截",
         "1000", "/preview/api/files/%s/pages" % sec_fid, {}, "", "enforce", False, None, False),

        ("[enforce] /page/N 带一致的 filePath → 照常判定（不可读则拦）",
         "1000", "/preview/api/files/%s/page/2?filePath=%s" % (sec_fid, sec_path),
         {}, "", "enforce", False, sec_path, False),

        ("其它接口不受影响：/preview/view 不带路径 → 照旧放行",
         "1000", "/preview/view", {}, "", "enforce", True, None, False),
    ]

    for desc, uid, uri, hdrs, ref, guard, want_allow, want_path, want_obs in fid_cases:
        fid_state["v"] = guard
        logs.clear()
        h = FakeHandler(mod, FakeHeaders(hdrs))
        allow, why, path = h._decide(uid, uri, ref)
        got_obs = any("【观察】" in m for m in logs)
        ok = (allow == want_allow) and (path == want_path) and (got_obs == want_obs)
        mark = "OK " if ok else "FAIL"
        if not ok:
            failed += 1
        print("  %s  %s" % (mark, desc))
        print("        -> %s | path=%s | %s" % ("放行" if allow else "拦截", path, why))
        if not ok:
            print("        ❌ 期望 allow=%s path=%s 观察记录=%s（实际 %s）"
                  % (want_allow, want_path, want_obs, got_obs))

    print()
    total = len(cases) + len(fid_cases)
    if failed == 0:
        print("✅ 闸门判定矩阵全部通过（%d 条）" % total)
    else:
        print("❌ 有 %d 条判定不符（共 %d 条）" % (failed, total))
    return failed


if __name__ == "__main__":
    sys.exit(run())
