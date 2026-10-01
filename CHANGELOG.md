# 更新说明

包版本号与预览引擎版本**解耦**：包版本 `0.5.x` 对应引擎 `basemetas/fileview:1.5.2`。
只改外壳（配置 / nginx / 图标）时末位 +1；升级引擎镜像时整段跟着抬（如引擎 1.6.0 → 包 0.6.0）。
飞牛靠版本号**递增**判断升级安装，同版本不允许覆盖安装。

---

## 0.5.27

修复 0.5.26 在真机上暴露的**两个问题**：网关镜像的 njs 版本不够、以及启动脚本的诊断判据会误报。

### 问题一：`js_access` 需要 njs >= 1.0.1（不是"带 njs 就行"）

第二轮修完后，真机日志变成：

```
[fv-njs-boot] 在镜像里找到 njs 模块：/usr/lib/nginx/modules/ngx_http_js_module.so
[fv-njs-boot]    不行（[emerg] unknown directive "js_access" in /tmp/fv-conf.d/nginx.conf:211）
```

**注意报错行是 `nginx.conf:211`（片段），不是 `fv-main.main:40`（`load_module` 那行）**
—— 说明 `load_module` **成功了**，镜像确实有 njs。真正的问题是 **`js_access` 这个指令不被识别**。

查证结果：

| 事实 | 版本 / 日期 |
|---|---|
| `js_access` 首次引入 | **njs 0.9.9**（2026-05-19） |
| `js_access` 访问控制绕过漏洞 | **CVE-2026-18329**，0.9.9 ~ 1.0.0 均受影响 |
| 该漏洞修复 | **njs 1.0.1**（2026-09-02） |
| 官方 mainline 镜像自带 njs | **1.0.1**（其 Dockerfile `NJS_VERSION=1.0.1`） |
| 本项目原先用的 `nginx:1.27` | 2024 年，自带 njs **0.8.x** → 没有 `js_access` |

**所以这不是"镜像没 njs"，而是"镜像的 njs 太旧"，且旧得连指令都不认识。**

修法：`docker-compose.yaml` 的 gateway 镜像 `nginx:1.27` → **`nginx:1.31`**（官方 mainline，自带 njs 1.0.1）。
选 1.31 而不是"任意带 njs 的版本"，是因为 0.9.9~1.0.0 有上面那个绕过漏洞 —— 目标必须是 **>= 1.0.1**。

### 问题二：降级判据把"版本太旧"误报成"缺模块"

启动脚本原来的降级判据有个真 bug：

> `/tmp/njs-t.log` **每轮尝试都被覆盖**，循环结束后里面是**最后一个候选**的日志。
> 而最后几个候选是兜底假路径，必然 `dlopen ... No such file`。
> 于是**即使真路径已经把模块加载成功**，也会因为"最后一条是 dlopen 失败"而判成
> **"镜像确实没有 njs 模块"** —— 真机上就是这么误报的。

改为**逐个分类 + 累积证据**（`SAW_LOADED`）：

- 只要**任何一次**加载成功过（报错不是 `dlopen` 类），就不算"缺模块"；
- 这种情况报**准确原因**，并对 `js_access` 给出专门诊断（含所需版本与 CVE 提示）；
- 只有在**全部候选都是 dlopen 失败**时，才说"镜像不含 njs"。

降级本身保留（否则应用起不来），但文案按三种情况分开说，不再误导。

### 回归保护

- `test_njs_boot.py` 新增 ⑤b 段：**用脚本里抽出来的真实 `is_load_failure` 函数**，
  喂**真机日志原样序列**，断言必须判成"模块存在"；反向再喂"全是 dlopen"的序列，
  断言仍判"缺模块"（不误伤）。另加一条回归：确认**最后一条日志确实是 dlopen 失败**
  —— 这正是旧逻辑必然误判的成因。
- `selfcheck.sh` 新增：网关镜像不得是 `nginx:1.2x/1.30` 之类旧标签；
  compose 里必须写明 `njs >= 1.0.1` 的要求。

> 教训：**"有模块"不等于"模块能用"**。版本门控的指令（`js_access` 自 0.9.9 才有）
> 会把"版本太旧"伪装成"功能不存在"，而**兜底逻辑如果只看最后一次尝试的日志，
> 必然被最后的假路径带偏**。判据要基于**全部尝试的累积证据**，不是最后一条。
> 另外：安全相关的指令要连**它自己的 CVE 修复版本**一起查 —— 光有 `js_access`
> 还不够，0.9.9~1.0.0 反而是有漏洞的。

---

## 0.5.26

堵上**「POST body 路径绕过」**高危缺口。这是本项目迄今最严重的一个问题：
逐用户权限闸门**看不到请求体里的路径**，导致任意已登录用户可以让引擎把别人的私有文件读出来。

- **问题**：FileView 的**主预览链路就是 POST**（`POST /preview/api/localFile`，路径在 body 的
  `srcRelativePath`），而 nginx 的 `auth_request` 认证子请求**物理上读不到 body**
  （配置里写死了 `proxy_pass_request_body off`）。闸门只从 query 串和 Referer 里找路径，
  于是 POST 请求落到「未解析到路径（放行）」分支 —— 直接放行。
- **为什么之前判成低风险是错的**：源码层读通了整条链 —— 引擎的 `@SecurePath` 校验器
  **只挡 `..` 穿越、不禁止绝对路径**，到 `new File()` 之间**没有根目录收敛**，
  所以 body 里直接写 `/vol2/<别人uid>/私密.docx` 就能读。
- **真机已复现**（2026-09-30，普通用户会话）：

  | 用例 | 结果 |
  |---|---|
  | GET 带私有路径（对照） | 403（闸门正常） |
  | POST `/localFile` **无 Referer** | **200 → 绕过成立** |
  | POST `/localFile` **带合法 Referer** | **200 → 掩护也成立** |

  第三条是决定性的：攻击者**先打开一个自己有权读的文件**拿到合法 Referer，
  再把 body 里的路径换成别人的 —— 闸门会拿 Referer 里那个合法路径判定并放行，
  **body 里的非法路径根本没被看过**。
  → 因此「无 Referer 就拒」这类 fail-closed 收紧**不管用**，必须让鉴权层真正读到 body。
- **修法**：新增 `app/docker/body-path-guard.js`（njs），在主 location 上加 `js_access`：

  ```
  js_access bodyguard.guard       ← 先读 body、取路径、问闸门；不可读直接 403
  auth_request /__acl             ← 原链路保留（负责 GET 的 query 路径与 Referer 退回）
  proxy_pass http://fileview:80/  ← 两道都放行才转发
  ```

  - 只对「路径在 body 里」的接口生效（`/localFile`、`/netFile`、`/status/poll`、
    `/password/unlock`、`/epub/resource`、`/convert/api/srvFile`），其余请求原样放过；
  - 闸门新增 `GET /check-body` 入口，**复用同一套 `can_read` + `current_mode`**
    （判定单一事实来源），但**不退回 Referer** —— 这正是堵住「合法 Referer 掩护」的关键；
  - 闸门不可用 / body 非 JSON / 子请求异常 → **fail-open**，与原有 `upstream backup`
    方向一致（宁可没保护，不把应用弄坏）；
  - 主 location 与 SPA location **都挂了** `js_access`（少挂一处即可被绕过，自检有断言）。
- **不赌镜像**：`load_module` 加载失败会让 nginx **起不来**，而"官方镜像带不带 njs"
  文档只承诺过 `nginx:latest`。所以 gateway 的启动命令改为 `fv-njs-boot.sh`：
  启动前用 `nginx -t` 实测，不能加载就**自动降级**成去掉 njs 的配置并打 WARN
  （应用仍能打开，但会明确告知"body 路径保护已关闭"），绝不让应用打不开。
- **验证**：`test_acl_decide.py` 从 12 条扩到 **20 条**（新增 8 条 body 路径判定，
  含「合法 Referer 掩护场景仍拦截」）；`selfcheck.sh` 新增 7 + 3 条断言。
  详见 `fpk/tools/POST-BYPASS-VERDICT.md` 与 `fpk/tools/VERIFY-0.5.26-ONNAS.md`。

> 一并记录：`POST /convert/api/srvFile` 是**「读+写」**（`targetPath` 可控且引擎侧
> 无根目录校验），当前被网关的 location 配置挡在门外（返回 nginx 的 404 而非引擎响应）。
> 这是**配置遮蔽、不是引擎修复** —— 已在 njs 名单里预先纳入，一旦将来为别的功能加了
> `/convert/` 转发，它会自动受闸门保护。

### 0.5.26 修订（真机事故修复）

首版 0.5.26 装上去后 **gateway 容器无限重启**，应用打不开。日志只有一句：

```
nginx: [emerg] "map" directive is not allowed here in /etc/nginx/conf.d/nginx.conf:13
```

**根因**：`/etc/nginx/conf.d/nginx.conf` 是**「conf.d 片段」**（内容是 **http 块上下文**的
指令，第 13 行就直接写 `map {}`），**不是主配置**。而首版的 `fv-njs-boot.sh` 用
`nginx -t -c "$ORIG"` / `nginx -c "$ORIG"` 把它**当主配置**来检查和启动 ——
`map` 于是落在 http 之外，nginx 立刻 `[emerg]` 退出。

**为什么这个错特别隐蔽**：

- 报错信息**和 njs 一点关系都没有**，所以降级路径也照样失败（降级只删 njs 行，`map` 还在）；
- 探测因此**永远返回"不通过"**，脚本每次都回落到"用原配置启动"，而启动同样报错 → 死循环重启；
- 换句话说，这个包装脚本把「njs 有没有都能正常起」的情况，变成了**一定起不来**。

**修法**（`fv-njs-boot.sh` 重写 + `docker-compose.yaml` 命令注释订正）：

- **正常路径**：什么都不传，`exec nginx -g 'daemon off;'` —— 用**镜像自带的
  `/etc/nginx/nginx.conf`**，它本来就有 `include /etc/nginx/conf.d/*.conf;`，
  天然把我们的片段放在 http 上下文里。**这条路径零风险、最贴近原生。**
- **探测**：改用 `nginx -t`（**不带 `-c`**），与真实启动路径完全一致。
- **降级路径**：把 `conf.d` 复制到 `/tmp/fv-conf.d`（只读挂载改不了原目录），
  在副本上剥掉 njs 指令，再写一份**临时主配置**（`events{} + http{ include /tmp/fv-conf.d/*.conf; }`）
  用 `nginx -c` 启动。
- **只在"错误确实是 njs 引起"时才降级**：先 `grep` 报错里有没有 `js_module` / `js_` 关键字，
  没有就说明是配置的其它问题，降级救不了 —— 此时照常用完整配置启动、让错误打全，
  **避免把真正的语法错掩盖成"降级后能跑"**。
- **新增回归断言**（`selfcheck.sh` + `test_njs_boot.py`）：包括
  「正常路径必须存在不带 `-c` 的 `exec nginx`」、「探测必须用不带 `-c` 的 `nginx -t`」、
  「绝不能把 `$ORIG` 传给 `-c`」，以及模拟 `include` 展开后**确认 `map`/`server` 落在
  `http` 块内**的决定性检查。

> 教训：`nginx -c` 指向的必须是**主配置**。给一个 conf.d 片段做语法检查/启动时，
> 要么依赖镜像主配置的 `include`，要么自己包一层 `events{} + http{}`，**不能直接指片段**。
> 而一个"探测失败就回落到原配置"的包装器，如果探测方法本身永远失败，就等于**必然崩**。

### 0.5.26 修订（第二轮：`load_module` 放错了地方）

上面那版修完后容器能起来了，但启动日志显示**走到了降级分支**，报错是：

```
nginx: [emerg] "load_module" directive is not allowed here in /etc/nginx/conf.d/nginx.conf:40
```

**根因（比第一轮更根本）**：`load_module` 的合法上下文是 **`main`（主配置顶层）**
—— nginx 官方文档写得很清楚：`Syntax: load_module file;  Context: main`。
而我把这行写在了 `conf.d/nginx.conf` 里，它是被 `http { include conf.d/*.conf; }`
拉进来的，上下文是 **http** → **必然**报 "not allowed here"。

**关键区分（这次踩的坑）**：

| 报错 | 含义 | 该怎么办 |
|---|---|---|
| `"load_module" directive is not allowed here` | **位置**非法 | 把指令挪到 `main` 层 —— 与镜像带不带 njs **无关** |
| `dlopen() ".../ngx_http_js_module.so" failed` | **文件**缺失 | 这才是真的没有 njs，应降级 |
| `"map"/"server" directive is not allowed here` | 把 conf.d 片段当主配置了 | `-c` 指向主配置，别指片段 |

第一轮的降级判据是 `grep js_module`——**把"位置非法"和"文件缺失"混为一谈**，
于是明明镜像里可能有 njs，也被误判成"不含 njs"而走了降级（防护白关）。

**修法**：

- 新增 **`app/docker/fv-main.main`** —— 我们自己的**主配置**（`main` 上下文）：
  ```nginx
  load_module modules/ngx_http_js_module.so;   # ← main 层，合法
  events { worker_connections 1024; }
  http { include /etc/nginx/conf.d/*.conf; }    # ← 片段在这里，http 上下文
  ```
  文件名故意用 `.main` 而非 `.conf`：因为它和片段一起被挂到 `/etc/nginx/conf.d/`，
  若叫 `.conf` 就会被**镜像主配置**的 `include conf.d/*.conf` 误收进去，`load_module`
  又会落到 http 上下文里报同样的错。
- `nginx.conf`（片段）里**删掉 `load_module`**，只保留 `js_path` / `js_import`（http 上下文，合法）。
- 启动改为 `-c /etc/nginx/conf.d/fv-main.main`；探测也用同一个 `-c`。
- **降级判据收紧**：只认 `dlopen` / `not binary compatible` / `No such file` 等
  **"文件缺失"**特征；若报的是 `directive is not allowed here`，则判定为配置写错，
  **不降级**、让错误原样暴露（避免再次掩盖）。
- **探测 .so 真实路径**：`load_module modules/xxx.so` 的相对路径按编译前缀解析，
  而各发行版 .so 位置不同（`/usr/lib/nginx/modules/` vs `/etc/nginx/modules/`）。
  启动脚本先 `find` 定位实际路径，再逐一试常见路径，全失败才认定"镜像不含 njs"。
- **include 重写**：降级要把 conf.d 副本的 njs 指令剥掉，但主配置里 include 的是
  **绝对路径** `/etc/nginx/conf.d/*.conf` —— 剥掉的副本根本不会被读到。所以脚本
  会把 include 重写到副本目录（`/tmp/fv-conf.d/*.conf`），保证降级真正生效。
- 回归断言同步更新（`selfcheck.sh` 5 条 + `test_njs_boot.py` 全部用例）：
  新增「主配置的 `load_module` 必须在 main 层」「片段里绝不能有 `load_module`」
  「降级判据必须只认文件缺失特征」「include 必须能被重写到副本」等。

> 教训：**同一个"not allowed here"家族里，`load_module` / `map` 是两件不同的事**，
> 但都容易被误读成"环境缺东西"。看到 `not allowed here` 先想**上下文放错**，
> 而不是"缺依赖"。另外：**判据要能区分"配置写错"与"环境缺失"**，
> 否则降级机制会变成掩盖 bug 的帮凶。

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

## 0.5.19

去掉应用设置里没意义的「访问权限」标签页。

- **隐藏「访问权限」标签页**：那一栏是给「让用户自己选授权目录」的应用用的。本应用可访问的卷由安装向导决定、每个用户能看哪些文件由闸门按 ACL 判定，所以它永远显示「暂无授权记录」，留着只会让人以为没配好。
- **回退一次改错的尝试**：曾给入口加 `"control": {"accessPerm": "hidden"}` 想隐藏设置里的「自定义 URL」，但这个字段管的是**入口的访问权限**、不是设置项的可见性 —— 结果是入口对普通用户不可见（其他用户预览不了、桌面访问也改不动）。现已把该字段移除、恢复原状。
  「自定义 URL」那一行会继续显示，属外观问题，不影响功能。

## 0.5.17

**逐用户权限校验默认开启**，设置里不再需要开关。

没有读权限的文件直接返回 403。万一出现误拦：把 `@appdata/basemetas-fileview/acl.conf` 里的 `mode=enforce` 改成 `mode=log`，即退回「只记录不拦截」——改完立即生效，不用重启容器也不用重装，且应用不会覆盖手工改动。

## 0.5.16

修闸门两处判定问题。

- 静态资源（css / js / 图片）不再按文件权限拦 —— 否则被拦用户的样式与脚本也会 403。
- `GET /preview/api/file?filePath=/opt/…` 这类请求带的是引擎内部转换产物路径，改为按**来源页 URL 里的原始路径**判定，堵掉「知道转换后文件名就能取走」的旁路。

## 0.5.15

新增**逐用户权限校验闸门**：按当前登录用户检查目标文件能否读取，没有读权限返回 403。

不依赖官方开放 API（那条路实测走不通：应用脚本拿不到 token），改用网关转发的身份头，并以该用户身份做 VFS 层权限判定 —— 含用户组，所以团队文件也能正确放行。
同时新增诊断端点 `/app/basemetas-fileview/__whoami`。

## 0.5.14

新增 `/app/basemetas-fileview/__whoami` 诊断端点，回显网关转发过来的身份头；网关访问日志增加 `uid` / `isadmin` 两列。

## 0.5.13

撤回 `cmd/main stop` 里自己加的「兜底停容器」—— 它反而制造了问题：先把容器停掉会让框架自己那次 `compose stop` 状态对不上；而且给的 5 秒太短，引擎被 SIGKILL 后退出码变成 137。不加干预时容器本来就能正常停下。

## 0.5.12

清理 compose 重建被中断时残留的临时容器（形如 `<hash>_<容器名>`）。它会和正式容器同名同项目，让飞牛每次停用 / 卸载都报 `No such container`。

## 0.5.11

修「点停用报 `Request failed`」：保存设置时不再无条件重建容器，改成「挂载清单真的变了才重建」，消除与框架停用动作的竞态。

## 0.5.10

`docker-compose.yaml` 里的 `${TRIM_PKGVAR}` / `${TRIM_APPDEST}` 改为在回调里就地替换成真实路径，不再依赖框架注入环境变量（框架自己跑 compose 时不保证注入）。

## 0.5.9

声明 `api-scope`，并新增启动时的开放 API 预检（结果写进 `@appdata/basemetas-fileview/fv-volumes.log`），用来判断能否走官方的 `trim.file.checkUserACL`。

## 0.5.8

修「新加的存储卷永远预览不了」（典型现象：`/vol1`、`/vol2` 正常，`/vol3` 里的文件一律报「文件不存在」）。

真因：生命周期脚本以应用用户身份运行，而它不在 `docker` 组里，所有 docker 操作都静默失败 —— 于是「保存设置自动重建容器」从未生效，容器从安装起就没被重建过，compose 里后加的 `/vol3` 永远进不了容器。
修法：`config/privilege` 增加 `join-groups: ["docker"]`；docker 用不了时写日志与界面提示，不再静默跳过。

---

## 0.5.7

修复「docker 里容器已经没了，但应用中心卸载失败」的问题。

### 修复

- **卸载时报 `Request failed, please try again later`**
  如果你曾经手动执行过 `docker compose up -d` 且没有指定 `-p basemetas-fileview`，
  生成的容器 label 里的 compose project 名会脱离飞牛管理。
  应用中心卸载时按自己的 project 名 `basemetas-fileview` 执行 `docker compose down`，
  找不到对应工程，于是失败，但 `docker ps` 里容器其实已经被手动操作删掉了。
  现在 `cmd/uninstall_init` 和 `cmd/uninstall_callback` 都先按**容器名**强删一次，
  再按**项目名**幂等 down 一次，并清理宿主机残留的 `app.sock` / `docker/.env`，
  让卸载流程能正常完成。

### 新增

- `tools/fv-uninstall-fix.sh` —— 针对当前已经卡住的卸载状态，在 NAS 上 root 执行，
  按容器名强删、按项目名 down、备份并移除应用目录、重启应用中心服务刷新 UI。

---

## 0.5.6

本次修的是一个「应用看起来在跑、实际上预览全挂」的问题，以及存储卷配置的老毛病。

### 修复

- **网关容器无限重启（`Restarting`）**
  `app.sock` 落在应用目录里，而该目录是宿主机的 bind 挂载——容器删除、重启都不会清掉这个文件。
  nginx 不会自己处理已存在的 unix socket，启动时直接 `bind() ... failed (98: Address already in use)`
  → 进程退出 → 配合 `restart: unless-stopped` 陷入无限重启。
  表现为「引擎容器是 Up 的，但整个预览打不开」。
  现在启动前会先清理残留 socket（compose 启动命令 + `cmd/main` 两处，互为兜底）。

- **改了存储卷设置却不生效**
  bind 挂载在容器**创建时**就确定了，改完 compose 再 `docker restart` 不会应用新挂载，必须重建容器；
  而飞牛保存设置后并不会重建容器。现在保存设置即自动重建，无需手动重启应用。

- **命令行手工 `docker compose up -d` 报 `invalid spec: :/app/target:rw`**
  `TRIM_APPDEST` / `TRIM_PKGVAR` 只有飞牛框架执行脚本时才注入，手工执行时为空。
  现在会自动生成 `docker/.env` 写死这两个值。

### 改进

- **存储卷默认改成 `auto`，自动挂载本机全部 `/volN`**
  此前默认值写死 `/vol1,/vol2`，机器上新增的盘（如 `/vol3`）必须手工补填，否则一律「文件不存在」；
  卸载重装还会回到默认值，问题必然复现。现在以 `/proc/mounts` 的真实挂载情况为准。
  想只开放部分卷，把 `auto` 换成 `/vol1,/vol2` 这样的列表即可。
  以后新增硬盘：把设置改回 `auto` 保存一次就会自动纳入。

### 新增

- `tools/fv-repair.sh` —— NAS 上一键修复脚本：探测存储卷 → 重写挂载段 → 清残留 socket → 重建容器 → 验证并打印结果。

---

## 0.5.5

- **修复 Excel / CSV 打开后无限转圈**（Word / PPT / PDF / DWG 均正常）。
  根因在前端源码：只有 Excel/CSV 这个渲染器取文件时写了 `credentials: 'omit'`，
  在统一网关模式下文件请求要靠登录 Cookie 鉴权，凭据被 omit 掉就拿不到文件字节；
  而该渲染器没有 error 回调，遮罩永远不会隐藏，界面表现为静默转圈。
  已在网关层用 `sub_filter` 把这一处改写回浏览器默认的 `same-origin`。
  已向上游反馈（`fetch` 不应 omit 凭据），上游修复后这段改写会移除。

## 0.5.4

- 支持**自定义字体**。镜像只内置免费思源字体与部分英文字体，官方机制是把宿主目录挂到
  容器的 `/usr/local/share/fonts`。本包挂到应用数据目录 `${TRIM_PKGVAR}/fonts`，卸载/升级不丢。

## 0.5.3

- 入口精简为只保留「用 FileView 打开」，去掉桌面图标入口（唯一作用是打开欢迎页，还在设置里多一张卡片）。

## 0.5.2

- 首个可安装版本。包版本号与引擎版本解耦，`0.5.2` 对应引擎 `1.5.2`。

---

## 升级方法

应用中心 → 卸载 → 重新「手动安装」新版 `.fpk`。镜像会复用，重装很快。

若不想重装，也可以只替换运行中的文件后重启容器（`@appcenter` 目录下的 `docker/` 可通过文件管理器「管理员视角」访问）。
遇到「引擎 Up、网关 Restarting」这类故障时，直接在 NAS 上跑 `tools/fv-repair.sh` 即可，不必重装。
