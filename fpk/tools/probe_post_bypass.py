#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""POST 无来源页绕过 —— 独立复核脚本（作者版，与用户上报的脚本无关）。

目的：验证「POST /preview/api/localFile 不带 Referer 时，闸门是否放行」。
方法：import 闸门模块，打桩 can_read / current_mode / headers，直接调 Handler._decide。

★ 关键：本脚本必须**忠实还原 nginx 实际传给闸门的头**，不能想当然。
  看 nginx.conf 的 `location = /__acl`：
      proxy_set_header X-Acl-Path $arg_path;      # ← query 串里的 path 参数
      proxy_set_header X-Acl-File $arg_filePath;  # ← query 串里的 filePath 参数
      proxy_set_header X-Acl-Uri  $request_uri;
      proxy_set_header X-Acl-Ref  $http_referer;
  也就是说 X-Acl-* 这些头是 **nginx 从 query 串生成**的，
  **不是**攻击者能自己塞的任意头（客户端同名头会被 proxy_set_header 覆盖）。

用法：
  "C:/Users/yang/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe" \
      fpk/tools/probe_post_bypass.py
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.normpath(os.path.join(HERE, "..", "basemetas-fileview", "app", "docker", "fv-acl-gate.py"))

PRIVATE = "/vol2/1000/私密/合同.docx"      # 不可读（不属于 uid=1001）
PUBLIC = "/vol1/1001/我的/公开.docx"        # 可读


def load():
    spec = importlib.util.spec_from_file_location("fv_acl_gate", GATE)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class Hdrs:
    def __init__(self, d):
        self._d = {k.lower(): v for k, v in d.items()}

    def get(self, k, default=""):
        return self._d.get(k.lower(), default)


class Gate:
    """只提供 _decide 依赖的接口。"""

    def __init__(self, mod):
        self._mod = mod
        self.SKIP_EXT = mod.Handler.SKIP_EXT

    @staticmethod
    def _decode(v):
        import urllib.parse
        return urllib.parse.unquote(v) if v and "%" in v else v

    def _from_qs(self, qs):
        return self._mod.Handler._from_qs(qs)

    def _decide(self, **kw):
        self.headers = Hdrs(kw.get("headers", {}))
        return self._mod.Handler._decide(self, kw["uid"], kw["uri"], kw.get("ref", ""))


def build_headers_from_nginx(uri, ref):
    """模拟 nginx `location = /__acl`：从 uri 的 query 串生成 X-Acl-Path / X-Acl-File。

    ★ 这是复现的关键 —— 用户的脚本若直接把 X-Acl-File 当成「客户端可任意设置的请求头」，
       结论就会失真。这里严格按 nginx 配置的 $arg_* 语义来。
    """
    import urllib.parse
    qs = uri.split("?", 1)[1] if "?" in uri else ""
    p = urllib.parse.parse_qs(qs, keep_blank_values=True)
    return {
        "X-Acl-Uid": "1001",
        "X-Acl-Path": (p.get("path") or [""])[0],
        "X-Acl-File": (p.get("filePath") or [""])[0],
        "X-Acl-Uri": uri,
        "X-Acl-Ref": ref,
    }


def main():
    mod = load()

    # uid=1001 只能读 PUBLIC
    mod.can_read = lambda uid, path: path == PUBLIC
    mod.current_mode = lambda: "enforce"
    g = Gate(mod)

    cases = [
        # 说明, uid, uri(到 nginx 的原始请求), referer, 期望 allow
        ("A) 对照：GET 带私有路径 → 应拦截",
         "1001", "/app/basemetas-fileview/preview/view?path=" + PRIVATE, "", False),

        ("B) POST /preview/api/localFile，无 Referer（路径在 body）",
         "1001", "/app/basemetas-fileview/preview/api/localFile", "", None),

        ("C) POST + Referer 是普通页（不带 /vol）",
         "1001", "/app/basemetas-fileview/preview/api/localFile",
         "https://nas.local/app/basemetas-fileview/preview/welcome", None),

        ("D) POST + Referer 是正确预览页（正常浏览器流程）",
         "1001", "/app/basemetas-fileview/preview/api/localFile",
         "https://nas.local/app/basemetas-fileview/preview/view?path=" + PRIVATE, False),

        # ★ 复核用户的 E 用例：攻击者自己塞 X-Acl-File 头
        #    在 nginx 真实配置下，X-Acl-File 由 $arg_filePath 生成 → 客户端头会被覆盖成空。
        #    所以这条在真实链路上**不是「依赖头」**，而是**根本无效**。
        ("E) POST + 攻击者自带 X-Acl-File 头（真实 nginx 下会被 $arg_filePath 覆盖为空）",
         "1001", "/app/basemetas-fileview/preview/api/localFile", "",
         None),   # 只看放行与否；注意 headers 由 build_headers_from_nginx 生成，忽略客户端塞的头
    ]

    print("=" * 78)
    print("POST 无来源页绕过 —— 判定结果复核")
    print("=" * 78)
    fails = 0
    for desc, uid, uri, ref, want in cases:
        h = build_headers_from_nginx(uri, ref)
        allow, why, path = g._decide(uid=uid, uri=uri, ref=ref, headers=h)
        verdict = "放行 ⚠️" if allow else "拦截 ✅"
        flag = ""
        if want is not None and allow != want:
            flag = "   ❌ 与期望不符"
            fails += 1
        print("\n%s%s" % (desc, flag))
        print("   uri      = %s" % uri)
        print("   referer  = %s" % (ref or "(无)"))
        print("   → %s | path=%s | %s" % (verdict, path, why))

    print("\n" + "=" * 78)
    print("补充：用户脚本把 X-Acl-File 当作「攻击者可设置的请求头」——验证这一假设")
    print("=" * 78)
    # 直接塞一个 X-Acl-File 头，看 _decide 会不会因此去判定它
    h = {"X-Acl-Uid": "1001", "X-Acl-File": PRIVATE}
    allow, why, path = g._decide(uid="1001",
                                 uri="/app/basemetas-fileview/preview/api/localFile",
                                 ref="", headers=h)
    print("  若闸门真收到 X-Acl-File=%s：" % PRIVATE)
    print("   → %s | path=%s | %s" % ("放行" if allow else "拦截", path, why))
    print("  （若这里拦截，说明该头**确实能**改变判定；")
    print("    但在真实链路上 nginx 用 $arg_filePath 覆盖它，攻击者塞不进这个值。）")

    return fails


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
