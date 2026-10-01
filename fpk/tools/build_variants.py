"""从同一份源码生成两个「打开方式」变体的 .fpk。

背景
----
飞牛入口 `app/ui/config` 里的 `type` 决定「用 FileView 打开」时怎么打开：

    iframe → 在飞牛 fnOS 桌面窗口内打开
    url    → 在浏览器标签页 / 外部 Web 视图中打开

两者只差这一个值，但飞牛的入口配置在**安装时**读取、且**同版本不允许覆盖安装**，
所以没法做成运行时开关 —— 只能打成两个包，让用户按需下载。

本脚本把源码复制到临时目录、只改那一个字段、再调 fnpack 打包，
**全程不动工作区**（避免中断时把 url 留在源码里）。

产物（写到仓库根目录）：
    basemetas-fileview-<version>-desktop.fpk   在飞牛桌面窗口内打开
    basemetas-fileview-<version>-browser.fpk   在浏览器标签页打开

用法：
    python fpk/tools/build_variants.py
    python fpk/tools/build_variants.py --only desktop
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FPK_DIR = os.path.normpath(os.path.join(HERE, ".."))
APP_DIR = os.path.join(FPK_DIR, "basemetas-fileview")
OUT_DIR = os.path.normpath(os.path.join(FPK_DIR, ".."))
ENTRY_ID = "basemetas-fileview.view"

# 变体名 → (入口 type, 中文说明)
VARIANTS = {
    "desktop": ("iframe", "在飞牛桌面窗口内打开"),
    "browser": ("url", "在浏览器标签页打开"),
}

# 二进制文件里可能凑巧出现 0x0D 0x0A，行尾检查要跳过
BINARY_EXT = {".png", ".PNG", ".jpg", ".jpeg", ".ico", ".exe", ".gz", ".fpk"}


def find_fnpack():
    for name in ("fnpack.exe", "fnpack"):
        p = os.path.join(HERE, name)
        if os.path.isfile(p):
            return p
    raise SystemExit(
        "找不到 fnpack。请把官方 fnpack 放到 fpk/tools/ 下：\n"
        "  Windows: tools/fnpack.exe\n"
        "  Linux  : curl -L -o tools/fnpack "
        "https://static2.fnnas.com/fnpack/fnpack-1.2.3-linux-amd64 && chmod +x tools/fnpack"
    )


def read_version():
    with open(os.path.join(APP_DIR, "manifest"), encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("version="):
                return line.split("=", 1)[1].strip()
    raise SystemExit("manifest 里没有 version=")


def check_eol(root):
    """包内脚本必须全是 LF —— CRLF 的 shell 脚本在 Linux 上会静默失效。

    用二进制读再找 b'\\r\\n'，比 shell 里 grep $'\\r' 可靠（后者在 Git Bash 上会误报）。
    """
    bad = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        for fn in filenames:
            if os.path.splitext(fn)[1] in BINARY_EXT:
                continue
            p = os.path.join(dirpath, fn)
            with open(p, "rb") as fh:
                data = fh.read()
            if b"\r\n" in data:
                bad.append(os.path.relpath(p, root))
    return bad


def drop_pycache(root):
    """本地跑过一次 py_compile 就会生成 __pycache__，会被 fnpack 打进包。"""
    for dirpath, dirnames, _ in os.walk(root):
        for d in list(dirnames):
            if d == "__pycache__":
                shutil.rmtree(os.path.join(dirpath, d), ignore_errors=True)
                dirnames.remove(d)


def patch_type(app_copy, type_value):
    """只改入口的 type，其余字段原样保留；写出时锁 LF。"""
    cfg_path = os.path.join(app_copy, "app", "ui", "config")
    with open(cfg_path, encoding="utf-8") as fh:
        cfg = json.load(fh)

    entry = cfg[".url"][ENTRY_ID]
    before = entry.get("type")
    entry["type"] = type_value

    text = json.dumps(cfg, ensure_ascii=False, indent=2) + "\n"
    with open(cfg_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    return before


def build_variant(fnpack, version, variant):
    type_value, label = VARIANTS[variant]
    tmp = tempfile.mkdtemp(prefix=f"fvbuild-{variant}-")
    try:
        app_copy = os.path.join(tmp, "basemetas-fileview")
        shutil.copytree(APP_DIR, app_copy)
        drop_pycache(app_copy)

        before = patch_type(app_copy, type_value)
        print(f"  入口 type: {before} → {type_value}（{label}）")

        bad = check_eol(app_copy)
        if bad:
            print("  ❌ 行尾检查未通过，以下文件含 CRLF：")
            for b in bad:
                print("     ", b)
            raise SystemExit(1)
        print("  行尾检查：全部 LF ✅")

        # fnpack 把产物写到「当前工作目录」，所以 cwd 用临时目录，
        # 打完再改名搬走 —— 这样两个变体不会互相覆盖。
        proc = subprocess.run(
            [fnpack, "build", "--directory", app_copy],
            cwd=tmp, capture_output=True, text=True,
        )
        if proc.returncode != 0:
            print(proc.stdout)
            print(proc.stderr)
            raise SystemExit(f"fnpack 打包失败（{variant}）")

        produced = os.path.join(tmp, "basemetas-fileview.fpk")
        if not os.path.isfile(produced):
            listing = os.listdir(tmp)
            raise SystemExit(f"没找到产物，临时目录里只有：{listing}")

        final = os.path.join(OUT_DIR, f"basemetas-fileview-{version}-{variant}.fpk")
        shutil.move(produced, final)
        return final, type_value, label, os.path.getsize(final)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description="生成打开方式的两个变体包")
    ap.add_argument("--only", choices=sorted(VARIANTS), help="只打某一个变体")
    args = ap.parse_args()

    fnpack = find_fnpack()
    version = read_version()
    targets = [args.only] if args.only else ["desktop", "browser"]

    print(f"fnpack : {fnpack}")
    print(f"版本   : {version}")
    print(f"源码   : {APP_DIR}")
    print()

    results = []
    for v in targets:
        print(f"[{v}]")
        results.append(build_variant(fnpack, version, v))
        print()

    print("=" * 68)
    print(f"{'产物':<48}{'大小':>10}")
    print("-" * 68)
    for path, type_value, label, size in results:
        print(f"{os.path.basename(path):<48}{size:>10}")
        print(f"    type={type_value}  {label}")
    print("=" * 68)
    print("两个包版本号相同（都取自 manifest），切换变体需先在应用中心卸载再安装。")
    print("不要对生成的 .fpk 做任何后处理 —— 会破坏 manifest 里的 checksum 校验。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
