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


def git(*args):
    """跑一条 git 命令，返回 (退出码, stdout, stderr)。"""
    p = subprocess.run(["git"] + list(args), cwd=ROOT,
                       capture_output=True, text=True, timeout=180)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def remote_tag_sha(tag):
    """远端同名 tag 指向的**提交**（注解 tag 取 peeled 值）；不存在返回 None。"""
    rc, out, _ = git("ls-remote", "--tags", "origin",
                     "refs/tags/%s" % tag, "refs/tags/%s^{}" % tag)
    if not out:
        return None
    plain = None
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        sha, ref = parts
        if ref.endswith("^{}"):
            return sha          # peeled = 真正的提交对象
        plain = sha
    return plain


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
    """从 CHANGELOG 该版本小节里取正文（Release 说明 = 给别人看的，不放排查过程）。"""
    text = open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8").read()
    m = re.search(r"^## %s\s*$" % re.escape(ver), text, re.M)
    if not m:
        return "见仓库 CHANGELOG.md"
    rest = text[m.end():]
    nxt = re.search(r"^## ", rest, re.M)
    return (rest[:nxt.start()] if nxt else rest).strip()


def main():
    if len(sys.argv) < 2:
        print("用法: python release.py <版本号>")
        return 1
    ver = sys.argv[1].lstrip("v")
    tag = "v" + ver

    # ⚠️⚠️ 发版前必须确认「分支已推送」+「tag 指向 HEAD」——
    #     GitHub 建 Release 时如果不给 target_commitish，就会把 tag 落在
    #     **远端默认分支当时的位置**上；而远端可能还停在旧提交 ✗
    #     0.5.58 就这么踩过：本地已提交「删 CAD」，但没 push → tag 钉在了
    #     删 CAD **之前**的提交上 → Release 的源码包是旧代码（README 还是旧的）✗
    rc, head_sha, _ = git("rev-parse", "HEAD")
    if rc != 0 or not head_sha:
        print("❌ 取不到 HEAD（不在 git 仓库里？）")
        return 1

    rc, ahead, _ = git("log", "--oneline", "@{u}..HEAD")
    if ahead:
        print("❌ 有**未推送**的提交 —— 远端默认分支还停在旧位置：")
        for line in ahead.splitlines():
            print("     " + line)
        print("   先 `git push origin <分支>` 再发版，否则 tag 会建在旧提交上 ✗")
        return 1

    st, me = api("GET", "https://api.github.com/user")
    print("凭据：HTTP %s（%s）" % (st, me.get("login") if st == 200 else str(me)[:120]))
    if st != 200:
        return 1

    # ⚠️⚠️⚠️ 顺序很关键：**必须先删掉已有的 Release，再动 tag** ✗
    #   只要一个 tag 上**挂着 Release**，无论你是「删掉 tag」还是「push -f 移动 tag」，
    #   GitHub 都会把这个 Release 改成 `untagged-<hash>`（**丢掉 tag 关联**）✗
    #   而且改名是**异步**的 —— 用 API PATCH 把 tag_name 改回去，过一会儿还会被再改一次 ✗
    #   （cadviewer 0.4.3 连踩两次：先删 tag → 游离；改成 push -f → **还是**游离）
    #   所以：先把 Release 删掉（此时 tag 上没有挂东西）→ 再动 tag → 最后重建 Release ✓
    st, rel = api("GET", "https://api.github.com/repos/%s/releases/tags/%s" % (REPO, tag))
    if st == 200:
        print("已存在 Release id=%s，先删重建（幂等）" % rel["id"])
        api("DELETE", "https://api.github.com/repos/%s/releases/%s" % (REPO, rel["id"]))
    elif st != 404:
        print("查询异常 HTTP %s" % st)
        return 1

    # 顺手清理历史遗留的游离 Release（tag 被改名后留下的 `untagged-*`，
    # 里面若含本应用的资产，就一并删掉，别在 Release 页上堆着）
    # ⚠️ 注意 `api()` **已经把 JSON 解析好了**（返回 list/dict，不是 bytes）——
    #    再套一层 `json.loads` 会报 "not list" ✗（0.5.59 就这么崩过一次，
    #    而且是在**删掉 Release 之后**崩的 → 留下一个没有 Release 的 tag ✗）
    st, rels = api("GET", "https://api.github.com/repos/%s/releases?per_page=100" % REPO)
    if not isinstance(rels, list):
        print("   ⚠️ 取 Release 列表失败（HTTP %s），跳过清理与去重" % st)
        rels = []
    for x in rels:
        if str(x.get("tag_name", "")).startswith("untagged-"):
            names = [a["name"] for a in x.get("assets", [])]
            if any(n.startswith("basemetas-fileview-") for n in names):
                api("DELETE", "https://api.github.com/repos/%s/releases/%s"
                    % (REPO, x["id"]))
                print("   🧹 清掉游离 Release id=%s（%s）" % (x["id"], x["tag_name"]))

    old = remote_tag_sha(tag)
    if old != head_sha:
        rc, _, err = git("tag", "-f", tag, head_sha)
        if rc != 0:
            print("❌ 本地 tag 重指失败：%s" % err[:200])
            return 1
        rc, _, err = git("push", "-f", "origin", tag)
        if rc != 0:
            print("❌ 推 tag 失败：%s" % err[:200])
            return 1
        print("   ✅ tag %s → %s（原 %s）" % (tag, head_sha[:8], (old or "无")[:8]))
    else:
        print("   ✅ tag %s 已指向 HEAD（%s）" % (tag, head_sha[:8]))

    body = one_line(ver)
    st, rel = api("POST", "https://api.github.com/repos/%s/releases" % REPO, {
        "tag_name": tag, "name": tag, "body": body,
        "target_commitish": head_sha,      # ★ 显式钉到 HEAD，别让 GitHub 猜
        "draft": False, "prerelease": False,
    })
    if st not in (200, 201):
        print("❌ 建 Release 失败 HTTP %s：%s" % (st, str(rel)[:300]))
        return 1
    print("✅ Release 已建：%s" % rel["html_url"])
    print("   说明：%s" % body.splitlines()[0][:70])

    # 去重自愈：同一个 tag 上**只应有一个 Release**。
    # 一旦出现过「GET /releases/tags/<tag> 返回 404、于是又建了一个」的情况，
    # 就会留下两个同名 Release ✗ —— 这里把除刚建的这个以外的都删掉 ✓
    st, again = api("GET", "https://api.github.com/repos/%s/releases?per_page=100" % REPO)
    if isinstance(again, list):
        for x in again:
            if x.get("tag_name") == tag and x["id"] != rel["id"]:
                api("DELETE", "https://api.github.com/repos/%s/releases/%s"
                    % (REPO, x["id"]))
                print("   🧹 清掉重复的 %s Release id=%s" % (tag, x["id"]))

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
