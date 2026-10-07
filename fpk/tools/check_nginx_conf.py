#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
nginx.conf 语法自检（本地无 Docker 时的替代手段）

真正的校验一定是 `nginx -t`。本脚本做的是"能不能被解析器读进去"这一层的自检，
覆盖最容易让 nginx 直接起不来的几类错误：

  1. 花括号不配对
  2. 引号不配对
  3. 语句没有以 ; { } 结尾（漏分号）
  4. `location ~ <regex>` 里的正则无法编译
  5. 可疑指令名（拼写错误）—— 仅在非 map 块内检查
  6. **`proxy_pass` 带字面量 URI 部分，却处在 regex / 命名 / if / limit_except 块里**

⚠️ 关于第 6 条：nginx 源码 `ngx_http_proxy_pass()` 里，
   `if (clcf->named || clcf->regex || clcf->predicate || clcf->noname) { if (plcf->vars.uri.len) 报错 }`
   —— 报错信息是
     "proxy_pass" cannot have URI part in location given by regular expression,
     or inside predicate location, or inside named location, or inside "if" statement,
     or inside "limit_except" block
   这是**启动期 emerg**：整个网关容器会起不来、无限重启。
   注意：**含 `$` 变量的写法不受限**（同函数里 `if (n) { ... return NGX_CONF_OK; }` 提前返回），
   所以本检查只针对字面量 URI 部分 —— 与 nginx 行为一致。

   历史教训（2026-10-06）：0.5.31 首版把 body-path 接口的代理写成
   `location ~ ^…/preview/api/(localFile|password/unlock)$ { proxy_pass http://aclbody/guard; }`
   → 真机网关无限重启。当时本脚本没有第 6 条检查、也**没被 selfcheck 调用**，
   两道防线都缺。现在两处都补上了。**能用 `location =`（精确匹配）就别用 regex**：
   精确匹配不受这条限制，而且优先级高于任何 regex。

⚠️ 关于 map 块：`map` 的块体里每行是「键 值;」而不是「指令 参数;」，
   键可以是 default、空串、带引号的正则。这里是常见的误报来源，必须跳过。

用法：
    python check_nginx_conf.py <nginx.conf 路径>

退出码 0 = 通过；1 = 发现问题。
"""
import re
import sys

# 允许出现的指令名（前缀匹配，宽松白名单）。
# 目的不是穷举，而是把"拼错的指令名"这种低级错误拦下来。
KNOWN_PREFIXES = (
    "listen", "server_name", "autoindex", "location", "return", "root", "index",
    "proxy_pass", "proxy_http_version", "proxy_set_header", "proxy_read_timeout",
    "proxy_send_timeout", "proxy_buffering", "proxy_redirect", "proxy_buffers",
    "proxy_buffer_size", "proxy_max_temp_file_size", "proxy_connect_timeout",
    "proxy_ignore_headers", "client_max_body_size", "client_body_timeout",
    "client_header_timeout", "send_timeout", "keepalive_timeout", "resolver",
    "access_log", "error_log", "log_format", "map", "default_type",
    "add_header", "sub_filter", "rewrite", "if", "try_files", "gzip",
    "gzip_types", "charset", "include", "worker_processes", "events", "http",
    "server", "upstream", "types", "etag", "expires", "limit_except",
    "auth_basic", "ssl_certificate", "umask", "pid", "user", "error_page",
    # 逐用户权限闸门用到（见 app/docker/fv-acl-gate.py）
    "auth_request", "internal", "proxy_pass_request_body", "proxy_method",
    # body-path 接口的 fail-open：必须拦下**上游（闸门）返回的** 502，
    # 否则 error_page 不触发、兜底直连引擎那条路走不到
    "proxy_intercept_errors",
    # 静态补丁文件 fv-web-patch.js 用 alias 指到挂进来的 conf.d 目录
    "alias",
    # 重定向发相对 Location（默认 on 会拼绝对地址，在 unix socket + 网关去端口
    # 的组合下会把外部端口弄丢 —— 见 nginx.conf 里的说明）
    "absolute_redirect",
)


def strip_comment(line: str) -> str:
    """去掉行尾注释，但保留引号内的 #。"""
    out, quote = [], None
    for ch in line:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    return "".join(out)


# 这些块里 proxy_pass 不允许带字面量 URI 部分（见文件头第 6 条）
RESTRICTED_TAGS = {"@regex", "@named", "@if", "@limit_except", "@predicate"}


def block_tag(stripped: str) -> str:
    """给一个块的开头行打标签，用于判断「当前处在哪类块里」。"""
    if stripped.startswith("location"):
        rest = stripped[len("location"):].strip()
        if rest.startswith("@"):
            return "@named"
        if rest.startswith("~"):
            return "@regex"
        return "@prefix"
    if stripped.startswith("if") and re.match(r"if\s*[({]", stripped):
        return "@if"
    if stripped.startswith("limit_except"):
        return "@limit_except"
    return stripped.split()[0] if stripped.split() else ""


def has_literal_uri_part(arg: str) -> bool:
    """proxy_pass 的参数里是否有**字面量** URI 部分。

    含 `$` 变量的一律返回 False —— nginx 对变量形式会提前 return，不做这项检查。
    """
    if "$" in arg:
        return False
    m = re.match(r"^https?://[^/]*(/.*)$", arg)
    return bool(m)


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: python check_nginx_conf.py <nginx.conf>")
        return 1

    path = sys.argv[1]
    with open(path, encoding="utf-8") as fh:
        raw_lines = fh.read().splitlines()

    problems: list[str] = []
    depth = 0
    stack: list[str] = []              # 块关键字栈，用于判断是否在 map 块内
    locations: list[tuple[int, str]] = []
    sub_filter_count = 0

    for lineno, line in enumerate(raw_lines, 1):
        text = strip_comment(line)
        if not text.strip():
            continue

        if text.count('"') % 2 or text.count("'") % 2:
            problems.append(f"L{lineno}: 引号不配对 -> {text.strip()[:80]}")

        stripped = text.strip()
        head = stripped.split()[0] if stripped.split() else ""
        # map / types 块体里都不是「指令名 参数;」的形式：
        #   map 里是「键 值;」，types 里是「MIME类型 扩展名;」
        # 所以这两类块体内要跳过"指令名白名单"检查。
        # ⚠️ 0.5.55 给 CAD 页加了 types 块之后，里面的 application/wasm 等被误报成
        #    "可疑指令名"，3 处误报让整个自检失败 ✗（其实 nginx 写法完全合法）。
        in_data_block = bool(stack) and stack[-1] in ("map", "types")

        # 语句结尾
        if not stripped.endswith((";", "{", "}")):
            problems.append(f"L{lineno}: 语句未以 ; {{ }} 结尾（可能漏分号）-> {stripped[:80]}")

        # 指令名白名单
        if not in_data_block and head not in ("", "}"):
            if not head.startswith(("~", '"', "'")) and head != "default":
                if not any(head.startswith(p) for p in KNOWN_PREFIXES):
                    problems.append(f"L{lineno}: 可疑指令名 '{head}'（不在白名单，确认拼写）")

        # location 正则可编译性
        match = re.match(r"location\s+([~*^=]+)?\s*(\S+)", stripped)
        if match and match.group(1) and "~" in match.group(1):
            pattern = match.group(2)
            locations.append((lineno, pattern))
            try:
                re.compile(pattern)
            except re.error as exc:
                problems.append(f"L{lineno}: location 正则无法编译 -> {pattern} ({exc})")

        if stripped.startswith("sub_filter "):
            sub_filter_count += 1

        # ★ proxy_pass 带字面量 URI 部分，且处在 regex / 命名 / if / limit_except 块里
        #   —— nginx 启动期 emerg，整个容器起不来。见文件头第 6 条。
        if stripped.startswith("proxy_pass "):
            arg = stripped[len("proxy_pass"):].strip().rstrip(";").strip()
            if has_literal_uri_part(arg) and any(t in RESTRICTED_TAGS for t in stack):
                bad = [t for t in stack if t in RESTRICTED_TAGS]
                problems.append(
                    f"L{lineno}: proxy_pass 带字面量 URI 部分，但处在 {bad[-1]} 块里 "
                    f"-> {arg}（nginx 会 emerg 起不来；改用 location = 精确匹配，"
                    f"或改成含 $ 变量的写法）")

        # 维护括号深度与块栈
        opens, closes = text.count("{"), text.count("}")
        tag = block_tag(stripped)
        for _ in range(opens):
            stack.append(tag)
        depth += opens
        for _ in range(closes):
            if stack:
                stack.pop()
            depth -= 1
        if depth < 0:
            problems.append(f"L{lineno}: 出现了多余的 '}}'")
            depth = 0

    if depth != 0:
        problems.append(f"文件结束时花括号不配对，depth={depth}（多出/缺少 {abs(depth)} 个）")

    print(f"文件：{path}")
    print(f"行数：{len(raw_lines)}")
    print("location 正则：")
    for lineno, pattern in locations:
        print(f"  L{lineno}: {pattern}")
    print(f"sub_filter 指令：{sub_filter_count} 条")
    print("-" * 60)
    if problems:
        print(f"❌ 发现 {len(problems)} 处可疑：")
        for item in problems:
            print("  " + item)
        return 1
    print("✅ 通过：花括号配对、引号配对、语句结尾、指令名、location 正则均正常")
    print("   （注意：这只是解析层自检，真正的校验请在真机执行 nginx -t）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
