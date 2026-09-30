# 0.5.26 上机验证清单（njs body 路径判定）

> ⚠️ **本机（开发机）没有 Docker、WSL 被安全策略禁用**，因此 njs 的加载与运行
> **未能在开发机上验证**。下面这些步骤必须在 NAS 上跑一遍。
> 已完成的是：判定矩阵单测（20 条全绿）、nginx 配置静态结构检查、js 语法检查（node ESM）、
> 降级脚本 `sed` 剥离逻辑实测、全部 shell 脚本 `bash -n`。

---

## 0. 关键设计：**不赌镜像，自带降级**

`load_module modules/ngx_http_js_module.so;` 加载失败会让 nginx 以 `[emerg]` 退出 →
**整个应用打不开**。而"官方镜像到底带不带 njs"，文档只明确承诺过 `nginx:latest`
（`docker run nginx:latest /usr/bin/njs -V`），alpine 变体与版本标签都没承诺。

所以本版**不依赖镜像选择**：gateway 的启动命令改为 `sh /etc/nginx/conf.d/fv-njs-boot.sh`，
它在启动前用 `nginx -t`（**不带 `-c`**，走镜像默认主配置）实测：
- **能加载** → 直接用镜像默认主配置启动（body 路径保护 **开启**）
- **不能** → 把 `conf.d` 复制到 `/tmp`、剥掉 njs 指令，用一份临时主配置
  （`events{} + http{ include /tmp/fv-conf.d/*.conf; }`）启动
  （回到 0.5.25 的防护水平，**应用仍能正常打开**），同时打醒目 WARN

> ⚠️ **不要**把 `nginx -c` 指向 `/etc/nginx/conf.d/nginx.conf`。那是 conf.d **片段**
> （http 上下文，第 13 行就是 `map {}`），当主配置用会报
> `[emerg] "map" directive is not allowed here ... :13` 并无限重启 ——
> **0.5.26 首版就是这样翻车的**。正常路径必须**不带 `-c`**。

**先看这一行就知道处于哪个模式：**

```bash
docker logs basemetas-fileview-gateway 2>&1 | grep -i 'fv-njs-boot' | head -20
```

| 日志 | 模式 | 含义 |
|---|---|---|
| `njs 可用，使用镜像默认主配置启动（POST body 路径保护：**已开启**）` | 完整 | 保护生效 ✅ |
| `看起来是镜像不含 njs。准备降级配置……` + `WARN：…无 body 路径保护…` | 降级 | **漏洞仍敞开**，需换镜像 ⚠️ |
| `"map" directive is not allowed here` | **首版事故** | 见下方「历史故障」；本版应已消失 |

**如果是降级模式**：把 `docker-compose.yaml` 里 gateway 的 `image:` 改成官方文档
确认带 njs 的 `nginx:latest`，然后 `docker restart basemetas-fileview-gateway`。
自查镜像是否带 njs：

```bash
docker run --rm nginx:latest /usr/bin/njs -V     # 有版本输出即可
```

---

## 1. 部署与启动

```bash
docker ps --filter name=basemetas-fileview --format 'table {{.Names}}\t{{.Status}}'
```

`basemetas-fileview-gateway` 若反复重启（`Restarting`）：

```bash
docker logs --tail 50 basemetas-fileview-gateway
```

| 日志 | 含义 | 处理 |
|---|---|---|
| `"map" directive is not allowed here in /etc/nginx/conf.d/nginx.conf:13` | **0.5.26 首版的 bug**：把 conf.d 片段当主配置传给了 `-c` | 更新到修订版即可（正常路径不带 `-c`）；若已是最新版仍报这句，说明 boot 脚本被改坏 |
| `dlopen() ".../ngx_http_js_module.so" failed` | 镜像无 njs | boot 脚本应已自动降级；若没降级，报告这个 case |
| `unknown directive "js_import"` | 同上 | 同上 |
| `open() ".../body-path-guard.js" failed` | 脚本没挂进容器 | 确认 `${TRIM_APPDEST}/docker/` 下有 `body-path-guard.js` |
| `[emerg] ... duplicate location` | 配置语法错 | `docker exec <gw> nginx -t` 看详情 |

---

## 2. 确认 njs 真的在工作

加载成功**不等于** `js_access` 被执行。用一次请求验证：

```bash
# 浏览器里打开应用、预览任意文件后：
docker logs --tail 100 basemetas-fileview-gateway 2>&1 | grep -i 'body-path-guard'
docker logs --tail 100 basemetas-fileview-acl     2>&1 | grep 'check-body'
```

要点：
- 预览**自己的文件**时，应当看到 `[check-body] ... 可读`（说明整条链路通了）；
- 若**完全没有** `body-path-guard` 字样 → `js_access` 没被执行，
  检查主 location 里那行是否写在 `auth_request` 之前（顺序错会静默失效）。

---

## 3. 端到端回归（最重要）

### 3.1 正常流程不能被误伤（这里失败说明改动不可用）

用**普通用户**预览**自己有权读**的文件：页面能开、文件能预览
（**Office / PDF / 图片 / 压缩包各试一个**）。

### 3.2 用 v2 脚本复跑攻击用例（应从 200 变 403）

浏览器（普通用户 + 无痕）→ F12 → 粘贴 `fpk/tools/probe_post_bypass_console.js`
→ 填 `PRIVATE`（别人的真实文件）、`PUBLIC`（自己的文件）→ 回车。

**期望：**

| 用例 | 修复前 | 修复后期望 |
|---|---|---|
| `[0-a]` PRIVATE 自检 | 403 | 403（不变） |
| `[0-b]` PUBLIC 自检 | 200 | 200（不变） |
| `[1]` GET 对照 | 403 | 403（不变） |
| `[2]` POST 无 Referer | **200** | **403** ← 关键 |
| `[3]` POST 合法 Referer | **200** | **403** ← 关键（方案 B 的价值） |
| `[4]` POST `/srvFile` | 404 | 404（网关未转发该前缀，不变） |

### 3.3 若 `[2]`/`[3]` 仍是 200

```bash
docker logs --tail 200 basemetas-fileview-gateway 2>&1 | grep -i 'body-path-guard'
docker logs --tail 200 basemetas-fileview-acl     2>&1 | grep 'check-body'
```

| 现象 | 原因 | 处理 |
|---|---|---|
| 无 `body-path-guard` 日志 | `js_access` 没生效（或已降级） | 先看第 0 节的模式日志 |
| 有日志但显示「放行」 | 没能从 body 取到路径 | 核对字段名（`srcRelativePath`）与 `PATH_KEYS` |
| 有「拦截」但客户端仍 200 | `r.return(403)` 没生效 | 检查指令顺序 |
| 无 `check-body` 日志 | 子请求没到闸门 | 检查 `location = /__acl-body`、`aclgate` upstream |
| 有 `check-body` 但「可读」 | 闸门把私有文件判成可读 | 闸门自身问题，单独查 |

### 3.4 fail-open 仍成立

```bash
docker stop basemetas-fileview-acl
# 预览自己的文件 —— 应仍能打开
docker start basemetas-fileview-acl
```

---

## 4. 回滚

**不用重装应用。**

```bash
# ① 只关拦截、保留记录（对 check 与 check-body 两条入口都生效）
echo 'mode=log' > "${TRIM_PKGVAR}/acl.conf"   # 路径以实际安装为准
```

```bash
# ② 连 njs 一起停掉：把 compose 的 gateway.command 改回直启 nginx
#    （这就是 0.5.25 及更早的做法 —— **不带 -c**，用镜像默认主配置，
#      它自带 include /etc/nginx/conf.d/*.conf，天然把片段放进 http 上下文）
command: ["sh", "-c", "mkdir -p /app/target && rm -f /app/target/app.sock && umask 000 && exec nginx -g 'daemon off;'"]
```

> ⚠️ ② 等于**退回到 0.5.25 的有漏洞状态**（POST 绕过重新可用）。
> 只在 njs 确实起不来、应用打不开时用，并尽快修回来。
>
> ⚠️⚠️ **千万不要写成 `nginx -c /etc/nginx/conf.d/nginx.conf`** ——
> 那个文件是 **conf.d 片段**（http 上下文，第 13 行就是 `map {}`），不是主配置。
> 当主配置用会立刻报
> `[emerg] "map" directive is not allowed here in .../nginx.conf:13`
> 然后容器无限重启。**0.5.26 首版正是这样翻车的**（见 CHANGELOG「0.5.26 修订」）。
> 正确做法永远是不带 `-c`，或自己包一层 `events{} + http{}` 再 `include` 片段。
