# 飞牛 fnOS 原生 .fpk 安装 BaseMetas FileView

把 [BaseMetas FileView](https://fileview.basemetas.cn/)（开源在线文件预览引擎）打包成飞牛 fnOS 的原生 `.fpk` 应用，通过**统一网关**接入，并接管文件管理器的「打开方式」右键菜单。

## 特性

- **`.fpk` 原生安装** —— 应用中心「手动安装」上传即完成，带安装向导、启动/停止/设置，与飞牛自带「Office 预览」同一形态。
- **统一网关接入** —— 不占用独立端口，复用系统访问域名（`/app/basemetas-fileview`），且网关会**先校验飞牛登录态**再转发。
- **接管文件打开方式** —— 文件管理器右键出现「用 FileView 打开」，覆盖 61 种飞牛没有原生能力的格式（DWG/DXF 图纸、OFD 版式、三维模型、压缩包、Visio、思维导图、PSD 等）。
- **只读挂载** —— 存储卷一律 `:ro`，预览不会改动 NAS 里的任何文件。

## 目录结构

| 路径 | 说明 |
|---|---|
| `basemetas-fileview.fpk` | 安装包 —— **构建产物，不在仓库里**（`.gitignore` 排除）。用 `fpk/build.sh` 或 `build.bat` 现场生成，或从 [Releases](../../releases) 下载 |
| `fpk/basemetas-fileview/` | 安装包工程源码（改配置改这里） |
| `fpk/build.bat` / `fpk/build.sh` | Windows / Linux 重新打包脚本 |
| `fpk/tools/` | 生成脚本与自检工具（`gen_filetypes.py`、`gen_icons.py`、`check_nginx_conf.py`、`check_nginx_map.py`、`verify_fpk.py`、`check_eol.sh`、`selfcheck.sh`） |
| `tools/fv-repair.sh` | NAS 上一键修复脚本（存储卷 / 网关重启故障） |
| `tools/fv-doctor.sh` | NAS 上一键**诊断**脚本（只读，定位「某个盘预览不了」卡在哪一环） |
| `tools/fv-uninstall-fix.sh` | NAS 上一键修复「卸载报 Request failed」的卡死状态 |
| `tools/fv-acl-check.sh` | NAS 上验证「按用户判定文件权限」是否可行（含对照组，只读） |
| `tools/fv-docker-doctor.sh` | NAS 上一键**诊断 Docker 侧**问题（安装报 `layer does not exist` / 拉不动镜像时用，只读） |
| `tools/fv-docker-layerdb.sh` | 检查 / 清理 Docker 镜像元数据（layerdb）里的残留条目（`layer does not exist` 的第二步处理；`--fix` 前会自动备份） |
| `tools/fv-docker-imageaudit.sh` | 审计 Docker 镜像记录健康度：坏记录有几条、对应哪些镜像名、**哪些容器引用了它们**（= 重启会起不来的应用），只读 |
| `CHANGELOG.md` | 版本更新说明 |

> `.fpk` 里装的是「怎么跑」而不是「跑什么」：预览引擎镜像 `basemetas/fileview:1.5.2`（约 863 MB）在**安装时**从 Docker Hub 拉取，不在包内。这也是飞牛官方 Docker 应用的标准形态。

## 安装

1. 应用中心 → 左下角「**手动安装**」→ 上传 `basemetas-fileview.fpk`
2. 安装向导的「允许预览的存储卷」保持默认 `auto` 即可（自动挂载本机全部 `/volN`）
3. 装完自动启动。文件管理器右键文件 → 「**用 FileView 打开**」

首次安装需拉取镜像，**耗时几分钟**；国内直连 Docker Hub 较慢，建议先配置镜像加速。卸载不会删除镜像，重装时直接复用。

### 更新

改配置后**重新打包**（见下），再升级安装。0.5.8 起**可以就地升级**（版本号递增即可，不必先卸载）；若走「卸载 → 重新手动安装」也一样安全（镜像复用，重装很快）。若仅临时改 `nginx.conf`，也可直接在「管理员视角」下编辑 `@appcenter/basemetas-fileview/docker/nginx.conf` 后重启网关容器，不必重装。

## 支持的文件类型

飞牛把入口的扩展名列表写进一个**限长约 500 字符**的数据库列，超长会导致安装被数据库拒绝（界面只报「服务异常」）。因此「全量接管」物理上做不到，只能在额度内取舍。当前注册 **61 个扩展名（约 255 字符）**：

| 分类 | 扩展名 |
|---|---|
| CAD / 工程图纸 | dwg dxf |
| 版式文档 | pdf ofd |
| 压缩包 | zip rar 7z tar tgz gz jar |
| Visio / 流程图 / 导图 | vsd vsdm vsdx vssx vstx bpmn drawio xmind |
| 三维模型 | gltf glb obj stl fbx ply dae wrl 3ds 3mf 3dm |
| 专业图像 | psd tga emf wmf tif tiff |
| Office | doc docx wps rtf · xls xlsx csv et ods · ppt pptx dps odp |
| 电子书 | epub |
| 纯文本 / 数据 | txt md json xml yaml conf log sql |
| 脚本 | sh py js |

未注册的格式（jpg/png/mp4 等位图与音视频、绝大多数编程语言）交给飞牛自带应用。清单由脚本生成并带**长度门禁**：

```bash
python fpk/tools/gen_filetypes.py --dry           # 打印长度并做门禁判定
python fpk/tools/gen_filetypes.py                 # 生成并覆盖 app/ui/config
```

飞牛支持在「应用设置」里为每种类型指定**默认打开方式**，谁当默认由用户决定。

## 工作原理

### 唯一入口

只保留一个入口 `basemetas-fileview.view`（文件打开方式，`type: url`，在浏览器新标签页打开），桌面不显示。飞牛在打开文件时会在入口 `url` 后自动追加 `?path=<绝对路径>`，因此入口 `url` 必须保留。

### 请求链路

```
浏览器 / 飞牛 App
   ↓  统一网关 /app/basemetas-fileview（校验登录态，附用户头）
Unix Socket app.sock
   ↓  nginx 网关容器（剥前缀，补 X-Forwarded-Prefix / Host）
FileView 引擎容器  http://fileview:80/preview/view?path=/vol1/...
```

### 三个容器

| 容器 | 镜像 | 作用 |
|---|---|---|
| `basemetas-fileview-engine` | `basemetas/fileview:1.5.2` | 预览引擎 |
| `basemetas-fileview-gateway` | `nginx:alpine` | 监听 `app.sock`，适配引擎，转发；调闸门做权限校验 |
| `basemetas-fileview-acl` | `python:3-alpine` | 逐用户权限闸门（0.5.15 起），以目标用户身份判定能否读该文件 |

三个容器都**不发布宿主机端口**，只能从统一网关进入。网关容器做目录级挂载：

```yaml
- "${TRIM_APPDEST}/docker:/etc/nginx/conf.d:ro"   # 配置目录
- "${TRIM_APPDEST}:/app/target:rw"                # 创建 app.sock
```

闸门容器只读挂载与引擎**相同**的存储卷，外加宿主机的 `/etc/passwd`、`/etc/group`
（用来还原目标用户的主组与附加组）。它不碰 docker、不写任何文件。

## 配置

### 应用设置里能看到什么

| 位置 | 内容 |
|---|---|
| 「存储卷」 | 可预览的存储卷范围：`auto` 或 `/vol1,/vol2` 这样的列表 |
| 「预览限制」 | 单文件预览大小上限（MB），默认 `1024` |
| 「逐用户权限校验」 | 纯说明（默认已开启，不需要设置） |
| 入口设置 | 「桌面访问 / 访问端口 / 访问路径 / 自定义 URL」。入口地址由统一网关的 `gatewayPrefix` / `gatewaySocket` 决定，**不要**去改「自定义 URL」，改了会让预览打不开 |

**没有「访问权限」标签页**：那一栏是给「让用户自己选授权目录」的应用用的
（对应开放 API 的 `trim.file.sharedAccess`）。本应用不走那套 ——
能访问哪些卷由上面的「存储卷」决定，每个用户能看哪些文件由闸门按飞牛 ACL 判定，
所以 manifest 里声明了 `disable_authorization_path=true` 把它隐藏（0.5.19 起）。

> 「自定义 URL」那一行是飞牛对**所有**入口固定渲染的，没有字段能单独隐藏它 ——
> 曾试过用 `"control": {"accessPerm": "hidden"}`，但那个字段管的是**入口的访问权限**、
> 不是设置项的可见性，结果是入口对普通用户不可见。所以现在保留显示，只是别去改它。

### 单文件大小上限（大文件提示「文件转换失败 413」）

预览引擎自带一道体积闸门：**超过上限的文件会在转换之前被直接拒绝**，
接口返回 HTTP 413，前端把状态码显示成「文件转换失败 413」——
看起来像转换器坏了，其实和转换器、nginx、网络都无关。

安装向导 / 应用「设置」里的 `wizard_max_file_mb`：

| 填什么 | 效果 |
|---|---|
| `1024`（默认） | 单文件最大 1 GB |
| 其它数字 | 按填写的 MB 值生效 |

保存后**会自动重建容器**使其生效（环境变量和 bind 挂载一样，只在容器创建那一刻定死）。

> 引擎自带的默认值是 **100 MB**。以前没暴露这个开关，所以任何超过 100 MB 的文件都会 413。
> 现在默认放开到 1024 MB。

**调多大合适**：PDF / 图片 / 代码等由浏览器端渲染，调大基本不增加服务端负担；
Word / Excel / PPT / CAD / OFD 需要服务端转换，上限过大时预览大文件会明显吃 CPU 和内存，
请按 NAS 的内存情况取舍。

> 另有一道独立限制：压缩包（zip / rar / 7z）**内部单个文件**的解压上限是 100 MB
> （引擎的 `fileview.archive.max-file-size`），本开关不影响它。

### 存储卷

FileView 需以**同名同路径**只读挂载存储卷（`/vol1:/vol1:ro`），否则容器内找不到飞牛传来的绝对路径。

安装向导 / 应用「设置」里的 `wizard_volumes`：

| 填什么 | 效果 |
|---|---|
| `auto`（默认） | 自动探测并挂载本机**全部** `/volN`，以 `/proc/mounts` 为准 |
| `/vol1,/vol2` | 只挂载指定的卷 |

保存后**会自动重建容器**使挂载生效，不必手动重启应用。以后新增了硬盘，把设置改回 `auto` 保存一次即可纳入。

> 注意：bind 挂载在容器创建时确定，只改配置不重建容器是**不会**生效的（`docker restart` 也不行）。这就是 0.5.6 之前「设置里明明有 `/vol3`，预览还是报文件不存在」的原因。

> ⚠️ **升级会顶掉挂载段**：升级时框架把新的 `app.tgz` 重新释放到 `${TRIM_APPDEST}`，`docker/docker-compose.yaml` 会被覆盖回安装包模板里写死的 `/vol1`、`/vol2`。所以任何「释放文件」之后的时机都必须重写一遍挂载段 —— 0.5.8 起 `cmd/upgrade_callback` 与 `cmd/main start` 都会做这件事（**升级后不必再去设置里保存一次**）。

向导里填的值会持久化到 `${TRIM_PKGVAR}/volumes.conf`，升级/重启时按「本次向导值 → 上次保存的设置 → `auto`」的顺序取值；同步结果记在 `${TRIM_PKGVAR}/fv-volumes.log`。

> 💡 **为什么探测要取并集（0.5.8 修的那个 bug）**：存储卷不一定都是独立挂载点。
> 实测有这种机器：`/vol1`、`/vol2` 在 `/proc/mounts` 里是独立挂载点，`/vol3` 却只是个目录。
> 旧写法「只要探到任意一个挂载点就不再看目录」会静默漏掉 `/vol3` ——
> 而 `/vol1`、`/vol2` 一切正常，看起来完全不像配置问题。
> 现在改成「挂载点 ∪ `/volN` 目录」取并集，两种情况都覆盖。

### 故障修复

遇到「引擎容器 Up、网关容器 Restarting」或「某个盘预览报文件不存在」，在 NAS 上用 root 执行：

```bash
bash tools/fv-repair.sh
```

> 如果现象是**某个大文件**打不开、提示「文件转换失败 413」，那不是挂载问题 ——
> 是引擎自带的体积闸门，见上面的[单文件大小上限](#单文件大小上限大文件提示文件转换失败-413)。
> 拿不准就用诊断脚本，它会直接告诉你文件有没有超限：
> ```bash
> bash tools/fv-doctor.sh --file /vol3/某大文件.pdf
> ```

脚本会依次做：探测存储卷 → 重写 compose 挂载段 → 清理残留 `app.sock` → 重建容器 → 验证并打印状态；网关仍未起来时会直接把日志打出来。

想先确认「到底是不是挂载的问题」，可以**手工指定卷列表**跑一次 —— 这一步完全绕开自动探测，能直接给出答案：

```bash
VOLS="/vol1,/vol2,/vol3" bash tools/fv-repair.sh
```

> ⚠️ **不要在应用目录里裸跑 `docker compose up -d`**
> `docker compose` 默认拿**目录名**当项目名（这个目录叫 `docker`），于是容器会挂到 `docker` 项目下，
> 而飞牛应用中心是按 `config/resource` 声明的 `basemetas-fileview` 来管容器的 —— 两边对不上，容器就**脱管**了：
> 点「停用」报 `Request failed, please try again later`，保存设置 / 更新也不会重建容器，**新加的卷永远挂不上**。
> 一定要手工操作时，务必带上项目名：
> ```bash
> cd /vol1/@appcenter/basemetas-fileview/docker
> TRIM_APPDEST=/vol1/@appcenter/basemetas-fileview \
> TRIM_PKGVAR=/vol1/@appdata/basemetas-fileview \
> docker compose -p basemetas-fileview up -d
> ```
> 已经脱管了就跑 `bash tools/fv-repair.sh`，它会自动纠正项目名。

指定后 `/vol3` 能预览了 → 问题就在探测/挂载；还是不行 → 问题不在挂载，去看 `fv-volumes.log` 和引擎容器日志。

想知道**具体是哪一环断的**（宿主机没这个卷？挂载段没写进去？容器里其实没挂上？容器里读不到？），先跑诊断脚本 —— 它只读、不改任何东西：

```bash
bash tools/fv-doctor.sh
bash tools/fv-doctor.sh --file /vol3/某文件.dwg    # 顺带实测某个具体文件能不能读
```


### 安装报 `layer does not exist`

安装时弹出（两种写法都会遇到）：

```
gateway Pulling / acl Pulling / fileview Pulling / acl Pulled
Error response from daemon: layer does not exist
```
```
unable to get image 'nginx:alpine': Error response from daemon: layer does not exist
```

这是 **Docker daemon 的镜像状态不一致，与本应用无关**：报错发生在 `docker pull` 阶段，比安装包里的任何脚本都早；本应用只做容器级操作（`docker rm -f`、`compose down`），**从不 `rmi` / `prune`**，卸载也不会删镜像。

同时会出现几个反直觉的现象，别被带偏：`docker images` 里列不出那个镜像、`docker rmi -f X` 回一句 `No such image`、`docker pull X` 打印了 `Downloaded newer image` 拉完却依然不在。

#### 第一步：看 dockerd 日志定性

```bash
journalctl -u docker --no-pager -n 200 | grep -E 'not restoring image|layer does not exist'
```

看到这种，就是本文要处理的情况：

```
level=error msg="not restoring image" chainID="sha256:xxxx…" err="layer does not exist"
level=error msg="Handler for GET /v1.51/images/nginx:alpine/json returned error: layer does not exist"
```

含义：**daemon 认为那个镜像在，但它的层取不出来**。有两种成因，处理方式完全不同：

| 成因 | 怎么判断 | 怎么修 |
|---|---|---|
| ① daemon 自己的索引状态不一致（**断电 / 异常重启后最常见**） | 跑第二步的扫描，**残留 0 条** | 干净地停一次再起（第二步） |
| ② layerdb 里真有残留条目 | 扫描报出残留条数 > 0 | 用脚本 `--fix` 清掉（第三步） |

#### 第二步：先试「干净地停一次再起」

> ⚠️ 是 `stop` + `start`，**不是 `restart`**。
> 实测（2026-09-28，断电后）：`systemctl restart docker` 试了两次都没修好，日志里还留着一堆
> ```
> docker.service: Unit process 72220 (docker-proxy) remains running after unit stopped.
> docker.service: Found left-over process … This usually indicates unclean termination of a previous run
> ```
> 一次干净的 `stop`（等它真的停完）→ `start` 之后，`docker pull nginx:alpine` 会回
> **`Image is up to date`** —— 但注意：**这只说明层数据在，不代表镜像记录是好的**
> （实测那次 pull 回 `up to date`，`docker image inspect nginx:alpine` 依然失败）。

```bash
systemctl stop docker
pgrep -a docker-proxy          # 应该没有输出；有就再等一会儿
systemctl start docker
docker image inspect nginx:alpine >/dev/null 2>&1 && echo "✅ 好了" || echo "❌ 记录还是坏的"
```

`❌` 就往下走 —— 那次实测的最终解是**给这两个名字换上一个能用的镜像**（见下面「根治」一节），
而不是继续折腾 daemon。

#### 第三步：查 layerdb 残留

```bash
bash tools/fv-docker-layerdb.sh          # 只读：报告残留条数（docker 跑着也能用）
systemctl stop docker
bash tools/fv-docker-layerdb.sh --fix    # 自动备份 layerdb 后，只删确认残留的条目
systemctl start docker
docker pull nginx:alpine
```

脚本只删这两类条目 —— 那部分数据已经丢了，元数据是垃圾，删掉不会影响任何还能用的镜像：

- `cache-id` 指向的层数据目录（`overlay2/<cache-id>`）不存在
- `parent` 指向的父层条目不存在（父层丢了同样会让整条链取不出来）

`--fix` 前会把 layerdb 打包备份到 `${DockerRootDir}/image/`。

#### 顺便确认不是别的原因

```bash
docker info --format '{{.DockerRootDir}}'      # 数据根（fnOS 上通常是 /vol1/docker）
df -h <数据根>; df -i <数据根>                  # 磁盘 / inode 有没有满
dmesg | grep -iE 'I/O error|btrfs|ext4|xfs|corrupt' | tail -30    # 文件系统有没有被写坏
docker ps -a --format '{{.Names}}\t{{.Status}}'                   # 其它应用有没有被牵连
```

前三项都正常、其它容器也都在跑，就放心按上面两步处理；**有文件系统报错就先处理存储**，别再折腾 Docker。

#### 三个镜像各自的作用

| 镜像 | 作用 |
|---|---|
| `nginx:alpine` | 网关 |
| `python:3-alpine` | 逐用户权限闸门 |
| `basemetas/fileview:1.5.2` | 预览引擎 |

报错点名哪个就处理哪个。**不要**拿机器上已有的 `nginx:latest` 来替换 `alpine` —— 两者基底不同（Debian 162MB vs musl ~40MB），而且会让本应用多一层对别人镜像的依赖。

> 三个镜像都能 `docker pull` 成功之后，回应用中心重装即可。

#### 根治：先审计影响面，再决定动到哪一层

`layer does not exist` 处理完之后，**别的应用可能还有同样的坏记录** —— 它们现在跑着，是因为已经挂载好了，**重启时才会暴露**。所以先只读审计一遍：

```bash
bash tools/fv-docker-imageaudit.sh
```

它会直接列出：坏掉的镜像记录有几条、分别对应哪些镜像名、**哪些容器引用了它们**（也就是重启后会起不来的应用）。

按结果分三种处理：

| 情况 | 处理 |
|---|---|
| 坏记录**没有名字**、也没有容器引用 | **不影响任何应用**，可以先不管；想清干净见下面「清理孤儿坏记录」 |
| 坏记录**被某个容器引用** | 那个容器重建时会失败 —— 先给它换个能用的镜像（`docker tag` 顶上，或改它的 image），再重建 |
| 想一次性消除所有隐患 | 先按上面「清理孤儿坏记录」来；只有连它都清不掉时才重建镜像存储（见最后一节） |

**「换名字」的具体做法**（2026-09-28 实测就是用这个解封的）—— 拿一个能跑的同类镜像顶掉坏名字：

```bash
# 找一个能用的同类镜像（inspect 成功的）
docker images | grep -iE 'nginx|python'

docker tag <能用的镜像> <坏掉的名字>          # 例：docker tag nginx:latest nginx:alpine
# 若 tag 报 layer does not exist，先把坏名字摘掉再 tag：
#   docker rmi -f nginx:alpine && docker tag nginx:latest nginx:alpine

# 验证名字现在能用了
docker image inspect <坏掉的名字> >/dev/null 2>&1 && echo "✅" || echo "❌"
```

compose 发现镜像在本地就不会去 pull，也就不会撞上那条坏记录。

**验证修好了没有**：

```bash
systemctl stop docker && systemctl start docker
journalctl -u docker --no-pager -n 100 | grep -E 'not restoring image|layer does not exist'
# 应该没有输出

# 再验一次「新拉一个 alpine 基底的镜像能不能用」—— 这是本问题的核心机制
docker pull alpine:latest && docker run --rm alpine:latest echo ok
docker rmi alpine:latest && docker pull alpine:latest     # 再来一遍，确认可重复
```

#### 清理「孤儿」坏记录（可选 —— 不影响任何应用）

如果审计结果是**无名字、且没有容器引用**的坏记录（典型来源：断电时拉了一半的镜像，之后名字又被 `docker tag` 顶掉了），那它们**不影响任何应用**，只是：

- 每次启动在日志里打两行 `not restoring image`
- `docker image prune -f` 清不掉（会回 `Total reclaimed space: 0B` —— prune 需要先加载记录才能删，而加载就失败）
- 隐患：**以后你再用到那个镜像名，还会撞上同一面墙**

想清掉的话，按下面来（**第 1 步是安全检查，有输出就别删**）：

```bash
# 0. 从 daemon 日志里拿到两个东西：坏记录的 imageID、和它对应的链顶 chainID
journalctl -u docker --no-pager -n 200 | grep -E 'not restoring image'
#   → chainID=sha256:xxxx… 就是链顶
bash tools/fv-docker-imageaudit.sh    # → 会列出坏记录的 imageID

# 1. ⚠️ 安全检查：链顶有没有被别的层当作 parent 引用？
grep -rl "<链顶chainID>" /vol1/docker/image/overlay2/layerdb/sha256/*/parent 2>/dev/null
#   无输出 → 安全（它是某条链的顶端，删掉不影响别的镜像）
#   有输出 → 它被别的镜像依赖，**不要删**，改用「换名字」的办法绕过

# 2. 备份镜像元数据（只是元数据，很小）
systemctl stop docker
tar czf /vol1/docker-image-meta-$(date +%Y%m%d%H%M).tar.gz -C /vol1/docker image

# 3. 删掉镜像记录 + 链顶条目（只删链顶，父层保留 —— 父层可能被别的镜像共用）
#
#    实测（2026-09-28）：**只删 layerdb 的链顶条目就已经让 not restoring image 消失了**，
#    imagedb 那两条记录删不删都行。想彻底清干净就两条一起删；嫌麻烦只做 layerdb 那步也可以。
#
#    ⚠️ 粘贴多行命令时小心终端把行弄乱 —— 实测踩过：`for id in <长ID1> \<换行><长ID2>; do`
#       被拼成一行后，循环体里的 rm 变成了循环列表的一部分，**一条都没删成**
#       （好在那些拼接出来的路径都不存在，没有误删）。粘完先 `history` 或回显确认一下。

for id in <坏记录的 imageID…>; do
  rm -rf "/vol1/docker/image/overlay2/imagedb/content/sha256/$id"
  rm -rf "/vol1/docker/image/overlay2/imagedb/metadata/sha256/$id"
done
for c in <链顶 chainID…>; do
  rm -rf "/vol1/docker/image/overlay2/layerdb/sha256/$c"
done

# 4. 起 docker 验证
#    ⚠️ 别用 `journalctl -n 60 | grep` —— dockerd 启动时会打很多行，
#       错误在开头，被 -n 截掉就误判成「好了」。要用计数或时间过滤：
systemctl start docker
journalctl -u docker --no-pager | grep -c 'not restoring image'          # 看总次数有没有增加
journalctl -u docker --no-pager | grep 'not restoring image' | tail -2   # 最近一次是什么时候

# 5. 顺带验一下「全新的 alpine 基底镜像能不能正常拉+跑」（不碰你在用的镜像名）
docker pull python:3.12-alpine && docker run --rm python:3.12-alpine python3 -V
```

> 删掉之后，对应的 `overlay2/<cache-id>` 层数据目录会变成无人引用的垃圾（占空间）。
> **确认一切正常、且相关应用都没问题之后**再考虑清理它们；不确认就先留着，只是占点空间。

#### 最后的办法：重建镜像存储

坏记录清不掉、或者想一次性消除隐患时才用：

```bash
# ⚠️ 代价：所有应用都要重新拉镜像。动手前先留好清单
docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u > /vol1/image-list.txt
docker ps -a --format '{{.Names}}\t{{.Image}}' > /vol1/container-images.txt

systemctl stop docker
# 停 docker 后所有容器已停止，此时移动 overlay2 才是安全的
mv /vol1/docker/image    /vol1/docker/image.broken.$(date +%s)
mv /vol1/docker/overlay2 /vol1/docker/overlay2.broken.$(date +%s)
systemctl start docker

# 然后按 image-list.txt 逐个 docker pull，再逐个 docker start 容器
```

- **卷数据（`/vol1/docker/volumes`）和容器定义（`/vol1/docker/containers`）都不动**，各应用的数据不会丢。
- 真正的风险是**镜像拉不回来**：有几个镜像来自 `ghcr.nju.edu.cn`、`registry.fnnas.com`、`registry.cn-hangzhou.aliyuncs.com` 这类源，若其中某个不可用，对应应用就起不来。**所以动手前先把 `image-list.txt` 存好，并确认这些源可达。**
- 一切正常后，那两个 `.broken.*` 目录可以删掉腾空间。

### 卸载失败（`Request failed`）

如果你之前手动执行过 `docker compose up -d`（没有带 `-p basemetas-fileview`），容器会脱离飞牛的 compose project 管理。此时应用中心卸载按自己的项目名 `down` 找不到工程，就会报 `Request failed`，但 `docker ps` 看容器其实已经没了。

**当前状态修复**：把本仓库的 `tools/fv-uninstall-fix.sh` 拷到 NAS，用 root 执行：

```bash
bash fv-uninstall-fix.sh
```

脚本会按容器名强删、按项目名幂等 down、备份并移除应用目录、重启应用中心服务刷新 UI。

**以后避免**：不要裸跑 `docker compose up -d`（务必带 `-p basemetas-fileview`），
具体命令见上一节「故障修复」里的警告框。

### 自定义字体

预览服务只内置免费的中文思源字体和部分英文字体，不含需授权商用的字体（仿宋、宋体、微软雅黑等）。本包已把字体目录挂到应用数据目录（卸载/升级不丢）：

```yaml
- "${TRIM_PKGVAR}/fonts:/usr/local/share/fonts:ro"
```

把字体文件放进 `/vol{n}/@appdata/basemetas-fileview/fonts/` 后重启引擎容器即可。

> 请使用正规渠道取得授权的字体。思源系列（已内置）开源可商用；从 Windows 直接拷贝宋体/微软雅黑属授权灰色地带。DWG 图纸走的是浏览器端 SHX 字体，与本目录无关。

### 数据与日志目录

引擎的**工作目录**和**日志**都挂到了应用数据目录（`${TRIM_PKGVAR}`，即 `/vol{n}/@appdata/basemetas-fileview/`）：

```yaml
- "${TRIM_PKGVAR}/data:/opt/fileview/data"    # 转换产物、解压临时文件、LibreOffice / CAD 工作目录
- "${TRIM_PKGVAR}/logs:/opt/fileview/logs"    # preview 与 convert 两个服务的文件日志
```

不挂的话它们会落在**容器可写层**，后果是：

1. 升级时容器会被 `--force-recreate` 重建，可写层整个丢弃 → 缓存和中间产物全没，每个文件都要重新转换一遍；
2. 日志只能从 `docker logs`（stdout）看，文件日志看不到也没法管理；
3. 这部分占用既不可见、也不受应用管理。

> 想看引擎到底写了什么、占了多少：
> ```bash
> docker exec basemetas-fileview-engine sh -c 'du -sh /opt/fileview/data /opt/fileview/logs'
> tail -f /vol1/@appdata/basemetas-fileview/logs/preview/fileview-preview.log
> ```
> 目录权限是 `0777`（引擎容器以什么用户跑都能写），内容只是临时产物和日志，不含用户文件。

## 安全说明

- ✅ 统一网关先校验登录态，未登录访问被挡在网关层；不对外暴露任何端口。
- ✅ **按用户区分权限（0.5.17 起默认开启）**：飞牛统一网关会把当前登录用户放进 `X-Trim-Userid`，闸门容器据此**以该用户的身份**检查目标文件能否读取，没有读权限就返回 403。
  不需要任何设置。团队文件 / 共享文件按你在飞牛里设的权限正常放行；静态资源不参与判定。
  看判定过程：`docker logs basemetas-fileview-acl`；出现误拦时的应急开关见下面「按用户区分权限」一节。
- ✅ 存储卷只读挂载，且仅限向导里填写的卷。
- ✅ **网络文件预览已关闭（0.5.22 起）**。本应用的入口只做本地路径预览，用不到引擎的「给一个 URL 让它去下载」能力。留着那条路等于开了一个 SSRF：任何能登录飞牛的人都能构造
  `/app/basemetas-fileview/preview/view?url=http://<内网地址>/...` 让引擎去抓内网资源渲染给他看，
  而且这条路径**绕过逐用户权限闸门**（闸门从 `path` / `filePath` 或来源页 query 里取路径，`url=` 请求里没有 `/vol` 路径，走的是「放行」分支）。

  做法是把白名单配成一个永不匹配的域名：`FILEVIEW_NETWORK_SECURITY_TRUSTED_SITES=none.invalid`。
  引擎源码里未配置该值时**默认允许所有域名**（`HttpUtils: if (!hasTrustedSitesConfig()) return true;`）。
  需要恢复网络预览时，把这一行改成你自己的域名（多个用逗号分隔），欢迎页的「查看样例」不受影响（它用的是容器内路径）。
- ⚠️ **应用用户加入了 `docker` 组**（`config/privilege` 里的 `join-groups: ["docker"]`）。

  这是必需的：本应用的「保存设置后自动重建容器」「如实上报运行状态」「停用」都要以应用用户身份
  操作 `docker`，而 `/var/run/docker.sock` 是 `root:docker 0660`。不加这一项，
  这些动作会**全部静默失败** —— 这正是 0.5.6 及更早版本「改了存储卷设置不生效、新加的盘永远预览不了」的真因。

  请知悉这等于把 docker socket 交给该应用用户（约等于 root）。本应用本来就要以 root 在容器里跑
  预览引擎、只读挂载全部存储卷，权限模型上并没有变得更弱；但**换机器部署前请确认你接受这一点**。
  不想给这个权限的话，就只能放弃「改设置自动生效」，改完设置后手工重建容器：

  ```bash
  cd /vol1/@appcenter/basemetas-fileview/docker
  TRIM_APPDEST=/vol1/@appcenter/basemetas-fileview \
  TRIM_PKGVAR=/vol1/@appdata/basemetas-fileview \
  docker compose -p basemetas-fileview up -d --force-recreate
  ```

## 按用户区分权限（0.5.15 已实现）

**旧问题**：容器以 root 挂载全部存储卷，等于绕过了飞牛的用户 ACL ——
凡能登录飞牛的用户，打开 `/app/basemetas-fileview/...` 都能预览已挂载卷里的文件。

**现在的做法**：

```
浏览器 → 统一网关（注入 X-Trim-Userid）→ app.sock → nginx 网关容器
    location /app/basemetas-fileview/  →  auth_request /__acl
         /__acl → 闸门容器（python:3-alpine，root）
                    fork → setgroups(按 /etc/group 算) → setgid → setuid(uid)
                    → os.access(path, R_OK) → 200 / 403
    → FileView 引擎容器
```

### 已默认开启（0.5.17 起）

**不需要任何设置**。装上就生效：只有对该文件有读权限的人才能预览，否则 403。

- 团队文件、共享文件按你在飞牛里设的权限正常放行；
- 判定读的是飞牛的 ACL，不是 POSIX 模式位（实测：模式位是 `0000` 但 ACL 允许读的文件，会正确判为可读）；
- 静态资源（css/js/图片）不参与判定，避免噪音。

**先确认身份头能到**（需要登录态，用浏览器打开）：

```
https://<你的域名>/app/basemetas-fileview/__whoami
→ 应显示 uid=<uid> | user=<用户名> | isadmin=true
```

看不到 `uid=…` 说明网关没传身份头，此时闸门不生效（但也不会拦你）。

**看判定过程**：`docker logs basemetas-fileview-acl`

### 出现误拦怎么办

设置界面里**没有**开关（不需要），应急开关在应用数据目录的一个文件里：

```bash
# /vol{n}/@appdata/basemetas-fileview/acl.conf
mode=enforce   →   mode=log      # 退回「只记录不拦截」
```

改完**立即生效**，不用重启容器、不用重装。应用只在文件不存在时写默认值，
**不会覆盖手工改动**，所以这个应急设置会留住。定位好问题后改回 `enforce` 即可。

### 为什么不是简单的 `docker exec -u <uid> … test -r`

`docker exec -u` **不会设置用户的附加组**。飞牛的「共享给设备内的用户」是按**用户**授权
（uid 能覆盖），但**团队文件是按用户组授权**的 —— 那样会被误判成不可读，
而**误拦会挡掉合法访问，是危险方向**。所以闸门 fork 子进程后按 `/etc/group`
设好 `setgroups → setgid → setuid` 再判定，完整还原该用户的权限上下文。

### 两道安全网

- **闸门只在「确定不可读」时拒绝**：缺 uid、解析不到路径、查不到用户、判定异常
  → 一律放行并记日志。
- **闸门不可用时自动 fail-open**：`upstream aclgate` 里挂了本机回环上的「永远 200」服务，
  闸门连不上时 nginx 自动 failover 过去 → 放行。最坏情况只是「没保护」，不会「应用打不开」。

### 已知边界

- `GET /preview/api/file?filePath=/opt/fileview/data/preview/<文件名>.pdf` 带的是**引擎内部转换产物**
  路径，回溯不出原文件。0.5.16 起会**退回用来源页 URL 里的原始 `path` 判定**，正常流程（浏览器从预览页
  发起）能被正确拦下；只有**手工构造、不带来源页**的请求才无法判定（此时 fail-open 放行）。
  要彻底堵死需要闸门记录「哪个 uid 触发过哪个转换」，属后续可选项。
- 用开放 API 的 `trim.file.checkUserACL` 是官方路线，但实测**走不通**
  （应用脚本拿不到 `TRIM_API_TOKEN`，socket 是 `root:root 0660`），故未采用。


### 背景：为什么不用飞牛的开放 API

官方给的路线是 `trim.file.checkUserACL`（后端 API，scope `trim.file.userAcl`），
但实测**走不通**：应用脚本里拿不到 `TRIM_API_TOKEN`，
`/var/run/trim_open_gateway_apiscope.socket` 又是 `root:root 0660`。
生态调研也印证了这一点 —— `grep checkUserACL` 在整个 `@appcenter` 里零使用。

（若将来飞牛开放了 token 注入，可以改用官方接口；那时需要系统 ≥ 1.2.0401、App ≥ 1.34.0。
现在的实现不依赖开放 API，所以 `manifest.os_min_version` 仍是 `1.2.0`。）

### 诊断

```bash
# 1) 确认网关有没有把身份传进来（浏览器打开，需要登录态）
https://<你的域名>/app/basemetas-fileview/__whoami
#    → 应显示 uid=1000 | user=<用户名> | isadmin=true

# 2) 看闸门的判定过程
docker logs basemetas-fileview-acl

# 3) 单独验证某个用户对某个文件的权限（在闸门容器里跑）
docker exec basemetas-fileview-acl python3 /acl/fv-acl-gate.py --test 1001 /vol1/1000/某文件.ofx
#    → 打印该用户的 主组 / 附加组，以及 可读 / 不可读 的结论
```

网关 `access_log` 里也加了 `uid=` / `isadmin=` 两列，日常请求就能看出身份有没有传进来。
`@appdata/basemetas-fileview/fv-volumes.log` 里还留着启动时的开放 API 预检结果
（token / socket / 已授权目录），将来若要改走官方路线可以拿它当参考。

## 重新打包

```bash
# 飞牛 NAS / Linux
cd fpk
curl -L -o tools/fnpack https://static2.fnnas.com/fnpack/fnpack-1.2.3-linux-amd64
chmod +x tools/fnpack build.sh
./build.sh

# Windows（tools/fnpack.exe 已附带）
build.bat
```

产物落在 `fpk` 上层目录：`basemetas-fileview.fpk`。打包工具是飞牛官方 `fnpack` 1.2.3。**打包后不要对 `.fpk` 做任何后处理**（包内 manifest 含 `app.tgz` 的 MD5 校验，飞牛安装时做完整性校验）。

两个脚本都会先跑一遍**行尾检查**（`fpk/tools/check_eol.sh`），`basemetas-fileview/` 下只要出现 CRLF 就中止打包：

> ⚠️ 为什么必须有这道检查：Windows 上 `core.autocrlf=true` 时，Git 提交会把 CRLF 归一成 LF **存进仓库**，但**工作区里的文件仍然是 CRLF** —— 而 `fnpack` 打的正是工作区。于是 `git status` 一片干净，`.fpk` 里却混进了 CRLF 的 shell 脚本：轻则 shebang 变成 `#!/bin/bash\r` 直接起不来，重则变量值末尾多一个 `\r`，让 `docker rm -f "$PROJ-engine"` 之类**静默失败**（0.5.21 修的正是这个）。
>
> 单独跑：`bash fpk/tools/check_eol.sh`

## 更新

**就地升级**：改完配置或代码后，把 `manifest` 的 `version` 末位 +1、重新打包，然后在应用中心「手动安装」新版 `.fpk` 即可 —— **不需要先卸载**（飞牛靠版本号递增判断升级安装，走包里的 `cmd/upgrade_init` / `cmd/upgrade_callback`）。

> ⚠️ 飞牛应用设置里的「自动更新应用」开关**对本应用无效**：它只对**应用中心上架**的应用做更新检查，手动安装的第三方包飞牛不知道去哪里查新版本。
>
> 本仓库早期自带过一套「自建发布点 + 计划任务」的自动更新方案（`自动更新/`：`version.txt` + `.fpk` + `appcenter-cli install-fpk --env`）。0.5.19 起移除，原因：
>
> 1. 它有两个行为**始终没在真机验证过**（`appcenter-cli list` 的输出格式、`install-fpk` 对已安装应用是走升级还是报错）；
> 2. 它原本要解决的主要痛点「每次更新都得先卸载」**早已由版本号规则解决**（见上），剩下的收益只是省掉"下载 + 手动安装"两步。
>
> 需要时可以随时从 git 历史取回：
>
> ```bash
> git show ebd4015:自动更新/auto-update.sh > auto-update.sh
> git show ebd4015:自动更新/README.md      > 自动更新-手册.md
> ```

### 版本号规则

`manifest` 的 `version` 与引擎镜像 tag **解耦**，当前为 `0.5.22`（对应引擎 `1.5.2`）：

| 包版本 | 对应引擎 | 用途 |
|---|---|---|
| 0.5.x | 1.5.2 | 只改配置/图标/nginx，末位 +1 |
| 0.6.0 | 1.6.0 | 升级引擎镜像时跟着抬 |

飞牛靠版本号**递增**判断升级安装；同版本不允许覆盖安装。

## 更新说明

各版本的改动详见 [CHANGELOG.md](CHANGELOG.md)。最近几个版本：

| 版本 | 要点 |
|---|---|
| **0.5.22** | 挂出引擎的工作目录与日志（此前落在容器可写层，升级就丢）；关掉网络文件预览（SSRF 入口，且绕过权限闸门） |
| **0.5.21** | 修 `cmd/uninstall_*` 的 CRLF 行尾（此前以 CRLF 打进包，卸载清理动作静默失效）；新增打包前行尾强制检查 |
| **0.5.20** | 放开单文件预览大小上限，默认 **1 GB**（引擎自带 100 MB 闸门，超过就提示「文件转换失败 413」），可在设置里调整 |
| **0.5.19** | 去掉应用设置里没意义的「访问权限」标签页 |
| **0.5.17** | **按用户区分预览权限**（默认开启）：只有对该文件有读权限的人才能预览，没有权限返回 403。另修：新加的存储卷永远预览不了、点「停用」报 Request failed、升级覆盖挂载段 |
| **0.5.15** | 新增逐用户权限校验闸门（不依赖官方开放 API） |
| **0.5.8** | 修复「某个盘（如 `/vol3`）报文件不存在」—— 根因是**应用用户没有 docker 权限**，所有 docker 操作静默失败、容器从安装起就没被重建过 |
| 0.5.7 | 修复卸载失败 |
| 0.5.6 | 修复网关容器无限重启；存储卷默认 `auto` |
| 0.5.5 | 修复 Excel / CSV 打开后无限转圈 |
| 0.5.4 | 支持自定义字体 |
| 0.5.3 | 入口精简为只保留「用 FileView 打开」 |
| 0.5.2 | 首个可安装版本 |

## 已知限制

- **Excel / CSV 首次打开需强制刷新一次**：上游 FileView 前端取文件时用了 `credentials: 'omit'`，在带鉴权的网关下会取不到文件。本包已在网关层用 `sub_filter` 改写回默认行为，但该 JS 带 hash 被浏览器缓存，需强刷（`Ctrl+F5`）一次后生效。
- 大图纸（几十 MB 的 DWG）渲染性能官方无指标，建议实测。
- 扩展名列表受约 500 字符上限约束，无法全量注册。