# 0.5.26 上机验证清单（njs body 路径判定）

> ⚠️ **本机（开发机）没有 Docker、WSL 被安全策略禁用**，因此 njs 的加载与运行
> **未能在开发机上验证**。下面这些步骤必须在 NAS 上跑一遍。
> 已完成的是：判定矩阵单测（20 条全绿）、nginx 配置静态结构检查、js 语法检查（node ESM）、
> 降级脚本 `sed` 剥离逻辑实测、全部 shell 脚本 `bash -n`。

---

## 0. 关键设计：**自带主配置 + 不赌镜像**

njs 是**动态模块**，必须用 `load_module` 加载，而该指令的合法上下文是
**`main`（主配置顶层）** —— 不能写在被 `http{}` include 的片段里。
所以本项目自带一份主配置 `app/docker/fv-main.main`：

```nginx
load_module modules/ngx_http_js_module.so;   # ← main 层，唯一合法位置
events { worker_connections 1024; }
http   { include /etc/nginx/conf.d/*.conf; }  # ← 业务片段在这里（http 上下文）
```

`load_module` 失败会让 nginx 以 `[emerg]` 退出 → **整个应用打不开**。
所以 gateway 启动走 `sh /etc/nginx/conf.d/fv-njs-boot.sh`：

- 先 `find` 定位 `ngx_http_js_module.so` 的**实际路径**，再逐一试常见路径；
- **能加载** → 用 `fv-main.main` 启动（body 路径保护 **开启**）；
- **不能** → 把 `conf.d` 复制到 `/tmp/fv-conf.d`、剥掉 njs 指令，
  并把主配置里的 `include` 重写到该副本目录，然后启动
  （回到 0.5.25 的防护水平，**应用仍能正常打开**），同时打醒目 WARN。

> ⚠️ **不要**把 `nginx -c` 指向 `/etc/nginx/conf.d/nginx.conf`。那是 conf.d **片段**
> （http 上下文），当主配置用会报 `"map" directive is not allowed here` 并无限重启
> —— **0.5.26 第一轮就是这样翻车的**。
> ⚠️ 也**不要**把 `load_module` 写进片段里 —— 会报
> `"load_module" directive is not allowed here`（**第二轮**翻车点）。
> 两个错都与"镜像带不带 njs"无关，却都会被误判成"没有 njs"。详见 CHANGELOG。

**先看这几行就知道处于哪个模式：**

```bash
docker logs basemetas-fileview-gateway 2>&1 | grep -i 'fv-njs-boot' | head -20
```

| 日志 | 模式 | 含义 |
|---|---|---|
| `在镜像里找到 njs 模块：<路径>` + `njs 可用…（POST body 路径保护：**已开启**）` | 完整 | 保护生效 ✅ |
| `find 没有找到 ngx_http_js_module.so` + `WARN：…无 body 路径保护…` | 降级 | **漏洞仍敞开**，需换镜像 ⚠️ |
| `"map" directive is not allowed here` | **第一轮事故** | 把片段当主配置了；本版应已消失 |
| `"load_module" directive is not allowed here` | **第二轮事故** | 把 `load_module` 写进片段了；本版应已消失 |

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
| `"map" directive is not allowed here in .../nginx.conf:NN` | **第一轮 bug**：把 conf.d 片段当主配置传给了 `-c` | 更新到修订版；若已最新仍报，说明 boot 脚本被改坏 |
| `"load_module" directive is not allowed here in .../nginx.conf:NN` | **第二轮 bug**：`load_module` 写进了片段（应在 main 层） | 更新到修订版；确认 `fv-main.main` 存在且启动 `-c` 指向它 |
| `dlopen() ".../ngx_http_js_module.so" failed` | 镜像确实无 njs（真·该降级） | boot 脚本应已自动降级；若没降级，报告这个 case |
| `unknown directive "js_import"` | 没加载 njs 却用了 js_* | 同上 |
| `open() ".../body-path-guard.js" failed` | 脚本没挂进容器 | 确认 `${TRIM_APPDEST}/docker/` 下有 `body-path-guard.js` |
| `[emerg] ... duplicate location` | 配置语法错 | `docker exec <gw> nginx -t -c /etc/nginx/conf.d/fv-main.main` 看详情 |
| 反复 `尝试加载 njs 模块：…` + `不行` | 所有候选路径都不通 | 手动查：`docker exec <gw> find / -name 'ngx_http_js_module.so' 2>/dev/null` |

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
# ② 连 njs 一起停掉：用降级主配置启动（脚本已生成，含被注释的 njs 指令）
#    正常路径是 -c /etc/nginx/conf.d/fv-main.main（main 层加载 njs）
#    降级路径是 -c /tmp/fv-conf.d/fv-main-fallback.conf（njs 已注释）
command: ["sh", "-c", "mkdir -p /app/target && rm -f /app/target/app.sock && umask 000 && exec nginx -c /tmp/fv-conf.d/fv-main-fallback.conf -g 'daemon off;'"]
```

> ⚠️ ② 等于**退回到 0.5.25 的有漏洞状态**（POST 绕过重新可用）。
> 只在 njs 确实起不来、应用打不开时用，并尽快修回来。
> 注意 `fv-main-fallback.conf` 要**先跑过一次 boot 脚本**才会生成（它在探到无 njs 时才写）。
> 如果连它都没有，就临时手动剥：把 `fv-main.main` 复制出来、注释掉 `load_module` 与
> 三个 `js_*` 指令，再 `-c` 指它。
>
> ⚠️⚠️ **两个绝对不能写的形式**：
> - `nginx -c /etc/nginx/conf.d/nginx.conf` —— 那是 conf.d **片段**（http 上下文），
>   当主配置用会报 `"map" directive is not allowed here`（**第一轮**翻车点）；
> - 把 `load_module` 写回 `nginx.conf` 片段里 —— 会报
>   `"load_module" directive is not allowed here`（**第二轮**翻车点）。
>   它只能在主配置的 **main 层**（即 `fv-main.main` 那种文件里）。
>
> ✅ 正确形态：`-c` 指向一个**主配置**（含 `load_module`（main 层）+ `events{}` +
> `http{ include ... }`），业务片段由它 include 进来。
