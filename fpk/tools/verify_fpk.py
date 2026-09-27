"""校验 .fpk 安装包的内部结构 —— 只依赖标准库。

为什么要校验：
  fnpack 打包时会把 app.tgz 的 MD5 写进 manifest 的 checksum 字段，飞牛安装时做完整性校验。
  所以「包里到底装了什么」必须解开来看，不能只看文件大小。
  实际上正是这个脚本抓到过两次问题：
    ① manifest 里还是旧版本号（产物被写到别的目录、又把旧包覆盖回来）；
    ② app/lib/ 下的共享库被 fnpack 整目录丢弃（app.tgz 只收 docker/、ui/、config/）。

用法：
  python fpk/tools/verify_fpk.py                    # 默认校验 ../basemetas-fileview.fpk
  python fpk/tools/verify_fpk.py 路径/xxx.fpk
"""

import gzip
import hashlib
import io
import os
import re
import sys
import tarfile

DEFAULT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "basemetas-fileview.fpk")
)


def main() -> int:
    fpk = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    if not os.path.isfile(fpk):
        print(f"找不到文件：{fpk}")
        return 2

    with gzip.open(fpk, "rb") as f:
        raw = f.read()

    tf = tarfile.open(fileobj=io.BytesIO(raw))
    names = tf.getnames()
    print("== 顶层条目 ==")
    for n in names:
        print("  ", n)

    app_member = next((n for n in names if os.path.basename(n) == "app.tgz"), None)
    if app_member is None:
        print("\n❌ 包内没有 app.tgz，这不是一个正常的 fpk")
        return 1
    print("\napp.tgz =", app_member)

    data = tf.extractfile(app_member).read()
    print("\n== app.tgz 内容 ==")
    with tarfile.open(fileobj=io.BytesIO(data)) as itf:
        for n in itf.getnames():
            print("  ", n)

    md5 = hashlib.md5(data).hexdigest()
    mf = tf.extractfile(next(n for n in names if os.path.basename(n) == "manifest")).read()
    mf = mf.decode("utf-8", "replace")
    m = re.search(r"checksum\s*=\s*(\S+)", mf)
    declared = m.group(1) if m else "(无)"
    ok = bool(m) and declared.strip() == md5

    print("\nmanifest.checksum =", declared)
    print("app.tgz 实际 md5   =", md5)
    print("一致 :", ok)

    ver = re.search(r"^version\s*=\s*(\S+)", mf, re.M)
    print("version            =", ver.group(1) if ver else "(无)")

    print("\n== manifest ==")
    print(mf)

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
