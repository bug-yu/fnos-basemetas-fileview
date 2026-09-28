# POST body 路径判定 —— 复核报告

> 2026-09-29。起因：对 0.5.25 `SECURITY.md` 中「审计 #6 POST body 路径判定，低优先级」这一判断的复核。
> **结论：原判断错误。该风险被低估，且已从「强推断」升级为源码级坐实。**

---

## 1. 复核方法

不采信任何未经独立复现的结论。分三层验证：

1. **离线**：直接调 `fv-acl-gate.py` 的 `Handler._decide()`，打桩 `can_read`/`current_mode`/`headers`
   —— 脚本 `fpk/tools/probe_post_bypass.py`（本仓库）。
2. **机制**：回到 `nginx.conf` 确认 `X-Acl-*` 头到底怎么生成（**不能想当然**）。
3. **引擎源码**：`fileview-backend` 是**开源**的，直接读 Controller 与校验器源码，确认
   POST 接口、参数位置、以及有无根目录限制。

---

## 2. 离线判定复核（第 1 层）

| 场景 | 闸门结果 | 说明 |
|---|---|---|
| A) GET `/preview/view?path=<私有>` | ✅ 拦截 | 对照，保护正常 |
| B) POST `/preview/api/localFile`，**无 Referer** | ❌ **放行** | `未解析到路径（放行）` ← 绕过 |
| C) POST + Referer 是普通页（不带 `/vol`） | ❌ **放行** | 同上 |
| D) POST + Referer 带正确私有路径（正常流程） | ✅ 拦截 | 靠来源页判定 |

**报告原文的 E 用例（「伪造 `X-Acl-File` 头 → 拦截」）结论是错的**，见下节。

---

## 3. 机制复核（第 2 层）—— 更正报告的一处错误

报告的表述：

> 闸门从 `X-Acl-Path` / `X-Acl-File` 头（来自 nginx `$arg_*` 查询串）取路径……攻击者只要不带 Referer……

前半句对（来自 `$arg_*`），但据此推出的 E 用例错了。看 `nginx.conf` 的 `location = /__acl`：

```nginx
proxy_set_header X-Acl-Path $arg_path;       # ← 由 query 串的 path 参数生成
proxy_set_header X-Acl-File $arg_filePath;   # ← 由 query 串的 filePath 参数生成
```

**`proxy_set_header` 会用 `$arg_*` 覆盖客户端传来的同名头。** 所以：

- 攻击者**无法**通过自己塞 `X-Acl-File` 头来影响判定 —— 该输入通道**不由客户端控制**；
- 所以 E 场景既不是「攻击者可利用」，也不是「攻击者可规避」，而是**该通道不存在**。

> 教训：判断「攻击者能不能构造某个输入」时，必须**沿着真实的头生成链路**追到底，
> 不能只看闸门函数的入参。否则会得出「依赖头」这种反了方向的结论。

---

## 4. 引擎源码复核（第 3 层）—— 坐实

`fileview-backend` 开源，直接读源码：

### 4.1 接口确实存在，路径确实在 body

`FilePreviewController.java`：

```java
@RestController
@RequestMapping("/preview/api")
public class FilePreviewController {

    @PostMapping("/localFile")
    public ResponseEntity<Map<String, Object>> processPreviewRequest(
            @Valid @RequestBody FilePreviewRequest request, HttpServletRequest httpRequest) { ... }

    @PostMapping("/netFile")
    public ResponseEntity<Map<String, Object>> previewServerFile(
            @Valid @RequestBody FilePreviewRequest request, ...) { ... }
```

→ **`POST /preview/api/localFile` 存在，参数是 `@RequestBody`。** 报告「强推断」的部分成立。

### 4.2 路径字段：`srcRelativePath`

`FilePreviewRequest.java`：

```java
/** 源文件路径（用于SERVER_FILE类型） - 可以是目录或完整文件路径 */
@Size(max = 512, ...)
@SecurePath(message = "srcRelativePath包含不安全的路径遍历字符")
private String srcRelativePath;
```

### 4.3 `@SecurePath` **不禁止绝对路径**（关键）

`SecurePath.java` 的校验器：

```java
if (value.contains("..")) {
    if (value.contains("../") || value.contains("..\\") ||
        value.startsWith("..") || value.endsWith("..")) {
        return false;          // 只挡路径穿越
    }
}
return true;                   // ← "/vol2/1000/私密.docx" 这样的绝对路径**直接通过**
```

→ **`srcRelativePath` 接受 `/volN/...` 绝对路径。** 防的是 `../` 穿越，不是「读别人的文件」。

### 4.4 到实际读盘之间**没有根目录限制**

`FilePreviewService.processServerFilePreview()`：

```java
String actualFilePath = fileUtils.processFilePath(srcRelativePath, request.getFileName());
...
File file = new File(actualFilePath);
```

`FileUtils.processFilePath()` 只做「是目录还是文件」的判断，**原样返回**路径：

```java
File path = new File(srcRelativePath);
if (path.isDirectory()) { ... return normalizedPath + fileName.trim(); }
else if (path.isFile()) { return srcRelativePath; }   // ← 原样返回
...
```

→ **没有 `normalize()` + `startsWith(allowedRoot)` 之类的约束。** 任意绝对路径直达 `new File(...)`。

### 4.5 这**不是**少数接口，而是前端主链路

`fileview-frontend/src/api/index.ts`：

```ts
const endpointUrl = networkFileUrl ? `${apiContext}/netFile` : `${apiContext}/localFile`;
const data = { fileName: ... };
if (networkFileUrl) data.networkFileUrl = ...;
else data.srcRelativePath = originalFilePath;      // ← 路径走 body
return post(endpointUrl, data);                    // ← POST
```

→ **正常预览流程就是 `POST /preview/api/localFile` + body 的 `srcRelativePath`**，
随后还有 `POST /preview/api/status/poll`。

---

## 5. 端到端攻击链（威胁模型内）

```
前提：A 是已登录飞牛用户（统一网关放行），知道 B 的私有文件 /vol 路径
      （团队共享盘、目录结构可猜时更容易）

1. A 构造 POST /app/basemetas-fileview/preview/api/localFile
   body: {"srcRelativePath":"/vol2/<B的uid>/私密.docx","previewType":"SERVER_FILE"}
   并且**不带 Referer**（fetch(...,{referrerPolicy:'no-referrer'}) 或 curl）

2. nginx 主 location 有 auth_request /__acl → 交给闸门
   闸门：X-Acl-Path/File 取自 query（POST 无 query）→ 空
         Referer 空 → 取不到路径
         → 落到「未解析到路径（放行）」

3. nginx 照常 proxy_pass 到引擎
4. 引擎：@SecurePath 放行绝对路径 → processFilePath 原样返回 → new File(该路径)
5. B 的私有文件被转换并返回预览内容
```

**与 0.5.25 修的「后缀绕过」是两个独立缺口**，但根因同源：**闸门的路径来源不够**。

---

## 6. 修复方案（按稳健性排序）

### 方案 A（推荐）：对「路径在 body」的接口，无来源页时 **fail-closed**

闸门对这几个 URI（`/preview/api/localFile`、`/netFile`、`/convert/api/srvFile`、
`/preview/api/password/unlock`）在**解析不到路径**时**拒绝**，而非放行。

- **依据**：正常流程一定有 Referer（上游前端未设 `referrerPolicy`，也未设 `Referrer-Policy`
  → 浏览器同源 POST 默认带完整 Referer），且 Referer 的 query 里有**用户自己有权读的 path**。
- **风险**：若某个环境 Referer 被中间层剥掉，正常预览会被误拦。**必须先真机验证**
  （用 `fpk/tools/probe_post_bypass_e2e.py`）。
- **注意**：正常流程下 Referer 里的 path 是**用户自己打开的那个文件**（有权读），
  拿它判定 body 里的目标（同一文件）是正确的；但若攻击者拿「有权读的文件」做 Referer、
  body 里放私有文件，则**仍会误放行**（因为判定的是 Referer 的路径，不是 body 的）。
  → 所以方案 A 只能挡住「无 Referer」这一类，**挡不住「用合法 Referer 掩护非法 body」**。

### 方案 B（更彻底）：让闸门能看到 body

`auth_request` 阶段拿不到 body。可行做法：

1. **njs**（nginx JavaScript 模块）在 `auth_request` 之后、`proxy_pass` 之前解析 body →
   写进子请求头；或
2. 网关容器里用 **OpenResty/lua** 读取 body 后再鉴权；
3. 或要求上游把路径**在 query 上冗余带一份**（改不了上游，不可行）。

代价：引入 njs/lua 依赖，复杂度显著上升。

### 方案 C（官方路线）：飞牛开放 API `trim.file.checkUserACL`

README 已记：实测走不通（拿不到 token）。**不作为方案**。

### 方案 D（临时，不推荐）：网关层直接 deny 这几个 POST

会**直接打断正常预览**（因为正常流程也是 POST），**不可行**。

---

## 7. 建议

1. **立刻**：先用 `probe_post_bypass_e2e.py` 在真机验证端到端可利用性（本轮无法在本机跑，
   需要 NAS 登录态）。
2. **然后**：按验证结果决定是上方案 A 还是 A+B。
3. **无论选哪个**：`SECURITY.md` 里「低优先级」的表述必须更正为**高危**，
   并注明「闸门对 POST body 路径无判定」是**已知缺口**，不是「低风险」。

---

## 附：本轮更正的原报告结论

| 报告结论 | 复核 |
|---|---|
| POST 无来源页 → 闸门放行 | ✅ 成立（且源码级坐实） |
| 攻击链（已登录 + 知路径 + 不带 Referer） | ✅ 成立 |
| 「作者判低风险偏乐观」 | ✅ 正确，原判断应更正为高危 |
| 「E) 伪造 X-Acl-File 头 → 拦截，依赖头，攻击者可不带」 | ❌ **机制搞反**：该头由 `$arg_*` 生成，客户端无法控制 |
| 「唯一缓解是须知道路径 + 已登录」 | ⚠️ 补充：`netFile` 的 SSRF 面已被 0.5.22 的 `trusted-sites=none.invalid` 关闭；但 `localFile` 的本地路径不受影响 |
