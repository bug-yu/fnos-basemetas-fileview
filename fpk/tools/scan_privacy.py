"""推送前隐私扫描：找出项目里可能泄露本机环境的信息。

设计原则：脚本本身**不含任何内部信息** —— 内部关键词（项目名、公司名等）
放在可选的本地文件 privacy-words.txt 里，该文件已被 .gitignore 排除。

用法： python scan_privacy.py                 # 用通用规则扫描
       python scan_privacy.py --words 文件    # 额外扫描内部关键词（每行一个）
"""

import os
import re
import sys

BASE = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SKIP_DIRS = {"__pycache__", ".git", ".sanitize-backup"}
SKIP_EXT = {".exe", ".fpk", ".png", ".jpg", ".ico"}

# 通用规则：只找"环境专属信息"，不含任何具体项目名
GENERIC_RULES = [
    ("私有 IP", re.compile(r"\b(?:10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])|192\.168)\.\d{1,3}\.\d{1,3}\b")),
    ("公网 IP", re.compile(r"\b(?!(?:10|172|192|127|0|255)\.)\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")),
    ("邮箱", re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")),
    ("疑似 token/密钥", re.compile(r"\b(?:ghp_|gho_|github_pat_|sk-|Bearer\s+)[A-Za-z0-9_\-]{12,}")),
    ("MAC 地址", re.compile(r"\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b")),
    ("内网系统目录", re.compile(r"@appcenter|@appconf|@appdata|@apphome|@apptemp")),
]

# 允许出现的值（通用占位、官方公网地址、版本号）
ALLOWLIST = [
    r"nas\.example\.com",
    r"example\.com",
    r"https?://192\.168\.1\.10\b",
    r"192\.168\.1\.10",                       # 文档里统一使用的占位内网 IP
    r"developer\.fnnas\.com", r"fileview\.basemetas\.cn", r"basemetas\.com",
    r"github\.com", r"githubusercontent\.com", r"hub\.docker\.com",
    r"static2\.fnnas\.com", r"club\.fnnas\.com", r"npmjs\.com",
    r"localhost", r"127\.0\.0\.1", r"0\.0\.0\.0",
    r"\d+\.\d+\.\d+\.\d+\.\d+",               # 四段以上 = 版本号
    r"\b1\.\d+(\.\d+)*\b",                    # 1.x 版本号
    r"\d+\.\d+\.\d+\.\d+",                    # 三/四段版本号（与私有 IP 规则冲突时优先按版本对待）
    r"\d+\.\d+\.\d+",                         # 三段版本号
    r"v?\d+\.\d+",                            # 两段版本号
]


def allowed(line: str) -> bool:
    return any(re.search(p, line) for p in ALLOWLIST)


def load_words(path):
    if not path or not os.path.exists(path):
        return []
    words = [w.strip() for w in open(path, encoding="utf-8") if w.strip() and not w.startswith("#")]
    return words


def main():
    words = []
    if "--words" in sys.argv:
        words = load_words(sys.argv[sys.argv.index("--words") + 1])
    rules = list(GENERIC_RULES)
    if words:
        rules.append(("内部关键词", re.compile("|".join(re.escape(w) for w in words))))

    findings = []
    scanned = 0
    for root, dirs, files in os.walk(BASE):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if os.path.splitext(name)[1].lower() in SKIP_EXT:
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, BASE).replace("\\", "/")
            # 排除：扫描/脱敏脚本自身、需保留的运行日志、本地内部词表、历史扫描报告
            if (rel.endswith(("scan_privacy.py", "sanitize.py", "privacy-words.txt", ".log"))
                    or rel.endswith("privacy-scan.txt")):
                continue
            try:
                text = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            scanned += 1
            for lineno, line in enumerate(text.splitlines(), 1):
                if allowed(line):
                    continue
                for label, rx in rules:
                    for m in rx.finditer(line):
                        findings.append((rel, lineno, label, m.group(0), line.strip()[:140]))

    print(f"扫描文件数：{scanned}；命中：{len(findings)}")
    if words:
        print(f"额外关键词：{len(words)} 个")
    print()
    cur = None
    for rel, lineno, label, match, text in findings:
        if rel != cur:
            cur = rel
            print(f"■ {rel}")
        print(f"    L{lineno:<5} [{label}] {match}")
        print(f"           {text}")
    if not findings:
        print("✅ 未发现环境专属信息。")
    else:
        print("⚠️  上述命中需人工确认（@appcenter 等 fnOS 系统目录属正常内容，可忽略）。")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
