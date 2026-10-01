# 更新说明

包版本号与预览引擎版本**解耦**：包版本 `0.5.x` 对应引擎 `basemetas/fileview:1.5.2`。
只改外壳（配置 / nginx / 图标）时末位 +1；升级引擎镜像时整段跟着抬（如引擎 1.6.0 → 包 0.6.0）。
飞牛靠版本号**递增**判断升级安装，同版本不允许覆盖安装。

---

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
