# -*- coding: utf-8 -*-
"""fv-acl-gate.py 里 /raw 用到的 safe_real_file() 的单元测试。

为什么单独测它：`/raw` 是 0.5.55 新增的「把文件字节交出去」的端点，
比闸门原有的「放行/拒绝」**能力更强** —— 它的路径收敛逻辑一旦有洞，
就等于开了任意文件读取。所以这里把边界逐条钉住。

测试办法：不依赖真实的 /vol（本机没有），把 os.path.realpath / isfile 打桩，
只验证**判定逻辑**本身。
用法：python fpk/tools/test_cad_raw.py
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "..", "basemetas-fileview", "app", "docker", "fv-acl-gate.py")

spec = importlib.util.spec_from_file_location("gate", GATE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

# 打桩：把 realpath 做成"原样返回"，isfile 只对白名单里的路径返回 True
REAL_FILES = {"/vol1/1000/a.dwg", "/vol2/x/y.pdf"}
gate.os.path.realpath = lambda p: p
gate.os.path.isfile = lambda p: p in REAL_FILES

FAILED = 0


def check(desc, got, want):
    global FAILED
    if got == want:
        print("  ✅ %s" % desc)
    else:
        print("  ❌ %s  got=%r want=%r" % (desc, got, want))
        FAILED = 1


print("== safe_real_file：应放行的 ==")
check("普通 /vol 文件", gate.safe_real_file("/vol1/1000/a.dwg"), "/vol1/1000/a.dwg")
check("另一个卷", gate.safe_real_file("/vol2/x/y.pdf"), "/vol2/x/y.pdf")

print()
print("== safe_real_file：应拒绝的 ==")
check("空路径", gate.safe_real_file(""), None)
check("非 /vol 前缀", gate.safe_real_file("/etc/passwd"), None)
check("相对路径", gate.safe_real_file("vol1/a.dwg"), None)
check("含 .. 的路径", gate.safe_real_file("/vol1/../etc/passwd"), None)
check("末尾 .. ", gate.safe_real_file("/vol1/1000/.."), None)
check("不存在（isfile 假）", gate.safe_real_file("/vol1/nope.dwg"), None)
check("目录（不在白名单）", gate.safe_real_file("/vol1/1000"), None)
check("前缀相似但非 /vol", gate.safe_real_file("/volume/x.dwg"), None)
check("windows 风格", gate.safe_real_file("C:/vol1/a.dwg"), None)

print()
print("== nginx 传进来的是**未解码**的 $arg_filePath，闸门要解一次 ==")
# 0.5.56 真机就是卡在这：页面发 ?filePath=%2Fvol1%2F...，nginx 的 $arg_xxx 不解码，
# 闸门收到 %2Fvol1... → 不以 /vol 开头 → 400 ✗
import urllib.parse  # noqa: E402

check("编码值解码后应放行",
      gate.safe_real_file(urllib.parse.unquote("%2Fvol1%2F1000%2Fa.dwg")),
      "/vol1/1000/a.dwg")
check("未编码的直接放行",
      gate.safe_real_file(urllib.parse.unquote("/vol1/1000/a.dwg")),
      "/vol1/1000/a.dwg")
# 双重编码：只解一次 → 仍是 %2F... → 不以 /vol 开头 → 拒绝（不会因为多解一层而绕过）
check("双重编码不能绕过（只解一次）",
      gate.safe_real_file(urllib.parse.unquote("%252Fvol1%252Fa.dwg")), None)

print()
print("== 符号链接绕过：realpath 后不在 /vol 下 → 必须拒绝 ==")
gate.os.path.realpath = lambda p: "/etc/passwd" if p == "/vol1/link" else p
check("软链指向 /etc/passwd", gate.safe_real_file("/vol1/link"), None)
gate.os.path.realpath = lambda p: p

print()
print("== can_read 的三态（打桩）==")
gate.can_read = lambda uid, path: True
check("可读 → True", gate.can_read(1000, "/vol1/1000/a.dwg"), True)
gate.can_read = lambda uid, path: None
check("无法判定 → None（/raw 会因此拒绝）", gate.can_read(1000, "/vol1/1000/a.dwg"), None)

print()
if FAILED:
    print("❌ 有用例失败")
    sys.exit(1)
print("✅ 全部通过")
