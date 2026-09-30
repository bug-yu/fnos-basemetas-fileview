# POST body 路径绕过 —— 验证定论

> 2026-09-30。承接 [`POST-BYPASS-REVIEW.md`](POST-BYPASS-REVIEW.md)，
> 本文件把「源码层是否成立」与「真机验证怎么做才有效」两件事一次说清。

---

## 1. 一句话结论

**源码层：绕过成立，且攻击面比原报告更宽（3 个接口，其中 1 个是可写）。**
**真机层：用户上一轮跑出的三行结果（403 / 404 / null）是无效证据，不能用来判定 ——
脚本本身的构造有缺陷。**

---

## 2. 为什么上一轮那三行结果作废

用户贴回的结果：

```
[1] GET 对照      : 403 （闸门正常）
[2] POST 无 Referer: 404
[3] POST 合法Referer: null
```

逐条拆：

| 行 | 表面 | 真相 |
|---|---|---|
| `[1] = 403` | 「闸门正常」 | ✅ 这行**有效**。闸门确实拦住了带 `/vol` 路径的 GET。但这只证明「闸门有在跑」，**不涉及 POST**。 |
| `[2] = 404` | 「未绕过」？ | ❌ **无效证据**。脚本 `PRIVATE` 留空 → 自动拼 `/vol1/@home/<uid+1>/probe-not-mine.docx`，**这个文件根本不存在**。闸门判定只看「路径前缀 + ACL」，**不检查文件存在性** → 闸门**放行了**；随后引擎 `FilePreviewService.processServerFilePreview()` 里有 `if (!file.exists() \|\| !file.isFile()) throw FILE_NOT_FOUND` → **返回 404**。<br>**404 恰恰说明请求穿过了闸门抵达了引擎** —— 这是「闸门放行」的**阳性信号**，不是「被拦住」。 |
| `[3] = null` | 「没跑」 | ❌ 脚本里 `PUBLIC` 留空 → `if (PUBLIC)` 为假 → `[3]` 被整个跳过，`result.postWithRef` 保持初始值 `null`。**这条用例从未执行。** |

**核心教训**：要区分「闸门放行」和「引擎成功返回内容」是两个独立的观测点。
`403` = 闸门拦；`404/400/500` = 闸门放行但引擎报错；`200` = 闸门放行且引擎成功。
上一轮脚本把 `404` 当成了「没绕过」，方向读反了。

---

## 3. 源码级定论（三层验证全绿）

### 3.1 闸门侧（`fpk/basemetas-fileview/app/docker/fv-acl-gate.py`）

`_decide()` 的放行分支，任一条成立即放行：

```python
if not uid or not uid.isdigit():     return True, "缺 uid（放行）", path
if not path:                          return True, "未解析到路径（放行）", None   # ← POST 无 Referer 走这里
if not path.startswith("/vol"):       return True, "非存储卷路径（放行）", path
```

路径来源只有三个：`X-Acl-Path` / `X-Acl-File`（来自 nginx `$arg_*`，即 **query 串**）、
以及 **Referer 的 query**。**POST body 完全不在其中。**

且 `can_read()` 用的是 `os.access(path, R_OK)` —— **只看权限位，不看文件是否存在**。
所以「文件不存在」不会让闸门拦，只会让引擎后续报 404。

### 3.2 网关侧（`nginx.conf`）

- 主 location 有 `auth_request /__acl`；
- `location = /__acl` 里 `proxy_pass_request_body off;` —— **鉴权子请求物理上拿不到 body**；
- `proxy_set_header X-Acl-Path $arg_path;` —— **客户端自己塞的同名头会被覆盖**，
  所以「伪造 `X-Acl-File`」这条路不存在（原报告的 E 用例错在这里）。

### 3.3 引擎侧（`fileview-backend`，开源，read from `git show`）

| 接口 | 方法 | 路径字段 | 位置 | 校验 | 后果 |
|---|---|---|---|---|---|
| `/preview/api/localFile` | POST | `srcRelativePath` | **body** | `@SecurePath` | **读取**任意绝对路径文件并预览 |
| `/preview/api/netFile` | POST | `networkFileUrl` | **body** | — | SSRF 面（0.5.22 已用 `trusted-sites=none.invalid` 关掉） |
| `/convert/api/srvFile` | POST | `filePath` / `targetPath` | **body** | `ValidateAndNormalized.validateFileNameAndPath()` | **读取源文件 → 转换 → 写到 `targetPath`**（**可写**，更重） |
| `/preview/api/password/unlock` | POST | `originalFilePath` | **body** | 无 | **探测**：`7zz t -p<pwd>`，密码对/错可区分 → 可爆破 + 存在性探测 |
| `/preview/api/status/poll` | POST | `fileId` | **body** | — | 无路径，不构成绕过 |

**关键源码证据（`@SecurePath` 不挡绝对路径）：**

```java
// SecurePath.java 校验器
if (value.contains("..")) {
    if (value.contains("../") || value.contains("..\\") ||
        value.startsWith("..") || value.endsWith("..")) return false;
}
return true;          // ← "/vol2/1000/私密.docx" 直接通过
```

**到 `new File()` 之间无根目录约束（`FileUtils.processFilePath`）：**

```java
File path = new File(srcRelativePath);
if (path.isDirectory()) { ... return normalizedPath + fileName.trim(); }
else if (path.isFile()) { return srcRelativePath; }   // ← 原样返回
```

**`isSystemDirectory()` 只挡 `/bin /etc /usr` 等系统目录，不挡 `/vol*`。**

### 3.4 补充：转换接口的可写性

`BaseConvertController.srvFileConvert()`：

```java
ValidateAndNormalized.ValidationResult r = validator.validateFileNameAndPath(
        request.getFilePath(), request.getTargetFormat());
// validateFileNameAndPath 只做三件事：
//   1. filePath 必须含路径分隔符（即必须是个"路径"而非纯文件名）
//   2. 文件名必须带合法后缀
//   3. 该后缀 → targetFormat 的转换组合必须被支持
// ★ 完全不校验 filePath 是否在允许根目录内、是否绝对路径
```

然后 `FileEventFactory.createConvertEvent()` → `buildFullTargetPath(targetPath, targetFileName, targetFormat)`
→ 事件进 MQ → `FileEventConsumer.convertFile()` → `fileConvertContext.convertFileWithParams(filePath, targetPath, ...)`
→ 策略实现（Word/PDF/Excel…）**直接读 `filePath`、写 `targetPath`**。

**没有一步做根目录收敛。** 这比 `localFile`（只读）更麻烦：它是**以 root 身份写任意可写目录**，
可以用来覆盖 `@appdata` 下的配置、投毒、或写 `/etc/` 之外的可写路径。

> ⚠️ 注意 `targetPath` 为空时会 fallback 到 `storageConfig.getConvertTargetDir()`，
> 所以攻击者**可以只控制源文件读取**，把内容转换后落回引擎自己的目录 —— 这也是一条信息外带路径
> （转换产物可通过 `/preview/api/file?filePath=<产物>` 取回）。

---

## 4. 有效的真机验证怎么做

### 4.1 必须满足的三个前提

1. **用真实存在的私有文件**（文件不存在 → 引擎 404，虽然闸门放行了但你拿不到 200）。
2. **该文件确实对当前普通用户不可读**（否则闸门放行不算绕过，因为本来就该放行）。
3. **Cookie 有效**（否则在网关层就被 401/302 挡掉，测不到闸门）。

### 4.2 判定矩阵（正确读法）

| `[1]` GET 对照 | `[2]` POST 无 Referer | 结论 |
|---|---|---|
| 403 | **200** | ✅ **绕过成立**（端到端坐实，核心证据） |
| 403 | 404 / 400 / 500 | ⚠️ **闸门放行**，但引擎没读到（文件不存在/格式不支持）→ 换真实文件重测 |
| 403 | 403 | ❌ 未绕过（fail-closed 已生效？或你这版不是 0.5.25） |
| 200 | 200 | ⚠️ 你的「私有文件」其实可读 —— 换一个真正读不到的 |

### 4.3 三步走到位

1. **准备**：管理员账号找出一个**普通用户读不到的真实文件**的容器内路径
   （形如 `/vol1/@home/<别人用户名>/xxx.docx`，或 `/vol2/<别人uid>/xxx.docx`）。
   用 `fpk/tools/probe_post_bypass_curl.sh` 最快（管理员终端直接跑）。
2. **跑**：浏览器版用改进后的 `probe_post_bypass_console.js`（本轮已改，见下）；
   或终端版用 `probe_post_bypass_curl.sh`。
3. **固化**：把结果贴进 `SECURITY.md` §6，然后定方案。

---

## 5. 本轮对脚本做的修正

`probe_post_bypass_console.js` 的问题与修法：

| 问题 | 修法 |
|---|---|
| `PRIVATE` 留空时自动拼不存在的路径 → 只能拿到 404，误导 | 留空时**不再伪造路径**，改为打印清晰的「必须填写真实路径」指引并**中止**（避免产出无效结论） |
| `PUBLIC` 留空静默跳过 `[3]` | 改为**显式打印跳过原因**，并在汇总里标注 `SKIP` 而非 `null` |
| 状态码判读把 404 当「未绕过」 | 改为按 §4.2 矩阵判读：`403`=闸门拦 / `404·400·500`=**闸门已放行**（同时提示换真实文件） / `200`=绕过成立 |
| 未验证 `PRIVATE` 是否真的不可读 | 新增 `[0]` 前置自检：先 GET 一次 `PRIVATE`，若返回 200 则直接判定「选错文件」并中止 |

---

## 6. 修复方案（不变，但选项更清晰）

| 方案 | 做法 | 能挡 | 挡不住 | 代价 |
|---|---|---|---|---|
| **A** | 对 4 个 body 接口，闸门解析不到路径时 **fail-closed** | 无 Referer 的 POST | 合法 Referer 掩护非法 body | 低；**需真机确认正常流程必带 Referer** |
| **B** | njs / OpenResty 在鉴权阶段读 body | A 的全部 + Referer 掩护 | — | 高（引入 njs/lua 依赖） |
| **A+B** | 先上 A，再评估 B | — | — | 中 |

**推荐路径**：真机验证 → 若 `[3]` 也返回 200（Referer 掩护成立）→ 必须 B；
若 `[3]` 返回 403 → A 即可兜住大部分场景，B 列为后续增强。

---

## 7. 复核过程中新发现的两处（超出原报告范围）

1. **`/convert/api/srvFile` 是「可写」而非「可读」** —— 原报告只讨论了读。
   由于 `targetPath` 可控且无根目录校验，这是**以 root 写任意可写路径**的能力。
2. **`/preview/api/password/unlock` 是泄密信道** —— `7zz t` 的退出码区分「密码错误」与
   「文件不存在/格式不支持」，且 `FilePasswordValidator` 对旧式加密格式（legacy doc/ppt/wps）
   在无法判定密码时**直接 `return true`（放行）**。这属于**已登录用户探测他人文件存在性**的辅助信道。

两处都在威胁模型内（已登录用户 A 针对 B），应一并纳入方案 A 的收紧范围。
