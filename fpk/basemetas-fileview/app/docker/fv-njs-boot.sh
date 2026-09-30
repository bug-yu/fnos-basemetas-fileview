#!/bin/sh
# ============================================================================
# fv-njs-boot.sh —— 网关容器启动包装：**探测 njs 可用性，不可用就自动降级**
# ============================================================================
#
# 为什么需要它
# ------------
# 0.5.26 起 nginx.conf 用了 njs（load_module / js_import / js_access）去读 POST
# body 里的路径，堵住「body 路径绕过」这个高危缺口。
#
# 但 `load_module modules/ngx_http_js_module.so;` 有个要命的性质：
# **加载失败会让 nginx 直接以 [emerg] 退出** —— 整个应用打不开。
# 而"镜像里到底有没有 njs"这件事，官方文档只明确说过 `nginx:latest` 有
# （`docker run nginx:latest /usr/bin/njs -V`），alpine 变体与各个版本标签都没承诺。
#
# 所以这里**不赌**：启动前先真正试一次，
#   能加载 → 直接用镜像默认主配置启动（有 body 路径保护）
#   不能   → 剥掉 njs 指令后用一份临时主配置启动（回到 0.5.25 的防护水平）
# 两种情况下应用都能正常打开，且会**明确打印当前处于哪个模式**，避免"以为有防护
# 其实没有"。
#
# ⚠️ 降级模式是有漏洞的（POST body 绕过重新可用），日志会打 WARN 并给出怎么办。
#
# ============================================================================
# ★★ 关键陷阱（0.5.26 首版就是在这里翻车的，务必看完再改）★★
# ============================================================================
# 本文件 /etc/nginx/conf.d/nginx.conf 是**「conf.d 片段」**，内容是
# **http 块上下文**的指令（第 13 行就直接写 `map {}`），**不是主配置**。
#
#   ① 绝不能 `nginx -c /etc/nginx/conf.d/nginx.conf` ——
#      那等于把它当主配置，`map` 会出现在 http 之外，立刻报
#          nginx: [emerg] "map" directive is not allowed here in .../nginx.conf:13
#      而这个报错**与 njs 有没有无关**，所以探测永远"失败"、必然崩 → 无限重启。
#      （真机日志正是这一句，见 CHANGELOG 0.5.26 修订记录。）
#
#   ② 正确做法（本脚本采用的）：
#      正常路径 —— 什么都不传，用镜像自带的 /etc/nginx/nginx.conf，
#                  它本来就有 `include /etc/nginx/conf.d/*.conf;`，天然把
#                  我们的片段放在 http 上下文里。**这条路径零风险、最贴近原生。**
#      降级路径 —— 把 conf.d 复制到 /tmp/conf.d（只读挂载改不了原目录），
#                  在副本上剥掉 njs 指令，再写一份最小主配置 include 副本目录，
#                  用 `nginx -c` 启动。
# ============================================================================
set -u

CONF_DIR=/etc/nginx/conf.d
ORIG="$CONF_DIR/nginx.conf"            # http 上下文片段（只读挂载）
WORK=/tmp/fv-conf.d                    # 可写的副本目录
FRAG_FB="$WORK/nginx.conf"             # 副本里被剥过 njs 的片段
MAIN_FB=/tmp/fv-main-fallback.conf     # 降级主配置

log() { echo "[fv-njs-boot] $*"; }

# --- 生成降级片段：把 njs 相关指令注释掉 -------------------------------------
# js_access 必须一起删：它引用的 bodyguard 来自被删掉的 js_import，
# 留着会报 "js_access" directive is unknown 之类。
make_fallback_frag() {
    mkdir -p "$WORK"
    # 先把整个 conf.d 复制一份（可能还有别的 .conf，别漏）
    cp -a "$CONF_DIR"/. "$WORK"/ 2>/dev/null || true
    sed -e 's|^\([[:space:]]*\)load_module[[:space:]]\+modules/ngx_http_js_module\.so;.*|\1# [fv-njs-boot] removed (no njs in image)|' \
        -e 's|^\([[:space:]]*\)js_path[[:space:]].*|\1# [fv-njs-boot] removed (no njs in image)|' \
        -e 's|^\([[:space:]]*\)js_import[[:space:]].*|\1# [fv-njs-boot] removed (no njs in image)|' \
        -e 's|^\([[:space:]]*\)js_access[[:space:]].*|\1# [fv-njs-boot] removed -- DEGRADED: body path guard OFF|' \
        "$ORIG" > "$FRAG_FB"
}

# --- 生成降级主配置 ----------------------------------------------------------
write_main_fallback() {
    cat > "$MAIN_FB" <<EOF
# 由 fv-njs-boot.sh 生成 —— 仅供降级启动使用，不要手改
worker_processes auto;
error_log /dev/stderr warn;
pid /tmp/fv-nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log    /dev/stdout;

    include $WORK/*.conf;
}
EOF
}

# --- 判定：实测"含 njs 的完整配置"能不能加载 ---------------------------------
# 用镜像默认主配置（`nginx -t` 不带 -c）—— 这条命令同时验证了
#   片段位置正确 与 njs 能否 load_module，是最贴近真实启动的判据。
MODE=njs
if ! nginx -t >/tmp/njs-t.log 2>&1; then
    log "完整配置（含 njs）检查未通过："
    sed 's/^/[fv-njs-boot]   /' /tmp/njs-t.log
    MODE=fallback
fi

if [ "$MODE" = njs ]; then
    log "njs 可用，使用镜像默认主配置启动（POST body 路径保护：**已开启**）"
    exec nginx -g 'daemon off;'
fi

# --- 降级路径 ----------------------------------------------------------------
# 只有"确实是 njs 加载/指令问题"才降级；若是别的语法错，降级也救不了，
# 应当照常暴露错误（避免把真正的配置错误掩盖过去）。
if ! grep -qiE 'js_module|unknown directive "js_|load_module' /tmp/njs-t.log; then
    log "❌ 失败原因看起来**不是** njs（上面的报错里没有 js_module / js_* 关键字）。"
    log "    这意味着配置本身有别的问题，降级不会解决。"
    log "    仍用完整配置启动，让它把错误打全（容器会退出，请把日志发出来）。"
    exec nginx -g 'daemon off;'
fi

log "看起来是镜像不含 njs。准备降级配置……"
make_fallback_frag
write_main_fallback
if nginx -t -c "$MAIN_FB" >/tmp/njs-t2.log 2>&1; then
    log "================================================================"
    log "⚠️  WARN：网关镜像不含 njs，已降级为**无 body 路径保护**的配置。"
    log "    含义：「POST body 路径绕过」这个高危缺口**当前是敞开的** ——"
    log "    任意已登录用户可用 POST 读出别人的私有文件（详见 SECURITY.md §6）。"
    log ""
    log "    修法二选一："
    log "      a) 把 gateway 的 image 换成带 njs 的官方镜像（推荐 nginx:latest，"
    log "         官方文档明确它有 njs），然后重启本容器。自查："
    log "             docker run --rm nginx:latest /usr/bin/njs -V"
    log "      b) 若因故必须用当前镜像，则本项目暂不具备防护能力，"
    log "         应改用网关级用户白名单限制可用人群。"
    log ""
    log "    降级片段：$FRAG_FB   降级主配置：$MAIN_FB"
    log "================================================================"
    exec nginx -c "$MAIN_FB" -g 'daemon off;'
fi

log "❌ 降级配置语法检查也失败："
sed 's/^/[fv-njs-boot]   /' /tmp/njs-t2.log
log "    改用完整配置启动，请把上面日志发出来定位。"
exec nginx -g 'daemon off;'
