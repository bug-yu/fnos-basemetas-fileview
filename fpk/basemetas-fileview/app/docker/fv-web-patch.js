/*
 * FileView 预览 —— 浏览器端运行时补丁
 * 由网关 nginx 注入到 SPA 页面的 <head>（见 app/docker/nginx.conf 里的 sub_filter）。
 *
 * ⚠️ 这是「改上游运行时」的临时措施，上游修好后应当整段删掉。
 *    本仓库目前有三处这类补丁：
 *      1. 触屏电脑被误判成 iPad → PDF 没有工具栏
 *         —— 逻辑很短，内联在 nginx.conf 的那个 sub_filter 里（已实测生效）
 *      2. 本文件 ①：Excel 没有缩放控件
 *      3. 本文件 ②：应用内 webview 里 Excel 无法用手指滚动
 *    都是「上游一改就失效、但不会报错」的类型，所以各自留了 console 日志。
 */
(function () {
  'use strict';

  try { console.log('[fv-patch] loaded'); } catch (e) {}

  /*
   * ==========================================================================
   * Excel 缩放
   * ==========================================================================
   * 现象：xls / xlsx / csv 预览能看，但没有缩放。
   *
   * 真因（上游 components/render/cell/index.tsx 里 luckysheet.create 的参数）：
   *     showinfobar: false, showtoolbar: false, showstatisticBar: false, ...
   * 「统计栏」整条被隐藏 —— 而**缩放控件就在统计栏里**：
   *     .luckysheet-stat-area > .luckysheet-sta-c > #luckysheet-zoom-content
   * 里面是一个 0.1x~4x 的滑杆 + 加减按钮（#luckysheet-zoom-minus / -plus）。
   *
   * Luckysheet 本身支持**细粒度**开关 showstatisticBarConfig，
   * 而 cell/index.tsx 没有传它。所以这里包一层 create 把配置补上：
   *     showstatisticBar: true
   *     showstatisticBarConfig: { count: false, view: false, zoom: true }
   *
   * 效果：统计栏只出现缩放控件；求和（count）和视图（view）保持隐藏。
   *      而且 Luckysheet 只有在三个子项**全部**被隐藏时才会把统计栏整条藏掉
   *      （并把 statisticBarHeight 置 0）；我们留了一个 zoom，所以
   *      statisticBarHeight 会被正确计算，表格不会错位。
   *
   * 为什么用「拦截 window.luckysheet 赋值」而不是轮询：
   *   luckysheet 是 cell 渲染器动态 loadJS 加载的，加载完紧接着就调 create ——
   *   50ms 一次的轮询很可能来不及打补丁。而它的 UMD 包装是
   *       (globalThis).luckysheet = factory()
   *   在这个赋值上装 setter，就能保证 create 被调用**之前**已经打好补丁。
   */
  try {
    var _ls;
    Object.defineProperty(window, 'luckysheet', {
      configurable: true,
      get: function () { return _ls; },
      set: function (v) {
        try {
          if (v && typeof v.create === 'function' && !v.__fvZoomPatched) {
            var orig = v.create;
            var wrapped = function (opts) {
              try {
                opts = opts || {};
                opts.showstatisticBar = true;
                opts.showstatisticBarConfig = { count: false, view: false, zoom: true };
              } catch (e) {}
              return orig.call(this, opts);
            };
            try { v.create = wrapped; } catch (e) {}
            if (v.create !== wrapped) {
              // 万一 create 是不可写属性，再试一次 defineProperty
              try {
                Object.defineProperty(v, 'create', {
                  value: wrapped, writable: true, configurable: true
                });
              } catch (e) {}
            }
            try { v.__fvZoomPatched = 1; } catch (e) {}
            try { console.log('[fv-patch] luckysheet.create 已包装：开启缩放控件'); } catch (e) {}
          }
          // ② 包一层 luckysheetrefreshgrid —— **直接测量上游重绘耗时**（诊断用，不改行为）。
          //    它是公开 API（core.js: luckysheet.luckysheetrefreshgrid = ...），
          //    每次滚动都会由上游的 scroll 处理器调用它一次。
          if (v && typeof v.luckysheetrefreshgrid === 'function' && !v.__fvRdPatched) {
            var origRefresh = v.luckysheetrefreshgrid;
            var timedRefresh = function () {
              var t0 = nowMs();
              var r = origRefresh.apply(this, arguments);
              var cost = nowMs() - t0;
              diag.rdSum += cost;
              diag.rdN++;
              if (cost > diag.rdMax) { diag.rdMax = cost; }
              return r;
            };
            try { v.luckysheetrefreshgrid = timedRefresh; } catch (e) {}
            if (v.luckysheetrefreshgrid !== timedRefresh) {
              try {
                Object.defineProperty(v, 'luckysheetrefreshgrid', {
                  value: timedRefresh, writable: true, configurable: true
                });
              } catch (e) {}
            }
            try { v.__fvRdPatched = 1; } catch (e) {}
          }
        } catch (e) {}
        _ls = v;
      }
    });
  } catch (e) {
    try { console.log('[fv-patch] 无法拦截 window.luckysheet：', e); } catch (e2) {}
  }
  /*
   * ==========================================================================
   * ② 平板 / 应用内 webview：Excel 表格无法用手指滚动
   * ==========================================================================
   * 现象（真机，华为 HarmonyOS NEXT 平板 + 飞牛 App）：
   *   同一台平板、同一个 xlsx —— **浏览器里手指能滑，飞牛 App 里滑不动**；
   *   插鼠标用滚轮两边都能滚。对照：**PDF 在 App 里手指能滚**，
   *   Excel 里手指也能**选中单元格**（说明触摸事件确实到达了渲染器）。
   *
   * 真因：Luckysheet 的滚动是**它自己实现的**，只接 `wheel` 事件；
   *   手指滑动走的是**页面滚动**。浏览器里页面本身可滚（内容比视口高），
   *   所以滑起来像"表格在滚"；而 App 的 webview 视口固定、页面不可滚
   *   → 手指滑就没有可滚的对象，表格纹丝不动。
   *   （PDF 用 PDF.js，自己处理触摸平移，所以不受影响。）
   *
   * 修法（两级）：
   *   ★ 首选：**直接驱动它的滚动位置**，做到跟手。
   *     Luckysheet 的滚动状态存在真实 DOM 上 —— `#luckysheet-scrollbar-y` 的 scrollTop、
   *     `#luckysheet-scrollbar-x` 的 scrollLeft（它的源码里就是这么读写的）。
   *     所以记住手指起点与当时的滚动位置，touchmove 时按**绝对位移**回写即可。
   *     ⚠️ 不能靠伪造 wheel：它的 wheel 处理器是**固定步进** ——
   *        `scrollNum = deltaFactor<40?1:deltaFactor<80?2:3; scrollTop += 10*scrollNum`
   *        完全不看 deltaY 的绝对值，还会按行边界吸附，
   *        所以伪造 wheel 只能得到"一格一格跳"的手感（0.5.36 第一版就是这个毛病）。
   *   ○ 兜底：万一拿不到那两个滚动条元素（上游改版），退回伪造 wheel ——
   *     至少能滚，只是不跟手。
   *
   * 生效条件（两个必须同时成立，缺一不可）：
   *   ① 页面本身不可滚 —— 否则交给浏览器；浏览器里行为**完全不变**（不会双滚动）
   *   ② 手指落在 Luckysheet 区域内 —— 否则可能与 PDF.js 自己的触摸平移叠加（双滚动）
   *
   * ⚠️ 同样是"上游一改就失效"的补丁（Luckysheet 换版本 / 改 id 前缀都会失效），留 console 日志。
   */
  // ── 公共小工具（触摸块与缩放块都要用，所以放在外层）──
  var nowMs = function () {
    try { return (window.performance && performance.now) ? performance.now() : Date.now(); }
    catch (e) { return Date.now(); }
  };
  var pageCanScroll = function () {
    var d = document.scrollingElement || document.documentElement;
    return !!d && d.scrollHeight > window.innerHeight + 1;
  };
  var inLuckysheet = function (el) {
    try { return !!(el && el.closest && el.closest('[id^="luckysheet"]')); } catch (e) { return false; }
  };

  // ── 屏上诊断徽标（默认关闭；排查现场时把 DIAG 改成 true 即可，改完 reload nginx）──
  //    显示：触摸事件计数 / rAF 次数 / 写入次数 / wheel 与 ctrl+wheel 计数
  //    / 页面是否可滚 / Luckysheet 滚动条元素的 scrollTop、scrollHeight、clientHeight。
  //    最后一项最关键：scrollHeight == clientHeight 说明它不是真的可滚容器。
  //    （2026-10-07 就是靠它确认了「触摸其实已经能滚、且滚动条确实可滚」。）
  var DIAG = false;
  var diag = {
    ts: 0, tm: 0, te: 0, raf: 0, writes: 0, w: 0, cW: 0, err: '',
    // 0.5.43 新增：写入来源与帧间隔 —— 用来判断"段落感"到底出在哪
    wrRaf: 0,      // 由 rAF（帧边界）触发的写入次数
    wrTo: 0,       // 由兜底定时器触发的写入次数（**若这个数很大，说明 rAF 被节流** → 段落感来源）
    dtSum: 0, dtN: 0,   // 相邻两次 rAF 的间隔（用来算实际帧率；若 ≈33ms+ 说明重绘跟不上）
    dtMax: 0,      // 单次最大帧间隔（比平均值可靠：不会被跨手势的停顿污染）
    // 0.5.47 新增：**直接测上游重绘耗时** —— 把 luckysheetrefreshgrid 包一层计时。
    // 这是判断"卡"到底是我们的问题、还是上游重绘天花板的**直接证据**。
    rdSum: 0, rdN: 0, rdMax: 0,
    // 0.5.45 新增：**滚动位置漂移** —— 我们写进去的目标值 vs 元素实际停留的值。
    // 若不为 0，说明有别人在改它（最可疑的是 Luckysheet 在**有冻结行列**时
    // 调用的 luckysheetFreezen.scrollAdapt()），我们的写入就被它顶掉 → "段落感"。
    lastTargetTop: null, drift: 0,
  };
  var diagEl = null;
  var diagPaint = function () {
    if (!DIAG) return;
    try {
      if (!document.createElement || !document.body) return;   // 桩环境直接跳过
      if (!diagEl || !diagEl.parentNode) {
        diagEl = document.createElement('div');
        diagEl.style.cssText = 'position:fixed;left:4px;bottom:4px;z-index:2147483647;'
          + 'background:rgba(0,0,0,.75);color:#7CFC00;font:11px/1.4 monospace;'
          + 'padding:4px 6px;border-radius:4px;pointer-events:none;white-space:pre';
        document.body.appendChild(diagEl);
      }
      var sy0 = document.getElementById('luckysheet-scrollbar-y');
      diagEl.textContent =
        'ts' + diag.ts + ' tm' + diag.tm + ' te' + diag.te + ' raf' + diag.raf
        + ' wr' + diag.writes + '\n'
        + 'wrRaf' + diag.wrRaf + ' wrTo' + diag.wrTo
        + ' dt' + (diag.dtN ? Math.round(diag.dtSum / diag.dtN) : '-') + 'ms'
        + ' mx' + Math.round(diag.dtMax) + '\n'
        + 'redraw ' + (diag.rdN ? (diag.rdSum / diag.rdN).toFixed(1) : '-') + 'ms'
        + ' max' + diag.rdMax.toFixed(1) + ' n' + diag.rdN + '\n'
        + 'wheel' + diag.w + ' ctrlW' + diag.cW + ' pgScroll' + (pageCanScroll() ? 1 : 0) + '\n'
        + 'sbY ' + (sy0 ? (sy0.scrollTop + '/' + sy0.scrollHeight + '/' + sy0.clientHeight) : 'null')
        + (diag.lastTargetTop === null ? '' : (' drift ' + Math.round((sy0 ? sy0.scrollTop : 0) - diag.lastTargetTop)))
        + (diag.err ? ('\nERR ' + diag.err) : '');
    } catch (e) {}
  };

  // ── 工作表缩放的共享状态与读写（Ctrl+滚轮 与 双指缩放 共用）──
  //    Luckysheet 只有 setter（setSheetZoom）、**没有 getter** ——
  //    所以首次从缩放标签 #luckysheet-zoom-ratioText 的文本懒读一次，之后用自己记的值
  //    （不依赖"上游每次都会更新标签"这个脆弱假设）。
  var cl = function (v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); };
  var zoomState = null;
  var getSheetZoom = function () {
    if (zoomState !== null) return zoomState;
    zoomState = 1;
    try {
      var el = document.getElementById('luckysheet-zoom-ratioText');
      var m = el && /\d+/.exec(el.textContent || el.innerText || '');
      if (m) {
        var v = parseInt(m[0], 10) / 100;
        if (v >= 0.1 && v <= 4) zoomState = v;
      }
    } catch (e) {}
    return zoomState;
  };
  var applySheetZoom = function (z) {
    z = Math.round(cl(z, 0.1, 4) * 100) / 100;
    var ls = window.luckysheet;
    if (!ls || typeof ls.setSheetZoom !== 'function') return false;
    try { ls.setSheetZoom(z); } catch (e) { return false; }
    zoomState = z;
    return true;
  };

  // ── 把「页面缩放手势」摘掉（0.5.41 起 / 0.5.43 扩到全局）──
  //    双指缩放**拦不住**：preventDefault 对 pinch 无效 ——
  //    能不能取消由 CSS `touch-action` / viewport 决定。
  //    · 表格区域：[id^="luckysheet"] 用 `none`（连平移也由我们的 JS 接管）
  //    · 整页其它地方：body 用 `pan-x pan-y` —— **保留原生平移**（PDF/Word 的单指滚动
  //      不受影响 ✓），只**禁止缩放**，于是浏览器不会缩放网页、飞牛 App 不会缩放整个页面。
  //    ⚠️ touch-action 的有效值是**沿祖先链取最严**：Luckysheet 子树自己写着 none，
  //       比 body 的 pan-x pan-y 更严 → 取 none → 表格区域完全不受 body 这条影响。
  try {
    var st = document.createElement('style');
    st.textContent = '[id^="luckysheet"] { touch-action: none !important; }'
      + 'body { touch-action: pan-x pan-y !important; }';
    (document.head || document.documentElement).appendChild(st);
  } catch (e) {}

  // ── 表格滚动：给滚轮一个正常的速度（0.5.46）──
  // Luckysheet 自己的滚轮处理器是**固定步进**：
  //     scrollNum = deltaFactor<40?1:deltaFactor<80?2:3;  scrollTop += 10*scrollNum;
  // 也就是**一格只滚 10~30px**，而且完全不看 deltaY 的大小 → 真机反馈「鼠标滚轮滚动比较慢」。
  // 我们在 window 的 capture 阶段接管（比上游那份 document capture 更早），
  // 自己按 deltaY 滚，然后 stopPropagation 把上游那套挡掉。
  var WHEEL_SPEED = 1.5;      // 可调：一格（deltaY=100）→ 150px。嫌慢调大、嫌快调小。
  var scrollSheetBy = function (dx, dy) {
    try {
      var sy = document.getElementById('luckysheet-scrollbar-y');
      var sx = document.getElementById('luckysheet-scrollbar-x');
      if (!sy || !sx) return false;
      if (dy) { sy.scrollTop = sy.scrollTop + dy; }
      if (dx) { sx.scrollLeft = sx.scrollLeft + dx; }
      return true;
    } catch (e) { return false; }
  };

  try {
    if ('ontouchstart' in window) {
      // Luckysheet 的滚动条元素（滚动状态就在它们身上）
      var sbY = null, sbX = null;
      var barsReady = function () {
        if (!sbY || !sbY.parentNode) sbY = document.getElementById('luckysheet-scrollbar-y');
        if (!sbX || !sbX.parentNode) sbX = document.getElementById('luckysheet-scrollbar-x');
        return !!(sbY && sbX);
      };

      // ── 拖动 + 惯性 ──
      // 拖动中**不**直接写 scrollTop：只更新目标位置，由 rAF 统一回写
      //   → 每帧最多重绘一次 canvas（每个 touchmove 都写会让渲染抖动）
      // 松手后按最后的速度继续滑行、指数衰减 → 接近原生的"甩一下滑一段"
      var now = function () {
        try { return (window.performance && performance.now) ? performance.now() : Date.now(); }
        catch (e) { return Date.now(); }
      };
      var raf = function (fn) {
        var f = window.requestAnimationFrame;
        return f ? f.call(window, fn) : setTimeout(fn, 16);
      };
      var clamp = function (v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); };

      var tTop = 0, tLeft = 0;             // 目标滚动位置
      var ticking = false;                 // rAF 是否已排队
      var inertia = false;                 // 是否在惯性滑行
      var vY = 0, vX = 0;                  // 速度（px/ms）
      var lastT = 0, lastTop = 0, lastLeft = 0;

      // ⚠️ 目标位置**不做 clamp** —— 浏览器自己会把 scrollTop/scrollLeft 钳在有效范围内。
      //    0.5.38 曾写 `clamp(v, 0, scrollHeight - clientHeight)`，但 Luckysheet 的滚动条
      //    是自绘的、scrollHeight 不一定反映内容高度 → maxTop() 可能是 0 →
      //    目标被钳死为 0 → **完全滚不动**（0.5.38 触摸失效的元凶）。
      // 可选：写入后**立刻**同步刷新一次，消掉"等 scroll 事件"那一跳的延迟。
      // ⚠️ 默认**关** —— 上游随后还会因 scroll 事件再重绘一次，开了就是**每帧两次重绘**。
      //    如果觉得"内容比手指慢半拍"，把它改成 true 试试（一行，reload 即可）。
      var SYNC_REFRESH = false;
      var write = function () {
        try {
          if (sbY.scrollTop !== tTop) sbY.scrollTop = tTop;
          if (sbX.scrollLeft !== tLeft) sbX.scrollLeft = tLeft;
          diag.lastTargetTop = tTop;      // 记下我们写进去的目标值，供诊断比对漂移
          if (SYNC_REFRESH) {
            var ls = window.luckysheet;
            if (ls && typeof ls.luckysheetrefreshgrid === 'function') {
              ls.luckysheetrefreshgrid(tLeft, tTop);
            }
          }
        } catch (e) {}
        diag.writes++;
      };

      // 惯性滑行：只在**松手后**用 rAF 推进。
      // 拖动阶段是**同步写** —— 不依赖 rAF 是否被 webview 节流。
      var tick = function () {
        ticking = false;
        diag.raf++;
        if (!inertia) return;
        if (!barsReady()) { inertia = false; return; }
        var t = now();
        var dt = clamp(t - lastT, 1, 48);        // 掉帧时别一步跳太远
        lastT = t;
        tTop += vY * dt;
        tLeft += vX * dt;
        var decay = Math.pow(0.996, dt);         // 0.5.47：0.99 → 0.996（约每 16ms 衰减到 0.938）
        vY *= decay;                             //   原来的 0.85/帧 停得太快，手感"滑不远"
        vX *= decay;
        if (Math.abs(vY) < 0.01 && Math.abs(vX) < 0.01) { inertia = false; vY = vX = 0; }
        write();
        if (inertia) schedule();
      };
      var schedule = function () {
        if (ticking) return;
        ticking = true;
        raf(tick);
      };

      var sx = null, sy = null;          // 手指起点
      var baseTop = 0, baseLeft = 0;     // 起点时的滚动位置
      var drag = false;                  // 本次触摸是否走「直接拖动」这条路
      var lastX = null, lastY = null;    // 兜底 wheel 用

      // ── 速度采样：用**时间窗口**而不是"最后一帧"（0.5.48）──
      // 手指在抬手前通常会**减速**，只用最后一帧的速度会把"甩"的速度严重低估
      // → 松手后滑不远（真机反馈"慢"）。原生系统都是取最近 ~50-100ms 的平均速度。
      var samples = [];        // [{t, top, left}]，只保留最近 ~60ms
      var pushSample = function (t, top, left) {
        samples.push({ t: t, top: top, left: left });
        while (samples.length > 2 && (t - samples[0].t) > 60) { samples.shift(); }
      };
      var calcVelocity = function () {
        if (samples.length < 2) { vY = vX = 0; return; }
        var a = samples[0], b = samples[samples.length - 1];
        var dts = b.t - a.t;
        if (dts <= 0) { vY = vX = 0; return; }
        vY = (b.top - a.top) / dts;
        vX = (b.left - a.left) / dts;
      };

      // ── 写入调度（0.5.42）──
      // 每次写 scrollTop 都会让 Luckysheet **完整重绘一次**（scrollbar 的 scroll 事件 →
      // luckysheetscrollevent → luckysheetrefreshgrid）。已确认这条路径是**最小的**：
      //   · 列表头 / 行表头 / 主区**没有** scroll 监听 → 不会级联重绘
      //   · 那个自我续订的 rAF 循环（execScroll）在启动处被上游注释掉了 → 没有失控循环
      // 所以关键不是"写多少次"，而是**写的时间点要和显示帧对齐**：
      //   · 用 rAF 调度 → 每帧最多一次，且落在帧首（重绘跟着落在同一帧内，不撕裂）
      //   · 再挂一个 ~24ms 的 setTimeout 兜底 —— 万一 webview 节流了 rAF，也能靠它写进去
      //   （0.5.41 用的是 14ms 时间节流：写入落在帧中间 → 某帧重绘两次、某帧零次 →
      //     "打拍子"式的微抖，真机反馈「不够顺滑」。）
      var writeScheduled = false, writeTimer = null, writeRafId = null;
      var lastRafT = 0;
      var cancelScheduled = function () {
        if (writeTimer !== null && typeof clearTimeout === 'function') { clearTimeout(writeTimer); }
        writeTimer = null;
        if (writeRafId !== null) {
          try { (window.cancelAnimationFrame || clearTimeout).call(window, writeRafId); } catch (e) {}
        }
        writeRafId = null;
      };
      var flushWrite = function (from) {
        cancelScheduled();
        if (!writeScheduled) return;
        writeScheduled = false;
        if (from === 'to') { diag.wrTo++; } else { diag.wrRaf++; }
        write();
      };
      var scheduleWrite = function () {
        if (writeScheduled) return;
        writeScheduled = true;
        try {
          var f = window.requestAnimationFrame;
          writeRafId = f ? f.call(window, function () {
            var t = now();
            if (lastRafT) {
              var gap = t - lastRafT;
              // ⚠️ 只统计**同一个手势内**的间隔：>200ms 的基本是两次手势之间的停顿，
              //    算进去会把平均值拉到几百毫秒（0.5.46 的 dt 742ms 就是这么来的）✗
              if (gap < 200) {
                diag.dtSum += gap; diag.dtN++;
                if (gap > diag.dtMax) { diag.dtMax = gap; }
              }
            }
            lastRafT = t;
            flushWrite('raf');
          }) : null;
        } catch (e) { writeRafId = null; }
        // 兜底：只在 rAF **真的没来**时才启用 —— 所以放宽到 50ms。
        // ⚠️ 0.5.42 用的 24ms 太贴近 16.7ms 的帧间隔：rAF 稍慢一点兜底就"抢跑"，
        //    写入落在帧中间 → 就是真机反馈的"段落感"。诊断里的 wrTo 计数能直接证实。
        if (typeof setTimeout === 'function') {
          writeTimer = setTimeout(function () { flushWrite('to'); }, 50);
        }
        if (writeRafId === null && writeTimer === null) { flushWrite('raf'); }   // 都没有 → 立刻写
      };

      // ── 双指缩放工作表（0.5.41）──
      // Luckysheet 没有触摸缩放手势（桌面组件），而页面缩放已被上面的
      // `touch-action: none` 摘掉，所以自己算两指距离比 → 映射到 setSheetZoom。
      var pinchD0 = 0, pinchZ0 = 1, pinching = false;
      var twoDist = function (ev) {
        var a = ev.touches[0], b = ev.touches[1];
        var dx = a.clientX - b.clientX, dy = a.clientY - b.clientY;
        return Math.sqrt(dx * dx + dy * dy) || 1;
      };

      // ── 其它格式：把双指缩放翻译成「合成的 ctrl+滚轮」（0.5.43）──
      // PDF.js / Word 预览等**只认 Ctrl+滚轮、不处理 pinch**（用户实测：Ctrl+滚轮才正常），
      // 而 pinch 的默认行为已被 body 的 touch-action 摘掉 —— 所以走它们**本来就支持**的那条路。
      //
      // ★★ 关键：**映射成"离散的滚轮刻度"**，而不是按 touchmove 频率直接派发。
      //    因为这些渲染器的滚轮处理器多半是「**一个事件 = 一个固定缩放步进**」
      //    （和 Luckysheet 的滚轮处理器一个思路，根本不看 deltaY 的大小）。
      //    0.5.43 初版按 60/s 派发 → 缩放直接飙到底（真机反馈"太灵敏、一下变很大或很小"）✗
      //    现在：pinch 的**对数比例**换算成刻度数（1 刻度 ≈ 1.1 倍），
      //    **每帧最多派发 1 个刻度** —— 刻度总数由捏合比例决定，**天然自限** ✓
      var pinchOther = false, pinchLastD = 0, pinchTarget = null;
      var notchAccum = 0, notchBusy = false;
      // ★ 可调常量：捏合多少倍算「一个滚轮刻度」。
      //   用户反馈"太灵敏" → 宁可偏慢也不能再偏灵敏，所以取 1.2（常见浏览器的
      //   Ctrl+滚轮一档约 1.2 倍）。**觉得还灵敏就调大、觉得太慢就调小。**
      var NOTCH_BASE = 1.2;
      var pumpNotches = function () {
        notchBusy = false;
        if (!pinchTarget || Math.abs(notchAccum) < 1) return;
        var dir = notchAccum > 0 ? 1 : -1;
        notchAccum -= dir;                       // 一次只派发 1 个刻度
        try {
          if (typeof WheelEvent === 'function') {
            pinchTarget.dispatchEvent(new WheelEvent('wheel', {
              bubbles: true, cancelable: true, ctrlKey: true, deltaMode: 0,
              deltaY: -dir * 100,                // 向上滚 = 放大 = deltaY 负
            }));
          }
        } catch (err) {}
        if (Math.abs(notchAccum) >= 1) { scheduleNotch(); }
      };
      var scheduleNotch = function () {
        if (notchBusy) return;
        notchBusy = true;
        try {
          var f = window.requestAnimationFrame;
          if (f) { f.call(window, pumpNotches); } else { pumpNotches(); }
        } catch (err) { pumpNotches(); }
        if (typeof setTimeout === 'function') {
          setTimeout(function () { if (notchBusy) pumpNotches(); }, 50);   // 兜底
        }
      };
      var addNotches = function (ratio) {
        if (!(ratio > 0) || ratio === 1) return;
        notchAccum += Math.log(ratio) / Math.log(NOTCH_BASE);   // 1 个刻度 ≈ NOTCH_BASE 倍
        if (notchAccum > 20) { notchAccum = 20; }
        if (notchAccum < -20) { notchAccum = -20; }
        if (Math.abs(notchAccum) >= 1) { scheduleNotch(); }
      };

      // ── 表格区域：缩放也按帧节流（0.5.43）──
      // setSheetZoom 内部会 zoomRefreshView()（完整重排 + 重绘）。每个 touchmove 都调
      // 会让它跟不上手指 → 手感"跳"。所以只记最新目标值，每帧最多应用一次。
      var zoomPending = null, zoomRafId = null, zoomTimer = null;
      var flushZoom = function () {
        if (zoomTimer !== null && typeof clearTimeout === 'function') { clearTimeout(zoomTimer); }
        zoomTimer = null;
        zoomRafId = null;
        if (zoomPending === null) return;
        var z = zoomPending;
        zoomPending = null;
        applySheetZoom(z);
      };
      var queueZoom = function (z) {
        zoomPending = z;
        if (zoomRafId !== null) return;
        try {
          var f = window.requestAnimationFrame;
          zoomRafId = f ? f.call(window, flushZoom) : null;
        } catch (e) { zoomRafId = null; }
        if (typeof setTimeout === 'function') {
          zoomTimer = setTimeout(flushZoom, 50);       // 兜底：rAF 被节流也能应用
        }
        if (zoomRafId === null && zoomTimer === null) { flushZoom(); }
      };

      document.addEventListener('touchstart', function (e) {
        diag.ts++;
        inertia = false; vY = vX = 0;      // 手指一碰就停住惯性（和原生一致）
        if (!e.touches || e.touches.length !== 1) {
          sx = sy = lastX = lastY = null;
          drag = false;
          var two = !!(e.touches && e.touches.length === 2);
          // 双指 → 表格区域：直接缩放工作表（本应用接管）
          pinching = two && !pageCanScroll() && inLuckysheet(e.target);
          if (pinching) {
            pinchD0 = twoDist(e);
            pinchZ0 = getSheetZoom();
            pinchOther = false;
          } else if (two) {
            // 双指 → 其它区域：合成 ctrl+滚轮交给渲染器自己缩放
            // （这里**不**要求"页面不可滚"：浏览器里也要能缩放文档）
            pinchOther = true;
            pinchLastD = twoDist(e);
            pinchTarget = e.target;
          } else {
            pinchOther = false;
          }
          diagPaint();
          return;
        }
        pinching = false;
        pinchOther = false;
        var t = e.touches[0];
        sx = lastX = t.clientX;
        sy = lastY = t.clientY;
        drag = !pageCanScroll() && inLuckysheet(e.target) && barsReady();
        if (drag) {
          writeScheduled = false; cancelScheduled();   // 新的一次拖动，第一次移动必须写进去
          lastRafT = 0;                                // 帧间隔按手势重新起算（避免跨手势污染）
          samples = [];                                // 速度采样也按手势重来
          baseTop = sbY.scrollTop;
          baseLeft = sbX.scrollLeft;
          tTop = baseTop;
          tLeft = baseLeft;
          lastT = now();
          lastTop = baseTop;
          lastLeft = baseLeft;
        }
        diagPaint();
      }, { passive: true });

      document.addEventListener('touchmove', function (e) {
        diag.tm++;
        // ★ 双指 → 缩放
        if (e.touches && e.touches.length === 2) {
          var d2 = twoDist(e);
          if (pinching) {
            // 表格区域：两指距离比 → 目标缩放（**按帧节流**应用，见 queueZoom）
            // ⚠️ 起手两指太近时距离比会爆掉（d0 很小 → 比值极大），加个下限保护
            if (pinchD0 >= 30) { queueZoom(pinchZ0 * (d2 / pinchD0)); }
            if (e.cancelable) e.preventDefault();
            if (diag.tm % 5 === 0) diagPaint();
          } else if (pinchOther) {
            // 其它格式：换算成**离散滚轮刻度**（对数；每帧最多派发一个）
            if (pinchLastD > 0) { addNotches(d2 / pinchLastD); }
            pinchLastD = d2;
            if (e.cancelable) e.preventDefault();
            if (diag.tm % 5 === 0) diagPaint();
          }
          return;
        }
        if (sx === null || !e.touches || e.touches.length !== 1) return;
        var t = e.touches[0];

        if (drag) {
          // 跟手：按**距起点的绝对位移**算目标位置（不逐帧累加，避免漂移）
          // ⚠️ 不 clamp：浏览器自己会钳；见上面 write() 处的说明。
          tTop = baseTop + (sy - t.clientY);
          tLeft = baseLeft + (sx - t.clientX);
          // 速度采样（用**时间窗口**里的首末两点，不是最后一帧 —— 见上面 pushSample 的说明）
          var tt = now();
          pushSample(tt, tTop, tLeft);
          lastT = tt; lastTop = tTop; lastLeft = tLeft;
          scheduleWrite();               // ★ 由 rAF 调度：每帧最多一次、且与显示帧对齐
          // ★★ 必须 preventDefault：否则浏览器 / 应用外壳会**同时**做它自己的
          //    平移与回弹，和我们驱动的滚动打架 —— 表现就是「整个视窗（标题栏）
          //    跟着动、不顺畅」（真机反馈）。这也要求本监听是 passive:false
          //    —— passive 时 preventDefault 会被直接忽略。
          //    只在 drag 时取消：非拖动（点选单元格）与多指（缩放）都不动它。
          if (e.cancelable) e.preventDefault();
          if (diag.tm % 10 === 0) diagPaint();
          return;
        }

        // ── 兜底：拿不到滚动条元素时伪造 wheel（能滚，但不跟手）──
        if (pageCanScroll()) return;              // ① 页面自己能滚 → 交给浏览器
        if (!inLuckysheet(e.target)) return;      // ② 只在表格区域内兜底
        if (typeof WheelEvent !== 'function') return;
        var dx = lastX - t.clientX, dy = lastY - t.clientY;
        lastX = t.clientX;
        lastY = t.clientY;
        var opt = { bubbles: true, cancelable: true };
        if (Math.abs(dy) >= Math.abs(dx)) {
          if (Math.abs(dy) < 1) return;
          opt.deltaY = dy;
        } else {
          if (Math.abs(dx) < 1) return;
          opt.deltaX = dx;
        }
        try { e.target.dispatchEvent(new WheelEvent('wheel', opt)); } catch (err) {}
        // ⚠️ 这个监听必须是 **passive:false** —— 上面拖动分支要 preventDefault
        //    来取消浏览器自己的平移（passive:true 时 preventDefault 会被忽略）。
      }, { passive: false });

      document.addEventListener('touchend', function () {
        diag.te++;
        var wasDrag = drag;
        sx = sy = lastX = lastY = null;
        drag = false;
        pinching = false;
        pinchOther = false;
        flushZoom();                      // 表格缩放：应用最后一帧的目标值
        notchAccum = 0;                   // 其它格式：丢掉残余刻度（否则松手后还会继续缩放）
        if (!wasDrag) { diagPaint(); return; }
        flushWrite('raf');     // 补一次最终位置（拖动期间是按帧调度的，可能差最后一帧）
        calcVelocity();        // ★ 用"最近 ~60ms 窗口"算甩的速度（不是最后一帧）
        // 松手 → 惯性滑行（速度太低就不滑，避免"粘一下"）
        if (Math.abs(vY) < 0.05 && Math.abs(vX) < 0.05) { vY = vX = 0; diagPaint(); return; }
        inertia = true;
        lastT = now();
        schedule();
        diagPaint();
      }, { passive: true });

      try {
        console.log('[fv-patch] 触摸滚动已挂载（页面不可滚 + 表格区域内；rAF 合并重绘 + 松手惯性）');
      } catch (e) {}
    }
  } catch (e) {
    try { console.log('[fv-patch] 触摸滚动兜底挂载失败：', e); } catch (e2) {}
  }

  /*
   * ==========================================================================
   * ③ Ctrl + 滚轮缩放工作表（0.5.38 起）
   * ==========================================================================
   * Luckysheet **自带**这个功能（`controllers/zoom.js` 里 `ZOOM_WHEEL_STEP = 0.02`，
   * 绑在 document 上、capture:true），但实测无效 —— 而「缩放 ± 按钮能用」说明
   * 它的 `zoomInitial()` 确实被调用了，所以上游那份监听也在，只是没生效（原因未明）。
   *
   * 所以补丁**自己绑一份**（window 的 capture 阶段，比上游那份 document capture 更早），
   * 直接调公开 API `luckysheet.setSheetZoom(ratio)`；另外**自己跟踪 Ctrl 键状态**
   * （keydown/keyup）—— 有些 webview 的 wheel 事件不带 `ctrlKey`（修饰键被吞）。
   *
   * 缩放的读写统一用外层的 `getSheetZoom()` / `applySheetZoom()`
   * （双指缩放也走它们，见 ② 里的 pinch 分支）。
   */
  try {
    (function () {
      // Ctrl 键自跟踪：有些 webview 的 wheel 事件不带 ctrlKey（修饰键被吞）。
      var ctrlDown = false;
      try {
        window.addEventListener('keydown', function (e) {
          if (e.key === 'Control' || e.ctrlKey) ctrlDown = true;
        }, { capture: true });
        window.addEventListener('keyup', function (e) {
          if (e.key === 'Control') ctrlDown = false;
        }, { capture: true });
        window.addEventListener('blur', function () { ctrlDown = false; });
      } catch (e) {}

      window.addEventListener('wheel', function (ev) {
        diag.w++;
        var withCtrl = !!(ev.ctrlKey || ctrlDown);
        if (withCtrl) diag.cW++;
        if (diag.w % 5 === 0 || withCtrl) diagPaint();
        if (!ev.deltaY && !ev.deltaX) return;
        // ★ 只对**表格区域**生效 —— 否则会把「我们给其它渲染器合成的 ctrl+滚轮」
        //   也一起吞掉（下面有 stopPropagation），PDF / Word 就收不到、双指缩放失效。
        if (!inLuckysheet(ev.target)) return;

        if (withCtrl) {
          // Ctrl + 滚轮 → 缩放工作表（一个刻度约 ±0.05）
          if (!applySheetZoom(getSheetZoom() + (ev.deltaY < 0 ? 0.05 : -0.05))) {
            diag.err = 'setSheetZoom unavailable'; diagPaint(); return;
          }
          diag.err = '';
        } else {
          // 普通滚轮 → **自己按 deltaY 滚**。
          // 上游那套是固定步进（一格只滚 10~30px）→ 真机反馈"滚轮滚动比较慢"。
          var dy = ev.deltaY, dx = ev.deltaX || 0;
          if (ev.deltaMode === 1) { dy *= 16; dx *= 16; }        // 行 → 像素
          else if (ev.deltaMode === 2) { dy *= 100; dx *= 100; } // 页 → 像素
          if (!scrollSheetBy(dx * WHEEL_SPEED, dy * WHEEL_SPEED)) { return; }  // 拿不到滚动条 → 交回上游
        }
        ev.preventDefault();
        ev.stopPropagation();
      }, { capture: true, passive: false });

      try { console.log('[fv-patch] Ctrl+滚轮缩放已挂载'); } catch (e) {}
    })();
  } catch (e) {
    try { diag.err = 'zoomInit:' + e; diagPaint(); } catch (e2) {}
  }
})();
