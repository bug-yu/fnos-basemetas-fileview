# 安全说明与审计结论

本文分三部分：

1. **威胁模型**：这个应用的信任边界在哪
2. **审计核对**：第三方审计报告 9 项逐条核对（含 2 处修正）
3. **已实施 / 待办**：0.5.25 做了什么、还剩什么

> 版本基线：`0.5.26`（引擎 `basemetas/fileview:1.5.2@sha256:ebcb1dc6…`）。

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

另外，**应用用户被加入了 `docker` 组**（`config/privilege` 的 `join-groups: ["docker"]`），因为「保存设置后自动重建容器 / 停用 / 上报状态」都要以应用用户操作 docker socket。这约等于把 docker socket 交给该应用用户（≈ root）。这一点已如实写进 README「安全说明」，**换机器部署前请确认接受**。

---

## 2. 审计报告逐条核对

审计报告共列 9 项。逐条核对结论：

### ✅ 1. 容器以 root 运行 —— 准确

三容器都是 root，原因见上。这是**必要设计**（setuid 判定、上游镜像），不是疏忽。缓解：存储卷**只读**挂载。

### ✅ 2. 逐用户闸门是 fail-open 设计 —— 准确

`fv-acl-gate.py` 的所有异常路径（缺 uid、解析不到路径、查不到用户、判定超时）**一律放行并记日志**。设计取舍：宁可「没保护」也不「误拦合法访问」——误拦会把应用弄坏，方向更危险。应急开关 `acl.conf` 的 `mode=log` 可退回「只记录」。

### ⚠️ 3.「100 MB 解压上限是缓解措施」—— **归因错误**

审计报告把 `fileview.preview.storage.max-file-size-mb` 的默认值 100 MB 当作本应用的一层防护。**实际不是**：这是**引擎自带的默认值**，本应用反而把它**放开到了 1024 MB**（0.5.20，用户可在向导里调到 100 GB）。

也就是说这一项不仅不是缓解，方向还相反（为了让大文件能预览而放宽）。**真正的缓解是「单用户单请求」的量级限制，而不是这个上限。** 已在 CHANGELOG 更正。

### ⚠️ 4.「compose 未声明 `networks:`，可能与其它应用同一网络」—— **不准确**

本应用 compose **没有** `networks:` 声明，但这不等于和别的应用同网。没有声明时 docker compose 会为该项目创建**独立的默认 bridge 网络**，项目之间**不互通**。本应用三容器在该独立网络内互通，并且**不从外部加入其它应用的网络**。

真正需要注意的是：三容器之间**没有网络隔离**（engine ↔ gateway ↔ acl 可互访），因为它们本就靠同一网络协作。这不构成跨应用风险。

### ⚠️ 5. 路径穿越 / 后缀绕过 —— 准确（且已确认可利用）—— 0.5.25 已修

`SKIP_EXT` 只看 URI 后缀就放行是一处**真实旁路**。审计指出后，我实测验证：

```
GET /preview/api/file.css?filePath=/vol1/…/sample.docx   → 500
GET /preview/api/file?filePath=/vol1/…/sample.docx       → 200
```

**500 而不是 404** 是关键证据：若该 URL 没匹配到任何 location 会是 404，返回 500 说明它**确实被路由到了后端接口**（只是 `filePath` 被当成 `.css` 去读才报错）；正确路径返回 200 则证明 `filePath` 参数可用。结论：**「换后缀」不足以绕开封禁接口，但闸门那道放行是真的开着** —— 一旦上游放宽后缀匹配就是完整绕过。

**0.5.25 已修**：扩展名短路只在「请求自己没带 `/vol` 路径」时生效。带 `?filePath=/vol…` 或 `X-Acl-Path: /vol…` 的一律落到正常判定。12 条判定矩阵单测（`fpk/tools/test_acl_decide.py`）已并入自检。

### 🔴 6. POST body 里的路径判定不到 —— 准确，**已升级为高危**，**0.5.26 已修**

> ⚠️ **本条在 0.5.25 里被误判为「低优先级」，现已更正。** 详见
> [`fpk/tools/POST-BYPASS-REVIEW.md`](fpk/tools/POST-BYPASS-REVIEW.md)、
> [`fpk/tools/POST-BYPASS-VERDICT.md`](fpk/tools/POST-BYPASS-VERDICT.md)。

nginx 的 `auth_request` 看不到 POST body，所以「只在 body 里带路径」的接口无法由闸门判定路径。

**2026-09-29 源码级复核结论（`fileview-backend` 开源，直接读源码）：**

- `POST /preview/api/localFile`、`/netFile` 存在，参数 `@Valid @RequestBody FilePreviewRequest`，路径字段是 **`srcRelativePath`**；
- 该字段的 `@SecurePath` 校验器**只挡 `..` 穿越，不禁止绝对路径** → `/vol2/<别人uid>/私密.docx` 直接通过；
- 到 `new File(actualFilePath)` 之间**没有根目录限制**（`FileUtils.processFilePath` 原样返回）；
- **这前端主链路就是它**：`fileview-frontend/src/api/index.ts` 正常预览就是 `post('/localFile', {srcRelativePath})`。

**攻击链（威胁模型内）**：已登录用户 A，构造 `POST /preview/api/localFile`，body 带 B 的私有 `/vol` 路径、
**不带 Referer** → 闸门落到「未解析到路径（放行）」→ 引擎读该文件返回预览。

#### 攻击面清单（2026-09-30 三接口源码复核，见 [`POST-BYPASS-VERDICT.md`](fpk/tools/POST-BYPASS-VERDICT.md)）

| 接口 | 路径字段 | 性质 | 校验缺口 |
|---|---|---|---|
| `POST /preview/api/localFile` | `srcRelativePath` | **读** | `@SecurePath` 不挡绝对路径；无根目录收敛 |
| `POST /convert/api/srvFile` | `filePath` / `targetPath` | **读 + 写** | `validateFileNameAndPath()` 只校验后缀与转换组合，**完全不校验根目录** |
| `POST /preview/api/password/unlock` | `originalFilePath` | **探测** | 无校验；`7zz t` 退出码可区分「密码错/文件不存在」；旧式加密格式无法判定时 `return true` 放行 |

> 其中 `srvFile` 是**以 root 写任意可写路径**（含 `@appdata` 配置目录），比只读的 `localFile` 更重；
> `password/unlock` 是**他人文件存在性探测**的辅助信道。

#### 真机验证结果（2026-09-30，**已验证可利用**）

用改进后的 `probe_post_bypass_console.js`（v2）在真机普通用户会话跑出：

| 用例 | 结果 | 含义 |
|---|---|---|
| `[0-a]` PRIVATE 自检 | **403** | 前提成立：该文件确实读不到 |
| `[0-b]` PUBLIC 自检 | **200** | 对照有效：自己的文件能读 |
| `[1]` GET 对照 | **403** | 闸门在正常工作 |
| `[2]` POST 无 Referer | **200** | 🔴 **绕过成立**（核心证据） |
| `[3]` POST 合法 Referer | **200** | 🔴🔴 **「合法 Referer 掩护非法 body」也成立** |
| `[4]` POST `/convert/api/srvFile` | 404 | 网关未转发 `/convert/` 前缀 → 该面**未暴露**（是配置遮蔽，非引擎修复） |

**`[3]=200` 是决定性结论**：攻击者只要先打开一个自己有权读的文件拿到合法 Referer，
再在 POST body 里放别人的私有路径 —— 闸门会拿 **Referer 里那个合法路径**判定并放行，
**body 里的非法路径根本没被看过**。
→ **这意味着 fail-closed（方案 A）不成立**（攻击者不需要不带 Referer），**必须走方案 B**。

> 判读矩阵（上一轮曾读反）：`403`=闸门拦；`404/400/500`=**闸门已放行**（引擎层报错）；`200`=绕过成立。

---

#### 0.5.26 的修法（方案 B：让鉴权层看见 body）

新增 `app/docker/body-path-guard.js`（njs），在主 location 上加 `js_access`：

```
js_access bodyguard.guard      ← 先读 body、取路径、问闸门；不可读直接 403
auth_request /__acl            ← 原链路保留，负责 GET 的 query 路径与 Referer 退回
proxy_pass http://fileview:80/ ← 只有上面两道都放行才转发
```

要点：

- **njs 是 nginx 官方模块，官方 `nginx:alpine` 镜像自带**，无需换镜像；
- 只对「路径在 body 里」的接口生效（`/localFile`、`/netFile`、`/status/poll`、
  `/password/unlock`、`/epub/resource`、`/convert/api/srvFile`），其余请求原样放过；
- 新入口 `GET /check-body` **复用闸门的 `can_read` + `current_mode`**（判定单一事实来源），
  但**不退回 Referer** —— 这正是堵住「合法 Referer 掩护」的关键；
- 闸门不可用 / body 非 JSON / 子请求异常 → **fail-open**，与 `auth_request` 的
  `upstream backup` 方向一致（宁可没保护，不把应用弄坏）；
- 主 location 与 SPA location **都挂了** `js_access`（少挂一处即可被绕过，自检有断言）。

**自检**：`fpk/tools/selfcheck.sh` 新增 7 条断言（守卫脚本存在 / `load_module` njs /
`js_import` / `js_access` 至少 2 处 / 闸门 `/check-body` 入口 / `location = /__acl-body` /
判定复用 `can_read`）；`test_acl_decide.py` 从 12 条扩到 **20 条**（新增 8 条 body 路径判定，
含「合法 Referer 掩护场景仍拦截」）。

**残留风险（已知、未修）**：

- `[4]` 暴露的 `POST /convert/api/srvFile` 是**「读+写」**（`targetPath` 可控且无根目录收敛），
  当前被网关的 location 配置挡在门外（返回 nginx 的 404 而非引擎响应）。若以后为别的功能
  加了 `/convert/` 转发，这个可写面会立刻暴露 —— 已在 njs 名单里预先纳入，届时自动受保护。
- `POST /preview/api/status/poll` 只带 `fileId`，njs 取不到 `/vol` 路径 → 不额外判定，
  仍走原 `auth_request` 链路（该接口本身不读文件，风险低）。

### ✅ 7. 静态资源不判定 —— 准确（设计如此）

静态资源（css/js/字体/图片）不是用户的文件，按 ACL 拦它们只会产生噪音（被拦用户的样式 403）。**但** 0.5.25 后这条只在「请求不带路径」时生效，不再能被利用来放行带路径的接口。

### ✅ 8. `data` / `logs` 目录 0777 —— 准确 —— 0.5.25 已修

**0.5.25 改为 0700**。依据：引擎容器实测 `uid=0(root)`（`docker exec basemetas-fileview-engine id`），root 无视权限位，收紧不影响读写；而 `data`/`logs` 含**转换产物**（被预览文件的中间形态，可能是内容片段）与日志。

### ✅ 9. 网络文件预览 SSRF —— 准确 —— 0.5.22 已修

`fileview.network.security.trusted-sites` 未配置时引擎**默认允许所有域名**（`HttpUtils: if (!hasTrustedSitesConfig()) return true;`），而 `?url=` 路径**绕过逐用户闸门**（没有 `/vol` 路径 → 走「放行」分支）。

**0.5.22 已修**：配成永不匹配的域名 `none.invalid`，等价全禁。欢迎页「查看样例」用容器内路径，不受影响。

---

## 3. 已实施 / 待办

### 0.5.26 已实施（1 项，安全）

| # | 项 | 位置 |
|---|---|---|
| E | **POST body 路径判定**（审计 #6，高危）：njs 在鉴权阶段读 body、把路径交给闸门 | `app/docker/body-path-guard.js`（新增）+ `nginx.conf` + `fv-acl-gate.py`（新增 `/check-body`） |

自检新增 7 条断言；判定矩阵单测从 12 条扩到 20 条。

### 0.5.25 已实施（4 项，均不改变正常行为）

| # | 项 | 位置 |
|---|---|---|
| A | 闸门扩展名短路加 `/vol` 保护（修旁路） | `app/docker/fv-acl-gate.py` |
| B | 删掉未使用的 `api-scope` 声明 | `config/resource` |
| C | 引擎镜像锁 digest | `app/docker/docker-compose.yaml` |
| D | 目录权限 0777 → 0700 | `fv-volumes.sh` / `cmd/install_init` / `cmd/main` |

自检：`fpk/tools/selfcheck.sh` 新增 5 条断言（digest / 0700 / 旁路保护 / api-scope 已删 / 判定矩阵单测）。

### 其余已修（早于本次审计）

- **0.5.22**：网络预览 SSRF 关闭；引擎工作目录 + 日志挂出（不再落可写层）。

### 待办（未做，按优先级）

1. 🟡 **`convert/api/srvFile` 的可写面**（**读+写**）：当前被网关 location 配置挡在门外
   （返回 nginx 404），但那是**配置遮蔽而非引擎修复**。njs 名单里已预先纳入，
   一旦为别的功能加了 `/convert/` 转发就会自动受闸门保护；引擎侧仍建议上游做根目录收敛。
2. **`acl` 容器挂载收敛**：当前挂宿主 `/etc/passwd`、`/etc/group`（只读）。可评估是否可以缩到只挂必要字段 / 用 nss-wrapper，减少信息暴露。收益有限，暂缓。
3. **引擎镜像升级流程**：锁 digest 后升级要**同时改标签和 digest**。查 digest：
   ```bash
   docker buildx imagetools inspect basemetas/fileview:<tag>
   ```

### 明确不做的

- **不为「防已登录用户搞破坏」加防护**：超出威胁模型（见 §1）。
- **不改成非 root 运行 engine**：上游镜像就是 root，改了大概率起不来，且存储卷已只读。
