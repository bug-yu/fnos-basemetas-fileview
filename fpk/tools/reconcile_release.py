# -*- coding: utf-8 -*-
"""把某个版本的 Release 收敛到「只留它、且两个资产都在」。

为什么单独写：`fpk/tools/release.py` 不是幂等的（它直接 POST 建 release，
已存在就会 already_exists 失败）。而大资产上传（54MB×2）在不稳的网络上
很容易中途断（0.5.56 就断了：release 建了、资产 0 个 ✗）。
本脚本可以**反复跑**，直到状态正确。

用法：python reconcile_release.py 0.5.56
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = "bug-yu/fnos-basemetas-fileview"
ROOT = r"C:\Users\yang\WorkBuddy AI\2026-09-27-09-07-41\fnos-basemetas-fileview"
VER = sys.argv[1] if len(sys.argv) > 1 else "0.5.56"
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
    last = None
    for i in range(1, tries + 1):
        req = urllib.request.Request(url, method=method)
        req.add_header("Authorization", "Bearer " + TOK)
        req.add_header("User-Agent", "workbuddy-reconcile")
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
            last = e
            print("      第 %d 次失败：%s" % (i, str(e)[:80]))
            time.sleep(4)
    print("      ✗ 重试 %d 次仍失败：%s" % (tries, str(last)[:100]))
    return 0, b""


def list_releases():
    st, d = api("GET", "https://api.github.com/repos/%s/releases?per_page=100" % REPO)
    return json.loads(d) if st == 200 else []


print("① 找 %s 的 release" % TAG)
rels = list_releases()
rel = next((r for r in rels if r["tag_name"] == TAG), None)
if rel is None:
    print("  没有，创建一个")
    st, d = api("POST", "https://api.github.com/repos/%s/releases" % REPO,
                {"tag_name": TAG, "name": TAG, "body": "见仓库 CHANGELOG.md", "draft": False})
    if st not in (200, 201):
        print("  建失败：HTTP %s %s" % (st, d[:200]))
        sys.exit(1)
    rel = json.loads(d)
print("  release id=%s，现有资产 %s" % (rel["id"], [a["name"] for a in rel.get("assets", [])]))

print()
print("② 传资产（已有且大小一致的跳过）")
have = {a["name"]: a["size"] for a in rel.get("assets", [])}
for name in ASSETS:
    p = os.path.join(ROOT, name)
    if not os.path.isfile(p):
        print("  ✗ 本地没有 %s —— 先打包" % name)
        sys.exit(1)
    size = os.path.getsize(p)
    if have.get(name) == size:
        print("  ✓ %s 已存在且大小一致（%d 字节），跳过" % (name, size))
        continue
    print("  ↑ 上传 %s（%.1f MB）…" % (name, size / 1048576))
    data = open(p, "rb").read()
    url = ("https://uploads.github.com/repos/%s/releases/%s/assets?name=%s"
           % (REPO, rel["id"], urllib.parse.quote(name)))
    st, d = api("POST", url, raw=data, ctype="application/octet-stream")
    if st in (200, 201):
        print("    ✓ 上传成功")
    else:
        print("    ✗ 失败：HTTP %s %s" % (st, d[:200]))

print()
print("③ 删掉其它 Release")
for r in list_releases():
    if r["tag_name"] != TAG:
        st, _ = api("DELETE", "https://api.github.com/repos/%s/releases/%s" % (REPO, r["id"]))
        print("  删 %s → HTTP %s" % (r["tag_name"], st))

print()
print("④ 最终状态")
for r in list_releases():
    print("  %s  资产 %d 个: %s" % (r["tag_name"], len(r.get("assets", [])),
                                  sorted(a["name"] for a in r.get("assets", []))))
    print("     说明首行：%s" % (r.get("body") or "").splitlines()[0][:80])
