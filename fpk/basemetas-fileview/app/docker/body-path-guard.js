/* ============================================================================
 * body-path-guard.js —— 让逐用户权限闸门"看得见 POST body 里的路径"
 * ============================================================================
 *
 * 为什么需要它
 * ------------
 * nginx 的 `auth_request` 子请求**物理上看不到请求体**（配置里写死了
 * `proxy_pass_request_body off`），所以凡是"只把路径放在 body 里"的接口，
 * 闸门无法判定路径：
 *
 *     POST /preview/api/localFile     body: {"srcRelativePath": "/vol…"}
 *     POST /preview/api/status/poll   body: {"fileId": "…"}
 *     POST /preview/api/password/unlock body: {"originalFilePath": "/vol…"}
 *
 * 闸门落到「未解析到路径（放行）」分支 → 任意已登录用户可以指定别人的
 * 私有 /vol 路径把文件读出来。真机已验证可利用（2026-09-30）。
 *
 * 做法
 * ----
 * 用 njs 的 `js_access` 处理器在本 location 内**先读 body**，把路径提取出来
 * 写进请求变量，再用 `r.subrequest()` **同步问一次闸门**，闸门说不可读就直接
 * 403 拦在这里，根本不把请求转发给引擎。
 *
 *   js_access  → 读 body → 取路径 → 子请求问闸门 → 放行 / 403
 *   proxy_pass → 只有放行了才执行
 *
 * 为什么用子请求而不是直接调 `os.access`
 * --------------------------------------
 * 判定必须**以登录用户的身份**做（setuid + 附加组），而这只有闸门容器做得到
 * （它以 root 运行并挂了宿主 /etc/passwd、/etc/group）。nginx 里做不到这件事。
 * 所以这里只负责"把 body 里的路径喂给闸门"，判定仍由闸门做，**单一事实来源**。
 *
 * 为什么不用 njs 的 sha1 之类自己实现一套判定
 * -------------------------------------------
 * 同上：判定涉及用户组还原，nginx 侧没有这个能力，重复实现只会引入偏差。
 *
 * 兜底（fail-open，与整个闸门的设计方向一致）
 * ------------------------------------------
 * 闸门容器不可用 / 子请求超时 / body 解析失败 → **放行**，与 auth_request 那条
 * 链路的 `upstream backup` 行为保持一致。宁可"没保护"也不"把应用弄坏"。
 * 想临时退回"只记录"，仍是改 ${TRIM_PKGVAR}/acl.conf 里的 mode=log（闸门侧生效，
 * 本脚本不感知 mode，它只负责把路径送过去）。
 *
 * ⚠️ 本文件是**临时措施**，上游把闸门做进引擎、或飞牛开放文件 ACL API 后应删除。
 * ==========================================================================*/

/* 只在 body 里带路径、需要本脚本兜住的接口（前缀匹配，去掉网关前缀后比较）。
 * 注意：这里**不包含** GET 接口，GET 的路径在 query 里，auth_request 那条链路已能判定。 */
var BODY_PATH_APIS = [
    '/preview/api/localFile',
    '/preview/api/netFile',
    '/preview/api/status/poll',
    '/preview/api/password/unlock',
    '/preview/api/epub/resource',
    '/convert/api/srvFile',
];

/* 从 body 里按优先级找路径字段。语义与闸门侧 `_from_qs`（取 path / filePath）保持一致：
 * 先找"明确的绝对路径字段"，再找"可能是路径的字段"。 */
var PATH_KEYS = [
    'srcRelativePath',     // POST /preview/api/localFile —— 引擎实际读的就是它
    'filePath',            // POST /convert/api/srvFile
    'downloadTargetPath',
    'originalFilePath',    // POST /preview/api/password/unlock
    'targetPath',
];

function isBodyPathApi(uri) {
    for (var i = 0; i < BODY_PATH_APIS.length; i++) {
        var p = BODY_PATH_APIS[i];
        if (uri === p || uri.indexOf(p + '/') === 0) {
            return true;
        }
    }
    return false;
}

/* 网关前缀剥离：本脚本挂在主 location 里，$uri 是带 /app/basemetas-fileview 前缀的。
 * 但为了健壮（万一以后改成挂在剥前缀后的 location），两种情况都认。 */
var GATEWAY_PREFIX = '/app/basemetas-fileview';

function stripPrefix(uri) {
    if (uri.indexOf(GATEWAY_PREFIX) === 0) {
        var rest = uri.substring(GATEWAY_PREFIX.length);
        return rest === '' ? '/' : rest;
    }
    return uri;
}

function pickPath(body) {
    if (!body || typeof body !== 'object') {
        return '';
    }
    for (var i = 0; i < PATH_KEYS.length; i++) {
        var v = body[PATH_KEYS[i]];
        if (typeof v === 'string' && v.length) {
            return v;
        }
    }
    return '';
}

/* 只把 /vol 开头的路径送去判定 —— 与闸门自己的分支保持一致。
 * 非 /vol 路径（如引擎内部转换产物 /opt/fileview/…）闸门会放行，不必多问一趟。 */
function isStoragePath(p) {
    return typeof p === 'string' && p.indexOf('/vol') === 0;
}

async function guard(r) {
    var path = stripPrefix(r.uri);

    // 不在名单里 → 不干预，交给原有的 auth_request 链路
    if (!isBodyPathApi(path)) {
        return;
    }

    // GET/HEAD 等没有 body，路径在 query 里，auth_request 已能判定
    if (r.method !== 'POST' && r.method !== 'PUT' && r.method !== 'PATCH') {
        return;
    }

    var body;
    try {
        // ★ 读一次并缓存；proxy_pass 转发时上游仍会收到完整原始 body（官方样例语义）
        body = await r.readRequestJSON();
    } catch (e) {
        // body 不是 JSON（比如 multipart）或读取失败 → 放行，不因此把请求打死
        r.error('body-path-guard: readRequestJSON 失败，放行: ' + e);
        return;
    }

    var target = pickPath(body);

    if (!isStoragePath(target)) {
        // body 里没有 /vol 路径（例如 status/poll 只有 fileId）→ 无需额外判定。
        // ⚠️ 注意：这类请求若还带着 Referer，auth_request 那条链路仍会按 Referer 判定。
        return;
    }

    // 把路径放进变量，便于日志与排查（也让下面的子请求参数拼装更清晰）
    r.variables.fv_body_path = target;

    var uid = r.variables.http_x_trim_userid;   // 统一网关注入的身份头
    if (!uid || !/^[0-9]+$/.test(uid)) {
        r.error('body-path-guard: 缺 uid，放行（与闸门 fail-open 一致）');
        return;
    }

    // ── 问闸门：以该用户身份，这个路径可读吗 ──────────────────────────
    var sub;
    try {
        sub = await r.subrequest(
            '/__acl-body',
            {
                method: 'POST',
                args: 'uid=' + encodeURIComponent(uid) +
                      '&path=' + encodeURIComponent(target),
            }
        );
    } catch (e) {
        r.error('body-path-guard: 闸门子请求异常，放行: ' + e);
        return;
    }

    if (sub.status === 200) {
        return;                      // 放行，请求继续 proxy_pass 到引擎
    }

    // 闸门说不可读（403）→ 直接拦在这里，不把请求转发给引擎
    r.error('body-path-guard: 拦截 uid=' + uid + ' path=' + target +
            ' (闸门返回 ' + sub.status + ')');
    r.return(403, 'Forbidden\n');
}

export default {guard};
