#!/bin/sh
# ============================================================================
# fv-njs-boot.sh —— 网关容器启动包装：**探测 njs 可用性，不可用就自动降级**
# ============================================================================
#
# 背景
# ----
# 0.5.26 起用 njs 读 POST body 里的路径，堵住「body 路径绕过」高危缺口。
# njs 是**动态模块**，必须 `load_module` 加载；而
#     ★ `load_module` 的合法上下文是 **main（主配置顶层）**
# 所以它写在**主配置** fv-main.main 里，不写在 conf.d 片段里。
#
# 风险：`load_module` 若因**模块文件缺失**而失败，nginx 会以 [emerg] 退出
# —— 整个应用打不开。因此这里提供降级：真的缺模块就剥掉它再启动。
#
# ============================================================================
# ★★★ 两个必须分清的错误（0.5.26 两轮翻车的教训都在这里）★★★
# ============================================================================
# (1) 位置错：`"load_module" directive is not allowed here`
#     → 把 load_module 写在了 conf.d 片段（http 上下文）里。**与镜像带不带 njs 无关**，
#       任何镜像都会报。修法是把指令挪到 main 层，**不是**降级。
#       （0.5.26 第一轮：误当"不含 njs"而降级，掩盖了真错。）
#
# (2) 文件缺：`dlopen() ".../ngx_http_js_module.so" failed (No such file ...)`
#     或 `module "...so" is not binary compatible` / `bind() ... unknown directive "js_import"`
#     → 这才是镜像真的没 njs，应当降级。
#
# (3) 误用 -c 指片段：`"map" directive is not allowed here`
#     → conf.d/nginx.conf 是 http 上下文片段，当主配置用必然报这个。**也不要**拿它做 -t 对象。
#       （0.5.26 第二轮前的另一处错误。）
#
# 所以：**只有 (2) 才降级**；(1)(3) 属于配置写错，必须让它原样报出来。
# ============================================================================
set -u

CONF_DIR=/etc/nginx/conf.d
MAIN_SRC="$CONF_DIR/fv-main.main"      # 我们的主配置（只读挂载，不能就地改）
WORK=/tmp/fv-conf.d                    # 可写副本目录
MAIN="$WORK/fv-main.main"              # 实际使用的主配置（走副本，见下方说明）
MAIN_FB="$WORK/fv-main-fallback.conf"  # 降级主配置（注释掉 load_module）

log() { echo "[fv-njs-boot] $*"; }

# ============================================================================
# ★ 为什么连"正常路径"也要走副本（而不是直接 -c /etc/nginx/conf.d/fv-main.main）
# ============================================================================
# 因为主配置里有一行 `include /etc/nginx/conf.d/*.conf;` —— 它是**绝对路径**。
# 降级时我们需要把 conf.d 复制到 $WORK、剥掉 njs 指令，然后让主配置 include 那个副本；
# 但若主配置写死 include /etc/nginx/conf.d/*.conf，剥掉的副本**根本不会被读到**，
# 降级就变成了"注释了个寂寞"。
# 所以统一：主配置也复制到 $WORK，并把 include 路径重写为 $WORK/*.conf。
# 这样"正常"和"降级"两条路径行为一致、都读同一份副本，差异只有 njs 指令是否保留。
# ============================================================================

# --- 探测 ngx_http_js_module.so 的真实位置 -----------------------------------
# `load_module modules/xxx.so` 的相对路径相对**编译前缀**解析（官方镜像 prefix=/etc/nginx
# → 找 /etc/nginx/modules/xxx.so）。但 .so 实际位置因发行版而异，写死就是赌。
#
# 策略：**先用 find 实际找一遍**（一次调用，定位到确切路径最优），
#       找不到再退回常见路径清单逐个试。两者都失败才认定"镜像不含 njs"。
# 容器内 find 的代价：官方 nginx 镜像文件数不多（万级），通常 1~2 秒可接受；
# 相比"误判成没 njs 而让防护失效"，这点开销完全值得。
find_js_so() {
    # 优先在 nginx 相关目录里找（快且准），找不到再全盘
    for d in /etc/nginx /usr/lib/nginx /usr/share/nginx /usr/local /usr/lib /opt; do
        [ -d "$d" ] || continue
        p="$(find "$d" -name 'ngx_http_js_module.so' -type f 2>/dev/null | head -n 1)"
        [ -n "$p" ] && { echo "$p"; return 0; }
    done
    p="$(find / -name 'ngx_http_js_module.so' -type f 2>/dev/null | head -n 1)"
    [ -n "$p" ] && { echo "$p"; return 0; }
    return 1
}

FOUND_SO="$(find_js_so || true)"
if [ -n "$FOUND_SO" ]; then
    log "在镜像里找到 njs 模块：$FOUND_SO"
else
    log "find 没有找到 ngx_http_js_module.so"
fi

# 候选顺序：① 实际 find 到的路径  ② 裸相对路径（让 nginx 按自身 prefix 解析）
#           ③ 各发行版常见绝对路径
JS_SO_CANDIDATES="${FOUND_SO}
modules/ngx_http_js_module.so
/etc/nginx/modules/ngx_http_js_module.so
/usr/lib/nginx/modules/ngx_http_js_module.so
/usr/share/nginx/modules/ngx_http_js_module.so
/usr/local/nginx/modules/ngx_http_js_module.so
/usr/local/lib/nginx/modules/ngx_http_js_module.so
"

# --- 准备工作副本 ------------------------------------------------------------
prepare_work() {
    rm -rf "$WORK"
    mkdir -p "$WORK"
    cp -a "$CONF_DIR"/. "$WORK"/ 2>/dev/null || true
    # 主配置里的 include 改指副本目录（否则降级时剥掉的副本不会被读到）
    sed -e "s|include[[:space:]]\+/etc/nginx/conf\.d/\*\.conf;|include ${WORK}/*.conf;|" \
        "$MAIN_SRC" > "$MAIN"
}

# --- 用某个候选路径生成主配置并试 -t，成功则采用 ------------------------------
try_with_so() {
    so="$1"
    # 一次性生成：把 load_module 指向候选路径，并把 include 改指副本目录
    sed -e "s|^\([[:space:]]*\)load_module[[:space:]].*|\1load_module ${so};|" \
        -e "s|include[[:space:]]\+/etc/nginx/conf\.d/\*\.conf;|include ${WORK}/*.conf;|" \
        "$MAIN_SRC" > "$MAIN"
    nginx -t -c "$MAIN" >/tmp/njs-t.log 2>&1
}

prepare_work

# ★ 曾经的 bug：判据只看 /tmp/njs-t.log —— 而它**每轮都被覆盖**，循环结束后
#   里面是**最后一个候选**的日志。最后几个候选是兜底假路径，必然 dlopen 失败，
#   于是**即使真路径已把模块加载成功**，也会被判成"镜像不含 njs"。
#   （真机现象：明明报的是 js_access 不认识，却打印"镜像确实没有 njs 模块"。）
#   现在改为：逐个分类 + 累积证据 —— 只要有**任何一次**加载成功过，就不算缺模块。
OK=0
CHOSEN=""
SAW_LOADED=0          # 出现过"模块加载成功"（报错不是 dlopen 类）
LAST_LOAD_ERR=""      # 最后一次"模块文件加载失败"的报错
CONFIG_ERR=""         # "模块加载成功但配置/版本有问题"的报错（最有价值）

# 模块**文件**加载失败的特征；其余一律视为"模块已加载，问题在配置或版本"
is_load_failure() {
    grep -qiE 'dlopen|not binary compatible|cannot open shared object|No such file|module .* is not' "$1"
}

for so in $JS_SO_CANDIDATES; do
    [ -n "$so" ] || continue
    log "尝试加载 njs 模块：$so"
    if try_with_so "$so"; then
        log "✅ 模块可加载：$so"
        OK=1
        CHOSEN="$so"
        break
    fi
    err="$(grep -m1 -oE '\[emerg\].*' /tmp/njs-t.log || echo '见日志')"
    log "   不行（${err}）"
    if is_load_failure /tmp/njs-t.log; then
        LAST_LOAD_ERR="$err"
    else
        SAW_LOADED=1
        CONFIG_ERR="$err"
    fi
done

if [ "$OK" = "1" ]; then
    log "njs 可用（模块：${CHOSEN}），使用 fv-main.main 启动（POST body 路径保护：**已开启**）"
    exec nginx -c "$MAIN" -g 'daemon off;'
fi

log "所有候选路径都没能让 nginx -t 通过。"

# --- 到底是"缺模块"还是"模块在但版本/配置不对" -------------------------------
# 只有在**没有任何一次**加载成功过时，才认定为镜像真的缺 njs。
if [ "$SAW_LOADED" != "1" ]; then
    log "最后一次的报错（${LAST_LOAD_ERR:-见日志}）："
    sed 's/^/[fv-njs-boot]   /' /tmp/njs-t.log
    log "看起来是镜像确实没有 njs 模块，准备降级配置……"
else
    log "❌ 镜像**有** njs 模块（至少有一个候选路径把它加载起来了），"
    log "    失败原因是**配置或 njs 版本**，不是缺模块："
    log "      ${CONFIG_ERR}"
    case "$CONFIG_ERR" in
      *js_access*)
        log ""
        log "    ★ 诊断：这个 njs 版本不认识 js_access 指令。"
        log "      js_access 需要 njs >= 0.9.9（2026-05-19 才发布）。"
        log "      ⚠️ 且 0.9.9 ~ 1.0.0 存在访问控制绕过漏洞 CVE-2026-18329，"
        log "         njs >= 1.0.1 才修复 —— 目标应是 **njs >= 1.0.1**。"
        ;;
    esac
    log ""
    log "    → 仍然降级（否则应用起不来），但请记住：**是镜像太旧**，不是缺模块。"
fi

# --- 降级：注释掉 njs 相关指令 ----------------------------------------------
# njs 相关的 4 类指令要一起去掉，否则 js_import 会报 unknown directive。
sed -e 's|^\([[:space:]]*\)load_module[[:space:]].*|\1# [fv-njs-boot] removed (no njs in image)|' \
    "$MAIN" > "$MAIN_FB"
sed -e 's|^\([[:space:]]*\)js_path[[:space:]].*|\1# [fv-njs-boot] removed (no njs in image)|' \
    -e 's|^\([[:space:]]*\)js_import[[:space:]].*|\1# [fv-njs-boot] removed (no njs in image)|' \
    -e 's|^\([[:space:]]*\)js_access[[:space:]].*|\1# [fv-njs-boot] removed -- DEGRADED: body path guard OFF|' \
    "$WORK/nginx.conf" > "$WORK/nginx.conf.tmp" && mv -f "$WORK/nginx.conf.tmp" "$WORK/nginx.conf"

if nginx -t -c "$MAIN_FB" >/tmp/njs-t2.log 2>&1; then
    log "================================================================"
    if [ "$SAW_LOADED" = "1" ]; then
        log "⚠️  WARN：镜像**有 njs**，但这个 njs 版本用不了 —— 已降级为"
        log "           **无 body 路径保护**的配置。"
    else
        log "⚠️  WARN：网关镜像不含 njs，已降级为**无 body 路径保护**的配置。"
    fi
    log ""
    log "    含义：「POST body 路径绕过」这个高危缺口**当前是敞开的** ——"
    log "    任意已登录用户可用 POST 读出别人的私有文件（详见 SECURITY.md §6）。"
    log ""
    log "    修法：换一个 **njs >= 1.0.1** 的网关镜像并重启本容器。"
    log "      · js_access 自 njs 0.9.9 才有；而 0.9.9 ~ 1.0.0 存在访问控制"
    log "        绕过漏洞 CVE-2026-18329，njs 1.0.1 才修好。"
    log "      · 换镜像后重启本容器，看上面几行日志即可判断："
    log "          出现「POST body 路径保护：**已开启**」= 成功。"
    log "          仍出现 js_access 报错 = 那个镜像的 njs 还不够新。"
    log ""
    log "    降级主配置：$MAIN_FB"
    log "================================================================"
    exec nginx -c "$MAIN_FB" -g 'daemon off;'
fi

log "❌ 降级配置语法检查也失败："
sed 's/^/[fv-njs-boot]   /' /tmp/njs-t2.log
log "    说明问题**不在 njs**（剥掉 njs 指令后仍不合法）—— 多半是配置本身写错了。"
log "    请对照报错行："
log "      · \"load_module\" directive is not allowed here → 它必须放在 main 层"
log "      · \"map\"/\"server\" directive is not allowed here → 不要把 conf.d 片段当主配置"
log "      · duplicate location / unexpected \"}\"          → 片段本身有语法错"
log "    改用主配置启动，请把上面日志发出来定位。"
exec nginx -c "$MAIN" -g 'daemon off;'
