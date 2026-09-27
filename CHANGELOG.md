# 更新说明

包版本号与预览引擎版本**解耦**：包版本 `0.5.x` 对应引擎 `basemetas/fileview:1.5.2`。
只改外壳（配置 / nginx / 图标）时末位 +1；升级引擎镜像时整段跟着抬（如引擎 1.6.0 → 包 0.6.0）。
飞牛靠版本号**递增**判断升级安装，同版本不允许覆盖安装。

---

## 0.5.18

清掉应用设置里两处**没意义、只会让人误会**的项目。

### ① 隐藏「访问权限」标签页

那个页面（「允许访问以下文件夹 / 暂无授权记录」）是给**让用户自己选授权目录**的应用用的
（对应开放 API 的 `trim.file.sharedAccess`）。本应用不走那套：

- 能访问哪些存储卷，由安装向导的 `wizard_volumes` 决定；
- 每个用户能看哪些文件，由闸门按飞牛 ACL 判定。

所以那一栏永远是「暂无授权记录」，留着只会让人以为哪里没配好。

**改法**：manifest 增加

```ini
disable_authorization_path=true
```

官方文档原话：「仅当应用不需要用户选择文件或目录访问权限时，才使用 `true`。」

### ② 隐藏入口设置里的「自定义 URL」

入口设置里那一行「自定义 URL」（带铅笔图标）现在去掉了。

**改法**：`app/ui/config` 里入口的 `control.accessPerm` 由 `readonly` 改成 `hidden`
（官方文档：`control.accessPerm=hidden` → 隐藏该设置）。

原因：入口地址是由 `gatewayPrefix` / `gatewaySocket` 决定的，用户手工改 URL 只会让预览打不开。
`noDisplay` 仍然保留 —— 桌面不显示图标，只保留文件管理器右键的「用 FileView 打开」。
61 种文件类型注册不受影响。

---

## 0.5.17

### 逐用户权限校验改为**默认开启**

0.5.15 上线时默认是 `mode=log`（只记录不拦截），先观察再切。实测已经闭环：

| 场景 | 结果 |
|---|---|
| 用户 A 打开用户 B 的私有文件 | **403 拦截** |
| 用户 A 打开自己的文件 | 放行 |
| 用户 A 打开团队文件（按组授权） | 放行 |
| 静态资源（css/js） | 放行（不按文件权限拦） |
| 转换产物 `/opt/…`（带来源页） | 按原始路径判定，不可读则拦 |
| 模式位 `0000` 但 ACL 允许读的文件 | 判为**可读**（读的是 ACL，不是 POSIX 模式位） |

所以本版把默认改成 **`enforce`**，并在设置页去掉切换开关（那一栏改成纯说明）。

### 应急开关仍然保留（但不在设置界面里）

万一出现误拦，把应用数据目录下的 `acl.conf` 改一行即可：

```bash
# /vol{n}/@appdata/basemetas-fileview/acl.conf
mode=enforce   →   mode=log
```

改完**立即生效**，不用重启容器、也不用重装应用。
应用只在文件不存在时写默认值，**不会覆盖手工改动**，所以这个应急设置能留住。

看判定过程：`docker logs basemetas-fileview-acl`

---

## 0.5.16

0.5.15 上线后跑了一遍实测（`docker logs basemetas-fileview-acl`），核心判定完全正确：

```
放行 uid=1000 path=/vol1/1000/某目录/….ofd —— 可读
放行 uid=1003 path=/vol1/1000/某目录/….ofd —— 不可读（当前 mode=log，仅记录）
```

`--test` 也确认组查表正常（`用户 = 某用户  主组 gid=1001  附加组=（无）`）。
但日志暴露了两个判定问题，本版修掉：

### ① 静态资源不该按文件权限拦

日志里出现了这一行：

```
放行 uid=1003 path=/vol1/1000/某目录/….ofd —— 不可读 | uri=…/preview/css/index-DvZ8zWmN.css
```

CSS / JS / 图片 / 字体不是用户的文件，却因为**来源页 URL 里有 path** 而被判成了「不可读」。
在 `enforce` 模式下，被拦用户的样式和脚本会一起 403 —— 纯噪音。
现在按扩展名直接放行。

### ② 一个真实旁路：`/opt/fileview/data/preview/…`

```
放行 uid=1003 path=/opt/fileview/data/preview/….pdf —— 非存储卷路径（放行）
```

这条请求带的是**引擎内部转换产物**路径，回溯不出原文件，0.5.15 里一律放行 ——
等于「只要知道转换后的文件名，就能把别人无权查看的文档直接取走」。而转换后的文件名
就是从原名派生的（`X.ofd` → `X.pdf`），**是猜得出来的**。

修法：请求自身带的路径不是存储卷路径时，**退回用来源页 URL 里的原始 path 判定**。
正常流程一定是从预览页发起的，来源页里就有原始 `/vol…` 路径，于是这条被正确拦下。

### 实测验证（拿真实 URI 跑判定逻辑）

| uid | 请求 | 结果 |
|---|---|---|
| 1000 | `view?path=` / `api/localFile` / `api/file?filePath=/opt/…` | 放行（可读） |
| **1003** | `view?path=` | **拦截** |
| **1003** | `api/localFile` | **拦截** |
| **1003** | `api/file?filePath=/opt/…` | **拦截**（0.5.15 是放行） |
| 1000 / 1003 | `css` / `js` 等静态资源 | 放行 |

### 残留边界

`/opt/…` 这类请求若**完全没有来源页**（手工构造的请求），仍然只能放行（无法判定 → fail-open）。
要彻底堵死需要闸门记录「哪个 uid 触发过哪个转换」，属于后续可选项。

---

## 0.5.15

### 解决「凡能登录飞牛的用户都能预览全部已挂载卷」

这是本项目一直挂在 README 里的那条限制，本版真正修掉了。

### 为什么之前的开放 API 路线走不通

0.5.9 的预检已经实测证明：应用脚本里拿不到 `TRIM_API_TOKEN`，
`/var/run/trim_open_gateway_apiscope.socket` 又是 `root:root 0660` —— 官方那套
`trim.file.checkUserACL` 用不了。生态调研也印证了这点：`grep checkUserACL` 在整个
`@appcenter` 里零使用，`music-tidy` 的作者甚至把话说在注释里
「X-Trim-Userid（可信身份，仅用于日志与展示，**不做权限依据**）」。

### 转折：身份拿得到，权限也能在 VFS 层问出来

两件事凑齐了：

1. **身份**：飞牛统一网关会把当前登录用户放进请求头。实测（浏览器打开
   `/app/basemetas-fileview/__whoami`）返回 `uid=1000 | user=<用户名> | isadmin=true`。
2. **权限**：飞牛自 v1.2.0 起存储空间使用 Windows ACL，而它在 VFS 层生效。实测：

   ```
   -rwx------+ 1 yang Users … .pptx
   uid=1000 可读（属主） / uid=1001 不可读 / uid=1003 不可读
   ```

   于是「以某个用户的身份问一句这个文件能不能读」就能得到正确答案。

### 实现

```
浏览器 → 统一网关（注入 X-Trim-Userid）→ app.sock → nginx 网关容器
    location /app/basemetas-fileview/  →  auth_request /__acl
         /__acl → 闸门容器（python:3-alpine，root）
                    fork → setgroups(按 /etc/group 算) → setgid → setuid(uid)
                    → os.access(path, R_OK) → 200 / 403
    → FileView 引擎容器
```

- 新增 **`app/docker/fv-acl-gate.py`**：Python 3 标准库，无第三方依赖。
  - ⚠️ 为什么不是简单的 `docker exec -u <uid> … test -r`：`docker exec -u`
    **不会设置用户的附加组**。飞牛的「共享给设备内的用户」按用户授权（uid 能覆盖），
    但**团队文件按用户组授权** —— 那样会误判成不可读，而**误拦是危险方向**。
    所以它 fork 子进程后按 `/etc/group` 设好 setgroups → setgid → setuid 再判定，
    完整还原该用户的权限上下文。因此需要 root 运行。
  - 路径来源做了三重冗余：nginx 的 `$arg_path` / `$arg_filePath`、请求自身的 query、
    以及**来源页 URL 里的 path**（`POST /preview/api/localFile` 只在请求体里带路径，
    nginx 看不到 body，只能从来源页推断 —— 正常流程一定从预览页发起）。
- **compose 新增 `acl` 服务**：只读挂载与引擎**完全相同**的存储卷（判定必须在同一份
  文件系统视图上做）+ 宿主机 `/etc/passwd`、`/etc/group`。挂载段由安装向导自动重建
  （第二组标记 `## VOLUMES_ACL_BEGIN/END`）。
- **nginx 增加 `auth_request`** 与内部 `/__acl` 入口。

### 两个刻意的安全设计

1. **默认 `mode=log`：只记录判定结果，不拦截。**
   在「设置 → 逐用户权限校验」里改成 `enforce` 才真正拦截。闸门每次请求现读配置，
   改完立即生效，不用重启容器。建议先跑一段时间确认没有误拦。
2. **闸门不可用时自动 fail-open，绝不会把应用拖死。**
   `upstream aclgate` 里挂了一个永远连不上的备用 + 本机回环上的「永远 200」服务，
   闸门连不上时 nginx 自动 failover 过去 → 放行。最坏情况只是「没保护」，
   不会出现「应用打不开」。
   另外闸门只在**确定不可读**时拒绝：缺 uid、解析不到路径、查不到用户、判定异常
   → 一律放行并记日志。

### 诊断

```bash
# 1) 确认网关有没有把身份传进来（浏览器打开，需要登录态）
https://<你的域名>/app/basemetas-fileview/__whoami

# 2) 看闸门的判定过程
docker logs basemetas-fileview-acl

# 3) 单独验证某个用户对某个文件的权限（在闸门容器里跑）
docker exec basemetas-fileview-acl python3 /acl/fv-acl-gate.py --test 1001 /vol1/1000/某文件.ofx
```

---

## 0.5.14

本版**不改变访问行为**，只是把「按用户区分权限」的前置条件做成可直接验证的工具。

### 路线调整：放弃开放 API，改用 VFS 层的 ACL 判定

0.5.9 的预检已经证明开放 API 这条路走不通：

```
① TRIM_API_TOKEN：**没有** —— 脚本环境里拿不到 token
② API socket：srwxrw----+ 1 root root … /var/run/trim_open_gateway_apiscope.socket
```

而拆开社区项目 `qq1907/Fnos-onlyofficeEdit`（OnlyOffice 编辑器 fpk）后得到了新的突破口：

```bash
# 它的 ui/index.cgi（bash 反向代理）里
CURRENT_UID="$HTTP_X_TRIM_USERID"
CURRENT_USER="$HTTP_X_TRIM_USERNAME"
```

**当前登录用户身份是拿得到的** —— 网关设的 `X-Trim-Userid` 会传给应用。加上飞牛官方
[文件权限文档](https://help.fnnas.com/articles/v1/file/acl) 说的「自 v1.2.0 起存储空间使用
Windows ACL」「应用是一等 ACL 对象」，就有了下面这条**不依赖开放 API** 的路：

```
每个请求：uid = X-Trim-Userid，path = 请求参数
          docker exec -u "$uid" basemetas-fileview-engine test -r "$path"
          → 由 VFS 按 Windows ACL 判定该用户能否读该文件
```

不需要 token、不需要那个 socket、不需要 root、不需要新镜像 —— docker 权限我们已经有。

### 新增（验证工具）

- **诊断端点 `/app/basemetas-fileview/__whoami`**：回显网关转发过来的身份头。

  ```bash
  curl -i "https://<你的域名>/app/basemetas-fileview/__whoami"
  ```

  只回显请求头本身，不含任何文件内容；本容器只监听 `app.sock`、不对外暴露端口，
  所以必须先通过统一网关的登录态校验才能到达。

- **网关 `access_log` 增加 `uid` / `isadmin` 两列**，日常请求也能看出身份有没有传进来。

### 下一步

两件事确认后即可实现闸门（nginx `auth_request` + 宿主机小鉴权服务，Python 3 写，
已确认 `/usr/bin/python3` 存在）：

1. `docker exec -u <非属主 uid> … test -r <某私有文件>` 是否返回**不可读**；
2. `__whoami` 是否能看到真实的 uid。

---

## 0.5.13

### 撤回「兜底停容器」—— 它让情况更糟

先看实测事实：

```
$ docker ps -a --filter name=basemetas-fileview --format 'table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}'
NAMES                        STATUS          CREATED AT
basemetas-fileview-gateway   Up 15 minutes   2026-09-27 11:59:01 +0800 CST
basemetas-fileview-engine    Up 15 minutes   2026-09-27 11:59:01 +0800 CST
```

**没有残留的临时容器**（0.5.12 的推测不成立），而且**容器确实停下来了**。
但飞牛界面仍报失败，且引擎的退出码是 **137（SIGKILL）**。

顺着 137 往回看，问题出在我自己 0.5.8 起加进 `cmd/main stop` 的那段「兜底」：

| 我做了什么 | 后果 |
|---|---|
| 先在 `main stop` 里把容器停掉 | 框架随后自己那次 `compose stop/down` 看到的状态就对不上了 |
| `docker stop -t 5` 只给 5 秒 | 引擎是 Java + redis + rocketmq 的栈，5 秒内退不干净 → 被 SIGKILL → **退出码 137** → 界面显示「容器错误退出(137)」 |
| 0.5.8 还叠过 `docker compose stop` | 和框架的停用动作互相干扰，出现 `Container <hash>_xxx Stopping` / `No such container` |

而**观测事实是：不加任何干预时，容器本来就能正常停下**（框架自己的 compose 会处理）。

### 修复

- **`cmd/main stop` 改回空操作**，只写一行诊断日志（记录调用时刻的容器状态）。
  和 0.5.6 的行为一致 —— 那时候这里本来就是 `exit 0`。
- 保留 `fv_clean_orphans`（重建前、卸载前后仍会清理 compose 残留临时容器），
  它只删名字严格匹配 `<12 位十六进制>_basemetas-fileview-` 的容器，不误伤别的。

### 说明

这一版的教训值得记下来：**在别人（框架）已经负责的环节里「再兜一层」，很容易变成互相干扰。**
`stop` 就是典型 —— 框架本来会停，我加的那层反而制造了 137 和状态不一致。

---

## 0.5.12

### 停用/卸载是「**每次**都失败」，不是偶发 —— 真因是残留的 compose 临时容器

0.5.11 修了「重建竞态」，但停用仍然每次都失败。再看那次报错的完整名字列表，关键在这里：

```
 Container basemetas-fileview-gateway                 Stopped
 Container basemetas-fileview-engine                  Stopping
 Container f355c8f78542_basemetas-fileview-engine     Stopping   ← 另一个容器
 Container basemetas-fileview-engine                  Error while Stopping
 Container f355c8f78542_basemetas-fileview-engine     Stopped
Error response from daemon: No such container: f355c8f785421a50…
```

`f355c8f78542_basemetas-fileview-engine` 不是「同一个容器的临时名」，而是**真实存在的第二个容器**。

compose 用 `--force-recreate` 重建带 `container_name` 的容器时，流程是
「先建一个临时名的新容器 → 删掉旧的 → 再把新的改名」。这个重建一旦被中途打断
（回调脚本超时被杀、进程被 kill），临时容器就**留在了系统里**。

它带着和正式容器**同一套 compose 标签**（同项目、同服务），于是飞牛此后每次停用/卸载都会去停它：

```
Error while Stopping / No such container: f355c8f78542…
```

→ 界面**每次都报** `Request failed`。

这也解释了为什么 0.5.7 的卸载修复没治好：那个脚本按 `basemetas-fileview-engine` 这种**正式名字**强删，
删不到带 12 位哈希前缀的这个。

### 修复

- **新增 `fv_clean_orphans`**：按名字模式清理残留临时容器。
  调用点：`fv_rebuild` 重建前、`cmd/main stop` 停用前、`cmd/uninstall_init` / `uninstall_callback` 卸载前后。
- **安全边界**：只删名字严格匹配 `<12 位十六进制>_basemetas-fileview-` 的容器，
  不会误伤用户自己起的、名字里恰好含 `basemetas-fileview` 的容器。
- `config_callback` 改成「挂载清单双向比对，真的变了才重建」（0.5.11 已做），
  进一步减少重建窗口 —— 重建窗口越少，留下临时容器的机会越少。

### 工具

- `tools/fv-repair.sh` 新增步骤「0c. 清理 compose 残留的临时容器」，一键清掉。
- `tools/fv-doctor.sh` 会把残留容器报出来（并给出清理命令）。

---

## 0.5.11

### 停用失败的真因：容器重建竞态

拿到 `/var/log/trim_app_center/error.log` 后，飞牛自己把话说清楚了：

```
level=error msg="stop app" appName=basemetas-fileview class=stop
error="12006:exit status 1:
 Container basemetas-fileview-engine                 Stopping
 Container f355c8f78542_basemetas-fileview-engine    Stopping
 Container basemetas-fileview-engine                 Error while Stopping
 Container f355c8f78542_basemetas-fileview-engine    Stopped
Error response from daemon: No such container: f355c8f785421a50…"
```

`f355c8f78542_basemetas-fileview-engine` 是 **compose 重建容器时的临时名**。
对照我们自己的日志：

```
11:51:05   ← 框架在停容器
11:51:06 容器已重建（project=basemetas-fileview，原 basemetas-fileview）
```

**同一秒里，框架在停容器、我们在重建它们**，于是框架手里的容器 ID 失效，报 `No such container`。

根因是 `config_callback` 以前**无条件** `--force-recreate`：等于每次「保存设置」都把容器重建一遍，
哪怕配置一个字都没改。重建窗口内容器会短暂以 `<hash>_<name>` 存在，任何并发的停用/卸载都会踩中。

### 修复

- **`config_callback` 改成 `ensure` 模式：挂载清单双向比对，真的变了才重建。**
  - 少了 → 重建（新加的卷没挂上）
  - 多了 → 重建（用户把某个卷从列表里去掉了）
  - 一致 → **不动容器**
  新增 `fv_canon_vols` 把「期望列表」和「容器实际挂载」规范成同一形式再比较
  （统一分隔符、按卷号数值排序，`/vol2` 排在 `/vol10` 前面）。
- **`cmd/main stop` 去掉多余的 `docker compose stop`**，只保留最小兜底 `docker stop -t 5`。
  框架自己会停，我们再叠一层 compose 只会增加互相干扰的机会。
- **`fv_dir_volumes` 排除带前导零的卷号。** 实测真机上存在 `/vol00`（不是存储卷），
  旧写法 `/vol[0-9][0-9]` 会把它一起收进挂载列表。用户显式填写的列表不受影响。

### 预检增强（开放 API）

- 记录**调用来源**（`main start` / `config_callback`）—— 用来判断 `TRIM_API_TOKEN` 是不是只在某个上下文里注入。
- **实际连一次 socket**（不带 token），把原始响应写进日志：用来区分
  「应用用户连不上 socket（权限问题）」和「只是缺 token」，这两者修法完全不同。
- 打印 socket 的 `getfacl`。

---

## 0.5.10

> **后续更正（0.5.11）**：拿到 `/var/log/trim_app_center/error.log` 后确认，
> 停用失败的真因是**容器重建竞态**（见 0.5.11），不是下面这个变量插值问题。
> 本改动**保留**——去掉 compose 对环境变量的依赖本身是有价值的（框架自己跑 compose 时确实不保证注入），
> 但它不是停用失败的修复。

本次修的是「**点停用报 `Request failed, please try again later`**」——这个报错看不出任何原因，
而且它还会连带卡住卸载 / 重装。

### 高度嫌疑：compose 依赖了框架注入的环境变量

`docker-compose.yaml` 里有两处变量插值：

```yaml
- "${TRIM_PKGVAR}/fonts:/usr/local/share/fonts:ro"
- "${TRIM_APPDEST}/docker:/etc/nginx/conf.d:ro"
- "${TRIM_APPDEST}:/app/target:rw"
```

而 `TRIM_APPDEST` / `TRIM_PKGVAR` **只有飞牛框架执行应用脚本时才注入**。
框架自己那次 `docker compose`（停用、卸载、更新都会用到）一旦没有这两个变量，
compose 就会把 `:/app/target:rw` 解析成非法挂载、整体失败：

```
invalid spec: :/app/target:rw: empty section between colons
```

界面只会把这次失败折叠成一句 `Request failed`。
0.5.6 加的 `.env` 只能救「在 compose 同目录执行」这一种情况，**救不了别的工作目录**。

**修法**：新增 `fv_materialize_env`，在回调里把 `${TRIM_APPDEST}` / `${TRIM_PKGVAR}`
**就地替换成字面量路径**。compose 从此不依赖任何环境变量，从哪个目录执行都能解析。
升级时框架重新释放 `app.tgz` 会把模板（含 `${TRIM_*}`）覆盖回来，下次回调再替换一次——
和挂载段一样的「释放后重写」模式。替换是幂等的（已经没有 `${TRIM_` 就直接返回）。

### 顺带

- `cmd/main stop` 给 `docker compose stop` / `docker stop` 加了超时。
  引擎是 Java + redis + rocketmq 的栈，优雅退出可能很慢；停用接口一旦超时，
  界面同样只报一句 `Request failed`。
- **开放 API 预检改为同时挂在「保存设置」上**。
  `cmd/main start` 只在应用经历「停止 → 启动」状态迁移时才被调用，
  而实际使用中应用很少停过（何况停用本身还可能失败），于是预检根本不会执行。
  现在保存一次设置就能拿到结论。

---

## 0.5.9

本版**不改变任何访问行为**，只是为「按用户区分预览权限」把路铺好、把前提探明。

### 背景

现在的实现是「容器以 root 身份挂载全部存储卷」——这绕过了飞牛的用户 ACL，
所以**凡能登录飞牛的用户，打开 `/app/basemetas-fileview/...` 都能预览已挂载卷里的文件**。
要修掉它，需要飞牛的开放 API（[调用方式](https://developer.fnnas.com/api/calling/)）：

| 能力 | 接口 |
|---|---|
| 网关转发当前用户 | `X-Trim-Userid` / `X-Trim-Isadmin` / `X-Trim-Username` |
| 管理员授权固定目录 | 前端 `pickSharedFile` / `authorizeSharedFile`；后端 `trim.file.getSharedAccessibleFolders` |
| 按用户校验路径权限 | 后端 `trim.file.checkUserACL` `{uid, path}` → `{readable, writable, deletable}` |

设计方向（按你的选择）：**管理员授权固定目录，不要求用户逐个授权**；每次请求在网关层
用 `X-Trim-Userid` + 请求里的 `path` 调 `checkUserACL`，`readable: false` 就 403。

### 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| 飞牛 fnOS | **≥ 1.2.0401** | 开放 API 的硬门槛。低于此版本，开放 API 不可用 |
| 飞牛 App | **≥ 1.34.0** | 同上（用飞牛 App 打开预览时） |
| `manifest.os_min_version` | 仍为 `1.2.0` | **暂不上抬**：本版只是预检，不依赖开放 API；等权限闸门真正上线、成为必需功能时再抬，避免白白挡住老版本用户 |

预检会读取系统注入的 `TRIM_SYS_VERSION` 自行比对，并在日志里直接写「✅ 满足 / ❌ 低于」，
不用手工核对版本号。

### 新增

- `config/resource` 声明 `api-scope`：`trim.file.sharedAccess`、`trim.file.userAcl`。
- **启动时一次性开放 API 预检** `app/docker/fv-acl-probe.sh`（只读，不阻塞启动）。
  它把下面三件事连同**原始响应**写进 `@appdata/basemetas-fileview/fv-volumes.log`：

  1. `TRIM_API_TOKEN` 有没有注入到应用脚本环境（官方要求不得持久化，所以只能这么探）；
  2. `/var/run/trim_open_gateway_apiscope.socket` 在不在、当前用户能不能访问；
  3. 管理员已授权哪些目录，以及 `checkUserACL` 返回的是**真实权限**还是清一色 `false`。

  第 3 条尤其关键：官方文档写明「应用无权读取路径状态时，`readable/writable/deletable` 均为 `false`」，
  而我们并没有走授权流程（是靠 root 挂载绕过的），所以**必须先确认它返回的是真结果**，
  否则闸门一上线会把所有人挡住。

- 预检会同时打印 `TRIM_SYS_VERSION`（开放 API 要求系统 ≥ `1.2.0401`）。

### 下一步

预检结论出来后，再决定闸门落在哪一层（nginx `auth_request` + 一个小鉴权服务 / 换用支持脚本的网关镜像）。
`auth_request` 只认 HTTP 状态码，而飞牛接口是 `200` + body 里的 `code`/`data`，
所以**纯 nginx 配置做不到**，必须有能解析 JSON 的一层——这也是为什么先探明再动手。

---

## 0.5.8

本次修的是「某个存储卷（如 `/vol3`）里的文件预览报文件不存在」，而且**全新安装也一样**：
`/vol1`、`/vol2` 能预览，`/vol3` 不行。

### 现场证据（引擎容器日志）

```
POST /app/basemetas-fileview/preview/api/localFile  →  404
ERROR GlobalExceptionHandler - 业务异常 - 错误码: 30000,
  消息: 文件不存在: 文件不存在: /vol1/1000/某目录/某文件.ofd, 路径: /preview/api/localFile
```

同一时刻 `/vol1` 的 OFD 走完了 `localFile(200) → 状态轮询 → OFD 转 PDF → 取文件(200)`。
链路完全正常，**只有 `/vol3` 这个路径在引擎容器的文件系统里不存在** —— 也就是这个卷没挂进容器。

### 决定性证据：compose 里有 `/vol3`，容器里没有；应用用户用不了 docker

```
# compose 挂载段 —— 文件是对的
      - /vol1:/vol1:ro
      - /vol2:/vol2:ro
      - /vol3:/vol3:ro

# 容器**实际**挂载 —— 就是没有 /vol3
/vol1 -> /vol1
/vol2 -> /vol2
/vol1/@appdata/basemetas-fileview/fonts -> /usr/local/share/fonts

# 容器内部
uid=0(root) gid=0(root) groups=0(root)
ls: cannot access '/vol3': No such file or directory

# ★ 关键
runuser -u basemetas-fileview -- docker ps   →   不可以
```

顺带排除掉的：`/vol3` **确实在 `/proc/mounts` 里**（`/dev/mapper/trim_<uuid>-0 /vol3 btrfs`），
所以不是探测漏卷；声明项目名与容器实际所属项目都是 `basemetas-fileview`，也不是脱管；
`docker compose config` 通过，compose 合法。

### 根因：应用用户没有 Docker 权限

生命周期脚本是以 **应用用户 `basemetas-fileview`** 身份运行的，而它**不在 `docker` 组里**，
`/var/run/docker.sock` 是 `root:docker 0660` —— 于是**所有 docker 操作全部静默失败**：

| 代码 | 后果 |
|---|---|
| `fv_rebuild` 第一句 `docker inspect` | 失败 → `return 0` → **「保存设置即自动重建容器」从来就没生效过** |
| `cmd/main status` 的 `docker inspect` | 一直失败 → 飞牛看到的运行状态是错的 |
| 框架/脚本的停容器动作 | 失败 → 点「停用」报 `Request failed, please try again later` |

容器从安装那一刻起就没被重建过，所以 compose 里后来加上的 `/vol3` 永远进不了容器。
（0.5.6 的更新说明写着「保存后会自动重建容器」——那句话是没经过验证的。）

### 修复

- **`config/privilege` 声明 `join-groups: ["docker"]`（本次主因的修法）**
  飞牛官方文档给应用用户的附加用户组机制就是这个字段。加上之后：
  保存设置会真正重建容器、`status` 会如实上报、停用也会正常。

  > ⚠️ 这等于把 docker socket 交给应用用户，是一次**较大的权限授予**。
  > 本应用本来就要以 root 在容器里跑预览引擎、只读挂载全部存储卷，权限模型没有变得更弱，
  > 但换机器部署时请知悉这一点（README 的安全说明里也写了）。
  > 注意：`privilege` 只在安装 / 升级时应用；已经装好的机器可以手工 `usermod -aG docker basemetas-fileview`。

- **docker 用不了时不再静默**
  新增 `fv_docker_ok()`；`fv_rebuild` / `fv_ensure_mounts` 在无权限时会写日志
  （`@appdata/basemetas-fileview/fv-volumes.log`）并把「照着做就能好」的修法写进
  `TRIM_TEMP_LOGFILE`（应用界面可见）。以前这种情况看起来和「一切正常」完全一样。

- **容器「脱管」兜底**（同类隐患，不是本次主因）
  重建容器时原来用的是「读现有容器的 `com.docker.compose.project` 标签」，
  但飞牛应用中心是**按 `config/resource` 里声明的项目名**来管容器的。
  两者一旦不一致（典型踩法：在应用目录里手工 `docker compose up -d`，
  compose 默认拿目录名 `docker` 当项目名），飞牛就完全看不到这些容器。
  现在 `fv_rebuild` 改用声明的名字；发现不一致时先 `docker rm -f` 掉脱管的容器再按声明名重建。

- **`cmd/main stop` 显式兜底停容器**
  框架本来会自己停，但既然实测出现过停不掉，这里再显式停一次（重复停无害）。
  停不掉会连带让「卸载 / 重装」也做不了。

- **存储卷探测漏卷**（同类隐患，不是本次主因）
  旧写法是「`/proc/mounts` 里探到任意一个 `/volN` 就完全不走目录兜底」。
  于是「`/vol1`、`/vol2` 是独立挂载点，`/vol3` 只是目录（bind mount / 普通目录）」这种环境下，
  `/vol3` 被静默漏掉，而 `/vol1`、`/vol2` 看起来一切正常。
  现在改成「挂载点 ∪ `/volN` 目录」取并集，并按卷号排序；挂载点末尾多余的 `/` 也一并容忍。

- **只改 compose 不等于挂载生效**
  新增 `fv_ensure_mounts`：**启动 / 安装**时会 `docker exec` 进引擎容器，
  逐个核对每个卷在容器里是否真的可用，不对就强制重建容器。
  不再假定「飞牛框架一定会拿改过的 compose 重建一次容器」。

  这里要区分两种病 —— 都会表现成「文件不存在」，但只测「目录在不在」会漏掉第二种：
  | 现象 | 原因 | 判据 |
  |---|---|---|
  | 容器里没有 `/vol3` | 该卷没写进 compose，或容器建得比挂载段更新早 | `docker exec test -d` 失败 |
  | 容器里 `/vol3` 是**空目录** | 容器创建时该卷**还没挂上**，docker 把底层空目录绑了进去 | 宿主机有内容、容器里空 |

  第二种在真机上很容易发生：机械盘挂载比系统盘慢，**重启后容器先起来、盘后挂上**，
  于是容器里那个 `/vol3` 一直是个空目录。用 `docker exec` 而不是解析 `docker inspect`，
  是因为前者问的就是「引擎进程自己看得见吗」，和 FileView 报「文件不存在」是同一个判据。

- **探测过程留痕**
  `@appdata/basemetas-fileview/fv-volumes.log` 现在会记录
  `探测输入：mounts=[...] dirs=[...]`、`挂载段已同步：设置=... 实际=...`、
  `容器所属项目 X 与声明的 Y 不一致（脱管）`、`引擎容器挂载核对通过 / 不对`。
  下次再出问题，看一眼日志就知道断在哪一环。

- **升级路径**
  升级会把 `docker-compose.yaml` 覆盖回模板的 `/vol1`、`/vol2`，
  `cmd/upgrade_callback` 会重新同步挂载段并重建容器。

### 改动

| 回调 | 行为 |
|---|---|
| `install_callback` | 写挂载段 + **核对容器挂载 / 项目名**（容器已存在就核对，不存在交给框架首次创建） |
| `config_callback` | 写挂载段 + **无条件重建**（用户可能把某个卷去掉，没有「缺卷」可检测） |
| `upgrade_callback` | 写挂载段 + 无条件重建 |
| `main start` | 写挂载段 + 核对容器挂载 / 项目名（幂等自愈） |
| `main stop` | 显式兜底停容器（compose stop + docker stop） |

### 工具

- `tools/fv-repair.sh` 现在会：并集探测 → 重写挂载段 → **`docker compose config` 校验** →
  **修正脱管（按声明名重建）** → 重建容器 → 逐卷验证（区分「没有」和「空目录」）。
  也支持**手工指定卷列表**，用来快速判断「到底是不是挂载的问题」：
  ```bash
  VOLS="/vol1,/vol2,/vol3" bash tools/fv-repair.sh
  ```
- `tools/fv-doctor.sh` 一键诊断（只读）：新增 `docker compose config` 校验、
  容器项目名 vs 声明名比对、飞牛应用中心错误日志（`/var/log/trim_app_center/error.log`）。

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
