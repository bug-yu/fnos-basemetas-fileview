"""钉住「应用中心点打开 → 欢迎页」那条重定向的判定边界。

被钉住的逻辑在 app/docker/nginx.conf：

    map "$uri:$arg_path" $fv_view_needs_welcome {
        default 0;
        "~^/app/basemetas-fileview/preview/view:$" 1;
    }
    # 然后在 location ~ ^/preview/(index\\.html|[^.]*)$ 里：
    if ($fv_view_needs_welcome) { return 302 /app/basemetas-fileview/preview/welcome; }

为什么值得单测：**风险全在「误伤」** —— 一旦条件写宽了，真正的文件预览
（/preview/view?path=/vol1/xxx.pdf）也会被转到欢迎页。那时用户看到的是
「右键打开文件，结果跳到欢迎页」，很难联想到是网关里的一个 map 写错了。
反向漏判则表现为「应用中心点打开还是空白」，同样不好查。

用法：python fpk/tools/test_welcome_redirect.py     # 退出码 0 = 全过
"""

import re
import sys

# 与 nginx.conf 里的 map 正则逐字保持一致（`~` 区分大小写 → re 默认行为相同）
PATTERN = re.compile(r"^/app/basemetas-fileview/preview/view:$")

ENTRY_URI = "/app/basemetas-fileview/preview/view"

# (说明, $uri, $arg_path, 期望是否转欢迎页)
CASES = [
    ("★ 应用中心点「打开」：入口 url，无 path", ENTRY_URI, "", True),
    ("★ 文件管理器右键：带绝对路径（绝不能转走）", ENTRY_URI, "/vol1/1000/图纸.dwg", False),
    ("path 是根目录（也是合法路径，不能转）", ENTRY_URI, "/", False),
    ("path 带查询串以外的字符", ENTRY_URI, "/vol2/@appdata/x.pdf", False),
    ("欢迎页自己（转了就成无限重定向）", "/app/basemetas-fileview/preview/welcome", "", False),
    ("上游调试页", "/app/basemetas-fileview/preview/debug", "", False),
    ("index.html", "/app/basemetas-fileview/preview/index.html", "", False),
    ("入口 url 带尾斜杠", ENTRY_URI + "/", "", False),
    ("大小写不同（宁可漏转也不误伤）", "/app/basemetas-fileview/preview/VIEW", "", False),
    ("静态资源", "/app/basemetas-fileview/preview/static/app.js", "", False),
    ("网关前缀根（另有 302 规则处理）", "/app/basemetas-fileview", "", False),
    ("__whoami 诊断端点", "/app/basemetas-fileview/__whoami", "", False),
]


def needs_welcome(uri, arg_path):
    """复刻 nginx map 求值：键 = "$uri:$arg_path"，正则 search 命中则取该条目的值。"""
    return bool(PATTERN.search(f"{uri}:{arg_path}"))


def main():
    print("=" * 78)
    print("欢迎页重定向判定矩阵 —— map $uri:$arg_path → $fv_view_needs_welcome")
    print("=" * 78)
    failed = 0
    for name, uri, path, want in CASES:
        got = needs_welcome(uri, path)
        ok = got == want
        if not ok:
            failed += 1
        print(f"{'OK  ' if ok else 'FAIL'} {name}")
        print(f"     uri={uri!r}  path={path!r}")
        print(f"     → 转欢迎页 = {got}（期望 {want}）")
    print()
    print("=" * 78)
    print(f"失败 {failed} / {len(CASES)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
