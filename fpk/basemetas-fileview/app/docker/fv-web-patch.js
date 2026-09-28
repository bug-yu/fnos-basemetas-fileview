/*
 * FileView 预览 —— 浏览器端运行时补丁
 * 由网关 nginx 注入到 SPA 页面的 <head>（见 app/docker/nginx.conf 里的 sub_filter）。
 *
 * ⚠️ 这是「改上游运行时」的临时措施，上游修好后应当整段删掉。
 *    本仓库目前有两处这类补丁：
 *      1. 触屏电脑被误判成 iPad → PDF 没有工具栏
 *         —— 逻辑很短，内联在 nginx.conf 的那个 sub_filter 里（已实测生效）
 *      2. 本文件：Excel 没有缩放控件
 *         —— 逻辑长一些，单独放文件便于维护
 *    两者都是「上游一改就失效、但不会报错」的类型，所以各自留了 console 日志。
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
        } catch (e) {}
        _ls = v;
      }
    });
  } catch (e) {
    try { console.log('[fv-patch] 无法拦截 window.luckysheet：', e); } catch (e2) {}
  }
})();
