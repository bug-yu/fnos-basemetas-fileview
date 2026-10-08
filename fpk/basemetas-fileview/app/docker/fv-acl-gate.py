#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FileView 预览 —— 逐用户文件权限闸门
=====================================

问题
----
FileView 引擎容器以 root 读文件，绕过了飞牛的用户 ACL，于是「凡能登录飞牛的用户，
打开 /app/basemetas-fileview/... 都能预览已挂载卷里的文件」。

做法
----
飞牛统一网关会把当前登录用户放进请求头：

    X-Trim-Userid / X-Trim-Username / X-Trim-Isadmin

nginx 用 auth_request 把每个请求交给本服务，本服务**以那个用户的身份**去问一句
「这个文件我能不能读」（飞牛自 v1.2.0 起存储空间用 Windows ACL），不可读就 403。

⚠️ 不能简单地 `docker exec -u <uid> … test -r`：`docker exec -u` 不会设置用户的
附加组，而团队文件是**按用户组授权**的，那种情况会被误判成「不可读」—— 误拦会挡掉
合法访问，是危险方向。所以这里 fork 子进程后按 /etc/group 依次 setgroups → setgid →
setuid 再判定，完整还原该用户的权限上下文。
因此本服务需要以 root 运行，并挂载宿主机的 /etc/passwd、/etc/group（只读）
以及与引擎相同的只读存储卷。

两种工作模式
------------
1. `/check` —— 供 nginx `auth_request` 调用（**只看状态码**）。
   覆盖绝大多数请求：路径在 query 串里（`?path=` / `?filePath=`），
   nginx 用 `$arg_*` 就能取到，子请求里判得清清楚楚。

2. `/guard` —— 供 nginx **整体代理**调用（**读 body → 判 → 转发**）。
   只用于「路径只在请求体里」的接口（清单见 BODY_PATH_FIELDS）。
   原因：`auth_request` 在 ACCESS 阶段执行，**请求体还没被读**，
   鉴权子请求物理上看不到 body；这类接口若只靠来源页（Referer）判定，
   会被「合法 Referer 掩护非法 body」绕过（真机已复现：无 Referer=200、带合法 Referer=200）。
   走 /guard 时由本服务读 body 取路径、判完**自己转发给引擎** ——
   判定的路径与引擎实际读的路径必然一致。

安全默认
--------
**只在「确定不可读」时拒绝，其余一律放行**（缺 uid、解析不到路径、查不到用户、
判定异常 → 放行并记日志）。这样即使身份头没传进来、或判定逻辑有问题，也只是
「没保护」，不会把应用弄坏。

拦截开关（`${TRIM_PKGVAR}/acl.conf`，**每次请求现读，改完立即生效**）：
    mode=enforce          # 总体：enforce 拦截 / log 只记录（默认 enforce）
    body_guard=enforce    # 只管 /guard 那一层：enforce 拒绝 / log 只记录仍转发（默认 enforce）
    fileid_guard=log      # 只管 fileId 系接口：enforce 拒绝「不带 filePath」的请求 / log 只记录（默认 log）
拆成三个是为了能**各自单独回退**，互不影响：
  · 某个 body-path 接口的正常流程被误拦 → 把 body_guard 改成 log；
  · fileId 校验误伤 → 把 fileid_guard 改成 log（**它出厂就是 log**，见下）。
（应用只在文件不存在时写入默认值；已存在的值不会被覆盖，所以手工改的能留住。）

⚠️ 为什么 fileid_guard **默认是 log 而不是 enforce**：
   fileId 系接口（`/preview/api/files/<fileId>`）的 fileId 是**原始路径的 md5 前 16 位**
   —— 知道路径就能算出来，不具备保密性；而这类请求里没有路径参数、闸门天然判不到，
   引擎在 path 缺省时会用缓存里的原始路径把文件吐出来，构成绕过。
   对策是「要求请求自带 filePath」，但**合法流程里 `/page/{n}` 与 `/pages` 没有日志样本**，
   无法确认它们是否都带 filePath。盲切 enforce 有误伤风险（0.5.31/0.5.32 两次都是
   「本地自检全绿、真机才暴露」）。所以先 log 跑一遍全部预览类型，确认没有合法请求被记，
   再改成 enforce。

用法
----
    python3 fv-acl-gate.py                      # 以 HTTP 服务运行（容器里用）
    python3 fv-acl-gate.py --test <uid> <path>  # 命令行自测（需 root），直接打印结论
    python3 fv-acl-gate.py --check <uid> <path> # 内部子进程模式，只用退出码：0 可读 / 1 不可读 / 3 无法判定
"""

import hashlib
import json
import os
import re
import sys
import time
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE_FILE = os.environ.get("FV_ACL_MODE_FILE", "/acl-conf/acl.conf")
PORT = int(os.environ.get("FV_ACL_PORT", "8080"))
SELF = os.path.abspath(__file__)
DEFAULT_MODE = "enforce"
DEFAULT_BODY_GUARD = "enforce"
# fileId 系接口的校验档位：**默认 log（只记录不拦）**，理由见 FILEID_RE 的注释。
DEFAULT_FILEID_GUARD = "log"

# fileId 系接口：/preview/api/files/<fileId>[/page/N | /pages]
FILEID_RE = re.compile(r"/preview/api/files/([^/?#]+)")

# 引擎地址（与网关容器同一个 compose 网络，服务名 fileview）
ENGINE_BASE = os.environ.get("FV_ENGINE_BASE", "http://fileview:80").rstrip("/")

# 网关前缀：转发给引擎前要剥掉
GATEWAY_PREFIX = "/app/basemetas-fileview"

# ---------------------------------------------------------------------------
# 路径只在**请求体**里的接口 → body 里承载文件路径的字段名
# ---------------------------------------------------------------------------
# 背景：nginx 的 auth_request 在 ACCESS 阶段执行，**请求体还没被读**，
# 所以鉴权子请求物理上看不到 body（见 nginx.conf 的 location = /__acl）。
# 对这几个接口，只靠来源页（Referer）判定会被绕过：
#   攻击者先打开一个自己有权读的文件拿到合法 Referer，再 POST 别人的路径 ——
#   闸门拿合法 Referer 判定并放行，body 里的非法路径根本没被看过。
#   （真机已复现：无 Referer = 200，带合法 Referer = 200。）
#
# 因此这几个接口改由 nginx **整体代理**到本服务的 /guard：
#   本服务读 body → 取出真实路径 → 按 uid 判 ACL → 通过后**由本服务转发给引擎**。
# 于是「判定的路径」与「引擎实际读的路径」必然是同一个值，没有空隙可钻。
#
# ⚠️ 这里的清单必须与 nginx.conf 里那条 regex location 的接口列表保持一致，
#    selfcheck.sh 有断言盯着这一点。
BODY_PATH_FIELDS = {
    "/preview/api/localFile":       "srcRelativePath",
    "/preview/api/password/unlock": "originalFilePath",
    "/convert/api/srvFile":         "filePath",          # nginx 侧已直接 403，这里只作兜底
}

# 转发给引擎时要带上的客户端头（白名单：不把 X-Acl-* 之类内部头透出去）。
#
# ⚠️⚠️ **必须带 Host 与 X-Forwarded-***，否则引擎会拼出浏览器打不开的绝对地址 ——
#   引擎的 RequestAwareBaseUrlProvider 是**按请求头**推导 baseUrl 的：
#     有正确的 Host + X-Forwarded-Proto + X-Forwarded-Prefix
#       → https://<域名>:<端口>/app/basemetas-fileview   ✅
#     只带 Host: fileview:80（urllib 默认按目标 URL 生成）
#       → http://fileview                                ❌ 前端拿这个地址去取文件必然失败
#   典型症状：**PDF 预览失败**（PDF 渲染器直接用 localFile 返回的绝对 URL 取文件），
#   而 ofd / xlsx 等用相对路径的渲染器看起来正常 —— 所以只测后者会漏掉。
#   （2026-10-06 真实踩过：0.5.32 装完 PDF 打不开，根因就是这里丢了 Host。）
FORWARD_HEADERS = (
    "host", "content-type", "accept", "cookie", "referer", "user-agent", "origin",
    "x-forwarded-proto", "x-forwarded-prefix", "x-forwarded-host", "x-forwarded-port",
    "x-forwarded-for", "x-real-ip",
)


def log(msg):
    sys.stdout.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# 用户查表：拿到主组 + 附加组
# ---------------------------------------------------------------------------
def lookup_user(uid):
    """返回 (username, gid, [附加组 gid…])；查不到返回 None。

    容器里挂的是宿主机的 /etc/passwd、/etc/group，所以这里看到的就是宿主真实的用户。
    """
    name = None
    gid = None
    try:
        with open("/etc/passwd", encoding="utf-8", errors="replace") as f:
            for line in f:
                p = line.rstrip("\n").split(":")
                if len(p) >= 4 and p[2].isdigit() and int(p[2]) == uid:
                    name = p[0]
                    gid = int(p[3]) if p[3].isdigit() else 0
                    break
    except OSError:
        return None
    if name is None:
        return None

    groups = []
    try:
        with open("/etc/group", encoding="utf-8", errors="replace") as f:
            for line in f:
                p = line.rstrip("\n").split(":")
                if len(p) >= 4 and p[3] and name in p[3].split(","):
                    if p[2].isdigit():
                        groups.append(int(p[2]))
    except OSError:
        pass
    return name, gid, groups


# ---------------------------------------------------------------------------
# 子进程模式：真正做判定（必须是 root，才能 setuid 到别人）
# ---------------------------------------------------------------------------
def check_one(uid, path):
    info = lookup_user(uid)
    if info is None:
        os._exit(3)                     # 查不到这个 uid → 无法判定
    _name, gid, groups = info
    try:
        os.setgroups(groups)            # 顺序不能反：先组、再 gid、最后 uid
        os.setgid(gid)
        os.setuid(uid)
    except OSError:
        os._exit(3)
    os._exit(0 if os.access(path, os.R_OK) else 1)


def can_read(uid, path):
    """True 可读 / False 不可读 / None 无法判定"""
    try:
        r = subprocess.run(
            [sys.executable, SELF, "--check", str(uid), path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8,
        )
    except Exception:
        return None
    if r.returncode == 0:
        return True
    if r.returncode == 1:
        return False
    return None


# ---------------------------------------------------------------------------
# 运行模式（每次请求现读，改完立刻生效，不用重启容器）
# ---------------------------------------------------------------------------
def conf_value(key, default):
    """从 acl.conf 读一个 KEY=VALUE；读不到或值非法就返回 default。"""
    try:
        with open(MODE_FILE, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith(key + "="):
                    v = line[len(key) + 1:].strip()
                    return v or default
    except OSError:
        pass
    return default


def current_mode():
    """总体开关：enforce 真正拦截 / log 只记录不拦。"""
    v = conf_value("mode", DEFAULT_MODE)
    return v if v in ("log", "enforce") else DEFAULT_MODE


def current_body_guard():
    """body 代理开关：enforce 判定不过就 403 / log 只记录、仍然转发。

    与 mode 分开是为了能**单独**回退这一层：万一某个 body-path 接口的正常流程
    被误拦，把 acl.conf 里的 body_guard 改成 log 即可立即恢复（不必重启容器）。
    """
    v = conf_value("body_guard", DEFAULT_BODY_GUARD)
    return v if v in ("log", "enforce") else DEFAULT_BODY_GUARD


def current_fileid_guard():
    """fileId 系接口的校验档位。

    **默认 log（只记录不拦）** —— 因为合法流程里 `/files/{fileId}/page/{n}` 与
    `/files/{fileId}/pages` **没有日志样本**，无法确认它们是否都带 filePath；
    盲切 enforce 有误伤风险。先在 log 档跑一遍全部预览类型，确认日志里没有
    合法请求被记，再改成 enforce。
    """
    v = conf_value("fileid_guard", DEFAULT_FILEID_GUARD)
    return v if v in ("log", "enforce") else DEFAULT_FILEID_GUARD


def engine_uri(uri):
    """把网关前缀剥掉，得到引擎侧的真实路径（保留 query 串）。"""
    u = uri or "/"
    if u.startswith(GATEWAY_PREFIX):
        u = u[len(GATEWAY_PREFIX):]
    if not u.startswith("/"):
        u = "/" + u
    return u


def body_path(body, field):
    """从 JSON 请求体里取出路径字段；取不到返回 None。

    ⚠️ **不做 URL 解码** —— 引擎拿到 `srcRelativePath` 后是直接 `new File(...)` 的，
    判定必须和引擎读的是**同一个字符串**。如果这里解码、引擎不解码，
    两者就会指向不同路径，那正是本机制要消灭的空隙。
    （正常流程下前端放进 JSON 的就是解码后的真实路径，不需要额外处理。）
    """
    try:
        data = json.loads(body.decode("utf-8", "replace"))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    v = data.get(field)
    if isinstance(v, str) and v.strip():
        return v.strip()
    return None


def is_file(p):
    """这个路径在文件系统上是不是一个普通文件（以 root 身份看）。

    单独抽成函数是为了能在单测里打桩（容器里 /vol* 是真的，测试机上没有）。
    """
    try:
        return os.path.isfile(p)
    except OSError:
        return False


def resolve_archive_prefix(path):
    """把「压缩包内文件」的复合路径还原成**压缩包本身**的路径。

    背景（2026-10-07 真机踩坑）：引擎的前端把包内文件表示成

        <压缩包绝对路径>/<包内路径>/<文件名>

    例如 `/vol1/1000/x.zip/x/报告.docx`。这种复合路径**在文件系统上不存在**，
    直接 `os.access` 必然判定「不可读」→ 被闸门拦掉（0.5.33 就是这样把
    「压缩包内文件预览」弄坏的；0.5.30 靠来源页判定才没暴露）。

    但引擎实际读的是**压缩包本身**（以 root 解包后再转换），所以真正该判的是
    **压缩包的 ACL**。这里从长到短找出第一个确实存在、且是普通文件的前缀。

    ⚠️ 这**不是**「退回来源页」—— 来源页由客户端完全控制，那才是被绕过的原因；
    这里还原出的路径必须**在文件系统上真实存在**，攻击者无法凭空构造。
    含 `..` 的一律不处理（引擎自己的 SecurePath 也会拒绝这种路径）。

    找不到就返回 None（交回原判定）。
    """
    if not path or ".." in path:
        return None
    p = path
    while True:
        i = p.rfind("/")
        if i <= 0:
            return None
        p = p[:i]
        if not p.startswith("/vol"):
            return None
        if is_file(p):
            return p


# ---------------------------------------------------------------------------
# HTTP 服务
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fv-acl-gate"

    def log_message(self, *args):       # 关掉 BaseHTTPRequestHandler 的逐请求 stderr 噪音
        pass

    # --- 从请求里找出「用户想看的那个路径」 ---
    # 静态资源不是用户的文件，不必也不该按文件权限拦（否则被拦用户的样式/脚本也会 403，纯噪音）。
    SKIP_EXT = (".css", ".js", ".mjs", ".map", ".png", ".jpg", ".jpeg", ".gif",
                ".svg", ".ico", ".webp", ".woff", ".woff2", ".ttf", ".otf")

    @staticmethod
    def _decode(v):
        if v and "%" in v:
            try:
                return urllib.parse.unquote(v)
            except Exception:
                return v
        return v

    @classmethod
    def _from_qs(cls, qs):
        if not qs:
            return None
        try:
            params = urllib.parse.parse_qs(qs, keep_blank_values=True)
        except Exception:
            return None
        for k in ("path", "filePath"):
            v = (params.get(k) or [None])[0]
            if v:
                return v
        return None

    def _decide(self, uid, uri, ref):
        """返回 (是否放行, 原因, 判定用的路径)"""
        # ⚠️ 扩展名短路必须**放在取到路径之后、且只在请求自己没带存储卷路径时**生效。
        #
        # 原写法只看 URI 后缀就放行，等于开了一条旁路：
        #   /preview/api/file.css?filePath=/vol1/私密.docx
        # 后缀是 .css → 直接「静态资源（放行）」，filePath 里的 /vol 路径完全没被判定。
        # 这不是想当然：实测该 URL 返回的是 **500 而不是 404**，说明它确实**被路由到了**
        # 后端接口（若未匹配到任何 location 会是 404），只是 filePath 被当成 .css 去读才报错。
        # 也就是说「换个后缀」并不能真正躲开封禁接口 —— 但闸门的这道放行是真的开了。
        #
        # 现在的要求：静态资源请求自己**不能**携带 /vol 路径；带了就照常做权限判定。
        # 正常的静态资源请求（/preview/static/xxx.css）不带路径参数，行为完全不变。
        own = None
        for h in ("X-Acl-Path", "X-Acl-File"):
            v = self._decode((self.headers.get(h) or "").strip())
            if v:
                own = v
                break
        if not own:
            own = self._from_qs(uri.split("?", 1)[1] if "?" in uri else "")

        if not (own and own.startswith("/vol")) \
           and uri.split("?", 1)[0].lower().endswith(self.SKIP_EXT):
            return True, "静态资源（放行）", None

        # ---- fileId 系接口：/preview/api/files/<fileId>[/page/N | /pages] ----
        #
        # 为什么单独管：**fileId = "preview_" + md5(原始绝对路径)[:16]**（已用真机数据
        # 离线验算、两组同时精确命中），所以它**不具备保密性** —— 知道路径就能算出来。
        # 而这类请求里本来没有路径参数，闸门天然判不到；引擎在 path 缺省时会用缓存里的
        # **原始路径**把文件吐出来（源码 serveFile: @RequestParam(required=false) path
        # → cacheInfo.getOriginalFilePath()）。
        # 于是「知道路径 → 算 fileId → GET /files/<fileId>」就能绕过逐用户 ACL。
        #
        # 对策：要求请求自带 filePath。
        #   · 没带 → 按 fileid_guard 处理：log 只记录 / enforce 拒绝
        #   · 带了但与 fileId 的 md5 对不上 → **只记录**，不拦
        #     （可能是合法的变体写法，先留证据；仍会落到下面按该路径正常判 ACL，
        #       所以即使构造了"自己的 filePath + 别人的 fileId"也取不到别人的文件）
        m = FILEID_RE.search(uri.split("?", 1)[0])
        if m:
            fid = m.group(1)
            if not own:
                why = "fileId 系接口未带 filePath（fileId=%s）" % fid
                if current_fileid_guard() == "enforce":
                    return False, "拒绝：" + why + " —— 防 fileId 推导绕过", None
                return True, "【fileid_guard=log 仅记录】" + why, None
            # ⚠️ 比对前要去掉 `preview_` 前缀：fileId 是「preview_ + md5[:16]」，
            #    直接拿整个 fileId 跟 md5 比会**永远不相等**（踩过）。
            fid_core = fid[len("preview_"):] if fid.startswith("preview_") else fid
            digest = hashlib.md5(own.encode("utf-8")).hexdigest()[:16]
            if fid_core != digest:
                log("【观察】fileId 与 filePath 的 md5 不一致（fileId=%s 期望=%s path=%s）| uri=%s"
                    % (fid, "preview_" + digest, own, uri))

        # 目标路径：优先用请求自带的；**若不是存储卷路径，就退回来源页的**。
        #
        #   ① GET /preview/view?path=/vol3/…            → 请求自带，直接用
        #   ② POST /preview/api/localFile                → 只在**请求体**里带路径，
        #      nginx 看不到 body，只能靠来源页 URL 里的 path
        #   ③ GET /preview/api/file?filePath=/opt/fileview/data/preview/xxx.pdf
        #      → 带的是**引擎内部转换产物**路径，回溯不出原文件；
        #        但来源页 URL 里有原始 path，退回去用它判定，
        #        否则「知道转换后文件名就能直接取走」是个真实旁路
        ref_path = self._from_qs(ref.split("?", 1)[1] if "?" in ref else "")

        path = own
        from_ref = False
        if not (path and path.startswith("/vol")) and ref_path and ref_path.startswith("/vol"):
            path = ref_path
            from_ref = True

        if not uid or not uid.isdigit():
            return True, "缺 uid（放行）", path
        if not path:
            return True, "未解析到路径（放行）", None
        if not path.startswith("/vol"):
            return True, "非存储卷路径，来源页也没给出（放行）", path

        verdict = can_read(int(uid), path)
        src = "来源页" if from_ref else "请求"
        if verdict is None:
            return True, "无法判定（放行）", path
        if verdict:
            return True, "可读（路径取自%s）" % src, path
        if current_mode() == "enforce":
            return False, "不可读 → 拦截（路径取自%s）" % src, path
        return True, "不可读（当前 mode=log，仅记录）", path

    def _handle(self):
        if not self.path.startswith("/check"):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        uid = (self.headers.get("X-Acl-Uid") or "").strip()
        uri = self.headers.get("X-Acl-Uri") or ""
        ref = self.headers.get("X-Acl-Ref") or ""
        allow, why, path = self._decide(uid, uri, ref)

        self.send_response(200 if allow else 403)
        self.send_header("Content-Length", "0")
        self.end_headers()
        log("%s uid=%s path=%s —— %s | uri=%s" % ("放行" if allow else "拒绝", uid or "-", path or "-", why, uri))

    # --- body 代理模式：路径只在请求体里的接口（nginx 整体代理到 /guard） ---
    def _forward(self, uri, uid, body, why, path):
        """把请求原样转发给引擎并把响应回传。

        失败时返回 502 —— nginx 侧对这条 location 配了
        `error_page 502 503 504 = @fv_guard_direct`，会自动直连引擎（fail-open）。
        """
        target = ENGINE_BASE + engine_uri(uri)
        headers = {}
        for h in FORWARD_HEADERS:
            v = self.headers.get(h)
            if v:
                headers[h] = v
        req = urllib.request.Request(
            target, data=(body or None), headers=headers, method=self.command,
        )
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                payload = resp.read()
                self.send_response(resp.status)
                ct = resp.headers.get("Content-Type")
                if ct:
                    self.send_header("Content-Type", ct)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                if payload:
                    self.wfile.write(payload)
        except urllib.error.HTTPError as e:
            # 引擎自己返回的非 2xx（如 404 / 400）：原样回传，**不要**当成失败
            payload = e.read()
            self.send_response(e.code)
            ct = e.headers.get("Content-Type") if e.headers else None
            if ct:
                self.send_header("Content-Type", ct)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if payload:
                self.wfile.write(payload)
        except Exception as e:
            log("转发引擎失败：%s（uri=%s）→ 返回 502，交给 nginx fail-open 直连" % (e, uri))
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
        log("%s uid=%s path=%s —— %s | uri=%s" % ("放行", uid or "-", path or "-", why, uri))

    def _guard(self):
        uri = self.headers.get("X-Acl-Uri") or ""
        uid = (self.headers.get("X-Acl-Uid") or "").strip()
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        body = self.rfile.read(n) if n > 0 else b""

        uri_path = uri.split("?", 1)[0]
        field = ep = None
        for suffix, f in BODY_PATH_FIELDS.items():
            if uri_path.endswith(suffix):
                field, ep = f, suffix
                break

        # 不在清单里 → 不判定，原样转发（保持 fail-open，别把未知接口弄坏）
        if field is None:
            return self._forward(uri, uid, body, "未知 body-path 接口（不判定，直接转发）", None)

        path = body_path(body, field)

        # ★ 判定只用**请求体里**的路径 —— 绝不退回来源页（Referer）。
        #   退回 Referer 正是被绕过的原因：合法 Referer + 非法 body = 放行。
        if not (uid and uid.isdigit()):
            return self._forward(uri, uid, body, "缺 uid（放行）", path)
        if not path:
            return self._forward(uri, uid, body, "请求体里没有路径（放行）", None)
        if not path.startswith("/vol"):
            return self._forward(uri, uid, body, "非存储卷路径（放行）", path)

        verdict = can_read(int(uid), path)
        if verdict is None:
            return self._forward(uri, uid, body, "无法判定（放行）", path)
        if verdict:
            return self._forward(uri, uid, body, "可读（路径取自请求体 %s，未退回来源页）" % field, path)

        # ★ 压缩包内文件：请求体里的路径是复合路径 <压缩包>/<包内路径>/<文件名>，
        #   在文件系统上不存在 → 直接判定必然「不可读」。但引擎实际读的是**压缩包**
        #   （以 root 解包后转换），所以该判的是压缩包的 ACL。见 resolve_archive_prefix()。
        #   （0.5.33 漏了这一步，把「压缩包内文件预览」拦死了 —— 0.5.35 修。）
        arch = resolve_archive_prefix(path)
        if arch:
            av = can_read(int(uid), arch)
            if av is True:
                return self._forward(uri, uid, body,
                                     "可读（压缩包内文件：按压缩包判定，未退回来源页）", arch)
            if av is False and current_body_guard() == "enforce":
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
                log("拒绝 uid=%s path=%s —— 压缩包 %s 不可读 → 拦截（未退回来源页）| uri=%s"
                    % (uid, path, arch, uri))
                return
            if av is False:
                return self._forward(uri, uid, body,
                                     "不可读（压缩包 %s 也不可读，当前 body_guard=log）" % arch, arch)
            # av is None → 无法判定，fail-open，落到下面按原路径转发

        if current_body_guard() == "enforce":
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            log("拒绝 uid=%s path=%s —— 不可读 → 拦截（路径取自请求体 %s，**未退回来源页**）| uri=%s"
                % (uid, path, field, uri))
            return
        return self._forward(uri, uid, body, "不可读（当前 body_guard=log，仅记录）", path)

    def _plain(self, code, msg):
        body = (msg + "\n").encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def do_GET(self):
        if self.path.startswith("/guard"):
            self._guard()
        else:
            self._handle()

    def do_POST(self):
        if self.path.startswith("/guard"):
            self._guard()
        else:
            self._handle()


def serve():
    log("acl-gate 启动：port=%d，mode=%s，body_guard=%s，fileid_guard=%s（改 %s 后立即生效，无需重启）"
        % (PORT, current_mode(), current_body_guard(), current_fileid_guard(), MODE_FILE))
    log("body-path 接口（走 /guard 代理）：%s" % ", ".join(sorted(BODY_PATH_FIELDS)))
    log("fileId 系接口校验：%s（log 只记录 / enforce 拒绝「不带 filePath」的请求）"
        % current_fileid_guard())
    log("引擎地址：%s" % ENGINE_BASE)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "--check":
        check_one(int(sys.argv[2]), sys.argv[3])

    if len(sys.argv) >= 4 and sys.argv[1] == "--test":
        uid = int(sys.argv[2])
        path = sys.argv[3]
        info = lookup_user(uid)
        print("uid  = %d" % uid)
        print("path = %s" % path)
        if info is None:
            print("用户 = 查不到（/etc/passwd 里没有这个 uid）")
        else:
            print("用户 = %s  主组 gid=%d  附加组=%s" % (info[0], info[1], info[2] or "（无）"))
        v = can_read(uid, path)
        print("结论 = %s" % ("可读" if v is True else "不可读" if v is False else "无法判定"))
        sys.exit(0 if v is not False else 1)

    serve()
