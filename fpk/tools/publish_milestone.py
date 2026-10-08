# -*- coding: utf-8 -*-
"""把历史里的某个版本重新发布到 GitHub（补 tag + Release + 资产）。

用途：阶段性的应用包要留在 Release 页上 ✓。
之前按"只留最新"的策略删过一些，本脚本可以从 **git 历史** + **本地 .fpk** 补回来。

  python fpk/tools/publish_milestone.py 0.5.54 231cad7
  python fpk/tools/publish_milestone.py 0.5.50 f4c0864

参数：<版本号> <该版本对应的提交>（提交要选 **manifest 里 version 正好是这个** 的那个）
幂等：Release 已存在就不重建，只补缺失的资产。
"""
import io
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = "bug-yu/fnos-basemetas-fileview"
ROOT = r"C:\Users\yang\WorkBuddy AI\2026-09-27-09-07-41\fnos-basemetas-fileview"

if len(sys.argv) < 3:
    print(__doc__)
    raise SystemExit(2)
VER = sys.argv[1]
COMMIT = sys.argv[2]
TAG = "v" + VER
ASSETS = ["basemetas-fileview-%s-%s.fpk" % (VER, v) for v in ("desktop", "browser")]


def token():
    p = subprocess.run(["git", "credential", "fill"], cwd=ROOT,
                       input="protocol=https\nhost=github.com\n\n",
                       capture_output=True, text=True, timeout=90)
    for line in p.stdout.splitlines():
        if line.startswith("password="):
            return line[len("password="):].strip()
    raise SystemExit("取不到凭据")


TOK = token()


def api(method, url, payload=None, raw=None, ctype="application/json", tries=4):
    for i in range(1, tries + 1):
        req = urllib.request.Request(url, method=method)
        req.add_header("Authorization", "Bearer " + TOK)
        req.add_header("User-Agent", "workbuddy-milestone")
        req.add_header("Accept", "application/vnd.github+json")
        body = None
        if payload is not None:
            body = json.dumps(payload).encode()
            req.add_header("Content-Type", "application/json")
        elif raw is not None:
            body = raw
            req.add_header("Content-Type", ctype)
        try:
            with urllib.request.urlopen(req, data=body, timeout=900) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()
        except Exception as e:
            print("    重试 %d/%d：%s" % (i, tries, str(e)[:70]))
            time.sleep(4)
    return 0, b""


def run(cmd):
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()


# ① 校验提交与版本一致（防止 tag 指错地方）
st, out = run(["git", "show", "%s:fpk/basemetas-fileview/manifest" % COMMIT])
if st != 0:
    print("✗ 取不到 %s 的 manifest：%s" % (COMMIT, out[:120]))
    raise SystemExit(1)
m = re.search(r"^version=(.+)$", out, re.M)
have = m.group(1).strip() if m else "?"
print("① 提交 %s 的 manifest 版本 = %s（期望 %s）" % (COMMIT, have, VER))
if have != VER:
    print("✗ 版本不一致，换一个提交（用 `git log -S'version=%s'` 找）" % VER)
    raise SystemExit(1)

# ② tag
st, out = run(["git", "rev-parse", TAG])
if st == 0:
    print("② tag %s 已存在，跳过" % TAG)
else:
    st, out = run(["git", "tag", "-a", TAG, COMMIT, "-m", "%s（里程碑版本，从历史补发）" % TAG])
    if st != 0:
        print("✗ 建 tag 失败：%s" % out[:120])
        raise SystemExit(1)
    st, out = run(["git", "push", "origin", TAG])
    print("② 建 tag %s → %s" % (TAG, "OK" if st == 0 else out[:100]))

# ③ Release 说明：优先取 CHANGELOG 里的小节
body = None
cl = io.open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8").read()
m = re.search(r"^## " + re.escape(VER) + r"\s*$", cl, re.M)
if m:
    rest = cl[m.end():]
    nxt = re.search(r"^## ", rest, re.M)
    body = (rest[:nxt.start()] if nxt else rest).strip()
    print("③ 说明取自 CHANGELOG（%d 字符）" % len(body))
else:
    body = "里程碑版本 %s（详见仓库 CHANGELOG.md）" % VER
    print("③ CHANGELOG 里没有 ## %s，用占位说明" % VER)

# ④ 建/找 Release
st, d = api("GET", "https://api.github.com/repos/%s/releases?per_page=100" % REPO)
rel = next((r for r in json.loads(d) if r["tag_name"] == TAG), None)
if rel is None:
    st, d = api("POST", "https://api.github.com/repos/%s/releases" % REPO,
                {"tag_name": TAG, "name": TAG, "body": body, "draft": False})
    if st not in (200, 201):
        print("✗ 建 Release 失败：HTTP %s %s" % (st, d[:200]))
        raise SystemExit(1)
    rel = json.loads(d)
    print("④ 建 Release %s ✓" % TAG)
else:
    st, _ = api("PATCH", "https://api.github.com/repos/%s/releases/%s" % (REPO, rel["id"]),
                {"body": body})
    print("④ Release %s 已存在，更新说明 → HTTP %s" % (TAG, st))

# ⑤ 补资产
have_sizes = {a["name"]: a["size"] for a in rel.get("assets", [])}
for name in ASSETS:
    p = os.path.join(ROOT, name)
    if not os.path.isfile(p):
        print("  ✗ 本地没有 %s —— 需要先构建该版本" % name)
        continue
    size = os.path.getsize(p)
    if have_sizes.get(name) == size:
        print("  ✓ %s 已存在（%d 字节）" % (name, size))
        continue
    print("  ↑ 上传 %s（%.1f MB）…" % (name, size / 1048576))
    data = open(p, "rb").read()
    url = ("https://uploads.github.com/repos/%s/releases/%s/assets?name=%s"
           % (REPO, rel["id"], urllib.parse.quote(name)))
    st, d = api("POST", url, raw=data, ctype="application/octet-stream")
    print("    %s" % ("✓ 成功" if st in (200, 201) else "✗ HTTP %s %s" % (st, d[:120])))

print()
print("完成。当前 Release 列表：")
st, d = api("GET", "https://api.github.com/repos/%s/releases?per_page=100" % REPO)
for r in sorted(json.loads(d), key=lambda x: x["tag_name"]):
    print("  %-10s %d 个资产" % (r["tag_name"], len(r["assets"])))
