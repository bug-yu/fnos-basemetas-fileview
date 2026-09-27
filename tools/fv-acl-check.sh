#!/bin/bash
#
# 逐用户文件权限校验 —— 可行性验证（在飞牛 NAS 上用 root 执行）
#
# 要验证什么：
#   FileView 现在能预览任意已挂载卷里的文件，是因为容器以 root 读文件、绕过了飞牛的 ACL。
#   要做到「按用户区分」，需要能在服务端回答「这个用户能不能读这个文件」。
#   飞牛自 v1.2.0 起存储空间使用 Windows ACL。**如果它在 VFS 层生效**，那么
#
#       docker exec -u <uid> basemetas-fileview-engine test -r <path>
#
#   就能给出正确答案 —— 让容器内以该 uid 执行，权限判定照常生效。
#   这条成立，闸门就能做（不需要开放 API、不需要 token、不需要 root、不需要新镜像）。
#   不成立，就只能退回「网关级用户白名单」（只让管理员或指定 uid 使用本应用）。
#
# 用法：
#   bash fv-acl-check.sh                        # 自动挑一个文件来测
#   bash fv-acl-check.sh /vol1/1000/某个文件     # 指定文件
#   bash fv-acl-check.sh /vol1/1000/某个文件 1000 1001 1003
#
# 只读：全程只执行 test -r / ls / stat，不读写任何文件。

set -u

ENGINE="${ENGINE:-basemetas-fileview-engine}"
CONTROL="/etc/hostname"          # 容器内人人可读的文件，用来验证「机制本身」是否正常

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31m[!!]\033[0m   %s\n' "$1"; }
inf()  { printf '  %s\n' "$1"; }

command -v docker >/dev/null 2>&1 || { echo "找不到 docker 命令。"; exit 1; }
docker inspect "$ENGINE" >/dev/null 2>&1 || { echo "找不到容器 $ENGINE，请确认应用已启动。"; exit 1; }

# ---------------------------------------------------------------------------
say "0. 对照组：验证 test -r 机制本身是否正常"
# 容器内 /etc/hostname 一般是 0644，任何 uid 都该能读。
# 如果连它都「不可读」，说明机制没按预期工作（例如容器用了 userns），后面的结论都不可信。
if docker exec -u 1001 "$ENGINE" test -r "$CONTROL" 2>/dev/null; then
  ok "uid 1001 能读 $CONTROL —— test -r 机制正常"
  CONTROL_OK=1
else
  bad "uid 1001 读不了 $CONTROL —— 机制异常，下面的结果不可信"
  inf "  可能原因：容器启用了 user namespace（uid 映射不一致），或镜像里没有 /etc/hostname"
  CONTROL_OK=0
fi

# ---------------------------------------------------------------------------
say "1. 选测试文件"
F="${1:-}"
if [ -z "$F" ]; then
  inf "未指定文件，自动从 /vol1/1000、/vol1/1000 里挑第一个普通文件"
  F="$(find /vol1/1000 -maxdepth 4 -type f -print 2>/dev/null | head -n 1)"
  [ -n "$F" ] || F="$(find /vol1/1000 -maxdepth 4 -type f -print 2>/dev/null | head -n 1)"
fi
if [ -z "$F" ] || [ ! -e "$F" ]; then
  bad "找不到可用文件：${F:-（空）}"
  inf "  请手动指定： bash fv-acl-check.sh /vol1/1000/你的某个文件"
  exit 1
fi
ok "测试文件：$F"
ls -l "$F" | sed 's/^/     /'
OWNER_UID="$(stat -c %u "$F" 2>/dev/null || echo 0)"
inf "属主 uid = $OWNER_UID（末尾带 + 表示该文件有扩展 ACL）"

# ---------------------------------------------------------------------------
say "2. 逐个 uid 实测（属主 / 其它用户）"
UIDS="${*:2}"
[ -n "$UIDS" ] || UIDS="$OWNER_UID 1001 1003"

READABLE_LIST=""
for u in $UIDS; do
  printf '  uid=%-6s ' "$u"
  if docker exec -u "$u" "$ENGINE" test -r "$F" 2>/dev/null; then
    echo "可读"
    READABLE_LIST="$READABLE_LIST $u"
  else
    echo "不可读"
  fi
done

# ---------------------------------------------------------------------------
say "3. 结论"
if [ "$CONTROL_OK" != "1" ]; then
  bad "机制本身异常，先解决上面第 0 节的问题再看结论。"
  exit 1
fi

OWNER_READABLE=0
case " $READABLE_LIST " in *" $OWNER_UID "*) OWNER_READABLE=1 ;; esac
COUNT=$(printf '%s' "$READABLE_LIST" | wc -w | tr -d ' ')

if [ "$OWNER_READABLE" = "1" ] && [ "$COUNT" = "1" ]; then
  ok "属主可读、其它用户不可读 —— **VFS 层的 ACL 判定可靠**"
  inf "  ⇒ 可以做「按用户区分预览权限」的闸门："
  inf "     每个请求用 X-Trim-Userid + 目标 path 做一次 test -r，不可读就 403"
elif [ "$COUNT" = "0" ]; then
  bad "所有 uid 都不可读 —— 这个文件本身可能就没人能读（或路径/权限特殊）"
  inf "  换一个你确定自己能打开的文件再试一次，别急着下结论"
elif [ "$COUNT" -ge 2 ]; then
  bad "多个 uid 都能读 —— **ACL 没有在挂载卷的 VFS 层生效**"
  inf "  ⇒ 逐用户校验这条路走不通，只能退回「网关级用户白名单」"
  inf "     （nginx 按 X-Trim-Userid / X-Trim-Isadmin 放行，只让管理员或指定 uid 使用本应用）"
fi

printf '\n'
inf "把完整输出发出来即可定方案。"
