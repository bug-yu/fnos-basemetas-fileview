"""仿真 nginx map 的求值逻辑，验证 nginx.conf 里「外部地址推导」在各种访问场景下是否正确。

nginx map 求值顺序：
  1. 精确字符串匹配（默认大小写不敏感）
  2. 按定义顺序逐个尝试正则；有捕获组时取捕获组，没有则取该条目配置的值
  3. 都不中则用 default

2026-09-26 新增：Referer 的「同源检查」。
  背景（实测日志抓到的真 bug）：飞牛「自定义 URL」会用外部地址打开应用，
  而这次跳转的 Referer 可能是内网页面，导致主机名与端口来自不同来源，
  拼出 nas.example.com:5666 这种不存在的地址。
  修法：Referer 的端口只在 Referer 主机名 == 本请求主机名时才采信。
"""

import re


class Entry:
    def __init__(self, kind, value, pattern=None, group=None, key=None):
        self.kind = kind          # default | exact | regex
        self.value = value        # 字符串，或 "$变量" 形式
        self.pattern = pattern
        self.group = group
        self.key = key


def d(value):
    return Entry("default", value)


def exact(key, value):
    return Entry("exact", value, key=key)


def rx(pattern, value, group=None):
    return Entry("regex", value, pattern=re.compile(pattern), group=group)


def nginx_map(entries, value, ctx):
    for e in entries:
        if e.kind == "exact" and value.lower() == e.key.lower():
            return resolve(e.value, ctx)
    for e in entries:
        if e.kind != "regex":
            continue
        m = e.pattern.search(value)
        if not m:
            continue
        if e.group is not None:
            return m.group(e.group)
        return resolve(e.value, ctx)
    for e in entries:
        if e.kind == "default":
            return resolve(e.value, ctx)
    return ""


def resolve(value, ctx):
    out = value
    for _ in range(6):
        new = re.sub(r"\$[a-z_]+", lambda mm: ctx.get(mm.group(0), ""), out)
        if new == out:
            break
        out = new
    return out


# ---------------- 与 nginx.conf 一一对应的 map 定义 ----------------

MAP_XH_HOSTNAME = [
    d("$http_x_forwarded_host"),
    exact("", "$host"),
    rx(r"^([^:]+):\d+$", None, group=1),
]

MAP_PORT_FROM_XH = [
    d(""),
    rx(r"^[^:]+:(\d+)$", None, group=1),
]

MAP_PORT_FROM_HOST = [
    d(""),
    rx(r"^[^:]+:(\d+)$", None, group=1),
]

# --- Referer 的同源检查 ---
MAP_PORT_FROM_REF_RAW = [
    d(""),
    rx(r"^https?://[^/]+:(\d+)/", None, group=1),
]

MAP_REF_HOST = [
    d(""),
    rx(r"^https?://([^/:]+)", None, group=1),
]

# 键： "$ref_host,$ext_hostname"   —— 反引用 \1 判断两段是否相同
MAP_REFERER_SAME_HOST = [
    d("0"),
    rx(r"^(.+),\1$", "1"),
]

# 键： "$port_from_ref_raw,$referer_same_host"
MAP_PORT_FROM_REF = [
    d(""),
    rx(r"^(\d+),1$", "$port_from_ref_raw"),
]

MAP_EXT_PORT = [
    d(""),                                  # 拿不到端口就不加端口
    rx(r"^\d+:", "$port_from_xh"),
    rx(r"^:\d+:", "$port_from_host"),
    rx(r"^::\d+$", "$port_from_ref"),
]

MAP_EXT_AUTHORITY = [
    d("$ext_hostname:$ext_port"),
    exact("", "$ext_hostname"),
]

MAP_PROTO_FROM_REF = [
    d("http"),
    rx(r"^https://", "https"),
]

MAP_EXT_PROTO = [
    d("$http_x_forwarded_proto"),
    exact("", "$proto_from_ref"),
]


def evaluate(case):
    host = case["host"]
    ctx = {
        "$http_host": host,
        "$http_referer": case["referer"],
        "$http_x_forwarded_host": case["xh_host"],
        "$http_x_forwarded_proto": case["xh_proto"],
        "$host": host.split(":")[0] if host else "nas",
    }
    ctx["$ext_hostname"] = nginx_map(MAP_XH_HOSTNAME, case["xh_host"], ctx)
    ctx["$port_from_xh"] = nginx_map(MAP_PORT_FROM_XH, case["xh_host"], ctx)
    ctx["$port_from_host"] = nginx_map(MAP_PORT_FROM_HOST, host, ctx)

    ctx["$ref_host"] = nginx_map(MAP_REF_HOST, case["referer"], ctx)
    ctx["$port_from_ref_raw"] = nginx_map(MAP_PORT_FROM_REF_RAW, case["referer"], ctx)
    ctx["$referer_same_host"] = nginx_map(
        MAP_REFERER_SAME_HOST, f'{ctx["$ref_host"]},{ctx["$ext_hostname"]}', ctx
    )
    ctx["$port_from_ref"] = nginx_map(
        MAP_PORT_FROM_REF,
        f'{ctx["$port_from_ref_raw"]},{ctx["$referer_same_host"]}',
        ctx,
    )

    ctx["$ext_port"] = nginx_map(
        MAP_EXT_PORT,
        f'{ctx["$port_from_xh"]}:{ctx["$port_from_host"]}:{ctx["$port_from_ref"]}',
        ctx,
    )
    ctx["$ext_authority"] = nginx_map(MAP_EXT_AUTHORITY, ctx["$ext_port"], ctx)
    ctx["$proto_from_ref"] = nginx_map(MAP_PROTO_FROM_REF, case["referer"], ctx)
    ctx["$ext_proto"] = nginx_map(MAP_EXT_PROTO, case["xh_proto"], ctx)
    return ctx["$ext_authority"], ctx["$ext_proto"]


REF_LAN = "http://192.168.1.10:5666/app/basemetas-fileview/preview/view?path=/x.pdf"
REF_WAN = "https://nas.example.com:8443/app/basemetas-fileview/preview/view?path=/x.pdf"
REF_LAN_8000 = "http://192.168.1.10:8000/app/basemetas-fileview/preview/view?path=/x.pdf"
REF_STD = "https://nas.example.com/app/basemetas-fileview/preview/view?path=/x.pdf"

CASES = [
    dict(name="① 局域网 5666，网关 Host 带端口",
         host="192.168.1.10:5666", referer=REF_LAN, xh_host="", xh_proto="",
         want=("192.168.1.10:5666", "http")),
    dict(name="② 局域网 5666，网关 Host 不带端口（同源 Referer 补）",
         host="192.168.1.10", referer=REF_LAN, xh_host="192.168.1.10", xh_proto="http",
         want=("192.168.1.10:5666", "http")),
    dict(name="③ 公网 8443（同源 Referer 补）",
         host="nas.example.com", referer=REF_WAN, xh_host="nas.example.com", xh_proto="https",
         want=("nas.example.com:8443", "https")),
    dict(name="④ 改成 8000 端口后（自动跟随，无需改配置）",
         host="192.168.1.10", referer=REF_LAN_8000, xh_host="192.168.1.10", xh_proto="http",
         want=("192.168.1.10:8000", "http")),
    dict(name="⑤ 用标准端口访问（地址栏不带端口）→ 不加端口，不能乱猜",
         host="nas.example.com", referer=REF_STD, xh_host="nas.example.com", xh_proto="https",
         want=("nas.example.com", "https")),
    dict(name="⑥ 首屏导航无 Referer、Host 无端口 → 不加端口（该次 baseUrl 不用来取文件）",
         host="192.168.1.10", referer="", xh_host="192.168.1.10", xh_proto="http",
         want=("192.168.1.10", "http")),
    dict(name="⑦ 网关透传的 X-Forwarded-Host 自带端口",
         host="192.168.1.10", referer="", xh_host="192.168.1.10:5666", xh_proto="http",
         want=("192.168.1.10:5666", "http")),
    dict(name="⑧ 公网 https，网关未透传 proto（由 Referer 判 https）",
         host="nas.example.com", referer=REF_WAN, xh_host="nas.example.com", xh_proto="",
         want=("nas.example.com:8443", "https")),
    dict(name="⑨ 公网 8443，Host 也带端口（Host 优先）",
         host="nas.example.com:8443", referer=REF_WAN, xh_host="nas.example.com", xh_proto="https",
         want=("nas.example.com:8443", "https")),
    # ↓↓↓ 本次新增：修复实测日志暴露的「主机名与端口来自不同来源」问题
    dict(name="⑩【实测复现】跨源 Referer：外网域名请求 + 内网页 Referer → 不得采信内网端口",
         host="nas.example.com", referer=REF_LAN, xh_host="nas.example.com", xh_proto="https",
         want=("nas.example.com", "https")),
    dict(name="⑪【实测复现】反向情形：内网 IP 请求 + 外网页 Referer → 不得采信外网端口",
         host="192.168.1.10", referer=REF_WAN, xh_host="192.168.1.10", xh_proto="http",
         want=("192.168.1.10", "http")),
    dict(name="⑫ 同源判定要对齐主机名（不是 IP）：同源 8443 仍必须采信",
         host="nas.example.com", referer=REF_WAN, xh_host="nas.example.com:8443", xh_proto="https",
         want=("nas.example.com:8443", "https")),
]

print("=" * 84)
print("nginx map 求值仿真 —— Host 头取值（$ext_authority）与协议（$ext_proto）推导")
print("=" * 84)
fail = 0
for case in CASES:
    got = evaluate(case)
    ok = got == case["want"]
    if not ok:
        fail += 1
    print(f"\n{'OK  ' if ok else 'FAIL'} {case['name']}")
    print(f"     输入 Host={case['host']!r}  Referer={case['referer'][:46]!r}")
    print(f"          X-Forwarded-Host={case['xh_host']!r}  X-Forwarded-Proto={case['xh_proto']!r}")
    print(f"     →  Host 头 = {got[0]!r}   X-Forwarded-Proto = {got[1]!r}")
    if not ok:
        print(f"     期望 {case['want'][0]!r} / {case['want'][1]!r}")

print()
print("=" * 84)
print(f"失败 {fail} / {len(CASES)}")
