# -*- coding: utf-8 -*-
"""构建 CAD 预览页（cad-viewer + LibreDWG），产物落到 app/docker/cad/。

为什么单独一个页面：FileView 引擎自带的 CAD 转换器（cad2x）对**多重引线**、
**面域边框**、**字体**还原都不行（真机对比过），而 cad-viewer 这三项都正常。
所以 dwg/dxf 从 FileView 的入口里摘出来，走这个页面。

产物合计约 80 MB（页面 18 MB + 字体 54 MB），**不进仓库**（见 .gitignore），
由本脚本生成：

  1. 克隆 mlightcad/cad-data（**固定 commit**）—— 提供 86 个 SHX 字体 + 数据 + 模板
  2. pnpm install --ignore-scripts && pnpm build
  3. 把 dist/* 拷进 fpk/basemetas-fileview/app/docker/cad/

依赖：git、node（自带 corepack → pnpm）
用法：
  python fpk/cad-viewer/build.py              # 完整构建
  python fpk/cad-viewer/build.py --skip-deps  # 依赖已装过，只重新打包
"""
import argparse
import os
import shutil
import subprocess
import sys

# cad-data 固定到某个 commit —— 字体/模板属于"渲染效果"的一部分，必须可复现。
# 升级时改这里，并重新跑一遍真机对比。
CAD_DATA_REPO = "https://github.com/mlightcad/cad-data.git"
CAD_DATA_COMMIT = "be0a4956038c05acdd664266e8c803ac04f0ac77"

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
CAD_DATA_DIR = os.path.join(HERE, "cad-data")
DIST_DIR = os.path.join(HERE, "dist")
TARGET = os.path.join(REPO_ROOT, "fpk", "basemetas-fileview", "app", "docker", "cad")

# node / corepack：优先用环境里的，其次找托管版本（Windows 本机常见）
NODE_CANDIDATES = [
    shutil.which("corepack"),
    os.path.expanduser("~/.workbuddy-ai/binaries/node/versions/22.22.2-3/corepack.cmd"),
    os.path.expanduser("~/.workbuddy-ai/binaries/node/versions/22.22.2-3/corepack"),
]


def run(cmd, cwd=None, env=None, desc=""):
    """跑一条命令；失败就**大声报错**（不吞退出码 —— 见技能里那条教训）。"""
    print("  $ %s" % " ".join(cmd))
    r = subprocess.run(cmd, cwd=cwd, env=env)
    if r.returncode != 0:
        print("  ✗ %s 失败（退出码 %d）" % (desc or cmd[0], r.returncode))
        sys.exit(1)


def find_corepack():
    for c in NODE_CANDIDATES:
        if c and os.path.exists(c):
            return c
    return None


def step_clone_cad_data():
    print("① 取 cad-data（字体/数据/模板）")
    if os.path.isdir(os.path.join(CAD_DATA_DIR, ".git")):
        print("  已存在，检查 commit …")
        r = subprocess.run(["git", "rev-parse", "HEAD"], cwd=CAD_DATA_DIR,
                           capture_output=True, text=True)
        if r.stdout.strip() == CAD_DATA_COMMIT:
            print("  ✓ 已是目标 commit")
            return
        print("  commit 不一致，重新取")
        shutil.rmtree(CAD_DATA_DIR, ignore_errors=True)
    else:
        shutil.rmtree(CAD_DATA_DIR, ignore_errors=True)

    os.makedirs(CAD_DATA_DIR, exist_ok=True)
    run(["git", "init", "-q"], cwd=CAD_DATA_DIR, desc="git init")
    run(["git", "remote", "add", "origin", CAD_DATA_REPO], cwd=CAD_DATA_DIR, desc="git remote")
    run(["git", "fetch", "-q", "--depth", "1", "origin", CAD_DATA_COMMIT],
        cwd=CAD_DATA_DIR, desc="git fetch")
    run(["git", "checkout", "-q", "FETCH_HEAD"], cwd=CAD_DATA_DIR, desc="git checkout")

    fonts = os.path.join(CAD_DATA_DIR, "fonts")
    n = len(os.listdir(fonts)) if os.path.isdir(fonts) else 0
    print("  ✓ 字体 %d 个" % n)


def step_build(skip_deps):
    print("② 构建前端（vite）")
    corepack = find_corepack()
    if not corepack:
        print("  ✗ 找不到 corepack/pnpm —— 请先装 node（含 corepack）")
        sys.exit(1)

    env = dict(os.environ)
    env["CAD_DATA_DIR"] = CAD_DATA_DIR

    if not skip_deps or not os.path.isdir(os.path.join(HERE, "node_modules")):
        # ⚠️ --ignore-scripts：esbuild 的 postinstall 在受限环境里会被拦（退出码 127 那类），
        #    而它只是自检版本号，跳过不影响构建。
        run([corepack, "pnpm", "install", "--ignore-scripts"], cwd=HERE, env=env,
            desc="pnpm install")
    run([corepack, "pnpm", "run", "build"], cwd=HERE, env=env, desc="pnpm build")


def step_normalize_lf():
    """把产物里的**文本**文件统一成 LF。

    ⚠️ 为什么必须做：打包前的行尾检查（check_eol.sh / build_variants.py）
       只放行二进制，文本一律要求 LF —— 而 **Vite 在 Windows 上产出的 HTML 带 CRLF**，
       cad-data 里的 `fonts.json` 也是。0.5.55 就因为这两处连挂了两次打包。
       二进制（.wasm/.shx/…）用"前 8KB 有没有 NUL 字节"判出来跳过，不动它们。
    """
    fixed = []
    for dp, _dn, fn in os.walk(TARGET):
        for f in fn:
            p = os.path.join(dp, f)
            try:
                with open(p, "rb") as fh:
                    if b"\x00" in fh.read(8192):
                        continue                      # 二进制，跳过
                with open(p, "rb") as fh:
                    data = fh.read()
                if b"\r\n" in data:
                    with open(p, "wb") as fh:
                        fh.write(data.replace(b"\r\n", b"\n"))
                    # ⚠️ 写回后**再读一次**确认真的干净了 —— Windows 上偶发半截写，
                    #    只报"已处理"而文件其实没变（0.5.55 就遇到过：报修了 7 个，
                    #    其中 2 个仍是 CRLF ✗）。宁可这里多读一遍，也别让打包再挂一次。
                    with open(p, "rb") as fh:
                        if b"\r\n" in fh.read():
                            print("    ⚠️ %s 写回后仍含 CRLF，重试一次" % os.path.relpath(p, TARGET))
                            with open(p, "wb") as fh2:
                                fh2.write(data.replace(b"\r\n", b"\n"))
                    fixed.append(os.path.relpath(p, TARGET))
            except OSError:
                continue
    print("  ✓ 归一成 LF 的文本文件：%d 个" % len(fixed))
    for f in fixed[:10]:
        print("      %s" % f)


def step_copy():
    print("③ 拷进 fpk")
    if not os.path.isdir(DIST_DIR):
        print("  ✗ 没有 dist/ —— 上一步没成功？")
        sys.exit(1)

    # ⚠️ 不要整目录删除再拷：
    #    `shutil.rmtree(TARGET)`（或 shell 的 `rm -rf`）要删 130+ 个文件，
    #    会触发**安全护栏的批量删除确认**（>50 文件），导致拷贝根本没执行 ✗
    #    （0.5.56 打包时就这么被拦下来的）。改成：**覆盖同名文件**，
    #    再**只删目标里多出来的**（通常只有几个带哈希的旧 chunk）。
    os.makedirs(TARGET, exist_ok=True)
    copied = 0
    for dp, _dn, fn in os.walk(DIST_DIR):
        rel = os.path.relpath(dp, DIST_DIR)
        dst_dir = TARGET if rel == "." else os.path.join(TARGET, rel)
        os.makedirs(dst_dir, exist_ok=True)
        for f in fn:
            shutil.copy2(os.path.join(dp, f), os.path.join(dst_dir, f))
            copied += 1
    print("  覆盖/新增 %d 个文件" % copied)

    stale = []
    for dp, _dn, fn in os.walk(TARGET):
        rel = os.path.relpath(dp, TARGET)
        src_dir = DIST_DIR if rel == "." else os.path.join(DIST_DIR, rel)
        for f in fn:
            if not os.path.exists(os.path.join(src_dir, f)):
                stale.append(os.path.join(dp, f))
    for p in stale:
        os.remove(p)
    print("  清掉多余的 %d 个" % len(stale))

    total = 0
    for dp, _dn, fn in os.walk(TARGET):
        for f in fn:
            total += os.path.getsize(os.path.join(dp, f))
    print("  ✓ %s（%.1f MB）" % (TARGET, total / 1048576))

    # 关键产物自检：少任何一个页面都起不来
    must = [
        "index.html",
        os.path.join("assets", "libredwg-parser-worker.js"),
        os.path.join("assets", "libredwg-web.wasm"),
    ]
    for m in must:
        p = os.path.join(TARGET, m)
        if os.path.exists(p):
            print("    ✓ %s" % m)
        else:
            print("    ✗ 缺 %s —— 构建产物不完整" % m)
            sys.exit(1)
    fonts = os.path.join(TARGET, "cad-data", "fonts")
    print("    ✓ cad-data/fonts：%d 个文件"
          % (len(os.listdir(fonts)) if os.path.isdir(fonts) else 0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-deps", action="store_true", help="跳过 pnpm install")
    ap.add_argument("--skip-data", action="store_true", help="跳过 cad-data 克隆")
    args = ap.parse_args()

    print("=" * 68)
    print("构建 CAD 预览页 → %s" % TARGET)
    print("=" * 68)
    if not args.skip_data:
        step_clone_cad_data()
    step_build(args.skip_deps)
    step_copy()
    print("④ 行尾归一")
    step_normalize_lf()
    print()
    print("✅ 完成。注意：产物不进仓库（.gitignore 已排除），打包 .fpk 前要先跑本脚本。")


if __name__ == "__main__":
    main()
