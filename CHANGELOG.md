# 更新说明

包版本号与预览引擎版本**解耦**：包版本 `0.5.x` 对应引擎 `basemetas/fileview:1.5.2`。
只改外壳（配置 / nginx / 图标）时末位 +1；升级引擎镜像时整段跟着抬（如引擎 1.6.0 → 包 0.6.0）。
飞牛靠版本号**递增**判断升级安装，同版本不允许覆盖安装。

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
  消息: 文件不存在: 文件不存在: /vol3/1000/某目录/某文件.ofd, 路径: /preview/api/localFile
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
