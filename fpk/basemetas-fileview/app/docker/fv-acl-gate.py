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

安全默认
--------
**只在「确定不可读」时拒绝，其余一律放行**（缺 uid、解析不到路径、查不到用户、
判定异常 → 放行并记日志）。这样即使身份头没传进来、或判定逻辑有问题，也只是
「没保护」，不会把应用弄坏。

拦截开关（${TRIM_PKGVAR}/acl.conf 里的 mode）**默认 enforce**。万一出现误拦，
把那个文件里的 mode 改成 log 即可退回「只记录不拦截」—— 闸门每次请求现读该文件，
改完立即生效，不用重启容器，也不用重装应用。
（应用只在文件不存在时写入默认值；已存在的值不会被覆盖，所以手工改的能留住。）

用法
----
    python3 fv-acl-gate.py                      # 以 HTTP 服务运行（容器里用）
    python3 fv-acl-gate.py --test <uid> <path>  # 命令行自测（需 root），直接打印结论
    python3 fv-acl-gate.py --check <uid> <path> # 内部子进程模式，只用退出码：0 可读 / 1 不可读 / 3 无法判定
"""

import os
import sys
import time
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE_FILE = os.environ.get("FV_ACL_MODE_FILE", "/acl-conf/acl.conf")
PORT = int(os.environ.get("FV_ACL_PORT", "8080"))
SELF = os.path.abspath(__file__)
DEFAULT_MODE = "enforce"


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
def current_mode():
    try:
        with open(MODE_FILE, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("mode="):
                    v = line[5:].strip()
                    return v if v in ("log", "enforce") else DEFAULT_MODE
    except OSError:
        pass
    return DEFAULT_MODE


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

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()


def serve():
    log("acl-gate 启动：port=%d，当前 mode=%s（改 %s 后立即生效，无需重启）"
        % (PORT, current_mode(), MODE_FILE))
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
