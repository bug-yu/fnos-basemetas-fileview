# 更新说明

包版本号与预览引擎版本**解耦**：包版本 `0.5.x` 对应引擎 `basemetas/fileview:1.5.2`。
只改外壳（配置 / nginx / 图标）时末位 +1；升级引擎镜像时整段跟着抬（如引擎 1.6.0 → 包 0.6.0）。
飞牛靠版本号**递增**判断升级安装，同版本不允许覆盖安装。

---

---

## 0.5.48

### 一、诊断的结论：**这不是性能问题**（数据说话）

0.5.47 想直接测上游重绘耗时，真机读数是 **`n0`（从未被调用）** ✗ —— 原因：
`luckysheetscrollevent` 内部是通过**模块内 `import`** 调 `luckysheetrefreshgrid` 的，
**不走 `luckysheet.` 这个属性**，所以包属性拦不到。（`core.js` 里那个赋值只是给外部调用者的副本。）

**但同一张截图给了更强的证据**：

```
wrRaf105 wrTo0 dt11ms mx14
```

`requestAnimationFrame` 是**跟着显示帧**走的 —— 它 11ms 一次，说明**帧率约 90fps**；
而如果重绘很慢，主线程会被占住、帧率会掉、`dt` 会变大。所以：

> **重绘不是瓶颈，这不是性能问题。** 结合 `drift 0`（写入没被顶掉）、
> `wrTo 0`（兜底没抢跑）、`tm105 / wrRaf105`（严格 1:1）——
> **机制运转是健康的。**

### 二、那"慢"在哪：**甩的速度被低估了**

原来算惯性速度只用**最后一帧**的位置差。而手指在**抬手前通常会减速** ——
于是"甩"的速度被严重低估 → 松手后滑不远（真机反馈"慢"）。
原生系统都是取**最近 50~100ms 的平均速度**。

**改成取最近 ~60ms 时间窗口的首末两点**算速度。

> 效果（单测里能量化）：同样的一次甩动，滑行距离从 **447 → 821**（约 1.8 倍）。
> 叠加 0.5.47 的衰减调整（0.85/帧 → 0.938/帧），总滑行距离约为原来的 **3 倍以上**。

### 三、新增可选开关 `SYNC_REFRESH`（默认关）

写入后**立刻**同步调一次 `luckysheet.luckysheetrefreshgrid(x, y)`，消掉"等 scroll 事件"那一跳。

⚠️ **默认关** —— 上游随后还会因 scroll 事件再重绘一次，开了就是**每帧两次重绘**。
如果觉得"内容比手指慢半拍"，改一行打开试试：

```bash
sed -i 's/var SYNC_REFRESH = false;/var SYNC_REFRESH = true;/' \
  /vol1/@appcenter/basemetas-fileview/docker/fv-web-patch.js
docker exec basemetas-fileview-gateway nginx -s reload
```

## 0.5.47

### 一、诊断改成**直接测量上游重绘耗时**

真机读数（App 与平板浏览器各一张）解读：

```
ts10 tm33 te10 raf46 wr77
wrRaf33 wrTo0 dt742ms          ← dt 是"假"的（见下）
wheel0 ctrlW0 pgScroll0
sbY 754/3705/535 drift 0       ← ★ 关键：drift = 0
```

**好消息（数字全部自洽）**：

- **`drift 0`** → 我们的写入**没有被任何人顶掉** → 不是"冻结行列 `scrollAdapt()` 打架"
- **`wrTo 0`** → 兜底定时器没抢跑
- `wr77 = wrRaf33 + 惯性写入 44`、`raf46` → 与设计一致（惯性走 `write()` 不经计数器）

**但 `dt 742ms` 是我测错了**：`lastRafT` 跨手势没重置，把**两次拖动之间的停顿**也算成了帧间隔 ✗

**修正 + 升级**：

1. 按手势重置 `lastRafT`，并丢弃 `> 200ms` 的间隔（那是手势之间的停顿）
2. 新增 `dtMax`（单次最大帧间隔，比平均值可靠）
3. **把公开 API `luckysheetrefreshgrid` 包一层计时** —— **直接测上游重绘耗时**，
   这才是判断"卡"到底是我们还是上游天花板的**直接证据**（不改行为，只计时）

徽标新增一行：

```
redraw 12.3ms max 41.2 n37
```

- `redraw` 平均 ≲ 8ms → 重绘不是瓶颈，问题在我们的调度
- **`redraw` ≥ 16ms** → 上游重绘就是瓶颈（画布只有一屏，每帧必须重绘）→ 架构天花板

### 二、惯性滑行调长

原来衰减 `0.99/ms`（每帧 ≈ **0.85**）→ 停得太快，手感"滑不远"。
改成 **`0.996/ms`（每帧 ≈ 0.938）**，停止阈值 `0.02 → 0.01` —— 滑行距离约 **3 倍**，更接近原生。

> 两个常量都在补丁里写着，嫌长/嫌短都能一行调。

## 0.5.46

修 **「鼠标滚轮滚表格太慢」**。

**根因**：滚轮走的是 Luckysheet **自己的**处理器，而它是**固定步进**：

```js
let scrollNum = event.deltaFactor < 40 ? 1 : event.deltaFactor < 80 ? 2 : 3;
scrollTop = scrollTop + 10 * scrollNum;      // 一格只滚 10~30px
```

**完全不看 `deltaY` 的大小** —— 所以一格滚 10~30px，慢得离谱。

**做法**：在 `window` 的 **capture 阶段**接管普通滚轮（比上游那份 `document` capture 更早），
自己按 `deltaY` 滚，然后 `stopPropagation()` 把上游那套挡掉：

```
WHEEL_SPEED = 1.5        // 一格（deltaY=100）→ 150px；嫌慢调大、嫌快调小
```

同时按 `deltaMode` 把「行 / 页」归一成像素（`deltaMode===1` ×16、`===2` ×100）。

**只对表格区域生效**（`inLuckysheet(ev.target)`）—— 其它格式的滚轮完全不受影响 ✓

> 这一条也顺带让滚轮**不再按行吸附**（上游那套会吸附到行边界）。

### 关于「手指滚动也慢还卡」

**本版没有动它** —— 因为它的病因有**两种可能，修法完全不同**，必须先看诊断读数：

| 读数 | 病因 | 能不能修 |
|---|---|---|
| `drift` ≠ 0 | 有别人在改滚动位置（最可疑：**有冻结行列**时上游调的 `scrollAdapt()`） | ✅ 能修 |
| `dt ≥ 33ms` | Luckysheet **每帧重绘跟不上**（画布只有一屏，见 0.5.45 的说明） | ❌ 架构天花板 |
| `wrTo` 很大 | 兜底定时器在抢跑 | ✅ 能修 |

**有了读数就不用再猜** —— 这是这几轮最省时间的一条经验。

## 0.5.45

### 一、工具栏改为**始终显示**（修「PDF 无法旋转」）

**现象**：平板上预览 PDF 时**没有工具栏**，于是**没法旋转页面**。

**根因**：上游 `utils/device.ts` 用 `maxTouchPoints` 判断 `isPhoneFun()` / `isPadFun()`，
真机（华为 HarmonyOS NEXT 平板）上 `isMobile = true` → **工具栏整条不渲染**（不是被隐藏，
是根本没渲染）。

而 0.5.23 的补丁**只在非移动端 UA 上**归零 `maxTouchPoints`
（当时的理由是"怕禁用平板的触摸手势"）→ 真平板正好落在"不归零"那一侧 → 工具栏消失 ✗

**做法**：**无条件**归零 `maxTouchPoints`：

- 只归零它，**不动 `ontouchstart`** —— 用 `ontouchstart` 判断触摸的库不受影响
- 留了开关：`nginx.conf` 里把 `var FORCE_DESKTOP=true;` 改成 `false` 即可退回旧行为
  （改完 `nginx -s reload`，不用重装）

> ⚠️ **需要真机验证**：平板上 PDF 的**单指触摸滚动是否仍正常**。
> 若失效 → 把 `FORCE_DESKTOP` 改回 `false`（并告诉我，我换别的办法保住两者）。

### 二、诊断新增「滚动位置漂移 `drift`」

徽标多一项：**我们写进去的目标值** vs **元素实际停留的值**。

- `drift 0` → 我们的写入没被顶掉
- **`drift` 不为 0** → 有别人在改滚动位置 —— 最可疑的是 Luckysheet 在**有冻结行列**时
  调用的 `luckysheetFreezen.scrollAdapt()`，它会把我们的写入顶掉，那正是「段落感」的一个来源

### 三、关于「Excel 能不能用 Word 那套逻辑」

**不能** —— 读源码确认了架构差异（`controllers/resize.js`）：

```js
$("#luckysheet-cell-main").height(Store.cellmainHeight);   // = 视口高度
Store.luckysheetTableContentHW = [ ... ];
$("#luckysheetTableContent").attr({ width: ..., height: ... })   // 画布 = 视口大小
```

**画布只覆盖可见视口**，不是整张表。所以：

| | Word / PDF | Excel |
|---|---|---|
| 内容是什么 | **真实 DOM**（文本、图片） | **canvas**（`#luckysheetTableContent`） |
| 滚动由谁做 | 浏览器原生（合成器，60fps、原生惯性） | 我们写 `scrollTop` → Luckysheet **重绘画布** |
| 滚动时浏览器要做什么 | **什么都不用做**（画好的内容平移即可） | **必须重绘**（画布只有一屏） |

→ 原生滚动在 Excel 上**架构上做不到**（一滚就会露出空白）。
Word 的顺滑**不是"某个技巧"，而是"内容本身就是 DOM"**。

所以 Excel 的顺滑度上限 = **Luckysheet 每帧重绘画布的开销**。要确认是不是这个上限，
就看诊断里的 `dt`（帧间隔）：`dt ≥ 33ms` 就是重绘跟不上。

## 0.5.44

修 **「双指缩放太灵敏，一下子变很大或很小」**。

### 先查证：不是"松手才跳"

`setSheetZoom` 内部**没有防抖** —— 它是直接
`Store.zoomRatio = zoom; zoomNumberDomBind(); zoomRefreshView();`
（那个 100ms 防抖在另一个函数 `zoomChange` 里，公开 API 走的是这条直接路径）。
→ 所以问题出在**调用频率**上，两条路径都要改。

### ① 其它格式（PDF / Word）：改成"对数刻度 + 每帧最多一个"

这些渲染器的滚轮处理器多半是「**一个事件 = 一个固定缩放步进**」
（和 Luckysheet 的滚轮处理器一个思路 —— **根本不看 `deltaY` 的大小**）。
而 0.5.43 是**按 `touchmove` 频率（~60/s）**派发事件的 → 缩放直接飙到底 ✗

现在把捏合的**对数比例**换算成**离散滚轮刻度**：

```
刻度数 = log(捏合比例) / log(NOTCH_BASE)      // NOTCH_BASE 默认 1.2（可调常量）
每帧最多派发 1 个刻度，deltaY = ∓100
```

**刻度总数由捏合比例决定**（拉开 2 倍 ≈ 3.8 个刻度）→ **天然自限**，不会飙到底 ✓

> 用户反馈"太灵敏"，所以取 1.2（常见浏览器 Ctrl+滚轮一档约 1.2 倍），
> **宁可偏慢也不能再偏灵敏**。觉得还灵敏就把 `NOTCH_BASE` 调大、觉得太慢就调小。

### ② 表格区域：缩放也按帧节流

`setSheetZoom` 内部会 `zoomRefreshView()`（**完整重排 + 重绘**）。
每个 `touchmove` 都调会让它**跟不上手指** → 手感"跳" ✗

现在只记最新目标值，**每帧最多应用一次**（rAF + 50ms 兜底，与滚动写入同一套思路）。

另外加了保护：**起手两指太近（< 30px）时不缩放** —— 否则距离比 `d/d0` 会爆掉。

### 三、测试

`fpk/tools/test_web_patch.js` 扩到 **43 条断言**全过，新增：
「未到帧边界不应用 `setSheetZoom`」「帧边界派发一个刻度且 `deltaY = -100`」
「**拉开 2 倍 → 共约 3~4 个刻度（自限）**」「刻度全为同一方向」。

## 0.5.43

### 一、双指缩放扩到**所有格式**（原来只对 Excel 生效）

**现象**：其它格式（Word / PDF 等）双指缩放时，缩放的是**页面 / 标题窗口**，不是文档；
而 **Ctrl+滚轮是正常的**。

**根因**：那些渲染器（PDF.js / Word 预览）**只认 `Ctrl+滚轮`，不处理触摸 pinch**；
而 pinch 的默认行为由 CSS `touch-action` / viewport 决定 —— 没人拦，就落到浏览器 / 应用外壳
头上 → 缩放的是页面而不是文档。

**用户实测「Ctrl+滚轮才是正常的缩放」就是证据**：它们认这条路 ✓

**做法**：

1. **把 pinch 翻译成合成的 `ctrl+滚轮`**：全局拦双指 → 算两指距离比 → 合成
   `wheel`（`ctrlKey: true`、`deltaY` 按比例）派发给手指下的元素 → 各渲染器走它们**本来就支持**的那条路
2. **注入 `body { touch-action: pan-x pan-y }`** —— 保留**原生平移**、**禁止缩放**，
   于是浏览器不再缩放网页、飞牛 App 不再缩放整个页面
3. 给我们自己的 ctrl+滚轮处理**加区域判断**（只对表格生效）—— 否则它会 `stopPropagation`
   掉刚合成的 ctrl+滚轮事件，其它渲染器就收不到了 ✗

> ⚠️ **`touch-action` 的有效值是「沿祖先链取最严」**：
> `body` 写 `pan-x pan-y`，而 Luckysheet 子树自己写着更严的 `none` → 取 `none`
> → **表格区域完全不受 body 这条影响**，Excel 的滚动/缩放行为不变 ✓

**按帧节流**：合成的 ctrl+滚轮是**每帧最多一个**，一帧内累计的距离**合并成一个 `deltaY`**
再派发 —— 否则 60/s 的事件会让渲染器每帧重排多次，缩放过程会卡。

### 二、"段落感"：放宽兜底 + 加诊断

0.5.42 的写入调度是「rAF 优先 + **24ms** 兜底」。而 **24ms 太贴近 16.7ms 的帧间隔** ——
rAF 稍慢一点，兜底就会**抢跑**，写入落在帧中间 → 这正是「段落感」的来源 ✗

- 兜底**放宽到 50ms**（只在 rAF 真的没来时才会启用，成为真正的安全网）
- 诊断徽标新增三个读数，用来**定位**（而不是继续猜）：
  `wrRaf`（rAF 写入数）/ `wrTo`（兜底写入数）/ `dt`（实测帧间隔）

> 判定：`wrTo` 很大 → 是兜底抢跑（本版已修）；`wrTo ≈ 0` 但 `dt ≥ 33ms`
> → 是 Luckysheet 的 canvas 重绘跟不上（外部补丁改不动，只能考虑改成原生滚动）。

### 三、测试

`fpk/tools/test_web_patch.js` 扩到 **40 条断言**全过，新增：
「其它格式的双指 → 帧边界派发合成的 ctrl+滚轮且带 `ctrlKey`、放大时 `deltaY < 0`」
「页面可滚（浏览器）时也派发」「非表格区域的 Ctrl+滚轮 → 不缩放表格且**不拦截**（放行给渲染器）」。

## 0.5.42

把写入从「时间节流」改成「**按帧调度**」，修「不够顺滑」。

### 先把上限摸清（读 Luckysheet 源码）

它的滚动路径**已经是最小的**，没有可省的地方：

| 查了什么 | 结论 |
|---|---|
| 谁触发重绘 | `#luckysheet-scrollbar-x/-y` 各绑一个 `scroll` → `luckysheetscrollevent()` → **一次 `luckysheetrefreshgrid()`** |
| 会不会级联 | 列表头（`#luckysheet-cols-h-c`）、行表头（`#luckysheet-rows-h`）、主区（`#luckysheet-cell-main`）**都没有** `scroll` 监听 → **不会级联重绘** |
| 有没有失控循环 | `scroll.js` 里那个自我续订的 `requestAnimationFrame` 循环（`execScroll`）**在启动处被上游注释掉了** → 没有 |

→ 所以**一次写入 = 一次完整重绘**，无法再减。

### 那问题在哪：**写的时间点**

0.5.41 用的是 **14ms 时间节流** —— 写入落在**帧中间**，重绘也跟着落在帧中间：
某一帧可能重绘两次、下一帧零次 → **"打拍子"式的微抖** ✗ 这就是「不够顺滑」。

**改成用 `requestAnimationFrame` 调度**：

- 写入对齐到**帧边界**（每帧最多一次，重绘跟着落在同一帧内）
- 再挂一个 **~24ms 的 `setTimeout` 兜底** —— 万一 webview 节流了 rAF，也能靠它写进去
- 松手时 `flushWrite()` 补一次最终位置

> 为什么不用纯 rAF：0.5.38 的教训 —— rAF 可能被 webview 节流，纯靠它会让功能整体失效。
> 所以是「rAF 优先 + 定时器兜底」，两者都不可用才立刻同步写。

### 测试

`fpk/tools/test_web_patch.js` **34 条断言**全过。相关断言改为：
「同一帧内多次 move → 只排队 1 次 rAF」「未到帧边界前不写」「帧边界写入取最后一次位置」
「一帧只写一次」「松手补一次最终位置」。

## 0.5.41

### 一、双指缩放：改为缩放**工作表**（原来缩放的是整个页面）

**Luckysheet 没有触摸缩放手势**（它是桌面组件），而浏览器 / 应用外壳默认把双指缩放
用在**整个页面**上 —— 真机反馈：浏览器里缩放的是网页、App 里缩放的是整个页面。

**修法**：

1. 自己算**两指距离比**，映射到 `luckysheet.setSheetZoom()`（与 Ctrl+滚轮共用同一套读写）
2. 用 CSS **`touch-action: none`** 把「页面缩放手势」从表格区域摘掉

> ⚠️ **`preventDefault()` 对 pinch 无效** —— 能不能取消由 CSS `touch-action` /
> viewport 决定。这是这次的关键点：只靠 `preventDefault` 是拦不住页面缩放的。

**生效条件与拖动一致**（页面本身不可滚 + 手指落在表格区域内），
所以浏览器里的行为完全不变。

### 二、修「跟手延迟很高」

0.5.40 每次 `touchmove` 都**同步写** `scrollTop` —— 而**每次写都会触发 Luckysheet
全量重绘 canvas**，重绘跟不上手指，就成了"延迟高"。

现在按**时间节流**（每 ~14ms 最多写一次），松手再**补一次最终位置**（否则可能差最后一帧）。

> ⚠️ 用**时间节流**而不是 `requestAnimationFrame`：rAF 可能被 webview 节流，
> 那样就会整体失效（0.5.38 的教训）。rAF 只留给"锦上添花"的惯性动画。
> 另外 `lastWriteT` 初值必须是 `-1e9` 而不是 `0` —— 否则页面刚加载、
> `now()` 还很小时，`t - 0 < 14` 会把**第一次**写入也节流掉。

### 三、测试

`fpk/tools/test_web_patch.js` 扩到 **34 条断言**全过，新增：
「两指拉开 2 倍 → setSheetZoom(2)」「非表格区域的双指不接管」「页面可滚时双指不接管」
「同一时刻的多次 move 只写一次」「时间推进 ≥14ms 后再写」「松手补一次最终位置」。

## 0.5.40

修 **「拖动时整个视窗（标题栏）跟着动、不顺畅」**。

### 根因

补丁的 `touchmove` 监听是 **`{ passive: true }`** —— 这种监听里 **`preventDefault()` 会被忽略**。
于是我们在驱动 Luckysheet 滚动的同时，**浏览器 / 应用外壳也在做它自己的平移与回弹**
（取消不掉），两套滚动打架 → 表现就是「整个视窗跟着动、不顺畅」。

### 修法

1. 该监听改成 **`{ passive: false }`**
2. 在**拖动时**调用 `preventDefault()` 取消浏览器自己的默认平移

**只在拖动时取消** —— 点选单元格（不 preventDefault，否则点选会失效）与多指缩放都不动它。

### 诊断徽标默认关掉

0.5.39 那版把它打开是为了拿现场数据，现在确认完毕 → `var DIAG = false;`
（以后要排查，把它改回 `true` 再 `nginx -s reload` 即可。）

### 0.5.39 诊断确认的两件事（记录）

| 环境 | 徽标读数 | 结论 |
|---|---|---|
| 平板（App） | `ts44 tm180 te44 raf258 wr366`、`sbY 94/3705/535`、`pgScroll0` | 触摸事件到达、rAF 在跑、**写入 366 次**、`scrollHeight > clientHeight` → **确实是可滚容器，触摸已能滚** ✓ |
| 电脑（浏览器） | `wheel161 ctrlW116` | 滚轮事件到达且**带 `ctrlKey`** → Ctrl+滚轮正常 ✓ |

## 0.5.39

修 0.5.38 引入的**触摸失效**、给 Ctrl+滚轮加兜底，并加一个**屏上诊断徽标**把现场数据拿回来。

### 一、修触摸失效（0.5.38 的回归）

0.5.38 给目标位置加了 `clamp(v, 0, scrollHeight - clientHeight)` —— 而 Luckysheet 的滚动条
**是自绘的**，`scrollHeight` 不一定反映内容高度 → `maxTop()` 可能是 **0**
→ 目标被钳死为 0 → **完全滚不动**。（0.5.37 能滚，就是因为它没 clamp。）

现在：**不做 clamp**（浏览器自己会把 `scrollTop` 钳在有效范围内），
并且拖动阶段改回**同步写** —— 不等 `requestAnimationFrame`
（webview 若节流 rAF，等它就会"滚不动"）。rAF **只用于松手后的惯性**。

### 二、Ctrl + 滚轮缩放：加 Ctrl 键自跟踪

真机上「缩放 ± 按钮能用」说明 `zoomInitial()` **确实被调用**了，
所以上游那份 Ctrl+滚轮监听也在 —— 但实测无效。两种可能（本版用诊断徽标确认）：

- webview 把带 Ctrl 的 wheel 事件**吞掉了**（JS 收不到）；
- 或者收到了但 **`ctrlKey` 被剥掉**（修饰键状态没传进来）→ `!ev.ctrlKey` 直接 return。

所以除了看 `ev.ctrlKey`，还用 `keydown`/`keyup` **自己记一份 Ctrl 的按下状态** ✓。
另外缩放块不再依赖触摸块里的 `clamp`（那是 `var` 提升的隐式耦合 —— 触摸块若没执行到
赋值那一步，缩放就会抛异常静默失效）。

### 三、屏上诊断徽标（临时）

左下角一小条，显示：

```
ts.. tm.. te.. raf.. wr..        ← touchstart/touchmove/touchend 计数、rAF 次数、写入次数
wheel.. ctrlW.. pgScroll..       ← wheel 事件数、其中带 Ctrl 的、页面是否可滚
sbY scrollTop/scrollHeight/clientHeight
```

**最后一项最关键**：若 `scrollHeight == clientHeight`，说明它并不是真的可滚容器
（那就得换别的驱动方式）。`ctrlW` 为 0 而 `wheel` 不为 0 → 说明 **Ctrl 被吞了**。

排查完把补丁里的 `var DIAG = true;` 改成 `false` 即可（或等下一版移除）。

## 0.5.38

修触摸手感（补上惯性 + 消除抖动），并补上 **Ctrl + 滚轮缩放**。

### 一、触摸滚动：加惯性、每帧合并回写

0.5.37 是**每个 `touchmove` 都直接写 `scrollTop`** —— 一帧内 canvas 可能被重绘多次（抖），
而且**松手立刻停住**，没有原生的滑行感。

现在：

- 拖动**只更新目标位置**，由 `requestAnimationFrame` 统一回写 → **每帧最多重绘一次**
- 松手后按最后的速度**继续滑行**并指数衰减（约每 16ms 衰减到 0.85），速度低于阈值自动停
- **手指一碰立即停住惯性**（与原生一致）
- 掉帧时按实际时间差推进（`dt` 钳在 1~48ms），不会一跳一大段

### 二、Ctrl + 滚轮缩放工作表

**Luckysheet 自带这个功能**（`controllers/zoom.js` 里 `ZOOM_WHEEL_STEP = 0.02`，
绑在 `document` 上、`capture: true`），但它的监听是在 **`zoomInitial()`** 里绑的 ——
而本应用这套集成里那个初始化**不一定被调用**
（缩放滑杆的点击事件也是同一个函数绑的，所以滑杆很可能也是死的）。

所以补丁**自己绑一份**（`window` 的 capture 阶段，比上游那份更早），
直接调公开 API `luckysheet.setSheetZoom(ratio)`：

- 按 `deltaY` 缩放：一个滚轮刻度约 ±100 → 约 ±0.05；clamp 到 `0.1 ~ 4`
- `preventDefault()` + `stopPropagation()` 挡住浏览器 / 应用外壳自己的缩放
- 当前缩放**没有 getter**：首次从缩放标签 `#luckysheet-zoom-ratioText` 的文本懒读一次，
  之后用自己记的值（**不依赖**上游是否更新标签，那是个脆弱假设）

### 三、测试

`fpk/tools/test_web_patch.js` 扩到 **21 条断言**全过，新增：
「同一帧内 3 次 touchmove → 只排队 1 次 rAF / 只写一次」「松手后继续滑行」「惯性最终停下」
「手指一碰立即停止惯性」「Ctrl+上滚 → setSheetZoom(1.05)」「不带 Ctrl 不拦截」「clamp 到 4」。

> 测试桩的坑（记一下）：补丁①用 `defineProperty` 拦截了 `window.luckysheet` 赋值，
> 所以桩里的 `window.luckysheet` **必须在补丁加载之后**再赋，否则会被覆盖成 undefined。
> 这也更贴近真实 —— Luckysheet 是动态 `loadJS` 加载完才赋值的。

## 0.5.37

让平板在飞牛 App 里滑 Excel **跟手**（修 0.5.36 的手感问题）。

0.5.36 把单指滑动伪造成 `wheel` 事件 —— 能滚了，但手感是「**一格一格跳、像手指下面按了个滚轮**」。

**为什么伪造 wheel 不可能跟手**（读 Luckysheet 源码确认）：它的 wheel 处理器是**固定步进** ——

```js
let scrollNum = event.deltaFactor < 40 ? 1 : event.deltaFactor < 80 ? 2 : 3;
if (event.deltaY < 0) { scrollTop = scrollTop + 10 * scrollNum; }
```

**完全不看 `deltaY` 的绝对值**，而且还会按行边界吸附。所以无论把 deltaY 调大调小，
一个事件就是固定的 10~30px → 只能一格一格跳。

**改法**：Luckysheet 的滚动状态其实存在**真实 DOM** 上 ——
`#luckysheet-scrollbar-y` 的 `scrollTop`、`#luckysheet-scrollbar-x` 的 `scrollLeft`
（它源码里就是这么读写的）。所以改成**直接驱动这两个滚动位置**：

- `touchstart` 记住手指起点与当时的滚动位置
- `touchmove` 按「**距起点的绝对位移**」回写（不是逐帧累加，避免漂移）
- 手指上滑 → 内容向上滚，1:1 跟手

原伪造 wheel 保留为**兜底**（万一上游改版拿不到滚动条元素，至少还能滚，只是不跟手）。

生效条件不变（缺一不可）：**页面本身不可滚** + **手指落在表格区域内** ——
前者保证浏览器里行为完全不变，后者保证不与 PDF.js 自己的触摸平移叠加。

**测试**：`fpk/tools/test_web_patch.js` 扩到 **12 条断言**全过，新增
「走拖动路径时**不**派发 wheel」「抬手后不再拖动」「按距起点的绝对位移而非逐帧累加」。

## 0.5.36

修 **「平板在飞牛 App 里 Excel 表格无法用手指滚动」**（浏览器里正常、插鼠标滚轮也正常）。

**现象**（真机，华为 HarmonyOS NEXT 平板 + 飞牛 App）：同一台平板、同一个 xlsx ——
浏览器里手指能滑，App 里滑不动；鼠标滚轮两边都能滚。对照测试：**PDF 在 App 里手指能滚**、
**Excel 里手指能选中单元格**（说明触摸事件确实到达了渲染器）。

**真因**：Luckysheet 的滚动是**它自己实现的**，只接 `wheel` 事件；而手指滑动走的是
**页面滚动**。浏览器里页面本身可滚（内容比视口高），滑起来像"表格在滚"；
App 的 webview 视口固定、页面不可滚 → 手指滑就没有可滚的对象。
（PDF 用 PDF.js，自己处理触摸平移，所以不受影响。）

**修法**：在 `fv-web-patch.js` 里加一层兜底 —— **只当这两个条件同时成立时**，
把单指滑动翻译成 `wheel` 事件派发给手指下的元素：

1. **页面本身不可滚** —— 否则交给浏览器；浏览器里行为**完全不变**（不会双滚动）
2. **手指落在 Luckysheet 区域内** —— 否则可能与 PDF.js 自己的触摸平移叠加（双滚动）

纵向、横向都处理（表格很宽时要能左右滑）；多指（缩放）一律不干预。

**验证**：新增 `fpk/tools/test_web_patch.js` —— 用桩 DOM 在 node 里跑的逻辑回归测试，
**7 条断言**全过，含「PDF 区域不派发」「页面可滚时不干预」「多指不干预」「位移 0 不派发」。
已接进 `selfcheck.sh`。

## 0.5.35

修 **「压缩包内文件预览」被误拦** —— 这是 0.5.33 引入的**回归**（0.5.30 时该功能正常）。

### 一、现象与根因

打开压缩包本身没问题（目录能列出来），但**点包内文件提示「文件转换失败」**。

闸门日志里的决定性三行（真机，2026-10-07）：

```
拒绝 uid=1000 path=/vol1/1000/<目录>/<某压缩包>.zip/<包内目录>/<某文档>.docx
     —— 不可读 → 拦截（路径取自请求体 srcRelativePath，**未退回来源页**）
```

**根因**：引擎把「压缩包内文件」表示成**复合路径**

```
<压缩包绝对路径>/<包内路径>/<文件名>
```

这个路径**在文件系统上根本不存在**，所以闸门 `os.access()` 必然判定「不可读」→ 403。
0.5.33 之前是靠**来源页**（Referer，里面带压缩包路径）判定才放行的；
0.5.33 为了堵「合法来源页掩护非法请求体」的绕过，把这条退路**彻底关掉**，
却没考虑复合路径这种**合法形态** —— 于是包内文件全被拦死。

转换日志里**完全没有**那个包内文件的记录，也印证了它根本没到引擎。

### 二、怎么修的

引擎实际读的是**压缩包本身**（以 root 解包后再转换），所以真正该判的是**压缩包的 ACL**。
闸门新增 `resolve_archive_prefix()`：从长到短找出第一个**确实存在、且是普通文件**的前缀，
按它判 ACL。

| 情况 | 处理 |
|---|---|
| 复合路径 → 还原出压缩包，压缩包**可读** | ✅ 放行（转发给引擎） |
| 复合路径 → 还原出压缩包，压缩包**不可读** | ❌ 拒绝（保护仍在） |
| 复合路径 → **还原不出**（压缩包不存在） | ❌ 拒绝（不能凭构造放行） |
| 路径含 `..` | ❌ 拒绝，**不做**前缀还原（引擎自己的 `SecurePath` 也会拒这种路径） |

> ⚠️ **这与「退回来源页」有本质区别**：来源页由客户端完全控制，那才是被绕过的原因；
> 而这里还原出的路径**必须在文件系统上真实存在**，攻击者无法凭空构造。
> 所以堵绕过的那条规则没有被削弱 —— 只是补上了它漏掉的合法形态。

### 三、验证

`test_body_guard.py` 新增 6 条压缩包用例（矩阵共 **26 条**全过）：

- 压缩包可读 → 包内文件放行（**★ 0.5.33 曾误拦**）
- 压缩包不可读 → 拒绝
- 压缩包根本不存在 → 拒绝
- 含 `..` 的复合路径 → 拒绝
- 压缩包本身（非复合路径）可读 → 放行

`selfcheck.sh` 新增 3 条断言（`resolve_archive_prefix` 存在、`is_file` 已抽成可打桩、
压缩包内文件走「按压缩包判 ACL」而非退回来源页）。

### 四、顺带确认：`fileid_guard` 可以切 `enforce`

0.5.34 装完后真机跑了一遍全部预览类型，闸门日志里：

- **所有** `/preview/api/files/<fileId>` 请求**都带 `filePath`**（5 个样本，覆盖 PDF / DWG / xlsx / ofd）
- `grep -E "仅记录|观察"` **一条都没有**

→ 说明合法流程都带 `filePath`，切 `enforce` **不会误伤**。命令见 README「fileId 系接口」一节。

### 五、实机验证（2026-10-07）

装上 0.5.35 后，**压缩包内文件预览恢复正常**（0.5.33/0.5.34 时该功能被拦死、
界面显示「文件转换失败」）。同时复测了 PDF / Excel / Office / CAD / OFD 等主链路，
均正常。→ 回归已闭环。

## 0.5.34

堵上 **「fileId 可预测 → 绕过逐用户权限闸门」（高危）**。

### 一、漏洞是什么

排查「`/files/{fileId}` 系接口请求里没有路径、闸门天然看不见」这条残余风险时确认：

```
fileId = "preview_" + md5(原始绝对路径)[:16]
```

用两组真机数据（路径 + fileId）**离线验算，同时精确命中**（不是巧合）：

| 路径 | 真机 fileId | md5(路径)[:16] |
|---|---|---|
| `/vol1/1000/<示例目录>/<示例文档>.pdf` | `<示例md5-1>` | `<示例md5-1>` ✅ |
| `/vol1/1000/<示例目录>/<示例表格>.xls` | `<示例md5-2>` | `<示例md5-2>` ✅ |

**即 fileId 是路径的确定性函数 —— 它不具备任何保密性，知道路径就能算出来。**

而引擎源码 `serveFile()` 里路径参数是**可选**的：

```java
@GetMapping("/files/{fileId}")
public ResponseEntity<Resource> serveFile(
        @PathVariable String fileId,
        @RequestParam(required = false) String path) {      // ← path 可选
    ...
    if (path != null && !path.trim().isEmpty()) {
        filePath = path;
    } else {
        filePath = cacheInfo.getOriginalFilePath();         // ← 不给 path 就用缓存的**原始路径**
    }
```

闸门对这类请求看不到任何路径 → 走 `未解析到路径（放行）` → **放行**。

**攻击链**：

```
① 知道目标文件路径（如 /vol2/1000/别人的私有文件.docx）
② 算 fileId = "preview_" + md5(路径)[:16]
③ GET /app/basemetas-fileview/preview/api/files/<fileId>     ← 不带任何参数
④ 闸门：看不到路径 → 放行
⑤ 引擎：查缓存 → getOriginalFilePath() → 返回**原始文件**
```

**前提**：该 fileId 必须在预览缓存里（Redis，TTL `86400s`），即该文件 24h 内被**任何人**
预览过 —— **团队 / 共享文件正好命中这个前提**（有权限的人正常预览一次，缓存就热了）。

### 二、怎么修的

闸门对 fileId 系接口（`/preview/api/files/<fileId>`，含 `/page/N` 与 `/pages`）
**要求请求自带 `filePath`**：

| 情况 | 处理 |
|---|---|
| 带了 `filePath` | 按该路径正常判 ACL（**注意**：引擎在有 `path` 时就用它，所以"带自己的 filePath + 别人的 fileId"也取不到别人的文件 —— 测试里有这条用例） |
| 没带 `filePath` | 按 `fileid_guard` 处理：`log` 只记录 / `enforce` 拒绝 |
| 带了但与 fileId 的 md5 对不上 | **只记录**（可能是合法的变体写法），仍按该路径正常判 ACL |

### 三、⚠️ `fileid_guard` **出厂默认 `log`（只记录不拦）**

**这是有意的，不是漏做。** 理由：合法流程里 `/files/{fileId}/page/{n}` 与
`/files/{fileId}/pages` **没有日志样本**，无法确认它们是否都带 `filePath`；
盲切 `enforce` 有误伤风险 —— 而 0.5.31 / 0.5.32 两次翻车都是「本地自检全绿、真机才暴露」。

**升级后请按这个节奏做**：

1. 保持 `fileid_guard=log`，跑一遍**全部**预览类型 —— 尤其
   **PDF 多页翻页**、Excel、压缩包内文件、三维模型。
2. 看闸门日志里有没有「`fileid_guard=log 仅记录`」被记在**合法**请求上：
   ```bash
   docker logs basemetas-fileview-acl | grep fileid_guard
   ```
   **一条都不该有**（合法请求都带 `filePath`）。
3. 确认干净后，改成 `enforce`（立即生效，不用重启容器）：
   ```bash
   sed -i 's/^fileid_guard=.*/fileid_guard=enforce/' /vol1/@appdata/basemetas-fileview/acl.conf
   ```
4. 复验：构造「不带 filePath 的 `/files/<fileId>`」请求，应得 **403**。

### 四、验证

- `test_acl_decide.py` 新增 **10 条** fileId 用例（含 `/page/N`、`/pages`、
  「自己的 filePath + 别人的 fileId」、以及"其它接口不受影响"），并断言
  **md5 一致时不得产生「观察」记录**（这里踩过一个坑：拿带 `preview_` 前缀的 fileId
  去比不带前缀的 md5 → 永远不一致）。矩阵共 **22 条**全过。
- `selfcheck.sh` 新增断言：`FILEID_RE` 存在、`fileid_guard` 开关存在、拒绝分支存在、
  **出厂默认必须是 log**（防止有人"顺手"改成 enforce）、acl.conf 模板写出该键。

## 0.5.33

本版做两件事：**堵上 POST body 路径绕过（高危）**，以及**修 PDF 预览失败**。

### 一、堵上 POST body 路径绕过（高危）

「用 FileView 打开」的**第一步**是 `POST /preview/api/localFile`，它的文件路径
`srcRelativePath` 只在**请求体**里。而 nginx 的 `auth_request` 在 ACCESS 阶段执行，
**请求体还没被读**（`location = /__acl` 里 `proxy_pass_request_body off`），
所以鉴权子请求**物理上看不到 body**，只能退回用来源页（Referer）URL 里的 `path` 判定。

于是可以这样绕过：

```
① 先打开一个**自己有权读**的文件 → 拿到合法来源页 URL（里面带 ?path=我的文件）
② 再发 POST，请求体里换成**别人的**路径
→ 闸门拿来源页里那个合法路径判定并放行；请求体里的非法路径**根本没被看过**
```

**这不是推演，真机已复现**（2026-09-30，普通用户会话）：

```
[1] GET  对照                  → 403   闸门正常
[2] POST 无 Referer            → 200   绕过成立
[3] POST 带**合法** Referer    → 200   ⚠️ 掩护也成立（决定性）
```

`[3]=200` 直接否掉了「无来源页时 fail-closed」这条廉价路线 —— 攻击者总能先弄到一个合法来源页。

**受影响的不止一个接口**（引擎开源源码 `basemetas/fileview-backend` 枚举，路径均在 body）：

| 接口 | 后果 |
|---|---|
| `POST /preview/api/localFile` | 读任意绝对路径文件（**前端主链路**，不是边缘接口） |
| `POST /convert/api/srvFile` | **以 root 写任意可写路径**（引擎侧无任何根目录收敛） |
| `POST /preview/api/password/unlock` | 密码爆破 + 文件存在性探测 |
| `POST /preview/api/netFile` | SSRF 面（0.5.22 已用 `trusted-sites=none.invalid` 关闭） |

**关键的不对称**：`GET /preview/api/file?filePath=` 同样能读任意绝对路径，
但它的路径在 **query** 里 → nginx `$arg_*` 取得到 → **闸门判得到，是受保护的**；
而 POST 那侧路径在 **body** 里 → **判不到**。同一个能力，一侧被管住，一侧敞开。

**修法（不依赖 njs）**：

1. **让闸门真正读到 body** —— 这几个接口**不走 `auth_request`**，
   改由 nginx 把**整个请求**代理给闸门的 `/guard`：

   ```
   闸门读请求体 → 取出真实路径 → 按 uid 判 ACL → 通过后**由闸门自己转发**给引擎
   ```

   关键在「**由闸门自己转发**」—— 于是「判定的路径」与「引擎实际读的路径」
   必然是同一个值，不存在"看得见一份、读的是另一份"的空隙。
   判定**只用请求体里的路径，绝不退回来源页**。

2. **封掉用不到的高危接口**：`/convert/api/srvFile`（root 写）在网关层直接 403。
   `password/unlock`（密码探测）**不封禁而是走闸门** —— 加密压缩包解锁功能保留，
   但路径先过逐用户 ACL 判定。

3. **fail-open 保持不变**：闸门不可用时 nginx `error_page` 直连引擎。
   最坏情况仍是"没保护"，不会变成"应用打不开"。

4. **可单独回退**：`${TRIM_PKGVAR}/acl.conf` 新增 `body_guard=enforce|log`，
   与原有的 `mode` 是**两个独立开关**（只想退回这一层就别动 `mode`）。改完立即生效，不用重启容器。

### 二、修 PDF 预览失败

**症状**：PDF 打不开，其它格式看起来正常。引擎日志里决定性的一行：

```
RequestAwareBaseUrlProvider - ✅ 动态生成baseUrl - Result: http://fileview
✅ 文件预览请求处理成功 - URL: http://fileview/preview/api/files/preview_e3f2…?filePath=…pdf
```

引擎拼出的绝对地址是 **`http://fileview`** —— 浏览器当然打不开。

**根因**：`localFile` 改由闸门（Python）转发给引擎，而转发只带了一个**白名单头**，
把 `Host` 与 `X-Forwarded-*` 全丢了。引擎的 `RequestAwareBaseUrlProvider` 是**按请求头**
推导 baseUrl 的：

| 转发时带的头 | 引擎拼出的 baseUrl |
|---|---|
| 正确（`Host` + `X-Forwarded-Proto` + `X-Forwarded-Prefix`） | `https://<域名>:<端口>/app/basemetas-fileview` ✅ |
| 只按目标 URL 生成 `Host: fileview:80` | `http://fileview` ❌ |

nginx 在 guard location 里其实**设了** `Host $ext_authority`，但**闸门没往下传**。

> **为什么只有 PDF 失败**：PDF 渲染器**直接使用** `localFile` 返回的绝对 URL 去取文件；
> 而 ofd / xlsx 等渲染器走**相对路径**（相对当前页面 `/app/basemetas-fileview/preview/view`），
> 自然带上了前缀、看起来完全正常。

**修法**：

1. 闸门的转发白名单补上 `host` 与
   `x-forwarded-proto / -prefix / -host / -port / -for / x-real-ip`
   （`urllib` 的语义：headers 里带 `Host` 时会 `skip_host`，即**用我们给的值**，不会被目标 URL 覆盖）。
2. nginx 的两条 guard location 与 fail-open 落点补上 `X-Forwarded-Host` / `X-Forwarded-Port`
   （与主 location 对齐）。
3. `test_body_guard.py` 新增 5 条断言：引擎必须收到正确的
   `Host` / `X-Forwarded-Proto` / `X-Forwarded-Prefix` / `X-Forwarded-Port`，
   且内部头 `X-Acl-*` **不得**透给引擎。

### 三、验证

- **判定矩阵单测** `fpk/tools/test_body_guard.py`：**20 条**，用**桩引擎**验证转发链路
  （不依赖 docker / nginx）。核心用例是 **「来源页合法 + 请求体私有 → 必须 403」**；
  另有 5 条盯着转发头。
- **`selfcheck.sh` 新增断言**：body-path 接口必须用 `location =` 精确匹配、fail-open 落点存在、
  `proxy_intercept_errors on` 存在、`srvFile` 已封禁、`password/unlock` 未被封禁、
  闸门清单与 nginx 路由一致；并把两个 nginx 检查器**接进自检**。
- **实机验证（2026-10-07）**：三容器正常 `Up`（网关不再重启）；
  闸门日志显示 `可读（路径取自请求体 srcRelativePath，未退回来源页）`；
  **PDF 恢复正常预览**。

---

### 附：开发过程中的两个中间版本（均已作废，未发布）

| 版本 | 问题 |
|---|---|
| `0.5.31` | 首次实现时把 body-path 接口的代理写成了 **regex location + 带 URI 的 `proxy_pass`** —— nginx 明确禁止这种组合，属**启动期 emerg**，网关容器无限重启。**从未生效。** |
| `0.5.32` | 改用 `location =` 精确匹配修好了启动问题，但**闸门转发时丢了 `Host` / `X-Forwarded-*`**，导致 PDF 打不开。 |

两个中间版本留下的教训（已固化成检查，值得记住）：

1. **regex / 命名 / `if` / `limit_except` 里 `proxy_pass` 不能带字面量 URI 部分** ——
   能用 `location =`（精确匹配）就用它：不受这条限制，且优先级高于任何 regex
   （顺带绕开「regex 顺序」这个坑）。含 `$` 变量的写法不受限。
2. **自建代理转发时不能只挑几个头** —— `Host` 与全套 `X-Forwarded-*` 必须带上，
   否则被代理的服务会拼出内网地址（`http://fileview` 这种）。
   **nginx 侧设了、代理侧还要再传一次**，只在一边做等于没做。
3. **`error_page` 只处理 nginx 自己产生的错误** —— 上游返回的 502 想被兜底，
   必须 `proxy_intercept_errors on`。
4. **检查器存在 ≠ 检查器在跑** —— `check_nginx_conf.py` / `check_nginx_map.py`
   此前从未被 `selfcheck.sh` 调用；现已接入，并补上「`proxy_pass` 带字面量 URI 却在受限块里」这条规则
   （含阳/阴性对照）。
5. **本地自检全绿 ≠ 真机能跑** —— 这两次都是本地全绿、真机才暴露。
   回归测试必须覆盖用**绝对地址**的渲染器（PDF），只测相对路径的（ofd / xlsx）会漏掉。

## 0.5.30

本版是**审查整改版**：修掉 0.5.25 引入的一个回归，并把三项"明知而接受"的风险写成显式声明。

### 一、修「开放 API 预检」失效（回归）

0.5.25 的审计把 `api-scope` 误判成「未使用」删掉了，而预检脚本从 0.5.9 起就一直在调那三个开放接口。

- **这是怎么发生的**：`api-scope` 声明和 `app/docker/fv-acl-probe.sh` 是 **0.5.9 同一次提交**
  引入的（commit message 原文：「声明 api-scope 并新增开放 API 预检，为『按用户区分预览权限』铺路」）
  —— 两者本是一体。0.5.25 的审计只看 `config/resource` 有没有被别处引用，
  没看预检脚本里的 `req` 名，于是判为「未使用」删掉了。
- **后果不是「跑不通」这么轻**：官方《错误码》里 `403` / `code 200003 Forbidden` 的处理建议
  第一条就是「检查应用包是否声明了对应 API Scope」。缺声明后预检的 ③④ 两步必然 403，
  而 `fv_json_vol_paths` 在 Forbidden 响应里正则抠不到任何 `/vol` 路径，于是日志打印：

  ```
  **没有解析到授权目录** —— 需要管理员在「应用设置 → 授权目录」里添加（例如 /vol3）
  ```

  这条**指向错误方向** —— 真因是 scope 没声明，不是管理员没授权。而本应用
  `disable_authorization_path=true` 又把那个页面藏了，管理员根本无从"添加"。
- **现在**：
  - `config/resource` 恢复 `api-scope`（`trim.file.sharedAccess` / `trim.file.userAcl` /
    `trim.system.getPlatformConfig`）。
  - 预检脚本新增响应分类 `fv_api_error_kind()`，把 403 / 401 / 404 分别判为
    「缺 scope / token 无效 / 接口或版本问题」，各自给出准确结论与修法；
    缺 scope 时直接列出「恢复官方路线」的完整清单（补 scope **且** 把
    `disable_authorization_path` 改回 `false`），不再猜。
  - `fpk/tools/selfcheck.sh` 新增断言：**预检脚本调用的每个开放接口，都必须在
    `config/resource` 里有对应 scope 声明** —— 这类"删掉看似没人用的声明"的改动会当场失败。
- **顺带更正**：`SECURITY.md` §4 里 0.5.25 的「B | 删掉未使用的 `api-scope` 声明」
  已标注为**结论错误并撤销**。

### 二、基础镜像补 digest 锁

`nginx:alpine` 与 `python:3-alpine` 此前只写标签。引擎镜像 0.5.25 就锁了 digest，
理由是「标签是可移动的，上游重推同名 tag 内容会变」—— 同一套论证对这两个基础镜像同样成立。

- 代价：**锁了不会自动拿到基础镜像的安全更新**，升级需手动改 digest
  （查法见 `SECURITY.md` §4 待办）。
- 自检里的 digest 断言从「只查引擎」放宽为「**所有** `image:` 行都必须带 digest」。

### 三、文档：把风险写成显式声明

- **`SECURITY.md` 新增「§3 风险接受声明」**：把三项**明知而接受**的残余风险从散落的注释与段落里
  集中成显式条目 ——
  1. **权限闸门 fail-open**：列出全部 5 种放行触发条件与后果（最坏情况 = 退化成"没有逐用户校验"，
     任何已登录用户可预览已挂载卷里的任意文件），说明为何选可用性优先、以及这与官方
     "默认拒绝"取向相反；给出唯一的验证手段（`/__whoami` 应显示 `uid=`）与应急开关。
  2. **`join-groups: ["docker"]` ≈ 宿主 root**：补充**上架影响** —— 第三方应用默认无法上架
     root 权限应用，需预先准备说明材料与降级路径。
  3. **未使用官方授权模型**：可访问范围由"挂载了哪些卷"决定而非"用户授权了哪些目录"，
     因此边界完全依赖闸门 —— 与第 1 项是同一风险的两面，不能分开评估。
- **`README.md`**：「背景：为什么不用飞牛的开放 API」一节重写 —— 原先只写「拿不到
  `TRIM_API_TOKEN`」，与官方《调用方式》（明确说启动 `cmd/main` 时会注入）表述冲突；
  现在拆成两层（token/socket 实测 + `api-scope` 回归），并给出切换官方路线的完整两步清单。
- **待办升级**：「复核 `TRIM_API_TOKEN` 是否真的拿不到」从低优先级提到**中** ——
  若能拿到 token 即可用官方 `trim.file.checkUserACL` 替掉整个闸门容器，
  少一个容器、少一份 fail-open 风险。

## 0.5.29

换应用图标：改用 **BaseMetas FileView 官方 logo**。

- **原来是什么**：一个通用的蓝色圆角方块 + 白色文件 + 放大镜。虽然合规，但
  **小尺寸下几乎看不出内容**（24~32 px 时就是一块蓝方块），在应用中心卡片和
  右键「打开方式」菜单里都容易被当成「没图标」。
- **现在**：浅蓝圆角磁贴 + 官方那个「B」标 —— 一眼认得出是 FileView，与引擎同品牌，
  64 px 下依然清晰可辨。
- **实现**：`fpk/tools/gen_icons.py` 改为读取 `fpk/tools/assets/fileview-logo.png`
  （取自官网 `fileview.basemetas.cn/favicon.png`，320×320、透明底 + 圆形主体），
  外面套一层飞牛风格的圆角方形磁贴，仍然一次生成 4 个文件
  （`ICON.PNG` / `ICON_256.PNG` / `app/ui/images/icon_64.png` / `icon_256.png`）。
- **磁贴底色为什么要用斜向渐变**：官方 logo 的圆边有一圈**颜色随角度变化**的柔光
  （左上偏白蓝、右下偏青蓝），纯色铺底会在圆边露出一圈可见接缝；用与圆边同向的
  渐变 + alpha 合成，接缝最轻。试过「把圆放大到盖满方形」，虽然彻底无缝，
  但 B 会过大、笔画被四边裁掉，所以没用。
- ⚠️ 官方 logo 是 BaseMetas 的商标/素材。本仓库是第三方打包工程，自用没问题；
  **若要公开发布，建议先确认对方对 logo 的使用态度**。不想用官方 logo 时，
  把 `gen_icons.py` 换回自绘几何图形、重跑一次即可。

## 0.5.28

修「重定向把外部端口弄丢」—— 用非标准端口访问时，应用中心点「打开」会跳到没有端口的地址。

- **现象**（实测，外部访问在 `:8443`）：
  ```
  https://<域名>:8443/app/basemetas-fileview/preview/view
    → 302 → https://<域名>/app/basemetas-fileview/preview/welcome     ← :8443 没了
  ```
  端口一丢，浏览器按 443 去请求就打不到 NAS，页面自然打不开。
- **真因（两个因素叠加）**：nginx 的 `absolute_redirect` **默认是 `on`** ——
  `return` / `rewrite` 发出的重定向会被拼成**绝对地址**，用 `$scheme` + `$host`(+端口)。
  而本 server 监听的是 **unix socket**（没有端口），`$host` 又来自 Host 头 ——
  飞牛统一网关经 socket 转发时**会把外部端口从 Host 里去掉**（见文件头那段「为什么要自己推导」）。
  于是 Location 只能写成 `http://<域名>/...`，浏览器再被 HSTS 升级成 https，端口就这么没了。
  （顺带解释了为什么之前 `/app/basemetas-fileview` 那两条 302 也有同样毛病。）
- **修法**：在 server 块里加一行 `absolute_redirect off;`。之后 Location 是**相对**的
  （`/app/basemetas-fileview/...`），浏览器用自己的 origin 解析，scheme / 域名 / **端口**都自然保留。
- **为什么不用「自己拼绝对地址」**：本包确实有一套 `$ext_proto` / `$ext_authority` 端口推导
  （给 FileView 的 Host 头用），但它在「首次导航、既无 Referer、Host 又不带端口」时会退化成
  不带端口 —— 正好是这个场景。相对 Location 不依赖任何推导，永远是浏览器当前的那个 origin。
- **自检**：`selfcheck.sh` 加了一条断言，`nginx.conf` 里必须有 `absolute_redirect off;`；
  `check_nginx_conf.py` 的指令白名单补上 `absolute_redirect`（否则会被误报成「可疑指令名」）。

## 0.5.27

修「应用中心点『打开』是一片空白页」。

- **现象**：装好后在应用中心点应用卡片上的「打开」，打开的是一片空白。
- **真因**：那个按钮走的是 `manifest` 的 `desktop_applaunchname` 指定的入口，
  也就是入口 `url` = `/app/basemetas-fileview/preview/view`。但**入口 url 本身不带 `?path=`** ——
  `?path=<绝对路径>` 是文件管理器右键「用 FileView 打开」时才由飞牛追加的。
  SPA 拿不到文件路径，就什么都不渲染，于是空白。看起来像部署失败，其实引擎好得很。
- **修法**：网关里加一个 `map` + `if` —— 把「URI 正好是 `/preview/view` **且** `path` 为空」
  的请求 302 到欢迎页 `/preview/welcome`。欢迎页会列出支持的格式，正好当**部署自检**：
  能打开就说明网关、容器、引擎这一条链路是通的。
- **不影响正常预览**：带 `?path=` 的请求（真正的文件预览）判定为不命中，照原样转发。
  判定用 `~`（区分大小写）而不是 `~*`，宁可漏转也不误伤。
- **新增单测** `fpk/tools/test_welcome_redirect.py`：12 条矩阵，覆盖「应用中心打开」、
  「右键打开带路径」、「欢迎页自己（防无限重定向）」、「静态资源」等，已并入 `selfcheck.sh`。
  风险全在**误伤** —— 条件写宽了会让右键打开文件也跳到欢迎页，那时很难联想到是网关里一个 map 写错了。
- ⚠️ `if` 用的是 nginx 里少数安全的形式（`if` 块内只放 `return`）；
  且 `return` 在 rewrite 阶段执行，会先于 `auth_request` 短路 —— 但重定向目标只是页面外壳，
  不读任何文件，且请求本身已过飞牛统一网关的登录态校验，所以没有鉴权缺口。

## 0.5.26

文件打开方式改为**在飞牛桌面窗口内打开**。

- **改动**：入口 `basemetas-fileview.view` 的 `type` 由 `url` 改为 `iframe`（`app/ui/config`）。
- **行为差异**：官文对两种打开方式的定义是 —— `iframe` = 在飞牛 fnOS 桌面窗口内打开；
  `url` = 在浏览器标签页或外部 Web 视图中打开。改之前右键「用 FileView 打开」会**新开一个浏览器标签页**，
  改之后直接嵌在飞牛桌面里，和飞牛自带「Office 预览」是同一形态（不跳浏览器、不占额外标签页）。
- **不变的部分**：入口仍只有这一个，`noDisplay: true` 保持 —— 即**不出现在桌面图标里**，
  只保留文件右键菜单的「打开方式」。官方「注册文件打开方式」的示例用的正是
  `type: iframe` + `noDisplay: true` 这个组合。
- **访问链路完全没动**：仍走统一网关（`gatewayPrefix` / `gatewaySocket`），
  网关先校验飞牛登录态再转发；逐用户权限闸门、只读挂载、引擎容器都保持原样。
  网关侧本来就没有 `X-Frame-Options` / CSP 响应头，所以内嵌不会被浏览器拦掉。
- **发布形式：两个包，安装时二选一**。Release 里同时挂
  `basemetas-fileview-<版本>-desktop.fpk`（`iframe`，在桌面窗口内打开）与
  `-browser.fpk`（`url`，在浏览器标签页打开），按需下载。
  之所以做成两个包而不是运行时开关：入口配置只在**安装时**读取，
  且飞牛**不允许同版本覆盖安装** —— 想换打开方式需先卸载再装另一个包
  （卸载不删引擎镜像，重装很快）。两个包**只差 `ui/config` 一个文件**。
- **新增** `fpk/tools/build_variants.py`：从同一份源码派生两个变体 ——
  复制到临时目录、只改 `type`、再调 fnpack，**全程不动工作区**（中断也不会把 `url` 留在源码里）；
  打包前用 Python 二进制读做行尾检查。
- **验证**：升级后在文件管理器里右键一个已注册格式的文件 → 「用 FileView 打开」，
  应在**飞牛桌面窗口内**直接打开预览页，而不是弹出新标签页。

## 0.5.25

按第三方安全审计逐条核对后，做掉四项「确认可行、且不改变正常行为」的收紧。

- **逐用户权限闸门：修掉扩展名旁路**（最重要）。
  - **原逻辑**：`fv-acl-gate.py` 的 `_decide()` 一进来就看 URI 后缀，命中了 `SKIP_EXT`（`.css/.png/.js/…`）就直接判「静态资源（放行）」，**根本没去解析 `filePath` 里的存储卷路径**。
  - **为什么这是真的旁路**：实测 `GET /preview/api/file.css?filePath=/vol1/私密.docx` 返回的是 **500 而不是 404** —— 若该 URL 没匹配到任何 location 会是 404，返回 500 说明它**确实被路由到了后端接口**（只是 `filePath` 被当成 `.css` 去读才报错），而正确路径（无后缀）返回 200。也就是说「换个后缀」并不足以绕开封禁接口，但闸门这道放行是真的开着 —— 一旦上游把后缀匹配放宽，就是完整绕过。
  - **修法**：扩展名短路**只在「请求自己没带 `/vol` 路径」时**才生效。正常的静态资源请求（`/preview/static/xxx.css`）不带路径参数，行为完全不变；带 `?filePath=/vol…` 或 `X-Acl-Path: /vol…` 的一律落到正常判定。
  - **验证**：新增 `fpk/tools/test_acl_decide.py`，12 条判定矩阵（含 3 条旁路用例），已并入 `selfcheck.sh` 自动跑。
- **引擎镜像锁 digest**：`basemetas/fileview:1.5.2` → `basemetas/fileview:1.5.2@sha256:ebcb1dc6…9f79ad`。标签是**可移动的**，上游重推同名标签时内容会变而版本号不变，等于「本地悄悄换了镜像」；锁 digest 后完全可复现。（digest 已用 Docker Hub tags API 核对确为 1.5.2。）
- **目录权限 0777 → 0700**：`fonts` / `data` / `logs` 三处。引擎容器**实测以 `uid=0(root)` 运行**（`docker exec basemetas-fileview-engine id`），root 无视权限位，收到 0700 不影响读写；但 `data`/`logs` 里会出现转换产物（含被预览文件的内容片段）与日志，不是纯公开数据，没有理由再留着全局可写。
- **删掉未使用的 `api-scope` 声明**：`config/resource` 里声明的 `trim.file.sharedAccess` / `trim.file.userAcl` 是全仓**唯一**出现处，没有任何脚本或代码读它（逐用户权限是自建闸门实现的，不走官方 `checkUserACL`）。留着只会让审计与维护者误以为应用依赖这两个 scope。

> 与本次一并更正的审计结论：审计报告 9 项中 8 项准确，2 项需修正 —— ①「100MB 解压上限」是**引擎自带默认值**，不是本应用的缓解措施；②「compose 未声明 `networks:` 导致与其它应用同网络」不准确，本应用三容器走默认 bridge，不加入其它应用网络。详见新增的 `SECURITY.md`。

## 0.5.24

Excel / CSV 预览恢复**缩放**控件。

- **现象**：xls / xlsx / csv 能正常预览，但没有缩放。
- **真因**：上游 `components/render/cell/index.tsx` 给 `luckysheet.create` 传了 `showstatisticBar: false`，把**统计栏整条**隐藏了 —— 而缩放控件（0.1x~4x 的滑杆 + 加减按钮，`#luckysheet-zoom-content`）就在统计栏里。也就是说上游**不是没有缩放能力，只是没把开关打开**。
- **修法**：Luckysheet 本身支持**细粒度**开关 `showstatisticBarConfig`，上游没传它。本包在浏览器端包了一层 `luckysheet.create` 把配置补上：

  ```js
  showstatisticBar: true,
  showstatisticBarConfig: { count: false, view: false, zoom: true }
  ```

  效果：底部只出现缩放控件，求和（`count`）与视图（`view`）保持隐藏。而且因为留了一项没关，Luckysheet 会正确计算 `statisticBarHeight`，表格不会错位（它的逻辑是「三个子项全关才把统计栏整条藏掉」）。
- **实现**：新增 `app/docker/fv-web-patch.js`，由网关 nginx 以 `<script src>` 注入到页面 `<head>`。用「拦截 `window.luckysheet` 赋值」而不是轮询 —— luckysheet 是 cell 渲染器动态 `loadJS` 加载的，加载完紧接着就调 `create`，50ms 的轮询来不及。
- **验证**：预览一个 xlsx，底部应出现缩放滑杆；浏览器控制台应有两行 `[fv-patch]` 开头的日志。
- ⚠️ 与 0.5.23 的 PDF 补丁一样，属于**改上游运行时的临时措施**，上游把开关打开后应删掉。

> 顺带：`fpk/tools/check_nginx_conf.py` 的指令白名单补上了 `alias`（新 location 用到），否则每次自检都会误报「可疑指令名」。

## 0.5.23

修「带触摸的电脑上 PDF 预览没有工具栏」。

- **现象**：PDF 预览没有工具栏 —— 不能旋转、双页、全屏、搜索，也没有浮动缩放按钮。
- **真因（上游前端的设备识别）**：`utils/device.ts` 的 `isPadFun()` 最后一行兜底是「屏幕短边 ≥ 600 就算 Pad」。**带触摸的电脑**（触屏笔记本、接了触屏显示器的台式机）会一路走到那一行，被判定成 iPad → `isMobile = true`；而 PDF 工具栏的每个按钮和浮动缩放控件都写着 `!isMobile`，于是被一起隐藏。实测 `preview/debug` 页显示 `isPad=true / isMobile=true`。
- **修法**：往 SPA 页面注入一小段脚本，把 `navigator.maxTouchPoints` 归零 —— `isPhoneFun()` 有 `maxTouchPoints <= 0 → false`、`isPadFun()` 有 `<= 1 → false`，归零后两个都返回 false。**只在非移动端 UA 上做**：iPad / iPhone / Android 保持上游的移动端布局（对所有设备一律归零会连带禁用它们的触摸手势，平板上连触摸滚动都会失效）。
- **验证**：打开 `<域名>/app/basemetas-fileview/preview/debug`，`isMobile` 应从 `true` 变成 `false`。
- ⚠️ 这是改上游运行时的临时措施，上游修好 `device.ts` 后应删掉；升级引擎镜像后可能失效（表现是工具栏又没了，**不会报错**）。

> **Excel 的缩放不在此列**：上游在 `components/render/cell/index.tsx` 里把 Luckysheet 的工具栏整个隐藏了（`showtoolbar: false`，配套还藏了信息栏、公式栏、统计栏），是一套「只读预览」的设计，缩放控件就在被隐藏的工具栏里。本版**不改动**这一点。

## 0.5.22

按官方《部署对接指南》补齐两处「生产必做」项。

- **挂出引擎的工作目录与日志**：`/opt/fileview/data` 和 `/opt/fileview/logs` 此前没挂，转换产物、解压临时文件、LibreOffice / CAD 的工作目录、两个服务的文件日志**全部落在容器可写层**。后果是升级时 `--force-recreate` 一重建就全丢（缓存和中间产物都要重来），日志也只能从 stdout 看，而且这部分占用既不可见也不受应用管理。现挂到应用数据目录 `${TRIM_PKGVAR}/data`、`/logs`，并在 `install_init` 里**先于容器创建**把目录备好（否则 docker 会以 root 身份建成 0755，容器里的进程可能写不进去）。
- **关掉网络文件预览**：引擎的 `fileview.network.security.trusted-sites` 未配置时**默认允许所有域名**，而本应用的入口只做本地路径预览，完全用不到网络下载能力。留着它就等于开了一个 SSRF：任何能登录飞牛的人都能构造 `/app/basemetas-fileview/preview/view?url=http://<内网地址>/...` 让引擎去抓内网资源，而且这条路径**绕过逐用户权限闸门**（闸门从 `path`/`filePath` 或来源页 query 取路径，`url=` 请求里没有 `/vol` 路径，走「放行」分支）。现配成永不匹配的域名，等价于全禁。欢迎页的「查看样例」用的是容器内路径，不受影响。

## 0.5.21

修复卸载容错脚本的行尾问题，并加一道打包前的强制检查。

- **修 `cmd/uninstall_init` / `cmd/uninstall_callback` 的 CRLF 行尾**：这两个「卸载容错清理」脚本此前是以 CRLF 打进 `.fpk` 的。在 Linux 上，变量值末尾会多带一个 `\r`（`docker rm -f "basemetas-fileview\r-engine"`），于是清理动作**静默失败** —— 表现为卸载 / 停用时仍可能报 `Request failed`。仓库里存的 blob 是 LF，坏的是工作区：Windows 上 `core.autocrlf=true` 会让工作区保持 CRLF，而 `fnpack` 打的正是工作区。
- **新增打包前强制检查** `fpk/tools/check_eol.sh`，并在 `build.sh` / `build.bat` / 自检里调用：`basemetas-fileview/` 下只要出现 CRLF 就中止打包，不让坏包流出去。
- 清理源码注释里的事故叙述（日期、症状复现、版本回顾），只保留「这段代码为什么这么写」的必要说明。

## 0.5.20

放开单文件预览大小上限，默认 **1024 MB**（原为引擎自带的 100 MB）。

- **现象**：大文件预览失败，提示「文件转换失败 413」。
- **真因**：引擎预览服务里有一道体积闸门 `fileview.preview.storage.max-file-size-mb`，默认 100。超过它的文件**在转换之前**就被直接拒绝，接口返回 HTTP 413「文件过大」——前端把这个 413 显示成「文件转换失败」，看起来像转换器坏了，其实和转换器、nginx、网络都无关。
- **修法**：通过环境变量 `FILEVIEW_PREVIEW_STORAGE_MAXFILESIZEMB` 覆盖，默认 1024 MB。可在安装向导 / 应用设置的「预览限制」里调整，保存后自动重建容器生效。
- PDF / 图片 / 代码由浏览器端渲染，调大基本不增加服务端负担；Word / Excel / PPT / CAD / OFD 需要服务端转换，上限过大时预览大文件会明显吃 CPU 和内存，请按 NAS 内存取舍。

## 更早版本（0.5.19 及以前）

只列要点，详细过程见 git 历史。

| 版本 | 要点 |
|---|---|
| 0.5.19 | 隐藏设置里没意义的「访问权限」标签页 |
| 0.5.17 | 逐用户权限校验改为**默认开启**（无读权限返回 403） |
| 0.5.16 | 闸门两处修正：静态资源不再按文件权限拦；引擎内部转换产物按来源页原始路径判定 |
| 0.5.15 | 新增**逐用户权限闸门**（不依赖官方开放 API） |
| 0.5.14 | 新增 `__whoami` 诊断端点；访问日志增加 `uid` / `isadmin` 两列 |
| 0.5.13 | 撤回 `cmd/main stop` 里自加的「兜底停容器」（反而造成状态不一致） |
| 0.5.12 | 清理 compose 重建中断时残留的临时容器 |
| 0.5.11 | 修「点停用报 `Request failed`」：只在挂载清单真变了才重建容器 |
| 0.5.10 | compose 里的 `${TRIM_*}` 改为在回调里就地替换成真实路径 |
| 0.5.9 | 声明 `api-scope`，并加开放 API 预检 |
| 0.5.8 | 修「新加的存储卷永远预览不了」—— 应用用户不在 `docker` 组，docker 操作静默失败 |
| 0.5.7 | 修「容器已没了但卸载报错」；新增 `tools/fv-uninstall-fix.sh` |
| 0.5.6 | 修网关容器无限重启（残留 `app.sock`）；存储卷默认改 `auto`；新增 `tools/fv-repair.sh` |
| 0.5.5 | 修 Excel / CSV 打开后无限转圈（上游用了 `credentials: 'omit'`） |
| 0.5.4 | 支持自定义字体 |
| 0.5.3 | 入口精简为只保留「用 FileView 打开」 |
| 0.5.2 | 首个可安装版本 |

---

## 升级方法

把 `manifest` 的 `version` 末位 +1、重新打包，然后在应用中心「手动安装」新版 `.fpk` 即可 —— **不需要先卸载**（飞牛靠版本号递增判断升级安装）。

若不想重装，也可以只替换运行中的文件后重启容器（`@appcenter` 目录下的 `docker/` 可通过文件管理器「管理员视角」访问）。
遇到「引擎 Up、网关 Restarting」这类故障时，直接在 NAS 上跑 `tools/fv-repair.sh` 即可，不必重装。
