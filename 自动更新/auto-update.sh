#!/bin/bash
# =============================================================================
# FileView 预览（basemetas-fileview）自动更新脚本
#
# 用途：检查你自建发布点上是否有新的 .fpk，有就下载并静默安装。
# 配合飞牛「系统设置 → 计划任务」按天/按周执行即可。
#
# 为什么需要这个脚本：
#   飞牛应用设置里那个「自动更新应用」开关，只对**在应用中心上架**的应用有效 ——
#   官方 manifest 里没有任何"更新源/更新地址"字段，只有 changelog（更新说明）。
#   我们是手动安装的 thirdparty 包，飞牛无从检查新版本，所以开关对本应用无效。
#   官方给的可脚本化入口是 `appcenter-cli install-fpk`，本脚本就是围绕它做的。
#
# ⚠️ 首次使用前，请把下面「需要你确认」的四项改成你自己的值。
# ⚠️ 本脚本未在真机验证过（我这边无法执行 appcenter-cli）。
#    第一次请手动跑一遍看日志，确认无误再挂到计划任务。
# =============================================================================

set -uo pipefail

# ---------------- 需要你确认的四项 ----------------
# 发布点根地址：下面要放 version.txt（纯文本，内容就是版本号）和 basemetas-fileview.fpk
# 例：https://nas.example.com/pkg/fileview  （用你自己的静态服务器/对象存储/网盘直链均可）
UPDATE_BASE="${UPDATE_BASE:-https://请替换成你的发布点/fileview}"

# 工作目录（存放下载的 fpk、日志、状态文件）
WORKDIR="${WORKDIR:-/vol1/1000/docker/fileview-update}"

# 安装向导的答案文件（自动安装时非交互传入，必须提供，否则会卡在向导）
ENV_FILE="${ENV_FILE:-$WORKDIR/config.env}"

# 应用名（与 manifest 里的 appname 一致，一般不用改）
APPNAME="basemetas-fileview"
# --------------------------------------------------

PKG_NAME="$APPNAME.fpk"
LOG="$WORKDIR/auto-update.log"
STATE="$WORKDIR/last-installed-version"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [auto-update] $*" | tee -a "$LOG"; }
die() { log "错误：$*"; exit 1; }

mkdir -p "$WORKDIR"
touch "$LOG"

log "===== 开始检查更新 ====="

# ---------- 1. 取远端版本号 ----------
REMOTE_VER="$(curl -fsSL --max-time 30 "$UPDATE_BASE/version.txt" 2>>"$LOG" | tr -d '[:space:]')"
if [ -z "${REMOTE_VER:-}" ]; then
  die "取不到远端版本号：$UPDATE_BASE/version.txt"
fi
log "远端版本：$REMOTE_VER"

# ---------- 2. 取本机已装版本 ----------
# 优先问 appcenter-cli；解析失败则退回上次成功安装时记录的状态文件
INSTALLED_VER="$(appcenter-cli list 2>>"$LOG" | grep -i "$APPNAME" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true)"
if [ -z "${INSTALLED_VER:-}" ] && [ -f "$STATE" ]; then
  INSTALLED_VER="$(tr -d '[:space:]' < "$STATE")"
  log "appcenter-cli 解析失败，改用状态文件记录的版本"
fi
if [ -z "${INSTALLED_VER:-}" ]; then
  log "判断不出已装版本（可能尚未安装）。为安全起见本次不自动安装，请手动装一次。"
  exit 0
fi
log "本机版本：$INSTALLED_VER"

# ---------- 3. 比对 ----------
if [ "$REMOTE_VER" = "$INSTALLED_VER" ]; then
  log "已是最新，无需更新"
  exit 0
fi
log "发现新版本：$INSTALLED_VER → $REMOTE_VER"

# ---------- 4. 下载并校验是真正的 gzip（避免下到错误页/HTML） ----------
TMP="$WORKDIR/$PKG_NAME.new"
curl -fsSL --max-time 300 -o "$TMP" "$UPDATE_BASE/$PKG_NAME" 2>>"$LOG" || die "下载失败：$UPDATE_BASE/$PKG_NAME"
MAGIC="$(od -An -tx1 -N2 "$TMP" 2>/dev/null | tr -d ' \n')"
if [ "$MAGIC" != "1f8b" ]; then
  rm -f "$TMP"
  die "下载到的不是 gzip 格式的 .fpk（魔数=$MAGIC），已丢弃"
fi
log "下载完成：$(du -h "$TMP" | cut -f1)，魔数 1f8b 正确"

# ---------- 5. 安装 ----------
if [ ! -f "$ENV_FILE" ]; then
  die "缺少向导答案文件：$ENV_FILE（至少要有 wizard_volumes=/vol1,/vol2 一行）"
fi

FINAL="$WORKDIR/$PKG_NAME"
mv -f "$TMP" "$FINAL"

if appcenter-cli install-fpk "$FINAL" --env "$ENV_FILE" >>"$LOG" 2>&1; then
  echo "$REMOTE_VER" > "$STATE"
  log "安装成功，已记录版本 $REMOTE_VER"
else
  die "安装失败，详见 $LOG（版本状态未更新，下次会重试）"
fi

log "===== 结束 ====="
