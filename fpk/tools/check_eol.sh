#!/bin/bash
# 打包前检查：app 目录里所有文本文件必须是 LF 行尾。
#
# 为什么必须有这道检查 —— 这是唯一能让 .fpk「仓库干净但包是坏的」的构建陷阱：
#   Windows 上 core.autocrlf=true 时，Git 提交会把 CRLF 归一成 LF **存进仓库**，
#   但**工作区里的文件仍然是 CRLF**；而 fnpack 打的是工作区。
#   于是 git status 一片干净，.fpk 里却混进了 CRLF 的 shell 脚本。在 Linux 上表现为
#     · shebang 变成 `#!/bin/bash\r` → `bad interpreter: No such file or directory`
#     · 更隐蔽：变量值末尾多一个 \r，`docker rm -f "$PROJ-engine"` 之类**静默失败**
#
# 用法： bash fpk/tools/check_eol.sh [目录]     有 CRLF 时退出码非 0 并列出文件
#
# 注意：本脚本只检查**工作区源码**。打包后 .fpk 里的 manifest 会变成 CRLF ——
#       那是 fnpack 自己重写 manifest（追加 checksum 字段）时的行为，历来如此，
#       飞牛能正常解析，不用管。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${1:-$HERE/../basemetas-fileview}"
[ -d "$DIR" ] || { echo "目录不存在：$DIR"; exit 2; }

bad=""
while IFS= read -r f; do
  # 二进制跳过：它们的字节里天然可能含 0x0D
  case "$f" in *.png|*.PNG|*.jpg|*.jpeg|*.ico|*.exe|*.fpk|*.gz) continue ;; esac
  # ⚠️ 不要用 `wc -c` + `tr -d '\r' | wc -c` 两趟外部命令来比对长度 ——
  #    在 Windows Git Bash 上每个文件要起 3~4 个进程，27 个文件就要 **50 多秒**
  #    （sys 时间几乎全是进程创建），selfcheck 会看起来像卡死。
  #
  # ⚠️ 也不要用 `grep -q $'\r'` —— 在 Git Bash 里 `$'\r'` 会被处理掉，
  #    导致**含 CRLF 的文件检不出来**（假阴性，比慢更糟：包会带着坏行尾发出去）。
  #
  # 正确做法：bash 内建读入，用字面 CR 做模式匹配（零子进程、无外部工具依赖）。
  #   注意不能用 `$(<"$f")` —— 命令替换会把行尾的 CR 一起吃掉，同样检不出来。
  content=""
  IFS= read -r -d '' content < "$f" 2>/dev/null || true
  case "$content" in
    *$'\r'*) bad="${bad}${f}
" ;;
  esac
done < <(find "$DIR" -type f)

if [ -n "$bad" ]; then
  echo "❌ 以下文件含 CRLF 行尾，不能打包："
  printf '%s' "$bad" | sed 's/^/   /'
  echo
  echo "   修：转成 LF 后重试，例如"
  echo "     sed -i 's/\\r\$//' <文件>"
  exit 1
fi

echo "✅ 行尾检查通过（全部 LF）"
exit 0
