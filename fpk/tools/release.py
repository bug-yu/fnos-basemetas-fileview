# -*- coding: utf-8 -*-
"""给指定版本建 GitHub Release 并上传 .fpk 资产（token 从 git 凭据助手现取）。

用法： python release.py <版本号>      例如 python release.py 0.5.36
说明： Release 说明取「一句话 + 指向本地详细记录」（用户的记录约定：GitHub 简略）。
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "bug-yu/fnos-basemetas-fileview"
ROOT = r"C:\Users\yang\WorkBuddy AI\2026-09-27-09-07-41\fnos-basemetas-fileview"


def token():
    p = subprocess.run(["git", "credential", "fill"], cwd=ROOT,
                       input="protocol=https\nhost=github.com\n\n",
                       capture_output=True, text=True, timeout=90)
    for line in p.stdout.splitlines():
        if line.startswith("password="):
            return line[len("password="):].strip()
    raise SystemExit("取不到凭据（git credential fill 没给出 password）")


TOK = token()


def api(method, url, payload=None, raw=None, ctype="application/json"):
    if raw is not None:
        body, ct = raw, ctype
    elif payload is not None:
        body, ct = json.dumps(payload).encode("utf-8"), "application/json"
    else:
        body, ct = None, None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", "Bearer " + TOK)
    req.add_header("User-Agent", "workbuddy-release")
    req.add_header("Accept", "application/vnd.github+json")
    if ct:
        req.add_header("Content-Type", ct)
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            data = r.read()
            return r.status, (json.loads(data) if data else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def one_line(ver):
    """从 CHANGELOG 该版本小节里取第一段非标题文字，作为 Release 的一句话说明。"""
    text = open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8").read()
    m = re.search(r"^## %s\s*$" % re.escape(ver), text, re.M)
    if not m:
        return "见仓库 CHANGELOG.md"
    rest = text[m.end():]
    nxt = re.search(r"^## ", rest, re.M)
    body = rest[:nxt.start()] if nxt else rest
    for para in [p.strip() for p in body.split("\n\n")]:
        if not para or para.startswith("#") or para.startswith("|") or para.startswith("---"):
            continue
        return para.replace("\n", "")
    return "见仓库 CHANGELOG.md"


def main():
    if len(sys.argv) < 2:
        print("用法: python release.py <版本号>")
        return 1
    ver = sys.argv[1].lstrip("v")
    tag = "v" + ver

    st, me = api("GET", "https://api.github.com/user")
    print("凭据：HTTP %s（%s）" % (st, me.get("login") if st == 200 else str(me)[:120]))
    if st != 200:
        return 1

    st, rel = api("GET", "https://api.github.com/repos/%s/releases/tags/%s" % (REPO, tag))
    if st == 200:
        print("已存在 Release id=%s，先删重建（幂等）" % rel["id"])
        api("DELETE", "https://api.github.com/repos/%s/releases/%s" % (REPO, rel["id"]))
    elif st != 404:
        print("查询异常 HTTP %s" % st)
        return 1

    body = one_line(ver) + "\n\n> 详细的排查过程与证据链保存在本地笔记，不入库。"
    st, rel = api("POST", "https://api.github.com/repos/%s/releases" % REPO, {
        "tag_name": tag, "name": tag, "body": body,
        "draft": False, "prerelease": False,
    })
    if st not in (200, 201):
        print("❌ 建 Release 失败 HTTP %s：%s" % (st, str(rel)[:300]))
        return 1
    print("✅ Release 已建：%s" % rel["html_url"])
    print("   说明：%s" % body.splitlines()[0][:70])

    rid, ok = rel["id"], 0
    for variant in ("desktop", "browser"):
        name = "basemetas-fileview-%s-%s.fpk" % (ver, variant)
        path = os.path.join(ROOT, name)
        if not os.path.isfile(path):
            print("  ⚠️ 缺文件：%s" % name)
            continue
        data = open(path, "rb").read()
        st, res = api("POST",
                      "https://uploads.github.com/repos/%s/releases/%s/assets?name=%s"
                      % (REPO, rid, name),
                      raw=data, ctype="application/octet-stream")
        print("  %s %s（%d 字节）" % ("✅" if st in (200, 201) else "❌", name, len(data)))
        if st in (200, 201):
            ok += 1
    print("上传成功 %d 个资产" % ok)
    return 0 if ok == 2 else 1


if __name__ == "__main__":
    sys.exit(main())
