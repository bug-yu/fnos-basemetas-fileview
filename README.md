# 飞牛 fnOS 原生 .fpk 安装 BaseMetas FileView

把 [BaseMetas FileView](https://fileview.basemetas.cn/)（开源在线文件预览引擎）打包成飞牛 fnOS 的原生 `.fpk` 应用，通过**统一网关**接入，并接管文件管理器的「打开方式」右键菜单。

## 为什么用它：**只读预览，不会误改文件**

飞牛自带的「Office 预览」基于 **OnlyOffice** —— 它带**编辑功能，修改会自动保存**。
对于"只是想看一眼"的场景，这其实是个风险：**很容易在不知情的情况下改动文件**
（尤其快速翻看、批量预览的时候）。

**本应用是预览引擎，不是编辑器**，定位完全不同：

| | 飞牛自带「Office 预览」 | 本应用（BaseMetas FileView） |
|---|---|---|
| 定位 | 在线**编辑**（OnlyOffice） | **纯预览** |
| 会不会改到文件 | 带编辑 + **修改自动保存** | **不会** —— 存储卷一律 `:ro` **只读**挂载，引擎**物理上无法写回**源文件 |
| 格式覆盖 | Office 文档 | **59 种** —— OFD 版式、压缩包、三维模型、Visio、思维导图、PSD…（CAD 图纸见下） |
| 权限 | —— | 按飞牛 ACL **逐用户**判定，没读权限直接 403 |

> **一句话**：**要改文件，用官方的 Office 预览；只是想看，用 FileView。**

两者**可以并存** —— 它们注册的扩展名有重叠（`doc` / `xls` / `ppt` 那几类），
谁当默认由你在「应用设置 → 打开方式」里决定。
**如果你也担心误改，把 Office 那几类也指给 FileView 就行。**

## ⚠️ CAD 图纸（DWG/DXF）**已移出本应用** —— 请装独立应用「CAD 查看器」

> **0.5.58 起，本应用不再处理 `dwg` / `dxf`。** 右键菜单里也不会再出现本应用。
> 要预览 CAD 图纸，请到应用中心安装**独立的飞牛应用**：
>
> ### 👉 [**fnos-cadviewer**](https://github.com/bug-yu/fnos-cadviewer) · [下载最新版](https://github.com/bug-yu/fnos-cadviewer/releases/latest)

独立应用做得比这里原来那份**更多**：

| | 本应用内嵌的版本（≤ 0.5.57） | 独立应用 fnos-cadviewer |
|---|---|---|
| 文件管理器右键预览 | ✅ 简易查看器 | ✅ 简易查看器 |
| **桌面图标** | ❌ 没有 | ✅ **完整版**（菜单 / 功能区 / 命令行 / 状态栏） |
| 打开 NAS 上的图纸 | ✅ | ✅ 走官方 `pickUserFile` / `openAppAuth` 授权 |
| 打开本地文件 | ✅ | ✅ |
| 字体 | 同一套（86 SHX + 12 woff / 2 ttf） | 同一套（共 101 个文件） |
| 安装包体积 | 让本应用涨到 **54.6 MB** | 它自己 **55.7 MB**，本应用回到 **~231 KB** |

> 「86 个 SHX」与「101 个字体文件」是**同一套字体**的两种数法 ——
> `mlightcad/cad-data` 里就是 86 个 `.shx` + 12 个 `.woff` + 2 个 `.ttf` + 1 个索引 = 101 个文件。
> 独立应用**没有**多打包字体，多出来的是**桌面图标那个完整版界面**（菜单 / 功能区 / 命令行）。

### 为什么移出

1. **体积**：CAD 页要带字体（54 MB）+ LibreDWG WASM（9.5 MB）。
   内嵌进来 → 本应用的包从 **231 KB 涨到 54.6 MB（×236）** ✗ ——
   而这 55 MB **只为 dwg/dxf 两个格式服务**，却要**所有用户**都下载。
2. **职责**：本应用是「全格式预览」，CAD 是其中一个专业子集 ——
   两者的依赖栈（Vue 3 / element-plus / LibreDWG）、发版节奏、
   许可（LibreDWG 是 **GPL-3.0**）都不一样。
3. **避免打两份**：两个应用各内置一份 cad-viewer 的话，
   字体与 WASM 要打两遍，而且两份会各自漂版本。

### 想看原来的实现？

在本仓库的 git 历史里：

```bash
git log --oneline -- fpk/cad-viewer | head
git show <最后一个包含它的提交>:fpk/cad-viewer/build.py
```

> ℹ️ 移出时**顺手删掉了一个多余的能力**：内嵌 CAD 页曾需要一条
> `/cad/api/raw`（把**文件字节**直接交给页面）。它是闸门里唯一
> 「交出字节」的接口（比「放行/拒绝」更强），既然唯一使用者没了，
> 就把它连同路径收敛函数一起**收回** —— 少一个攻击面 ✓（详见 SECURITY.md）

## 特性

- **`.fpk` 原生安装** —— 应用中心「手动安装」上传即完成，带安装向导、启动/停止/设置，与飞牛自带「Office 预览」同一形态。
- **统一网关接入** —— 不占用独立端口，复用系统访问域名（`/app/basemetas-fileview`），且网关会**先校验飞牛登录态**再转发。
- **接管文件打开方式** —— 文件管理器右键出现「用 FileView 打开」，覆盖 **59 种**飞牛没有原生能力的格式（OFD 版式、三维模型、压缩包、Visio、思维导图、PSD 等）。打开方式可选：**在飞牛桌面窗口内**（默认）或**在浏览器标签页**，安装时二选一。⚠️ `dwg` / `dxf` 已移出，改由独立应用 [fnos-cadviewer](https://github.com/bug-yu/fnos-cadviewer) 承接。
- **只读挂载** —— 存储卷一律 `:ro`，预览不会改动 NAS 里的任何文件。

## 目录结构

| 路径 | 说明 |
|---|---|
| `basemetas-fileview.fpk` | 安装包 —— **构建产物，不在仓库里**（`.gitignore` 排除）。用 `fpk/build.sh` 或 `build.bat` 现场生成，或从 [Releases](../../releases) 下载 |
| `fpk/basemetas-fileview/` | 安装包工程源码（改配置改这里） |
| `fpk/build.bat` / `fpk/build.sh` | Windows / Linux 重新打包脚本 |
| `fpk/tools/` | 生成脚本与自检工具（`build_variants.py`、`gen_filetypes.py`、`gen_icons.py`、`check_nginx_conf.py`、`check_nginx_map.py`、`test_acl_decide.py`、`test_welcome_redirect.py`、`verify_fpk.py`、`check_eol.sh`、`selfcheck.sh`） |
| `fpk/tools/assets/` | 图标素材：`fileview-logo.png`（BaseMetas FileView 官网 logo）。`gen_icons.py` 用它一次生成 4 个图标文件 |
| `fpk/cad-viewer/README.md` | ⚠️ **只有一份指路牌** —— CAD 预览页（DWG/DXF）已于 0.5.58 移出，改由独立应用 [fnos-cadviewer](https://github.com/bug-yu/fnos-cadviewer) 承接。原来的源码/构建脚本见 git 历史 |
| `tools/fv-repair.sh` | NAS 上一键修复脚本（存储卷 / 网关重启故障） |
| `tools/fv-doctor.sh` | NAS 上一键**诊断**脚本（只读，定位「某个盘预览不了」卡在哪一环） |
| `tools/fv-uninstall-fix.sh` | NAS 上一键修复「卸载报 Request failed」的卡死状态 |
| `tools/fv-acl-check.sh` | NAS 上验证「按用户判定文件权限」是否可行（含对照组，只读） |
| `CHANGELOG.md` | 版本更新说明 |

> `.fpk` 里装的是「怎么跑」而不是「跑什么」：预览引擎镜像 `basemetas/fileview:1.5.2`（约 863 MB）在**安装时**从 Docker Hub 拉取，不在包内。这也是飞牛官方 Docker 应用的标准形态。

## 安装

Release 里提供**两个包**，功能完全一样，只差「打开方式」这一个设置 —— 按需选一个下载：

> **Release 页保留阶段性的版本** —— 除了最新版，还会留几个**里程碑**，
> 方便回退到某个阶段（例如「换 CAD 渲染器之前」的那一版）。
> 每个版本的说明都取自本仓库的 [CHANGELOG.md](CHANGELOG.md)。

| 包 | 打开方式 | 什么时候选它 |
|---|---|---|
| `basemetas-fileview-<版本>-desktop.fpk` | `iframe` | 右键「用 FileView 打开」**在飞牛桌面窗口内**打开预览页。默认推荐 —— 与飞牛自带「Office 预览」同一形态，不跳浏览器、不占标签页 |
| `basemetas-fileview-<版本>-browser.fpk` | `url` | 同样从右键菜单进入，但在**浏览器新标签页**打开。想要完整浏览器能力（书签、多标签、插件），或桌面窗口里显示不正常时选它 |

> ⚠️ **两个包的版本号相同**，而飞牛**不允许同版本覆盖安装** —— 想换成另一种打开方式，
> 得先在应用中心**卸载**、再装另一个包（卸载不会删引擎镜像，重装很快）。
> 除「打开方式」外，两者完全一致：同样的统一网关接入、逐用户权限闸门、只读挂载、61 种扩展名。

1. 应用中心 → 左下角「**手动安装**」→ 上传你选的那个 `.fpk`
2. 安装向导的「允许预览的存储卷」保持默认 `auto` 即可（自动挂载本机全部 `/volN`）
3. 装完自动启动。文件管理器右键文件 → 「**用 FileView 打开**」

首次安装需拉取镜像，**耗时几分钟**；国内直连 Docker Hub 较慢，建议先配置镜像加速。卸载不会删除镜像，重装时直接复用。

### 更新

改配置后**重新打包**（见下），再升级安装。0.5.8 起**可以就地升级**（版本号递增即可，不必先卸载）；若走「卸载 → 重新手动安装」也一样安全（镜像复用，重装很快）。若仅临时改 `nginx.conf`，也可直接在「管理员视角」下编辑 `@appcenter/basemetas-fileview/docker/nginx.conf` 后重启网关容器，不必重装。

## 支持的文件类型

飞牛把入口的扩展名列表写进一个**限长约 500 字符**的数据库列，超长会导致安装被数据库拒绝（界面只报「服务异常」）。因此「全量接管」物理上做不到，只能在额度内取舍。当前注册 **59 个扩展名（约 247 字符）**：

| 分类 | 扩展名 |
|---|---|
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

只保留一个入口 `basemetas-fileview.view`（文件打开方式，`type: iframe`，**在飞牛桌面窗口内打开**），桌面不显示。飞牛在打开文件时会在入口 `url` 后自动追加 `?path=<绝对路径>`，因此入口 `url` 必须保留。

> **打开方式：桌面窗口内嵌（0.5.26 起）**。官文对入口 `type` 的定义是 ——
> `iframe` = 在飞牛 fnOS 桌面窗口内打开；`url` = 在浏览器标签页或外部 Web 视图中打开。
> 本入口 0.5.26 起用 `iframe`：右键「用 FileView 打开」直接在飞牛桌面里打开预览页，
> 不再新开浏览器标签页（与飞牛自带「Office 预览」同形态）。
> `noDisplay: true` 保持不变 —— 入口只出现在文件右键菜单，不占桌面图标。
> 这也是官方「注册文件打开方式」示例里的组合（`type: iframe` + `noDisplay: true`）。
>
> 两种打开方式**在安装时二选一**（见上面的[安装](#安装)）：源码里存的是 `iframe`（desktop 版），
> `url`（browser 版）由 `fpk/tools/build_variants.py` 在打包时改这一个字段派生出来。
> 做成两个包而不是运行时开关，是因为入口配置只在**安装时**读取、且飞牛不允许同版本覆盖安装。
>
> **应用中心点「打开」会落到欢迎页（0.5.27 起）**。那个按钮走 `desktop_applaunchname` 指向的入口，
> 也就是入口 `url`（`/preview/view`），但**不带 `?path=`** —— 那是右键打开文件时才由飞牛追加的。
> SPA 没有文件路径可渲染，所以原本是一片空白（看起来像部署失败，其实引擎好得很）。
> 现在网关把「URI 正好是 `/preview/view` 且 `path` 为空」的请求 302 到 `/preview/welcome`，
> 顺便当**部署自检**：能打开就说明网关 → 容器 → 引擎这条链路是通的。
> 判定逻辑见 `app/docker/nginx.conf` 里的 `map $fv_view_needs_welcome`，
> 边界由 `fpk/tools/test_welcome_redirect.py` 的 12 条矩阵钉住（带 `?path=` 的预览不会被误转）。
>
> **重定向发的是「相对」地址（0.5.28 起）**：`server` 块里关掉了 `absolute_redirect`。
> 它的默认值 `on` 会把 `return 302` 的 Location 拼成**绝对地址**，而本服务监听的是
> unix socket（没有端口）、飞牛统一网关又把外部端口从 Host 里去掉了 ——
> 于是非标准端口访问时重定向会把端口弄丢（`https://域名:8443/...` → `https://域名/...`，
> 页面直接打不开）。改成相对 Location 后，浏览器用自己的 origin 解析，端口自然保留。
> `selfcheck.sh` 里有断言盯着这一行，别删。

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

> **关于「访问端口 / 访问路径 / 自定义 URL」这三行**（0.5.54 起**已隐藏**）：
> 它们由入口的 `control` 控制，入口地址由统一网关的 `gatewayPrefix` / `gatewaySocket` 决定、
> 用户**不应该**去改（改错了预览打不开）。所以本应用把它们**隐藏**了：
>
> ```json
> "control": {
>   "accessPerm": "readonly",      // 官方文档有记载：可查看不可编辑（让「桌面访问」变灰）
>   "portPerm": "hidden",          // ⚠️ 官方文档**没有**记载，但实际生效
>   "pathPerm": "hidden",          // ⚠️ 同上
>   "fullUrlPerm": "hidden"        // ⚠️ 同上
> }
> ```
>
> ⚠️ **不要用 `accessPerm: "hidden"`** —— 那会把**整个入口**一起隐藏（实测过）。
> 后三个字段是**照着已发布的第三方应用**（`fygo-browser`）的 `ui/config` 抄来的 ——
> 官方文档只记录公开字段，"官文没写" ≠ "做不到"。

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
Word / Excel / PPT / OFD 需要服务端转换，上限过大时预览大文件会明显吃 CPU 和内存，
请按 NAS 的内存情况取舍。

> **引擎其实有「两道独立」的体积闸门**（0.5.54 起两道都可设置）：
>
> | 闸门 | 引擎配置键 | 本应用开关 | 默认 |
> |---|---|---|---|
> | 单文件预览上限 | `fileview.preview.storage.max-file-size-mb` | 「单文件预览大小上限（MB）」 | 1024 MB |
> | **压缩包内单个文件** | `fileview.archive.max-file-size` | 「压缩包内单个文件上限（MB）」 | 100 MB |
>
> 上面这个开关**管不到第二道** —— 「**压缩包能打开、但里面某个大文件点不开**」撞的就是它。
> 第二道现在也能在向导 / 应用设置里调了。
> ⚠️ 注意后者的引擎键**单位是字节**（不是 MB）：向导按 MB 填，脚本换算后写入环境变量
> `FILEVIEW_ARCHIVE_MAXFILESIZE`。

### 存储卷

FileView 需以**同名同路径**只读挂载存储卷（`/vol1:/vol1:ro`），否则容器内找不到飞牛传来的绝对路径。

安装向导 / 应用「设置」里的 `wizard_volumes`：

| 填什么 | 效果 |
|---|---|
| `auto`（默认） | 自动探测并挂载本机**全部** `/volN`，以 `/proc/mounts` 为准 |
| `/vol1,/vol2` | 只挂载指定的卷 |

保存后**会自动重建容器**使挂载生效，不必手动重启应用。以后新增了硬盘，把设置改回 `auto` 保存一次即可纳入。

> 注意：bind 挂载在容器创建时确定，只改配置不重建容器是**不会**生效的（`docker restart` 也不行）。这就是 0.5.6 之前「设置里明明有 `/vol3`，预览还是报文件不存在」的原因。

> ⚠️ **升级会顶掉挂载段**：升级时框架把新的 `app.tgz` 重新释放到 `${TRIM_APPDEST}`，`docker/docker-compose.yaml` 会被覆盖回安装包模板里写死的 `/vol1`、`/vol2`。所以任何「释放文件」之后的时机都必须重写一遍挂载段 —— 承担这件事的是 `cmd/upgrade_callback`（**升级后不必再去设置里保存一次**）。
>
> 📌 **`cmd/main start` 里也有同样的同步逻辑，但它其实跑不到**：实测（0.5.30）**框架启停应用时不调用 `cmd/main`**，而是自己走 compose —— `appcenter-cli stop` + `start` 之后 `${TRIM_PKGVAR}/fv-volumes.log` **一条新记录都没有**（而那段逻辑一旦执行必然写日志）。框架真正会调用的只有 `status`（会被轮询）。
> 所以「启动时自愈 / 启动时预检」这个时机**目前没有覆盖**；自愈实际发生在**升级**与**保存设置**两个时机。详见 [SECURITY.md](SECURITY.md) §4 待办 5。

向导里填的值会持久化到 `${TRIM_PKGVAR}/volumes.conf`，升级/重启时按「本次向导值 → 上次保存的设置 → `auto`」的顺序取值；同步结果记在 `${TRIM_PKGVAR}/fv-volumes.log`。

> 💡 **为什么探测要取并集（0.5.8 修的那个 bug）**：存储卷不一定都是独立挂载点。
> 有些机器上：`/vol1`、`/vol2` 在 `/proc/mounts` 里是独立挂载点，`/vol3` 却只是个目录。
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
bash tools/fv-doctor.sh --file /vol3/某文件.pdf    # 顺带检查某个具体文件能不能读
```

### 自定义字体

预览服务只内置免费的中文思源字体和部分英文字体，不含需授权商用的字体（仿宋、宋体、微软雅黑等）。本包已把字体目录挂到应用数据目录（卸载/升级不丢）：

```yaml
- "${TRIM_PKGVAR}/fonts:/usr/local/share/fonts:ro"
```

把字体文件放进 `/vol{n}/@appdata/basemetas-fileview/fonts/` 后重启引擎容器即可。

> 请使用正规渠道取得授权的字体。思源系列（已内置）开源可商用；从 Windows 直接拷贝宋体/微软雅黑属授权灰色地带。
> （CAD 图纸走的是浏览器端 SHX 字体，与本目录无关 —— 而且 0.5.58 起 CAD 已移出本应用，
> 见 [独立应用 fnos-cadviewer](https://github.com/bug-yu/fnos-cadviewer)。）

### 数据与日志目录

引擎的**工作目录**和**日志**都挂到了应用数据目录（`${TRIM_PKGVAR}`，即 `/vol{n}/@appdata/basemetas-fileview/`）：

```yaml
- "${TRIM_PKGVAR}/data:/opt/fileview/data"    # 转换产物、解压临时文件、LibreOffice 工作目录（引擎内部还有 cad2x 目录，本应用已不用 CAD）
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
> 目录权限是 `0700`，只给 root。引擎容器**以 `uid=0(root)` 运行**（可用 `docker exec basemetas-fileview-engine id` 确认），root 无视权限位，所以不影响引擎读写；收紧是为了挡住本地其它非 root 用户 —— `data`/`logs` 里会出现**转换产物**（含被预览文件的内容片段）与日志，不是纯公开数据。

### PDF 工具栏 / Excel 缩放 / 表格触摸滚动（三个「功能缺失」的真相）

| 现象 | 真相 |
|---|---|
| **PDF 预览没有工具栏**（不能旋转、双页、全屏、搜索，也没有浮动缩放） | 上游 `utils/device.ts` 把**带触摸的电脑**误判成 iPad —— `isPadFun()` 最后一行兜底是「屏幕短边 ≥ 600 就算 Pad」，触屏笔记本 / 接了触屏显示器的台式机正好一路走到那里。于是 `isMobile = true`，而工具栏每个按钮和浮动缩放控件都写着 `!isMobile`，全被隐藏。**0.5.23 已修** |
| **Excel 不能缩放** | 上游给 `luckysheet.create` 传了 `showstatisticBar: false`，把统计栏整条藏了 —— 而缩放滑杆就在统计栏里。**0.5.24 已修**（补上 Luckysheet 自带的细粒度开关，只放出「缩放」这一项，求和/视图仍隐藏） |
| **平板在飞牛 App 里 Excel 滑不动**（浏览器里正常、插鼠标滚轮也正常） | Luckysheet 的滚动由它**自己实现**、只接 `wheel`；手指滑动走的是**页面滚动**。浏览器里页面本身可滚（内容比视口高），滑起来像"表格在滚"；App 的 webview 视口固定、页面不可滚 → 手指滑没有可滚对象。**0.5.50 已修**（见下） |

**先确认是不是那个原因**：打开

```
<域名>/app/basemetas-fileview/preview/debug
```

看这四个标志（上游自己留的调试页，闸门对这个路径是放行的）。`isMobile: true` 就是它 —— 正常情况下电脑上应该是 `false`。

**0.5.23 的补丁怎么工作**：往 SPA 页面注入一小段脚本，把 `navigator.maxTouchPoints` 归零
（`isPhoneFun()` 有 `maxTouchPoints <= 0 → false`、`isPadFun()` 有 `<= 1 → false`，归零后两个都返回 false），
**但只在非移动端 UA 上做**：

| 设备 | 补丁 | `isMobile` |
|---|---|---|
| 电脑（含触屏笔记本、接了触屏显示器的台式机） | 生效 | `false` → 恢复桌面工具栏 |
| iPad / iPhone / Android 平板与手机 | **不生效** | `true` → 保持上游的移动端布局 |

> 为什么不能对所有设备一律归零：那会连带禁用它们的触摸手势 —— 平板上连触摸滚动 PDF 都会失效。

> ⚠️ 这是**改上游运行时的临时措施**，实现在 `app/docker/nginx.conf` 里的
> `location ~ ^/app/basemetas-fileview/preview/(index\.html|[^.]*)$`。
> 上游修好 `device.ts` 之后应该把整段删掉。升级引擎镜像后补丁可能失效 ——
> **表现是工具栏又没了，不会报错**，用上面那个 debug 页一看就知道。
> 想手动关掉：注释掉那个 location 即可（不影响旁边 JS 改写那个 location）。

**0.5.24 的 Excel 缩放补丁怎么工作**：Luckysheet 本身支持**细粒度**开关
`showstatisticBarConfig`，而上游没传它。补丁在浏览器端包了一层 `luckysheet.create`，补上：

```js
showstatisticBar: true,
showstatisticBarConfig: { count: false, view: false, zoom: true }
```

结果：底部只出现缩放滑杆，求和（`count`）与视图（`view`）保持隐藏。Luckysheet 的逻辑是
「三个子项全关才把统计栏整条藏掉」，我们留了 `zoom`，所以它还会正确计算
`statisticBarHeight`，表格不会错位。

实现在 `app/docker/fv-web-patch.js`，由上面那个 location 以 `<script src>` 注入。
用的是「拦截 `window.luckysheet` 赋值」而不是轮询 —— luckysheet 是动态 `loadJS` 加载的，
加载完紧接着就调 `create`，轮询来不及。

**0.5.50 / 0.5.50 的表格触摸滚动怎么工作**：Luckysheet 只接 `wheel` 事件做内部滚动，
手指滑动走的是页面滚动。补丁分两级：

**★ 首选（0.5.50）：直接驱动它的滚动位置 —— 跟手。**
Luckysheet 的滚动状态存在**真实 DOM** 上（`#luckysheet-scrollbar-y` 的 `scrollTop`、
`#luckysheet-scrollbar-x` 的 `scrollLeft`，它源码里就是这么读写的）。所以：

- `touchstart` 记住手指起点 + 当时的滚动位置
- `touchmove` 按「**距起点的绝对位移**」回写（不是逐帧累加，避免漂移）

> ⚠️ **为什么不能靠伪造 `wheel`**（0.5.50 第一版就是这么做的，手感是"一格一格跳"）：
> Luckysheet 的 wheel 处理器是**固定步进** ——
> `scrollNum = deltaFactor<40?1:deltaFactor<80?2:3; scrollTop += 10*scrollNum`，
> **完全不看 `deltaY` 的绝对值**，还会按行边界吸附。所以调 delta 大小没用。

**○ 兜底**：万一上游改版拿不到那两个滚动条元素，退回伪造 `wheel` —— 至少能滚，只是不跟手。

**顺滑（0.5.50）**：拖动**只更新目标位置**，由 `requestAnimationFrame` 统一回写
→ **每帧最多重绘一次**（原来每个 `touchmove` 都写，一帧内会重绘多次 → 抖）。
松手后按最后的速度**继续滑行**并指数衰减；**手指一碰立即停住惯性**（与原生一致）。

**两个生效条件（缺一不可）**：

| 条件 | 为什么 |
|---|---|
| **页面本身不可滚**（`scrollingElement.scrollHeight <= innerHeight + 1`） | 页面能滚时交给浏览器 → **浏览器里行为完全不变**，不会双滚动 |
| **手指落在 Luckysheet 区域内**（`closest('[id^="luckysheet"]')`） | 否则可能与 PDF.js 自己的触摸平移**叠加成双滚动**（PDF 本来是好的） |

纵向、横向都处理（表格很宽时要能左右滑）；多指（缩放）一律不干预。

> **判定思路值得记一下**（三个对照一次定位）：
> ① PDF 在 App 里手指**能**滚 → webview 触摸是好的；
> ② Excel 里手指**能选中单元格** → 触摸确实到达了 Luckysheet；
> ③ 鼠标滚轮两边都能滚 → 渲染器的 wheel 通路正常。
> 三条合起来只剩一个解释：**触摸事件到了，但"滚动"这条路径依赖页面可滚。**

**Ctrl + 滚轮缩放工作表（0.5.50）**：Luckysheet **自带**这个功能
（`controllers/zoom.js` 里 `ZOOM_WHEEL_STEP = 0.02`，绑在 `document` 上、`capture: true`），
但它的监听是在 **`zoomInitial()`** 里绑的 —— 而本应用这套集成里那个初始化**不一定被调用**
（缩放滑杆的点击事件也是同一个函数绑的，所以**滑杆很可能也是死的**，可以顺手验证一下）。
所以补丁**自己绑一份**（`window` 的 capture 阶段，比上游那份更早），
直接调公开 API `luckysheet.setSheetZoom(ratio)`：按 `deltaY` 缩放（一个滚轮刻度约 ±0.05）、
clamp 到 `0.1~4`，并 `preventDefault()` 挡住浏览器 / 应用外壳自己的缩放。

> 当前缩放**没有 getter**：首次从缩放标签 `#luckysheet-zoom-ratioText` 的文本懒读一次，
> 之后用自己记的值（**不依赖**上游是否更新标签）。

> **怎么确认补丁还活着**：打开浏览器控制台，应该看到四行 `[fv-patch]` 开头的日志
> （`loaded`、`luckysheet.create 已包装`、`触摸滚动已挂载`、`Ctrl+滚轮缩放已挂载`）。
> 没有就说明补丁失效了（多半是引擎镜像升级后路径变了）。
> 逻辑回归测试：`node fpk/tools/test_web_patch.js`（7 条断言，已接进自检）。
> 想手动关掉：注释掉 `__fv-patch.js` 那个 location，或把注入里的 `<script src=...>` 去掉。

## 安全说明

> 完整的威胁模型、第三方审计报告的逐条核对结论、以及待办清单，见 **[SECURITY.md](SECURITY.md)**。

- ✅ 统一网关先校验登录态，未登录访问被挡在网关层；不对外暴露任何端口。
- ✅ **按用户区分权限（0.5.17 起默认开启）**：飞牛统一网关会把当前登录用户放进 `X-Trim-Userid`，闸门容器据此**以该用户的身份**检查目标文件能否读取，没有读权限就返回 403。
  不需要任何设置。团队文件 / 共享文件按你在飞牛里设的权限正常放行；静态资源不参与判定。
  看判定过程：`docker logs basemetas-fileview-acl`；出现误拦时的应急开关见下面「按用户区分权限」一节。
  **（0.5.25 起）静态资源判定更严**：只有「请求自己没带 `/vol` 路径」的静态资源请求才被直接放行，带 `?filePath=/vol…` 之类的后缀变体（如 `file.css?filePath=/vol1/x.docx`）一律落到正常权限判定，不再有后缀旁路。
- ✅ 存储卷只读挂载，且仅限向导里填写的卷。
- ✅ **引擎镜像锁到 digest（0.5.25 起）**：`basemetas/fileview:1.5.2@sha256:ebcb1dc6…`。标签是可移动的，上游重推同名标签时内容会变而版本号不变；锁 digest 后拉到的永远是同一份内容。
- ✅ **数据目录权限 0700（0.5.25 起）**：`fonts` / `data` / `logs` 只给 root。引擎容器以 `uid=0(root)` 运行，不受影响；收紧是为了挡住本地其它非 root 用户（`data`/`logs` 里含转换产物与日志）。
- ✅ **网络文件预览已关闭（0.5.22 起）**。本应用的入口只做本地路径预览，用不到引擎的「给一个 URL 让它去下载」能力。留着那条路等于开了一个 SSRF：任何能登录飞牛的人都能构造
  `/app/basemetas-fileview/preview/view?url=http://<内网地址>/...` 让引擎去抓内网资源渲染给他看，
  而且这条路径**绕过逐用户权限闸门**（闸门从 `path` / `filePath` 或来源页 query 里取路径，`url=` 请求里没有 `/vol` 路径，走的是「放行」分支）。

  做法是把白名单配成一个永不匹配的域名：`FILEVIEW_NETWORK_SECURITY_TRUSTED_SITES=none.invalid`。
  引擎源码里未配置该值时**默认允许所有域名**（`HttpUtils: if (!hasTrustedSitesConfig()) return true;`）。
  需要恢复网络预览时，把这一行改成你自己的域名（多个用逗号分隔），欢迎页的「查看样例」不受影响（它用的是容器内路径）。
- ✅ **请求体里的路径也纳入判定（0.5.50 起）**：`POST /preview/api/localFile` 这类
  **路径只在请求体里**的接口，改由闸门读请求体取出路径、判完**自己转发**给引擎 ——
  判定路径与实际读取路径必然一致，「合法来源页掩护非法请求体」的绕过已堵上
  （该绕过真机复现过：不带来源页 200、带合法来源页也 200）。
  同时在网关层直接封掉本应用用不到的 `/convert/api/srvFile`（以 root 写）。
  详见「按用户区分权限」一节。
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
- 判定读的是飞牛的 ACL，不是 POSIX 模式位（模式位是 `0000`、但 ACL 允许读的文件会正确判为可读）；
- 静态资源（css/js/图片）不参与判定，避免噪音。

**先确认身份头能到**（需要登录态，用浏览器打开）：

```
https://<你的域名>/app/basemetas-fileview/__whoami
→ 应显示 uid=<uid> | user=<用户名> | isadmin=true
```

看不到 `uid=…` 说明网关没传身份头，此时闸门不生效（但也不会拦你）。

**看判定过程**：`docker logs basemetas-fileview-acl`

### 路径只在请求体里的接口（0.5.50 起，单独一层）

闸门平时是靠 nginx 的 `auth_request` 调用的 —— 但**鉴权子请求在读请求体之前就执行了**，
所以它**物理上看不到 body**（`location = /__acl` 里写着 `proxy_pass_request_body off`）。
平时这不是问题：绝大多数请求把路径放在 **query 串**里（`?path=` / `?filePath=`），
nginx 用 `$arg_*` 就取到了。

问题出在「用 FileView 打开」的**第一步** —— `POST /preview/api/localFile`，
它的路径 `srcRelativePath` 只在**请求体**里。这类接口如果只靠来源页（Referer）判定，会被这样绕过：

```
① 先打开一个**自己有权读**的文件 → 拿到合法的来源页 URL（里面带 ?path=我的文件）
② 再发 POST，请求体里换成**别人的**路径
→ 闸门拿来源页里那个合法路径判定 → 放行；请求体里的非法路径**根本没被看过**
```

这不是推演，**真机已复现**：不带来源页 200、带合法来源页也是 200。

**做法**：这几个接口**不走 `auth_request`**，改由网关把**整个请求**交给闸门：

```
浏览器 → 统一网关 → app.sock → nginx
                                   │  这几个接口 → 闸门容器（读请求体 → 取路径 → 按 uid 判 ACL）
                                   │                  通过 ↓            ↓ 不可读
                                   │              闸门自己转发给引擎     403
                                   └  其余接口 → auth_request → 引擎
```

关键点：**由闸门自己转发** —— 于是「判定的路径」与「引擎实际读的路径」必然是同一个值，
不存在「看得见一份、读的是另一份」的空隙。判定**只用请求体里的路径，绝不退回来源页**。

**fail-open 不变**：闸门不可用时 nginx 的 `error_page` 会直连引擎（最坏是"没保护"，
不会变成"应用打不开"）。

> ⚠️ **改这两条 location 时的硬约束（开发中踩过坑）**：
> 必须是 `location =`（**精确匹配**）。**regex / 命名 / `if` / `limit_except` 里
> `proxy_pass` 不允许带 URI 部分** —— 而这里正需要把 URI 改写成 `/guard`，
> 写进 regex 会让 nginx **启动期 emerg**、网关容器无限重启
> （中间版本就是这么废掉的）。精确匹配不受这条限制，且优先级高于任何 regex。
> 另外 fail-open 必须配 `proxy_intercept_errors on`，否则**上游（闸门）返回的** 502
> 会被直接透传、`error_page` 不触发。
> 这两点都有断言盯着（`selfcheck.sh` + `check_nginx_conf.py`）。

> ⚠️ **改闸门的转发白名单时（0.5.50 踩过坑）**：**必须带上 `Host` 与全套 `X-Forwarded-*`**。
> 引擎的 `RequestAwareBaseUrlProvider` 是**按请求头**推导绝对地址的 —— 少了它们，
> 引擎会拼出 `http://fileview/preview/api/files/...` 这种浏览器打不开的地址。
> **症状很偏**：只有 **PDF** 失败（PDF 渲染器直接用 `localFile` 返回的绝对 URL 取文件），
> 而 ofd / xlsx 等走相对路径的渲染器看起来完全正常 —— **回归测试只测后者会漏掉**。
> `test_body_guard.py` 有 5 条断言盯着这几个头。

**单独回退这一层**：`${TRIM_PKGVAR}/acl.conf` 里加了一行

```
body_guard=enforce   →   body_guard=log      # 只记录、仍然转发，不影响其它判定
```

改完立即生效，不用重启容器。`mode` 与 `body_guard` 是**两个独立开关** ——
只想退回这一层时不要动 `mode`。

### 压缩包内文件：复合路径要还原（0.5.50 起）

引擎把「压缩包内文件」表示成**复合路径**：

```
<压缩包绝对路径>/<包内路径>/<文件名>
```

这个路径**在文件系统上不存在**，所以闸门 `os.access()` 必然判定「不可读」。
0.5.50 引入「绝不退回来源页」之后，包内文件被一律拦死（界面显示「文件转换失败」）
—— 0.5.30 靠来源页判定才没暴露，属于**回归**。

**修法**：闸门把复合路径**还原成压缩包本身**再判 ACL —— 引擎实际读的就是压缩包
（以 root 解包后再转换），所以该判的确实是压缩包的权限。

> ⚠️ **这与「退回来源页」有本质区别**，改这块时别混淆：
> 来源页由客户端完全控制（那才是被绕过的原因）；而还原出的路径
> **必须在文件系统上真实存在**，攻击者无法凭空构造。
> 含 `..` 的路径一律不做还原；压缩包不存在或不可读仍然拒绝。

### fileId 系接口（0.5.50 起）

`/preview/api/files/<fileId>`（含 `/page/N`、`/pages`）这几个接口的请求里**没有文件路径**，
闸门平时判不到。而它们有一个坑：

```
fileId = "preview_" + md5(原始绝对路径)[:16]
```

**fileId 是路径的确定性函数 —— 不具备保密性**（已用两组真机数据离线验算、同时精确命中）。
而引擎的 `serveFile()` 里路径参数是**可选**的：

```java
@RequestParam(required = false) String path
...
filePath = cacheInfo.getOriginalFilePath();     // ← 不给 path 就用缓存的原始路径
```

于是「知道路径 → 算 fileId → `GET /files/<fileId>`（不带参数）」就能拿到**别人的**文件，
而闸门全程看不到任何路径。**前提**是该文件 24h 内被任何人预览过（缓存是热的）——
团队 / 共享文件正好命中。

**0.5.50 的对策**：这几个接口**要求请求自带 `filePath`**。

| 情况 | 处理 |
|---|---|
| 带了 `filePath` | 按该路径正常判 ACL（引擎在有 `path` 时就用它，所以"自己的 filePath + 别人的 fileId"也取不到别人的文件） |
| 没带 `filePath` | 按 `fileid_guard` 处理 |
| 带了但 md5 对不上 | 只记录，仍按该路径正常判 ACL |

**⚠️ `fileid_guard` 出厂默认是 `log`（只记录不拦）—— 这是有意的**：
合法流程里 `/files/{fileId}/page/{n}` 与 `/pages` **没有日志样本**，无法确认它们是否都带
`filePath`；盲切 `enforce` 有误伤风险。

**升级后请按这个节奏做**：

> ✅ **实机观察已完成（2026-10-07，0.5.50）**：跑了一遍全部预览类型（PDF / DWG / xlsx / ofd / 压缩包 ——
> 当时的 DWG 走的是内嵌的 CAD 页；0.5.58 起 CAD 已移出，见上文），
> 闸门日志里**所有** `/preview/api/files/<fileId>` 请求**都带 `filePath`**，
> 且 `grep -E "仅记录|观察"` **一条都没有** → **可以放心切 `enforce`**。

1. 保持 `fileid_guard=log`，跑一遍**全部**预览类型 —— 尤其 **PDF 多页翻页**、Excel、
   压缩包内文件、三维模型。
2. 看日志里有没有合法请求被记：
   ```bash
   docker logs basemetas-fileview-acl | grep fileid_guard
   ```
   **一条都不该有**。
3. 确认干净后切 `enforce`（立即生效，不用重启容器）：
   ```bash
   sed -i 's/^fileid_guard=.*/fileid_guard=enforce/' /vol1/@appdata/basemetas-fileview/acl.conf
   ```
4. 复验：构造「不带 `filePath` 的 `/files/<fileId>`」请求 → 应得 **403**。

### 一个被直接封掉的高危接口（0.5.50 起）

`POST /convert/api/srvFile` —— 本应用用不到，网关层直接 403。

引擎侧它是「以 root 读源文件 → 转换 → 写 `targetPath`」，**没有任何根目录收敛** ——
可覆盖任意可写位置。真机实测该前缀本就 404（未暴露），这里显式封掉，
防止上游改动或路由变化把它暴露出来。

> `POST /preview/api/password/unlock` **不封禁**，而是走上面的闸门代理：
> 它同样把路径放在请求体里（`originalFilePath`）且引擎侧无任何校验（可探测文件是否存在
> 并爆破密码），但加密压缩包的正常解锁流程需要它 —— 走闸门后功能保留、路径先过逐用户校验。

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

### 背景：为什么不用飞牛的开放 API

官方给的路线是 `trim.file.checkUserACL`（后端 API，scope `trim.file.userAcl`），
当前**没有采用**，原因有两层，第二层是 0.5.30 才查清的：

**第一层：拿不到 `TRIM_API_TOKEN`。**

官方《调用方式》写的是「token 由系统在调用应用脚本时自动注入，例如启动 `cmd/main` 等后端脚本时，
系统会把当前可用 token 写入环境变量 `TRIM_API_TOKEN`」，并要求系统 ≥ `1.2.0401`、App ≥ `1.34.0`。
但本机实测的预检结果是**没有**这个变量（`app/docker/fv-acl-probe.sh` 会把结论写进
`${TRIM_PKGVAR}/fv-volumes.log`）。此外 `/var/run/trim_open_gateway_apiscope.socket`
是 `root:root 0660`，应用用户也连不上。

> ✅ **已实机复核（2026-10-06，0.5.30）**：系统版本 `1.2.0701`（≥ `1.2.0401`，
> 预检自己判定为"满足开放 API 要求"）、`api-scope` 已声明（0.5.30 起）、
> socket 可连通（不带 token 实测返回 `{"code":200004,"msg":"Unauthorized"}` HTTP=401，
> 且 socket ACL 里 `group:TrimApiUsers:rw-` 对应用用户可用）——
> **在这种"其他条件全部满足"的情况下，`TRIM_API_TOKEN` 仍然是空的**。
> 所以「拿不到 token」是确证的，不是版本不够导致的，也不是缺 scope 导致的。
> 官方路线在本文所述实现下**暂不可行**。
>
> 保留 `api-scope` 声明的理由见下面第二层：它让预检能在 token 到位时**真正跑通** ③④，
> 而不是在 scope 层就被 403 掉 —— 一旦飞牛在后续版本里补上 token 注入，不需要再改包。
>
> ⚠️ **还有一个"数据缺口"要说明**：官方点名 token 是在**启动 `cmd/main`** 时注入的，
> 而实测（0.5.30）**框架启停应用根本不调用 `cmd/main`**（见上面「升级会顶掉挂载段」那节），
> 所以这个注入时机在本机**从未被执行过** —— 「`cmd/main` 里到底有没有 token」目前仍无数据。
> 也就是说：上面这条结论只覆盖「预检脚本实际跑到的时机（保存设置 / 升级）」，
> 不覆盖官方文档点名的那个时机。若要把这个缺口补上，在 `cmd/main` 里加一行
> token 存在性日志即可（`status` 会被框架轮询）。

**第二层（0.5.25 引入、0.5.30 修复的一个回归）：`api-scope` 被误删了。**

0.5.9 那次提交是**同时**新增 `api-scope` 声明和这个预检脚本的 —— 两者本是一体。
但 0.5.25 的审计把 `api-scope` 判为「未使用」删掉了，而预检脚本从 0.5.9 起就一直在调这三个接口：

| 预检调用的接口 | 需要的 scope |
|---|---|
| `trim.system.getPlatformConfig` | `trim.system.getPlatformConfig` |
| `trim.file.getSharedAccessibleFolders` | `trim.file.sharedAccess` |
| `trim.file.checkUserACL` | `trim.file.userAcl` |

官方《调用方式》：「应用调用开放能力前，**需要在应用包中声明会用到的 Scope**」；
《错误码》：`403` / `code 200003 Forbidden` 的处理建议第一条就是「**检查应用包是否声明了对应 API Scope**」。

后果不是「探针跑不通」这么轻 —— 它会**给出方向错误的结论**：第 ③ 步在 Forbidden 响应里
正则抠不到任何 `/vol` 路径，于是日志打印「**没有解析到授权目录** —— 需要管理员在
「应用设置 → 授权目录」里添加」，把你引去查「管理员授权」，而真因是 scope 没声明。

**0.5.30 已修**：`config/resource` 恢复 `api-scope`；预检脚本新增响应分类
（`fv_api_error_kind`），把 403/401/404 分别判为「缺 scope / token 无效 / 接口或版本问题」，
缺 scope 时直接给出下面这份完整清单，不再猜。`fpk/tools/selfcheck.sh` 加了断言：
**预检脚本调用的每个开放接口，都必须在 `config/resource` 里有对应 scope 声明** —— 防止再被当成「未使用」删掉。

**想真正切到官方路线，必须同时做两件事**（缺一件仍走不通）：

1. `config/resource` 保留 `api-scope` 声明（0.5.30 起已在包里）；
2. `manifest` 的 `disable_authorization_path` 改回 `false` —— 现在是 `true`，
   即「授权目录」页被隐藏，管理员**没有入口**去给应用授权目录，而 `checkUserACL`
   在应用未获授权时一律返回 `readable: false`。

做完后重跑预检，把 `fv-volumes.log` 里 ①~④ 的原文拿出来即可判定。

> 在切过去之前，逐用户权限仍由自建闸门按 `X-Trim-Userid` + 飞牛 ACL 判定
> （见下面「按用户区分权限」）。当前实现不依赖开放 API，所以 `manifest.os_min_version` 仍是 `1.2.0`。


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
`@appdata/basemetas-fileview/fv-volumes.log` 里还留着最近一次开放 API 预检结果
（token / socket / 已授权目录）。预检在**保存设置**与**升级**时执行 ——
注意**不是**「应用启动时」：框架启停应用不调用 `cmd/main`（见上面「升级会顶掉挂载段」那节的说明）。
将来若要改走官方路线，可以拿这份日志当参考。

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

### 打「打开方式」的两个变体

发布时要把 desktop / browser 两个包都产出来：

```bash
python fpk/tools/build_variants.py                 # 两个都打
python fpk/tools/build_variants.py --only browser  # 只打某一个
```

产物落在仓库根目录：`basemetas-fileview-<版本>-desktop.fpk`、`basemetas-fileview-<版本>-browser.fpk`。

脚本把源码**复制到临时目录**、只改入口 `type`、再调 fnpack 打包 —— **全程不动工作区**，
所以中断也不会把 `url` 留在源码里（源码里 `app/ui/config` 永远是 `iframe`）。
打包前同样跑一遍行尾检查（用 Python 二进制读判 `\r\n`，比 shell 里 `grep $'\r'` 可靠）。

> 两个包**只差 `ui/config` 一个文件**（可用文件级 md5 比对确认，别用整包 md5 ——
> 同一个目录重复打包，整包 md5 本来就会变）。

## 更新

**就地升级**：改完配置或代码后，把 `manifest` 的 `version` 末位 +1、重新打包，然后在应用中心「手动安装」新版 `.fpk` 即可 —— **不需要先卸载**（飞牛靠版本号递增判断升级安装，走包里的 `cmd/upgrade_init` / `cmd/upgrade_callback`）。

> ⚠️ 飞牛应用设置里的「自动更新应用」开关**对本应用无效**：它只对**应用中心上架**的应用做更新检查，手动安装的第三方包飞牛不知道去哪里查新版本。想用新版时，重新打包后到应用中心「手动安装」即可（见上）。

### 版本号规则

`manifest` 的 `version` 与引擎镜像 tag **解耦**，当前为 `0.5.55`（对应引擎 `1.5.2`）：

| 包版本 | 对应引擎 | 用途 |
|---|---|---|
| 0.5.x | 1.5.2 | 只改配置/图标/nginx，末位 +1 |
| 0.6.0 | 1.6.0 | 升级引擎镜像时跟着抬 |

飞牛靠版本号**递增**判断升级安装；同版本不允许覆盖安装。

## 更新说明

各版本的改动详见 [CHANGELOG.md](CHANGELOG.md)。最近几个版本：

| 版本 | 要点 |
|---|---|
| **0.5.58** | **CAD 图纸（DWG/DXF）彻底移出本应用** → 独立应用 [fnos-cadviewer](https://github.com/bug-yu/fnos-cadviewer)。删掉入口 `basemetas-fileview.cad`、`fpk/cad-viewer/` 源码与构建脚本、`app/docker/cad/` 资源（约 79 MB）、nginx 的 `/cad/` 与 `/cad/api/raw` 两条 location、闸门的 `/raw` 端点（**顺带收回「交出文件字节」这个能力，少一个攻击面**）。**安装包从 54.6 MB 回到 ~231 KB**。自检改成**反向断言**（这些痕迹必须不存在），防止从旧分支/旧文档带回来 |
| **0.5.57** | 修 **CAD 页取文件报 HTTP 400** —— nginx 的 `$arg_filePath` 是**未解码**的原始值（页面发 `%2Fvol1%2F...`，闸门收到就是 `%2Fvol1...` → 不以 `/vol` 开头 ✗）→ 闸门里**解码一次**（双重编码绕不过去，已加测试）+ 把失败原因显示到界面 |
| **0.5.56** | 修 **0.5.55 打开 CAD 文件时没自动加载**（钩子挂在懒初始化的  里，页面打开时永不触发）→ 挪到 （DOM 就绪即触发）+ 退避重试（worker 竞态）+ 没收到  时显示 URL 参数 |
| **0.5.55** | **DWG/DXF 改用独立的 CAD 预览页**（开源 `mlightcad/cad-viewer`）—— 引擎自带的 cad2x 对**多重引线**、**面域边框**、**字体**还原都不行（真机对比）；新页面用 **LibreDWG** 解析 + **86 个 SHX 字体**，三项都正常。`dwg`/`dxf` 从 FileView 摘出，改由「用 CAD 预览打开」承接。**字体/模板打进包内、不依赖公网 CDN** ✓。新增 `/cad/api/raw` 读原文件，**由闸门自己判 ACL 且 fail-closed** ✓ |
| **0.5.54** | ① 入口设置里「访问端口 / 访问路径 / 自定义 URL」三行**不再显示**（用官文未记载的 `portPerm`/`pathPerm`/`fullUrlPerm` = `hidden`；「桌面访问」保持可选）② **压缩包内单个文件的大小上限可以设置了** —— 引擎有第二道独立闸门 `fileview.archive.max-file-size`（默认 100 MB），此前写死、现在向导可调（单位字节，脚本按 MB 换算）。③ 顺带修 `app/ui/config` 被打成 CRLF |
| **0.5.50** | **安全加固 + 预览体验整合版**。**安全**：堵上「POST body 路径绕过」「fileId 可预测绕过闸门」两个高危，修好随之暴露的「压缩包内文件预览被误拦」，并封掉用不到的 `/convert/api/srvFile`。**体验**：平板在 App 里 Excel **跟手滚动 + 惯性**；**双指缩放对所有格式生效**（表格缩放工作表、Word/PDF 缩放文档）；**Ctrl+滚轮**缩放工作表；**鼠标滚轮**速度恢复正常；**PDF 工具栏始终显示**（可旋转页面）；修 PDF 预览失败 |
| **0.5.30** | 修**开放 API 预检失效** —— 0.5.25 的审计把 `api-scope` 误判成「未使用」删掉了，而预检脚本一直在调那三个接口，缺声明导致请求必然 403，日志还会误报成「没有解析到授权目录」把人引向错误方向。现已恢复声明 + 预检按 403/401/404 分别给出准确结论 + 自检新增「接口必须有对应 scope」断言。另：`nginx` / `python` 基础镜像补 digest 锁；`SECURITY.md` 新增「风险接受声明」一节 |
| **0.5.29** | 换应用图标 —— 改用 **BaseMetas FileView 官方 logo**（原来是通用的蓝色「文件+放大镜」方块，小尺寸下几乎看不出内容） |
| **0.5.28** | 修重定向**丢端口** —— 用非标准端口访问时，应用中心点「打开」会从 `:8443` 跳到没有端口的地址。nginx 默认 `absolute_redirect on` 会把 302 拼成绝对地址，而本服务监听 unix socket（无端口）、网关又把端口从 Host 里去掉了；改为发**相对** Location |
| **0.5.27** | 修应用中心点「打开」是空白页 —— 那个按钮打开的入口 url 不带 `?path=`，SPA 没东西可渲染；现在网关把它转到**欢迎页**（顺带当部署自检） |
| **0.5.26** | 「打开方式」做成**两个变体包，安装时二选一** —— `desktop` 版在飞牛桌面窗口内打开（`type: iframe`）、`browser` 版在浏览器标签页打开（`type: url`）；两包只差入口 `type` 一个字段 |
| **0.5.25** | 安全收紧：权限闸门不再因 URI 后缀是 `.css` / `.png` 就放行（堵住 `file.css?filePath=/vol1/私密.docx` 这类旁路）；引擎镜像锁到 digest；`data` / `logs` / `fonts` 目录权限收到 `0700` |
| **0.5.24** | Excel / CSV 恢复缩放控件（上游把 Luckysheet 统计栏整条藏了，缩放滑杆就在里面） |
| **0.5.23** | 修带触摸的电脑上 PDF 没有工具栏（上游把触屏电脑误判成 iPad）；Excel 不能缩放是上游设计，未改动 |
| **0.5.22** | 挂出引擎的工作目录与日志（此前落在容器可写层，升级就丢）；关掉网络文件预览（SSRF 入口，且绕过权限闸门） |
| **0.5.21** | 修 `cmd/uninstall_*` 的 CRLF 行尾（此前以 CRLF 打进包，卸载清理动作静默失效）；新增打包前行尾强制检查 |
| **0.5.20** | 放开单文件预览大小上限，默认 **1 GB**（引擎自带 100 MB 闸门，超过就提示「文件转换失败 413」），可在设置里调整 |

更早版本（0.5.19 及以前）见 [CHANGELOG.md](CHANGELOG.md)。

## 已知限制

- **Excel / CSV 首次打开需强制刷新一次**：上游 FileView 前端取文件时用了 `credentials: 'omit'`，在带鉴权的网关下会取不到文件。本包已在网关层用 `sub_filter` 改写回默认行为，但该 JS 带 hash 被浏览器缓存，需强刷（`Ctrl+F5`）一次后生效。
- 大图纸（几十 MB 的 DWG）渲染性能官方无指标，建议实际测试 —— 但 0.5.58 起 CAD 已移出本应用，这条请到 [fnos-cadviewer](https://github.com/bug-yu/fnos-cadviewer) 反馈。
- 扩展名列表受约 500 字符上限约束，无法全量注册。