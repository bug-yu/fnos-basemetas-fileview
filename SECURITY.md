# 安全说明与审计结论

本文分四部分：

1. **威胁模型**：这个应用的信任边界在哪
2. **审计核对**：第三方审计报告 9 项逐条核对（含 2 处修正）
3. **风险接受声明**：明知而接受的三项残余风险（**部署前请读完这一节**）
4. **已实施 / 待办**：0.5.30 做了什么、还剩什么

> 版本基线：`0.5.55`（引擎 `basemetas/fileview:1.5.2@sha256:ebcb1dc6…`）。

---

## 1. 威胁模型

**信任边界**：飞牛统一网关以内是「可信登录用户」。本应用**只防「已登录的用户 A 去看用户 B 的文件」**，不防已登录用户本身搞破坏。任何绕过网关的攻击面不在范围内（网关未登录一律挡住）。

三个容器：

| 容器 | 镜像 | 身份 | 职责 | 关键权限 |
|---|---|---|---|---|
| `-engine` | `basemetas/fileview`（锁 digest） | **root** | 预览引擎 | 只读挂载全部存储卷 |
| `-gateway` | `nginx:alpine` | root | 统一网关适配层、unix socket | 挂整个 docker 目录、挂 `${TRIM_APPDEST}` |
| `-acl` | `python:3-alpine` | **root** | 逐用户权限闸门 | 挂宿主 `/etc/passwd`、`/etc/group`（只读）+ 只读存储卷 |

**三容器都必须是 root**，这是设计使然：

- engine：上游镜像 `USER` 就是 root，无 override；
- acl：判定要 `setuid` 到目标用户，非 root 做不到；
- gateway：`nginx:alpine` 默认 root（监听 unix socket、`umask 000`）。

另外，**应用用户被加入了 `docker` 组**（`config/privilege` 的 `join-groups: ["docker"]`），因为「保存设置后自动重建容器 / 停用 / 上报状态」都要以应用用户操作 docker socket。这约等于把 docker socket 交给该应用用户（≈ root）。这一点已如实写进 README「安全说明」，**换机器部署前请确认接受**；上架相关影响见 §3.2。

---

## 2. 审计报告逐条核对

审计报告共列 9 项。逐条核对结论：

### ✅ 1. 容器以 root 运行 —— 准确

三容器都是 root，原因见上。这是**必要设计**（setuid 判定、上游镜像），不是疏忽。缓解：存储卷**只读**挂载。

### ✅ 2. 逐用户闸门是 fail-open 设计 —— 准确

`fv-acl-gate.py` 的所有异常路径（缺 uid、解析不到路径、查不到用户、判定超时）**一律放行并记日志**。设计取舍：宁可「没保护」也不「误拦合法访问」——误拦会把应用弄坏，方向更危险。应急开关 `acl.conf` 的 `mode=log` 可退回「只记录」。

> 这一项的风险含义已单列成显式条目，见 **§3.1**。原文只写在注释和这一段里，容易被读成「一句取舍说明」而漏掉其安全后果。

### ⚠️ 3.「100 MB 解压上限是缓解措施」—— **归因错误**

审计报告把 `fileview.preview.storage.max-file-size-mb` 的默认值 100 MB 当作本应用的一层防护。**实际不是**：这是**引擎自带的默认值**，本应用反而把它**放开到了 1024 MB**（0.5.20，用户可在向导里调到 100 GB）。

也就是说这一项不仅不是缓解，方向还相反（为了让大文件能预览而放宽）。**真正的缓解是「单用户单请求」的量级限制，而不是这个上限。** 已在 CHANGELOG 更正。

### ⚠️ 4.「compose 未声明 `networks:`，可能与其它应用同一网络」—— **不准确**

本应用 compose **没有** `networks:` 声明，但这不等于和别的应用同网。没有声明时 docker compose 会为该项目创建**独立的默认 bridge 网络**，项目之间**不互通**。本应用三容器在该独立网络内互通，并且**不从外部加入其它应用的网络**。

真正需要注意的是：三容器之间**没有网络隔离**（engine ↔ gateway ↔ acl 可互访），因为它们本就靠同一网络协作。这不构成跨应用风险。

### ✅ 5. 路径穿越 / 后缀绕过 —— 准确（且已确认可利用）—— 0.5.25 已修

`SKIP_EXT` 只看 URI 后缀就放行是一处**真实旁路**。验证结果：

```
GET /preview/api/file.css?filePath=/vol1/…/sample.docx   → 500
GET /preview/api/file?filePath=/vol1/…/sample.docx       → 200
```

**500 而不是 404** 是关键证据：若该 URL 没匹配到任何 location 会是 404，返回 500 说明它**确实被路由到了后端接口**（只是 `filePath` 被当成 `.css` 去读才报错）；正确路径返回 200 则证明 `filePath` 参数可用。结论：**「换后缀」不足以绕开封禁接口，但闸门那道放行是真的开着** —— 一旦上游放宽后缀匹配就是完整绕过。

**0.5.25 已修**：扩展名短路只在「请求自己没带 `/vol` 路径」时生效。带 `?filePath=/vol…` 或 `X-Acl-Path: /vol…` 的一律落到正常判定。12 条判定矩阵单测（`fpk/tools/test_acl_decide.py`）已并入自检。

### 🔴 6. POST body 里的路径判定不到 —— **准确，源码级坐实为高危 —— 0.5.50 已修**

> **本节曾经历一次「结论被回滚」**：原判「影响有限 / 低优先级」是**错的**，
> 项目已在 `c431a3b` 更正为**高危**；但 `5b11a63`（整体回退到 0.5.25）把这份更正一起
> 回滚了，于是文档又退回错误版本。2026-10-06 复核后恢复为高危，并在 0.5.50 修复。
> 复核材料：`git show 5b11a63^:fpk/tools/POST-BYPASS-{REVIEW,VERDICT}.md`

**机制**：nginx 的 `auth_request` 在 ACCESS 阶段执行，**请求体还没被读**，
所以鉴权子请求物理上看不到 body（`location = /__acl` 里 `proxy_pass_request_body off`）。
而引擎有多个 POST 接口把路径放在 body 里：

| 接口 | 后果 |
|---|---|
| `POST /preview/api/localFile` | 读任意绝对路径文件（**前端主链路**，不是边缘接口） |
| `POST /convert/api/srvFile` | **以 root 写任意可写路径**（最重） |
| `POST /preview/api/password/unlock` | 密码爆破 + 文件存在性探测 |
| `POST /preview/api/netFile` | SSRF 面（0.5.22 已用 `trusted-sites=none.invalid` 关闭） |
| `POST /preview/api/status/poll` | 无路径，不构成绕过 |

**为什么「退回来源页判定」挡不住**（真机 2026-09-30 复现）：

```
[1] GET  对照                    → 403   闸门正常
[2] POST 无 Referer              → 200   绕过成立
[3] POST 带**合法** Referer      → 200   ⚠️ 掩护也成立（决定性）
```

攻击者先打开一个**自己有权读**的文件拿到合法 `Referer`，再把 body 里的路径换成别人的 ——
闸门拿 Referer 里的合法路径判定并放行，**body 里的非法路径根本没被看过**。
这直接否掉了「无来源页时 fail-closed」这条廉价路线。

**修法**（不依赖 njs，见下「为什么不是 njs」）：

1. **让闸门读到 body**：这几个接口**不走 `auth_request`**，改由 nginx 把整个请求
   代理给闸门的 `/guard` —— 闸门读 body 取出路径、按 uid 判 ACL，
   **通过后由闸门自己转发给引擎**。于是「判定的路径」与「引擎实际读的路径」
   必然是同一个值，没有空隙可钻。判定**只用请求体里的路径，绝不退回来源页**。
2. **封掉用不到的高危接口**：`/convert/api/srvFile`（root 写）在网关层直接 403。
   `password/unlock`（密码探测）**不封禁而是走闸门** —— 加密压缩包解锁功能保留，
   但路径先过逐用户 ACL 判定。
3. **fail-open 不变**：闸门不可用时 nginx `error_page` 直连引擎 ——
   与 §3.1 的取向一致（最坏是"没保护"，不会变成"应用打不开"）。
4. **可单独回退**：`${TRIM_PKGVAR}/acl.conf` 的 `body_guard=enforce|log`，
   与 `mode` 是两个独立开关，改完立即生效、不用重启容器。

**为什么不是 njs**（0.5.26/0.5.27 走过的路）：当时用 njs `js_access` 在主 location 里读 body，
**真机连续三轮翻车** —— ① conf.d 片段被当主配置传给 `nginx -c` → `map` 报错、无限重启；
② `load_module` 写进 conf.d 片段 → "not allowed here"、被误判成"镜像不含 njs"；
③ 镜像的 njs 版本过旧不认识 `js_access`。用户判断「部署风险 > 收益」要求撤销。
本方案**不引入任何 nginx 模块**，失败形态从「容器起不来」降级为「某功能 403」。

**验证**：`fpk/tools/test_body_guard.py` 的判定矩阵（15 条，含桩引擎验证转发链路），
已并入 `fpk/tools/selfcheck.sh`；核心用例是
**「来源页合法 + 请求体私有 → 必须 403」**（旧实现会放行）。

**仍存的残余风险（需单独确认）**：`GET /files/{fileId}`、`/files/{fileId}/page/{n}`、
`/files/{fileId}/pages` 请求里**没有路径** → 闸门天然看不见 → 属 fail-open，
保护依赖「`fileId` 不可猜」+「触发转换那一步已被堵」。**需确认 `fileId` 是否可枚举**。

### ✅ 7. 静态资源不判定 —— 准确（设计如此）

静态资源（css/js/字体/图片）不是用户的文件，按 ACL 拦它们只会产生噪音（被拦用户的样式 403）。**但** 0.5.25 后这条只在「请求不带路径」时生效，不再能被利用来放行带路径的接口。

### ✅ 8. `data` / `logs` 目录 0777 —— 准确 —— 0.5.25 已修

**0.5.25 改为 0700**。依据：引擎容器以 `uid=0(root)` 运行（`docker exec basemetas-fileview-engine id`），root 无视权限位，收紧不影响读写；而 `data`/`logs` 含**转换产物**（被预览文件的中间形态，可能是内容片段）与日志。

### ✅ 9. 网络文件预览 SSRF —— 准确 —— 0.5.22 已修

`fileview.network.security.trusted-sites` 未配置时引擎**默认允许所有域名**（`HttpUtils: if (!hasTrustedSitesConfig()) return true;`），而 `?url=` 路径**绕过逐用户闸门**（没有 `/vol` 路径 → 走「放行」分支）。

**0.5.22 已修**：配成永不匹配的域名 `none.invalid`，等价全禁。欢迎页「查看样例」用容器内路径，不受影响。

---

### ~~10. `/cad/api/raw`（0.5.55 新增）~~ → **0.5.58 已删除**（攻击面收回）

> **0.5.58 起这个端点不存在了。** CAD 预览整体移出本应用
> （改由独立应用 [fnos-cadviewer](https://github.com/bug-yu/fnos-cadviewer) 承接），
> 而 `/cad/api/raw` 是**唯一**为它服务的接口 —— 既然没有使用者，就**把这个能力收回** ✓：
>
> - nginx 的 `location = /app/basemetas-fileview/cad/api/raw` 已删
> - 闸门的 `/raw` 处理、`safe_real_file()` 路径收敛函数已删
> - 自检加了**反向断言**：`grep aclgate/raw` / `grep 'def _raw'` 必须为空 ✗
>
> **净效果：本应用少了一个「把文件字节交出去」的端点。** 这是移出 CAD 顺带的收益，
> 不是损失 —— 原来它是全应用里**唯一**比「放行/拒绝」更强的接口。
>
> 下面保留原设计说明，供回看（也解释了当时为什么必须 fail-closed）。

<details>
<summary>原设计（0.5.55 ~ 0.5.57，已删除）</summary>

CAD 预览页要读**原文件**，所以多了一个「把文件字节交出去」的端点。
它比闸门原有的「放行 / 拒绝」**能力更强**，因此按最严设计：

| 措施 | 说明 |
|---|---|
| **不依赖 `auth_request`** | `auth_request` 是**子请求**，`$arg_filePath` 在子请求里不一定可用；而闸门在「解析不到路径」时是 **fail-open（放行）** —— 只靠它等于开了个**任意文件读取**后门 ✗ |
| **由闸门自己判** | nginx 把身份与路径**直接**交给闸门的 `/raw`，由它调 `can_read(uid, path)` 判定 |
| **fail-closed** | 与闸门其它地方**有意不同**：`can_read` 返回「无法判定」时**拒绝**（403），而不是放行 ✓ |
| 路径收敛 | 必须绝对路径且以 `/vol` 开头；拒绝含 `..`；`realpath` 之后仍须在 `/vol` 下（挡符号链接绕过）；只允许**普通文件** |
| 身份缺失 | 拿不到 uid 直接 403（不放行） |
| 响应头 | `X-Content-Type-Options: nosniff`（不让浏览器把 `.dwg` 当别的类型解析） |

**为什么当时可以接受这个新增端点**：它用的 `can_read` 与 FileView 本身**同一个判定口径**，
所以**没有扩大**任何用户能读到的范围 —— 只是把「能读到的文件」以字节形式交出去。

</details>

---

## 3. 风险接受声明

以下三项是**明知而接受**的残余风险。它们不是"待修的 bug"，而是设计取舍的代价。
本节存在的目的：把这些后果集中写清楚，而不是散落在代码注释、README 段落和审计核对里 ——
**换机器部署、或把本应用交给他人使用前，请逐条确认你能接受。**

### 3.1 权限闸门 fail-open —— 最坏情况是"没有保护"，而不是"应用打不开"

**这是本应用安全模型里最重要的一条取舍。**

闸门（`fv-acl-gate.py` + nginx `auth_request`）在以下任一情况下会**放行**：

| 触发条件 | 行为 |
|---|---|
| 请求里没有 `X-Trim-Userid`（网关没注入身份头） | 放行 + 记日志 |
| 从请求里解析不出目标路径 | 放行 + 记日志 |
| 目标 uid 在宿主 `/etc/passwd` 里查不到 | 放行 + 记日志 |
| 判定过程抛异常 / 超时 | 放行 + 记日志 |
| 闸门容器整个不可用 | nginx `upstream` 自动 failover 到本机回环上"永远返回 200"的服务 → 放行 |

**具体后果**：在上述任一状态下，**任何能登录飞牛的用户都能预览已挂载存储卷里的任意文件**
（引擎容器以 root 只读挂载全部 `/volN`，本身不做用户区分）。也就是说，这时本应用退化成
"没有逐用户权限校验"的版本。

**为什么这么设计**：反向失败（误拦）会挡掉合法访问 —— 用户打不开自己的文件、团队文件因附加组
没还原而被判不可读。误拦是**确定性故障**且难以自诊断；fail-open 只在"闸门本身出问题"时才暴露，
且**每一次放行都会留日志**。取舍是"可用性优先"。

**这与官方取向相反，必须知情**：官方《统一网关》对文件访问的要求是"标准化请求路径 / 拒绝 `..`
目录穿越 / 只从预期目录提供文件"—— 即**默认拒绝**。本应用的闸门是**默认放行 + 例外拦截**。
两种取向的安全边界不同，本应用选了后者。

**可验证 / 可缓解**：

- 每次放行都有日志：`docker logs basemetas-fileview-acl`。
- 想确认身份头到底有没有进来：浏览器打开 `https://<域名>/app/basemetas-fileview/__whoami`，
  应显示 `uid=<uid> | user=<用户名> | isadmin=true`。**看不到 `uid=` 就说明闸门当前等于没开。**
- 应急开关：`${TRIM_PKGVAR}/acl.conf` 的 `mode=enforce`（默认，真正拦截）/ `mode=log`（只记录）。
  改完立即生效，不用重启容器。
- **建议**：把 `__whoami` 作为部署后的常规自检项。它是判断"闸门是否真的在工作"的唯一直接证据。

> 注：`disable_authorization_path=true`（隐藏应用设置里的"访问权限"页）是同一决策的另一面 ——
> 本应用不走飞牛的"用户自行授权目录"模型，所以那一页留着只会误导。见 README 同名小节。

### 3.2 `join-groups: ["docker"]` ≈ 把 docker socket 交给应用用户（≈ root）

`config/privilege` 里应用用户加入了 `docker` 组，因为 `/var/run/docker.sock` 是 `root:docker 0660`，
不加就"保存设置后自动重建容器 / 如实上报运行状态 / 停用"**全部静默失败**。

**具体后果**：该应用用户可完全控制本机 docker —— 等价于 root（可起特权容器、挂宿主根目录）。
这比"应用以 root 在容器里跑"更进一步：前者是容器内 root，后者是**宿主上的 root 能力**。

**上架影响（重要）**：官方对第三方应用的 root 权限有明确限制 ——
**第三方应用默认无法在应用中心上架 root 权限应用，root 模式仅对飞牛官方合作的企业开发者开放**
（见社区技能 `fn-fpk` §5.2）。本应用 `run-as` 用的是 `package`（合规），但 `join-groups: ["docker"]`
在效果上等同 root，**上架审核时几乎必然被质疑**。

若计划上架，需预先准备：

1. 说明"为什么非给不可"（改设置自动生效依赖 docker 操作），并给出**不给权限时的降级路径**：
   改完设置后手工重建容器 ——
   ```bash
   cd /vol1/@appcenter/basemetas-fileview/docker
   TRIM_APPDEST=/vol1/@appcenter/basemetas-fileview \
   TRIM_PKGVAR=/vol1/@appdata/basemetas-fileview \
   docker compose -p basemetas-fileview up -d --force-recreate
   ```
2. 说明"给了之后风险面并没有扩大"：本应用本来就要以 root 在容器里跑预览引擎、只读挂载全部存储卷。
3. 明确提示部署方：**换机器部署前请确认接受这一点**。

**不想接受的话**：删掉 `join-groups`，接受"改设置需手工重建容器"。

### 3.3 未使用官方授权模型 —— 可访问范围由"挂载了哪些卷"决定，不由"用户授权了哪些目录"决定

官方路线是"用户在应用设置里授权目录 / 管理员配置共享授权"，本应用改为"安装向导决定挂载哪些
`/volN`，之后每个用户能看哪些文件由闸门按飞牛 ACL 判定"。原因：官方模型是"预先圈定目录"，
覆盖不了"在文件管理器里右键打开任意文件"这个核心交互。

**具体后果**：挂载进来的卷**整体**对引擎容器可见（root、只读）。权限边界**完全依赖 3.1 的闸门** ——
闸门一旦 fail-open，边界就没了。所以 3.1 和 3.3 是同一个风险的两面，不能分开评估。

**缓解**：只挂确实需要预览的卷（向导里不要图省事填 `auto`）；存储卷一律 `:ro`；`data` / `logs` / `fonts`
目录权限 0700（`data` / `logs` 含转换产物与日志，不是纯公开数据）。

---

## 4. 已实施 / 待办

### 0.5.50 已实施（修压缩包内文件被误拦的回归）

| # | 项 | 位置 |
|---|---|---|
| A | 闸门新增 `resolve_archive_prefix()`：把「压缩包内文件」的**复合路径**（`<压缩包>/<包内路径>/<文件名>`，文件系统上不存在）还原成**压缩包本身**再判 ACL —— 引擎实际读的就是压缩包 | `app/docker/fv-acl-gate.py` |
| B | 存在性探测抽成 `is_file()`，便于单测打桩 | `app/docker/fv-acl-gate.py` |
| C | 新增 6 条压缩包用例（矩阵共 26 条）：可读→放行、不可读→拒绝、包不存在→拒绝、含 `..`→拒绝 | `fpk/tools/test_body_guard.py` |
| D | 自检新增 3 条断言 | `fpk/tools/selfcheck.sh` |

> **这是 0.5.50 引入的回归**：为堵「合法来源页掩护非法请求体」而关掉了 Referer 退路，
> 却没考虑**复合路径这种合法形态** → 包内文件全被 403。
> ⚠️ 改这块时要分清：「还原复合路径」**不是**「退回来源页」——
> 来源页由客户端控制；还原出的路径必须**在文件系统上真实存在**，攻击者构造不出来。

### 0.5.50 已实施（堵上 fileId 推导绕过，出厂 log 档）

| # | 项 | 位置 |
|---|---|---|
| A | 闸门新增 fileId 系接口校验：`/preview/api/files/<fileId>`（含 `/page/N`、`/pages`）**要求请求自带 `filePath`**；带了就按该路径正常判 ACL，不带则按 `fileid_guard` 处理 | `app/docker/fv-acl-gate.py` |
| B | 新增独立开关 `fileid_guard=log|enforce`，**出厂默认 `log`**（先观察再收紧） | `acl.conf` / `fv-volumes.sh` |
| C | `test_acl_decide.py` 新增 **10 条** fileId 用例（含 `/page/N`、`/pages`、"自己的 filePath + 别人的 fileId"、"其它接口不受影响"），并断言 **md5 一致时不得产生「观察」记录** | `fpk/tools/test_acl_decide.py` |
| D | 自检新增断言：`FILEID_RE` / `fileid_guard` 开关 / 拒绝分支存在，且**出厂默认必须是 log** | `fpk/tools/selfcheck.sh` |

> **为什么出厂是 log 而不是 enforce**：合法流程里 `/files/{fileId}/page/{n}` 与 `/pages`
> **没有日志样本**，无法确认它们是否都带 `filePath`。盲切 `enforce` 有误伤风险 ——
> 0.5.31 / 0.5.32 两次翻车都是「本地自检全绿、真机才暴露」。
> 升级后需人工跑一遍全部预览类型（尤其 PDF 多页翻页）确认无误伤，再切 `enforce`。

### 0.5.50 已实施

本版做两件事：**堵上 §2 第 6 项那个高危绕过**，以及修 PDF 预览失败。

| # | 项 | 位置 |
|---|---|---|
| A | **闸门新增 `/guard` 代理模式**：读请求体取路径 → 判 ACL → 通过后**由闸门自己转发**给引擎（判定的路径与引擎实际读的路径必然一致） | `app/docker/fv-acl-gate.py` |
| B | **nginx 把 body-path 接口整体代理给闸门** —— 必须用 `location =` 精确匹配（regex / 命名 / `if` / `limit_except` 里 `proxy_pass` **不能**带 URI 部分，否则启动期 emerg） | `app/docker/nginx.conf` |
| C | **fail-open 落点** `@fv_guard_direct`：闸门不可用时直连引擎；并补 `proxy_intercept_errors on`（否则**上游返回的** 502 不触发 `error_page`） | `app/docker/nginx.conf` |
| D | **转发必须带 `Host` 与全套 `X-Forwarded-*`** —— 引擎按请求头推导绝对地址，少了会拼出 `http://fileview/...`（症状：**只有 PDF 打不开**） | `app/docker/fv-acl-gate.py`、`nginx.conf` |
| E | **网关层封禁** `/convert/api/srvFile`（root 写）；`password/unlock` 改为走闸门（功能保留 + 路径受校验） | `app/docker/nginx.conf` |
| F | **新增 `body_guard` 开关**（与 `mode` 独立），可单独回退这一层且立即生效 | `acl.conf` / `fv-volumes.sh` |
| G | **判定矩阵单测 20 条**（桩引擎验证转发链路 + 5 条转发头断言） | `fpk/tools/test_body_guard.py` |
| H | **两个 nginx 检查器接进自检**；`check_nginx_conf.py` 新增「`proxy_pass` 带字面量 URI 却在 regex/命名/if 块里」规则（含阳/阴性对照） | `fpk/tools/selfcheck.sh`、`check_nginx_conf.py` |

> **开发过程中的两个中间版本（均已作废、未发布）**：首个实现把代理写成
> regex location + 带 URI 的 `proxy_pass` → nginx 启动期 emerg、网关无限重启；
> 改用精确匹配后，又在闸门转发时丢了 `Host` / `X-Forwarded-*` → PDF 打不开。
> 两次的共同点是**本地自检全绿、真机才暴露**。教训已固化成断言（见 H）
> 与 README 里的硬约束说明。

### 0.5.30 已实施

| # | 项 | 位置 |
|---|---|---|
| A | **恢复 `api-scope` 声明**（0.5.25 误删，导致开放 API 预检必然 403） | `config/resource` |
| B | 预检脚本新增响应分类，403/401/404 分别给出准确结论，不再误报"没有授权目录" | `app/docker/fv-acl-probe.sh` |
| C | 自检新增断言：预检调用的每个开放接口都必须在 `config/resource` 有对应 scope | `fpk/tools/selfcheck.sh` |
| D | 基础镜像锁 digest（`nginx:alpine` / `python:3-alpine`） | `app/docker/docker-compose.yaml` |
| E | 本节（§3 风险接受声明）从注释/段落集中成显式条目 | `SECURITY.md` |

### 0.5.25 已实施（4 项，均不改变正常行为）

| # | 项 | 位置 |
|---|---|---|
| A | 闸门扩展名短路加 `/vol` 保护（修旁路） | `app/docker/fv-acl-gate.py` |
| B | ~~删掉未使用的 `api-scope` 声明~~ → **⚠️ 此项结论错误，0.5.30 已撤销** | `config/resource` |
| C | 引擎镜像锁 digest | `app/docker/docker-compose.yaml` |
| D | 目录权限 0777 → 0700 | `fv-volumes.sh` / `cmd/install_init` / `cmd/main` |

> **关于 B 项的更正**：审计判定"`api-scope` 未使用"是**事实错误**。`api-scope` 与预检脚本是
> 0.5.9 同一次提交引入的（"声明 api-scope 并新增开放 API 预检"），预检从那时起就一直在调
> `trim.system.getPlatformConfig` / `trim.file.getSharedAccessibleFolders` / `trim.file.checkUserACL`。
> 删掉 scope 后这些调用一律 `403 / 200003 Forbidden`，而探针会把 Forbidden 响应误报成
> "没有解析到授权目录，需要管理员添加" —— 一条**指向错误方向**的日志。
> 详见 README「背景：为什么不用飞牛的开放 API」。

自检：`fpk/tools/selfcheck.sh` 断言（digest / 0700 / 旁路保护 / **api-scope 覆盖预检全部调用** / 判定矩阵单测）。

### 其余已修（早于本次审计）

- **0.5.22**：网络预览 SSRF 关闭；引擎工作目录 + 日志挂出（不再落可写层）。

### 待办（未做，按优先级）

0. ✅ **`fileId` 可预测 → 绕过闸门 —— 已闭环（0.5.50 加校验 + 0.5.50 修回归 + 用户已切 `enforce`）**：
   **`fileId = "preview_" + md5(原始绝对路径)[:16]`** —— 已用两组真机数据离线验算，
   同时精确命中（`<示例文档>.pdf` → `<示例md5-1>`、`<示例表格>.xls` → `<示例md5-2>`）。

   而 `GET /preview/api/files/{fileId}` 的 `path` 参数是**可选**的（引擎源码
   `serveFile()` 里 `@RequestParam(required = false)`），不给路径时走
   `cacheInfo.getOriginalFilePath()` —— **只凭 fileId 就能吐原始文件**。
   闸门对这类请求看不到任何路径 → 走「未解析到路径（放行）」→ **放行**。
   前提是该文件 24h 内被**任何人**预览过（Redis 缓存 TTL 24h）—— 团队/共享文件正好命中。

   **0.5.50 已做的**：闸门对 fileId 系接口（含 `/page/N`、`/pages`）要求请求自带 `filePath`；
   带了就按该路径正常判 ACL，不带则按 `fileid_guard` 处理。

   **✅ 已由用户切换 `enforce`（2026-10-07）**。观察结论：跑遍全部预览类型
   （PDF / DWG / xlsx / ofd / 压缩包），闸门日志里**所有** `/preview/api/files/<fileId>`
   请求**都带 `filePath`**，且 `grep -E "仅记录|观察"` **一条都没有**
   → **可以放心切 `enforce`**：
   ```bash
   sed -i 's/^fileid_guard=.*/fileid_guard=enforce/' /vol1/@appdata/basemetas-fileview/acl.conf
   ```
   切完再跑一遍同样的预览类型确认功能没坏；有误伤就改回 `log`（同样立即生效）。

   详细证据链与复现命令：`D:\notes\10-Notes\飞牛NAS\fnos-basemetas-fileview-fileId可预测绕过.md`

1. ~~**复核 `TRIM_API_TOKEN` 是否真的拿不到**~~ —— ✅ **已实机复核（2026-10-06，0.5.30）：确认拿不到。**
   条件已全部满足：系统 `1.2.0701` ≥ `1.2.0401`、`api-scope` 已声明、socket 可连通
   （不带 token 返回 `200004 Unauthorized`，ACL 含 `group:TrimApiUsers:rw-`），
   但 `TRIM_API_TOKEN` 仍为空（预检来源 `config_callback`）。
   **结论：官方 `trim.file.checkUserACL` 路线在本文所述实现下暂不可行**，自建闸门仍是唯一方案。
   `api-scope` 声明保留（0.5.30 起）—— 它让预检在飞牛将来补上 token 注入时能直接跑通，
   不必再改包。**唯一未观测到的场景**：官方文档点名 `cmd/main`，而实测框架启停
   docker 应用**不调用 `cmd/main`**（见下条），所以"`cmd/main` 里是否有 token"仍无数据。
   若想补这个数据点，在 `cmd/main` 里加一行 token 存在性日志即可（`status` 会被轮询）。
2. ✅ **POST body 路径判定（审计 #6）—— 0.5.50 已修**，见 §2 第 6 项。
   闸门新增 `/guard` 代理模式（读 body → 判 ACL → 自己转发），
   并封禁了两个用不到的高危接口。判定矩阵单测 15 条已并入自检。
   **仍待确认的残余风险**：`GET /files/{fileId}`、`/files/{fileId}/page/{n}`、`/files/{fileId}/pages`
   请求里没有路径 → 闸门天然看不见 → 属 fail-open，保护依赖 `fileId` 不可猜。
   **需确认 `fileId` 是否可枚举/可预测**（本条优先级：中）。
3. **`acl` 容器挂载收敛**：当前挂宿主 `/etc/passwd`、`/etc/group`（只读）。可评估是否可以缩到只挂必要字段 / 用 nss-wrapper，减少信息暴露。收益有限，暂缓。
4. **镜像升级流程**：锁 digest 后升级要**同时改标签和 digest**。查 digest：
   ```bash
   docker buildx imagetools inspect basemetas/fileview:<tag>
   docker buildx imagetools inspect library/nginx:alpine
   docker buildx imagetools inspect library/python:3-alpine
   ```
5. ✅ **框架启停 docker 应用不调用 `cmd/main`（0.5.30 实测）—— 说法已更正（2026-10-08）**：
   `appcenter-cli stop` + `start`（提示 `Launching complete`）之后，
   `${TRIM_PKGVAR}/fv-volumes.log` **一条新记录都没有** —— 而 `cmd/main start` 一旦被调用
   必然写日志（无条件 `fv_sync_volumes "" ensure` + 跑预检）。所以它没被执行。
   **影响**：`cmd/main start` 里的「安装完整性预检 / 升级后自愈 / 开放 API 预检」
   在应用启停时不会跑。自愈能力没丢（`upgrade_callback` / `config_callback` 里有同样的同步逻辑），
   但"启动时"这个时机确实没覆盖 —— 而 `cmd/config_callback` 的注释一直假设它会被调用。

   **已做（2026-10-08）**：把「假设它会被调用」的说法全部改过来 ——
   - `cmd/main` 文件头：写明框架启停不调用本脚本，只有 `status` 会被轮询；
     start 分支里的「框架紧接着就用这份 compose 起容器」那句（错的）已删除，
     并注明自愈的真正落点是 `upgrade_callback` / `config_callback`；
   - `cmd/config_callback`：注明「保存设置」是预检**唯一**会自动执行的时机，
     并显式标出旧说法（「cmd/main start 只在停止→启动时被调用」）是已被否定的猜测；
   - `app/docker/fv-acl-probe.sh` 文件头：调用来源改为 `config_callback` + `cmd/main start`；
   - `README.md`：「升级会顶掉挂载段」一节与「诊断」一节同步更正
     （预检结果不是"启动时"写的，而是保存设置 / 升级时写的）。

   **仍未做（可选项）**：把「启动时自愈」挪到一个框架确实会调用的时机。
   现状是**接受**「只在升级 / 保存设置时自愈」—— 因为这两条路径已经覆盖了所有会改写
   compose 的场景（安装、升级、保存设置），启动时并不需要再同步一次。
6. ✅ **框架日志里的两类启停报错 —— 用户判断为正常现象，关闭**（2026-10-07）：
   `/var/log/apps/basemetas-fileview.log` 里会出现
   `failed to set up container networking: network … not found` 与
   `open /docker/docker-compose.yaml: no such file or directory`。
   经用户确认：**飞牛官方的应用启停也有类似现象**，属框架侧行为，不是本应用的问题。
   （发生时报错后框架会重试成功，容器最终 `Up`、预览正常。）
   保留记录仅供以后遇到同类现象时对照；项目自带 `tools/fv-repair.sh` 可备用。

### 明确不做的

- **不为「防已登录用户搞破坏」加防护**：超出威胁模型（见 §1）。
- **不改成非 root 运行 engine**：上游镜像就是 root，改了大概率起不来，且存储卷已只读。
- **不把闸门改成 fail-closed**：见 §3.1 的取舍理由。但**建议**把 `__whoami` 纳入部署自检。

