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
#   能加载 → 用原配置（有 body 路径保护）
#   不能   → 自动写一份去掉 njs 的配置到 /tmp，用它启动（回到 0.5.25 的防护水平）
# 两种情况下应用都能正常打开，且会**明确打印当前处于哪个模式**，避免"以为有防护
# 其实没有"。
#
# ⚠️ 降级模式是有漏洞的（POST body 绕过重新可用），日志会打 WARN 并给出怎么办。
# ============================================================================
set -u

CONF_DIR=/etc/nginx/conf.d
ORIG="$CONF_DIR/nginx.conf"
FALLBACK=/tmp/nginx-no-njs.conf

log() { echo "[fv-njs-boot] $*"; }

# --- 生成降级配置：把 njs 相关指令注释掉 -------------------------------------
# 用 sed 精确匹配行首指令，只动这四类，其它内容原样保留。
make_fallback() {
    sed -e 's|^\([[:space:]]*\)load_module[[:space:]]\+modules/ngx_http_js_module\.so;.*|\1# [fv-njs-boot] removed (no njs in image)|' \
        -e 's|^\([[:space:]]*\)js_path[[:space:]].*|\1# [fv-njs-boot] removed (no njs in image)|' \
        -e 's|^\([[:space:]]*\)js_import[[:space:]].*|\1# [fv-njs-boot] removed (no njs in image)|' \
        -e 's|^\([[:space:]]*\)js_access[[:space:]].*|\1# [fv-njs-boot] removed -- DEGRADED: body path guard OFF|' \
        "$ORIG" > "$FALLBACK"
}

# --- 判定：先用 nginx -t 实测原配置能不能过 ----------------------------------
# 这是唯一可靠的判据 —— 比猜镜像里有没有 .so 靠谱得多。
MODE=njs
if ! nginx -t -c "$ORIG" >/tmp/njs-t.log 2>&1; then
    log "原配置（含 njs）语法/加载检查未通过："
    sed 's/^/[fv-njs-boot]   /' /tmp/njs-t.log
    MODE=fallback
fi

if [ "$MODE" = njs ]; then
    log "njs 可用，使用完整配置（POST body 路径保护：**已开启**）"
    exec nginx -c "$ORIG" -g 'daemon off;'
fi

# --- 降级路径 ----------------------------------------------------------------
make_fallback
if nginx -t -c "$FALLBACK" >/tmp/njs-t2.log 2>&1; then
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
    log "    降级配置：$FALLBACK"
    log "================================================================"
    exec nginx -c "$FALLBACK" -g 'daemon off;'
fi

log "❌ 降级配置语法检查也失败："
sed 's/^/[fv-njs-boot]   /' /tmp/njs-t2.log
log "    改用原配置启动，请把上面日志发出来定位。"
exec nginx -c "$ORIG" -g 'daemon off;'
