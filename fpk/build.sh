#!/bin/bash
# 在飞牛 NAS（或任意 Linux）上重新打包。
# 准备：把官方 Linux 版 fnpack 放到 tools/fnpack 并 chmod +x
#   下载：https://static2.fnnas.com/fnpack/fnpack-1.2.3-linux-amd64
#
# 重要：打包后不要对 .fpk 做任何修改。fnpack 会在打包时把 app.tgz 的 MD5
#       写进 manifest 的 checksum 字段，任何后处理都会破坏这个校验关系。
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ ! -x "$HERE/tools/fnpack" ]; then
  echo "缺少 tools/fnpack 或没有可执行权限。"
  echo "请下载官方版本并授权："
  echo "  curl -L -o tools/fnpack https://static2.fnnas.com/fnpack/fnpack-1.2.3-linux-amd64"
  echo "  chmod +x tools/fnpack"
  exit 1
fi

echo "[1/2] 检查行尾（CRLF 的脚本会让回调在 Linux 上静默失效）"
bash "$HERE/tools/check_eol.sh" "$HERE/basemetas-fileview" || exit 1

echo "[2/2] 调用飞牛官方 fnpack 打包"
cd "$HERE"
"$HERE/tools/fnpack" build --directory "$HERE/basemetas-fileview"

if [ ! -f "$HERE/basemetas-fileview.fpk" ]; then
  echo "未找到产出的 fpk，请检查 fnpack 输出。"
  exit 1
fi

mv -f "$HERE/basemetas-fileview.fpk" "$HERE/../basemetas-fileview.fpk"
echo
echo "完成：$HERE/../basemetas-fileview.fpk"
echo "注意：不要对生成的 fpk 做任何后处理，manifest 里的 checksum 校验会被破坏。"
