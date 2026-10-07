/*
 * fv-web-patch.js 的逻辑回归测试（用桩 DOM 在 node 里跑，不需要浏览器）
 * ============================================================================
 * 覆盖三件事：
 *   ① 触摸拖动 Excel：直接驱动 #luckysheet-scrollbar-y/-x 的 scrollTop/scrollLeft
 *      —— 跟手（按距起点的绝对位移）、**每帧最多回写一次**（rAF 合并）、松手有惯性
 *   ② 两个生效条件（缺一不可）：页面本身不可滚 + 手指落在 Luckysheet 区域内
 *   ③ Ctrl + 滚轮缩放工作表（Luckysheet 自带的那个在本集成里没生效，补丁自己绑一份）
 *
 * 用法： node fpk/tools/test_web_patch.js      （退出码 0 = 全过）
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const PATCH = path.join(__dirname, '..', 'basemetas-fileview', 'app', 'docker', 'fv-web-patch.js');
const SRC = fs.readFileSync(PATCH, 'utf8');

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failed = 1;
  console.log('  %s  %s  got=%s want=%s',
    ok ? 'OK  ' : 'FAIL', name, JSON.stringify(got), JSON.stringify(want));
}
function checkTrue(name, cond, detail) {
  if (!cond) failed = 1;
  console.log('  %s  %s  %s', cond ? 'OK  ' : 'FAIL', name, detail === undefined ? '' : detail);
}

function makeEl(id) {
  return {
    id,
    dispatched: [],
    closest(sel) {
      return (sel === '[id^="luckysheet"]' && String(this.id).startsWith('luckysheet'))
        ? this : null;
    },
    dispatchEvent(ev) { this.dispatched.push(ev); return true; },
  };
}

// 滚动条元素：scrollTop/scrollLeft 用 setter 计数（用来断言"每帧只写一次"）
function makeBar() {
  const o = {
    parentNode: {}, scrollHeight: 2000, clientHeight: 800,
    scrollWidth: 2000, clientWidth: 800, _top: 0, _left: 0, writes: 0,
  };
  Object.defineProperty(o, 'scrollTop', {
    get() { return o._top; }, set(v) { o._top = v; o.writes++; },
  });
  Object.defineProperty(o, 'scrollLeft', {
    get() { return o._left; }, set(v) { o._left = v; o.writes++; },
  });
  return o;
}

function makeCtx(opts) {
  opts = opts || {};
  const pageScrollable = !!opts.pageScrollable;
  const withBars = opts.withBars !== false;
  const touchDevice = opts.touchDevice !== false;

  const docHandlers = {}, winHandlers = {}, docOpts = {};
  const rafQueue = [];
  let clock = 0;
  const bars = { 'luckysheet-scrollbar-y': makeBar(), 'luckysheet-scrollbar-x': makeBar() };
  const zoomLabel = { id: 'luckysheet-zoom-ratioText', textContent: '100%' };
  const setSheetZoomCalls = [];

  const doc = {
    scrollingElement: { scrollHeight: pageScrollable ? 3000 : 800 },
    documentElement: { scrollHeight: pageScrollable ? 3000 : 800 },
    addEventListener(t, fn, opt) {
      (docHandlers[t] = docHandlers[t] || []).push(fn);
      docOpts[t] = opt || {};
    },
    getElementById(id) {
      if (id === 'luckysheet-zoom-ratioText') return zoomLabel;
      if (withBars === false) return null;
      return bars[id] || null;
    },
  };
  const perf = { now() { return clock; } };
  const win = {
    innerHeight: 800,
    performance: perf,
    addEventListener(t, fn) { (winHandlers[t] = winHandlers[t] || []).push(fn); },
    requestAnimationFrame(fn) { rafQueue.push(fn); return rafQueue.length; },
  };
  if (touchDevice !== false) win.ontouchstart = null;

  const ctx = {
    window: win, document: doc, console: { log() {} }, performance: perf,
    WheelEvent: function (type, o) { Object.assign(this, { type }, o); },
  };
  vm.createContext(ctx);
  vm.runInContext(SRC, ctx);

  // ⚠️ 必须**在补丁加载之后**再赋 window.luckysheet ——
  //    补丁①用 defineProperty 拦截了这个赋值（为了包 create），提前塞的桩会被覆盖成 undefined。
  //    这样也更贴近真实：Luckysheet 是动态 loadJS 加载完才赋值的。
  win.luckysheet = { setSheetZoom(z) { setSheetZoomCalls.push(z); } };

  return {
    docHandlers, winHandlers, docOpts, bars, rafQueue, zoomLabel, setSheetZoomCalls,
    advance(ms) { clock += ms; },
    flushRaf() { const q = rafQueue.splice(0); q.forEach((f) => f()); },
    pendingRaf() { return rafQueue.length; },
  };
}

// touchmove 事件要带 cancelable + preventDefault（补丁会在拖动时取消浏览器默认平移）
function mkTouch(x, y, target) {
  return {
    target, touches: [{ clientX: x, clientY: y }],
    cancelable: true, prevented: false,
    preventDefault() { this.prevented = true; },
  };
}
function touchStart(c, x, y, target) {
  c.docHandlers.touchstart.forEach((f) => f({
    target, touches: [{ clientX: x, clientY: y }],
    cancelable: true, preventDefault() {},
  }));
}
function touchMoveEv(c, target, x, y) {
  const ev = mkTouch(x, y, target);
  c.docHandlers.touchmove.forEach((f) => f(ev));
  return ev;
}
function touchMove(c, target, x, y) {
  touchMoveEv(c, target, x, y);
}
function touchEnd(c) {
  c.docHandlers.touchend.forEach((f) => f({}));
}

console.log('== 拖动：跟手 + 按帧调度写入 ==');
{
  const c = makeCtx();
  const sheet = makeEl('luckysheet-cell-main');
  const y = c.bars['luckysheet-scrollbar-y'], x = c.bars['luckysheet-scrollbar-x'];
  y.scrollTop = 100; x.scrollLeft = 50;
  y.writes = 0; x.writes = 0;

  touchStart(c, 400, 400, sheet);
  touchMove(c, sheet, 400, 390);
  touchMove(c, sheet, 400, 380);
  touchMove(c, sheet, 400, 360);            // 三次 move 都在同一帧内
  // 每次写 scrollTop 都会让 Luckysheet 完整重绘一次 → 用 rAF 调度到帧边界，
  // 每帧最多一次、且与显示帧对齐（时间节流会让写入落在帧中间 → "打拍子"式微抖）
  checkTrue('同一帧内多次 move → 只排队 1 次 rAF', c.pendingRaf() === 1);
  check('  未到帧边界前不写', y.scrollTop, 100);

  c.flushRaf();
  check('★ 帧边界写入：位置 = 起点 + 手指位移（取最后一次）', y.scrollTop, 140);
  checkTrue('  一帧只写一次', y.writes === 1, 'writes=' + y.writes);

  touchEnd(c);
  check('★ 松手补一次最终位置（可能差最后一帧）', y.scrollTop, 140);
}

console.log('== 拖动：横向 + 绝对位移（不逐帧累加）==');
{
  const c = makeCtx();
  const sheet = makeEl('luckysheet-cell-main');
  const y = c.bars['luckysheet-scrollbar-y'], x = c.bars['luckysheet-scrollbar-x'];
  y.scrollTop = 100; x.scrollLeft = 50;
  touchStart(c, 400, 400, sheet);
  c.advance(20);
  touchMove(c, sheet, 360, 400); c.flushRaf();
  check('横向：scrollLeft = 起点 + 位移', x.scrollLeft, 90);
  c.advance(20);
  touchMove(c, sheet, 400, 430); c.flushRaf();
  check('★ 按距起点的绝对位移（不是逐帧累加）：scrollTop = 100 + (400-430)', y.scrollTop, 70);
  check('  （纵向仍是绝对映射）scrollLeft 回到起点', x.scrollLeft, 50);
}

console.log('== 松手惯性 ==');
{
  const c = makeCtx();
  const sheet = makeEl('luckysheet-cell-main');
  const y = c.bars['luckysheet-scrollbar-y'];
  y.scrollTop = 100;
  touchStart(c, 400, 400, sheet);
  c.advance(16); touchMove(c, sheet, 400, 360); c.flushRaf();   // 40px/16ms = 2.5px/ms
  c.advance(16); touchMove(c, sheet, 400, 320); c.flushRaf();
  const before = y.scrollTop;
  check('松手前位置', before, 180);

  touchEnd(c);
  c.advance(16); c.flushRaf();
  const after1 = y.scrollTop;
  checkTrue('★ 松手后继续滑行（惯性）', after1 > before, before + ' → ' + after1);

  for (let i = 0; i < 300 && c.pendingRaf(); i++) { c.advance(16); c.flushRaf(); }
  const settled = y.scrollTop;
  checkTrue('★ 惯性最终停下（不再排队 rAF）', c.pendingRaf() === 0 && settled > after1,
    after1 + ' → ' + settled);

  touchStart(c, 400, 400, sheet);
  checkTrue('★ 手指一碰 → 不再排队 rAF（惯性立即停止）', c.pendingRaf() === 0);
}

console.log('== ★ 双指缩放工作表（表格区域）==');
{
  // 两指间距 200 → 400（拉开 2 倍）→ 缩放应从 1 变成 2
  const two = (d) => [
    { clientX: 400 - d / 2, clientY: 300 },
    { clientX: 400 + d / 2, clientY: 300 },
  ];
  const c = makeCtx();
  const sheet = makeEl('luckysheet-cell-main');
  c.docHandlers.touchstart.forEach((f) => f({
    target: sheet, touches: two(200), cancelable: true, preventDefault() {},
  }));
  const ev = {
    target: sheet, touches: two(400), cancelable: true, prevented: false,
    preventDefault() { this.prevented = true; },
  };
  c.docHandlers.touchmove.forEach((f) => f(ev));
  checkTrue('未到帧边界不应用（setSheetZoom 会完整重排+重绘，必须按帧节流）',
    c.setSheetZoomCalls.length === 0);
  c.flushRaf();
  check('两指拉开 2 倍 → setSheetZoom(2)', c.setSheetZoomCalls, [2]);
  checkTrue('  并 preventDefault（顺手挡浏览器自己的缩放）', ev.prevented);
}

console.log('== ★ 双指缩放：其它格式 → 合成 ctrl+滚轮 ==');
{
  // 这些渲染器只认 Ctrl+滚轮、不处理 pinch（用户实测），所以把 pinch 翻译成合成的 ctrl+滚轮
  const two = (d) => [
    { clientX: 400 - d / 2, clientY: 300 },
    { clientX: 400 + d / 2, clientY: 300 },
  ];
  const c = makeCtx();
  const pdf = makeEl('pdfjs-canvas');
  c.docHandlers.touchstart.forEach((f) => f({ target: pdf, touches: two(200), cancelable: true, preventDefault() {} }));
  c.docHandlers.touchmove.forEach((f) => f({ target: pdf, touches: two(400), cancelable: true, preventDefault() {} }));
  check('不调 setSheetZoom（不是表格）', c.setSheetZoomCalls.length, 0);
  checkTrue('  未到帧边界不派发（按帧节流）', pdf.dispatched.length === 0);
  c.flushRaf();
  check('★ 帧边界派发一个滚轮刻度', pdf.dispatched.length, 1);
  checkTrue('  带 ctrlKey:true（渲染器就是认这个）', pdf.dispatched[0].ctrlKey === true);
  check('  拉开（放大）→ deltaY = -100（一个标准刻度）', pdf.dispatched[0].deltaY, -100);

  // ★ 刻度总数由**捏合比例**决定（对数），不是由时间决定 —— 这是"自限"的关键。
  //   拉开 2 倍 → log(2)/log(1.2) ≈ 3.8 个刻度（≈1.2^3.8 ≈ 2 倍）
  for (let i = 0; i < 50; i++) c.flushRaf();
  const total = pdf.dispatched.length;
  checkTrue('★ 拉开 2 倍 → 共约 3~4 个刻度（自限，不会飙到底）',
    total >= 3 && total <= 4, 'total=' + total);
  checkTrue('  全是同一个方向（放大）', pdf.dispatched.every((e) => e.deltaY === -100));
}
{
  // 浏览器里（页面可滚）也要能缩放文档 —— 这条路径**不**受"页面不可滚"限制
  const two = (d) => [
    { clientX: 400 - d / 2, clientY: 300 },
    { clientX: 400 + d / 2, clientY: 300 },
  ];
  const c = makeCtx({ pageScrollable: true });
  const pdf = makeEl('pdfjs-canvas');
  c.docHandlers.touchstart.forEach((f) => f({ target: pdf, touches: two(200), cancelable: true, preventDefault() {} }));
  c.docHandlers.touchmove.forEach((f) => f({ target: pdf, touches: two(400), cancelable: true, preventDefault() {} }));
  c.flushRaf();
  checkTrue('页面可滚（浏览器）时也派发合成事件', pdf.dispatched.length === 1);
}

console.log('== ★ 拖动时必须 preventDefault（取消浏览器自己的平移）==');
{
  const c = makeCtx();
  const sheet = makeEl('luckysheet-cell-main');
  c.bars['luckysheet-scrollbar-y'].scrollTop = 100;
  checkTrue('touchmove 监听是 passive:false（passive 时 preventDefault 会被忽略）',
    !!(c.docOpts.touchmove && c.docOpts.touchmove.passive === false),
    JSON.stringify(c.docOpts.touchmove));

  touchStart(c, 400, 400, sheet);
  const ev1 = touchMoveEv(c, sheet, 400, 360);
  // 真机反馈：不 preventDefault 时浏览器/外壳会同时做自己的平移 → 整个视窗（标题栏）跟着动
  checkTrue('★ 表格区域内拖动 → preventDefault', ev1.prevented);
}
{
  const c = makeCtx();
  const pdf = makeEl('pdfjs-canvas');
  touchStart(c, 400, 400, pdf);
  const ev2 = touchMoveEv(c, pdf, 400, 360);
  checkTrue('非表格区域 → 不 preventDefault（不干扰 PDF.js）', !ev2.prevented);
}
{
  const c = makeCtx();
  const sheet = makeEl('luckysheet-cell-main');
  c.docHandlers.touchstart.forEach((f) => f({
    target: sheet, touches: [{ clientX: 1, clientY: 1 }, { clientX: 2, clientY: 2 }],
    cancelable: true, preventDefault() {},
  }));
  const ev3 = touchMoveEv(c, sheet, 400, 360);
  checkTrue('多指（缩放）→ 不 preventDefault', !ev3.prevented);
}

console.log('== 生效条件（缺一不可）==');
{
  const c = makeCtx({ pageScrollable: true });          // 浏览器：页面可滚
  const sheet = makeEl('luckysheet-cell-main');
  c.bars['luckysheet-scrollbar-y'].scrollTop = 100;
  touchStart(c, 400, 400, sheet);
  touchMove(c, sheet, 400, 360); c.flushRaf();
  check('★ 页面自己能滚 → 不干预（交给浏览器）',
    [c.bars['luckysheet-scrollbar-y'].scrollTop, sheet.dispatched.length], [100, 0]);
}
{
  const c = makeCtx();
  const pdf = makeEl('pdfjs-canvas');                    // 非表格区域
  c.bars['luckysheet-scrollbar-y'].scrollTop = 100;
  touchStart(c, 400, 400, pdf);
  touchMove(c, pdf, 400, 360); c.flushRaf();
  check('★ 非表格区域（PDF）→ 不干预（不与 PDF.js 的触摸平移叠加）',
    [c.bars['luckysheet-scrollbar-y'].scrollTop, pdf.dispatched.length], [100, 0]);
}
{
  const c = makeCtx();
  const sheet = makeEl('luckysheet-cell-main');
  c.bars['luckysheet-scrollbar-y'].scrollTop = 100;
  c.docHandlers.touchstart.forEach((f) => f({
    target: sheet, touches: [{ clientX: 1, clientY: 1 }, { clientX: 2, clientY: 2 }],
  }));
  touchMove(c, sheet, 400, 360); c.flushRaf();
  check('★ 多指（缩放）→ 不干预', c.bars['luckysheet-scrollbar-y'].scrollTop, 100);
}
{
  const c = makeCtx({ withBars: false });                // 拿不到滚动条 → 兜底 wheel
  const sheet = makeEl('luckysheet-cell-main');
  touchStart(c, 100, 400, sheet);
  touchMove(c, sheet, 100, 360);
  check('拿不到滚动条 → 退回伪造 wheel', sheet.dispatched.length, 1);
}

console.log('== Ctrl + 滚轮缩放（表格区域）==');
{
  const c = makeCtx();
  const sheet = makeEl('luckysheet-cell-main');       // ★ 现在要带 target：只对表格区域生效
  checkTrue('已挂载 window 的 wheel 监听', (c.winHandlers.wheel || []).length === 1);
  const fire = (o) => {
    let prevented = false, stopped = false;
    const ev = Object.assign({
      target: sheet,
      preventDefault() { prevented = true; }, stopPropagation() { stopped = true; },
    }, o);
    c.winHandlers.wheel.forEach((f) => f(ev));
    return { prevented, stopped };
  };

  fire({ ctrlKey: true, deltaY: -100 });                 // 向上滚 → 放大
  check('Ctrl+上滚 → setSheetZoom(1.05)', c.setSheetZoomCalls, [1.05]);
  fire({ ctrlKey: true, deltaY: 100 });                  // 向下滚 → 缩小
  check('Ctrl+下滚 → setSheetZoom(1)', c.setSheetZoomCalls, [1.05, 1]);

  // 不带 Ctrl → **自己接管滚动**（上游那套是固定步进，一格只滚 10~30px，太慢）
  c.bars['luckysheet-scrollbar-y'].scrollTop = 500;
  const r1 = fire({ ctrlKey: false, deltaY: 100 });
  check('不带 Ctrl → 不缩放', c.setSheetZoomCalls.length, 2);
  check('★ 不带 Ctrl → 自己按 deltaY 滚（+100 × 1.5 = +150px）',
    c.bars['luckysheet-scrollbar-y'].scrollTop, 650);
  checkTrue('  且拦截掉上游那套慢速滚轮', r1.prevented && r1.stopped);

  const r2 = fire({ ctrlKey: true, deltaY: -100 });
  checkTrue('带 Ctrl → 拦截（挡住浏览器/外壳自己的缩放）', r2.prevented && r2.stopped);

  for (let i = 0; i < 300; i++) fire({ ctrlKey: true, deltaY: -100 });
  const last = c.setSheetZoomCalls[c.setSheetZoomCalls.length - 1];
  checkTrue('缩放被 clamp 在 4 以内', last <= 4, 'last=' + last);

  // ★ 0.5.43：非表格区域**不许**拦截 —— 否则会把我们给其它渲染器合成的
  //   ctrl+滚轮事件一起 stopPropagation 掉，PDF / Word 就收不到、双指缩放失效
  const pdf = makeEl('pdfjs-canvas');
  const before = c.setSheetZoomCalls.length;
  const r3 = c.winHandlers.wheel.reduce((acc, f) => {
    let prevented = false, stopped = false;
    f({
      target: pdf, ctrlKey: true, deltaY: -100,
      preventDefault() { prevented = true; }, stopPropagation() { stopped = true; },
    });
    return { prevented: acc.prevented || prevented, stopped: acc.stopped || stopped };
  }, { prevented: false, stopped: false });
  check('非表格区域的 Ctrl+滚轮 → 不缩放表格', c.setSheetZoomCalls.length, before);
  checkTrue('★ 且不拦截（放行给 PDF.js 等渲染器）', !r3.prevented && !r3.stopped);
}

console.log('== 非触摸设备（桌面）==');
{
  const c = makeCtx({ touchDevice: false });
  checkTrue('没有 ontouchstart → 不挂触摸监听', !c.docHandlers.touchstart);
  checkTrue('但 Ctrl+滚轮缩放仍挂载（桌面本来就用它）', (c.winHandlers.wheel || []).length === 1);
}

console.log();
if (failed === 0) {
  console.log('✅ fv-web-patch：拖动/惯性/生效条件/Ctrl+滚轮缩放 全部正确');
} else {
  console.log('❌ 有断言失败');
}
process.exit(failed);
