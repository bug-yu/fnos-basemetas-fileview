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
    # 静态补丁文件 fv-web-patch.js 用 alias 指到挂进来的 conf.d 目录
    "alias",
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
        in_map = stack and stack[-1] == "map"

        # 语句结尾
        if not stripped.endswith((";", "{", "}")):
            problems.append(f"L{lineno}: 语句未以 ; {{ }} 结尾（可能漏分号）-> {stripped[:80]}")

        # 指令名白名单（map 块体内跳过：那里是「键 值;」）
        if not in_map and head not in ("", "}"):
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

        # 维护括号深度与块栈
        opens, closes = text.count("{"), text.count("}")
        for _ in range(opens):
            stack.append(head)
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
