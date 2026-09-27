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
| `basemetas-fileview.fpk` | 可直接安装的安装包（约 45 KB，不含镜像） |
| `fpk/basemetas-fileview/` | 安装包工程源码（改配置改这里） |
| `fpk/build.bat` / `fpk/build.sh` | Windows / Linux 重新打包脚本 |
| `fpk/tools/` | 生成脚本与自检工具（`gen_filetypes.py`、`gen_icons.py`、`check_nginx_conf.py`、`check_nginx_map.py`、`verify_fpk.py`、`selfcheck.sh`） |
| `tools/fv-repair.sh` | NAS 上一键修复脚本（存储卷 / 网关重启故障） |
| `CHANGELOG.md` | 版本更新说明 |
| `自动更新/` | 自动更新方案（脚本 + 向导答案模板 + 操作手册） |

> `.fpk` 里装的是「怎么跑」而不是「跑什么」：预览引擎镜像 `basemetas/fileview:1.5.2`（约 863 MB）在**安装时**从 Docker Hub 拉取，不在包内。这也是飞牛官方 Docker 应用的标准形态。

## 安装

1. 应用中心 → 左下角「**手动安装**」→ 上传 `basemetas-fileview.fpk`
2. 安装向导的「允许预览的存储卷」保持默认 `auto` 即可（自动挂载本机全部 `/volN`）
3. 装完自动启动。文件管理器右键文件 → 「**用 FileView 打开**」

首次安装需拉取镜像，**耗时几分钟**；国内直连 Docker Hub 较慢，建议先配置镜像加速。卸载不会删除镜像，重装时直接复用。

### 更新

改配置后**重新打包**（见下），再升级安装：应用中心 → 卸载 → 重新「手动安装」新版 `.fpk`（镜像复用，重装很快）。若仅临时改 `nginx.conf`，也可直接在「管理员视角」下编辑 `@appcenter/basemetas-fileview/docker/nginx.conf` 后重启网关容器，不必重装。

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

### 两个容器

| 容器 | 镜像 | 作用 |
|---|---|---|
| `basemetas-fileview-engine` | `basemetas/fileview:1.5.2` | 预览引擎 |
| `basemetas-fileview-gateway` | `nginx:alpine` | 监听 `app.sock`，适配引擎，转发 |

两个容器都**不发布宿主机端口**，只能从统一网关进入。网关容器做目录级挂载：

```yaml
- "${TRIM_APPDEST}/docker:/etc/nginx/conf.d:ro"   # 配置目录
- "${TRIM_APPDEST}:/app/target:rw"                # 创建 app.sock
```

## 配置

### 存储卷

FileView 需以**同名同路径**只读挂载存储卷（`/vol1:/vol1:ro`），否则容器内找不到飞牛传来的绝对路径。

安装向导 / 应用「设置」里的 `wizard_volumes`：

| 填什么 | 效果 |
|---|---|
| `auto`（默认） | 自动探测并挂载本机**全部** `/volN`，以 `/proc/mounts` 为准 |
| `/vol1,/vol2` | 只挂载指定的卷 |

保存后**会自动重建容器**使挂载生效，不必手动重启应用。以后新增了硬盘，把设置改回 `auto` 保存一次即可纳入。

> 注意：bind 挂载在容器创建时确定，只改配置不重建容器是**不会**生效的（`docker restart` 也不行）。这就是 0.5.6 之前「设置里明明有 `/vol3`，预览还是报文件不存在」的原因。

### 故障修复

遇到「引擎容器 Up、网关容器 Restarting」或「新加的盘预览不了」，在 NAS 上用 root 执行：

```bash
bash tools/fv-repair.sh
```

脚本会依次做：探测存储卷 → 重写 compose 挂载段 → 清理残留 `app.sock` → 重建容器 → 验证并打印状态；网关仍未起来时会直接把日志打出来。

### 卸载失败（`Request failed`）

如果你之前手动执行过 `docker compose up -d`（没有带 `-p basemetas-fileview`），容器会脱离飞牛的 compose project 管理。此时应用中心卸载按自己的项目名 `down` 找不到工程，就会报 `Request failed`，但 `docker ps` 看容器其实已经没了。

**当前状态修复**：把本仓库的 `tools/fv-uninstall-fix.sh` 拷到 NAS，用 root 执行：

```bash
bash fv-uninstall-fix.sh
```

脚本会按容器名强删、按项目名幂等 down、备份并移除应用目录、重启应用中心服务刷新 UI。

**以后避免**：不要直接 `docker compose up -d`；如必须调试，请用：

```bash
cd /vol1/@appcenter/basemetas-fileview/docker
docker compose -p basemetas-fileview up -d
```

### 自定义字体

预览服务只内置免费的中文思源字体和部分英文字体，不含需授权商用的字体（仿宋、宋体、微软雅黑等）。本包已把字体目录挂到应用数据目录（卸载/升级不丢）：

```yaml
- "${TRIM_PKGVAR}/fonts:/usr/local/share/fonts:ro"
```

把字体文件放进 `/vol{n}/@appdata/basemetas-fileview/fonts/` 后重启引擎容器即可。

> 请使用正规渠道取得授权的字体。思源系列（已内置）开源可商用；从 Windows 直接拷贝宋体/微软雅黑属授权灰色地带。DWG 图纸走的是浏览器端 SHX 字体，与本目录无关。

## 安全说明

- ✅ 统一网关先校验登录态，未登录访问被挡在网关层；不对外暴露任何端口。
- ⚠️ **FileView 自身不按用户区分权限**：凡能登录飞牛的用户，打开 `/app/basemetas-fileview/...` 都能预览已挂载卷里的文件。多账号 / 访客环境建议只挂载可公开的卷。
- ✅ 存储卷只读挂载，且仅限向导里填写的卷。

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

## 自动更新

飞牛应用设置里的「自动更新」只对应用中心上架的应用有效；手动安装的第三方包需自建更新。完整方案见 `自动更新/`：把 `version.txt` + `.fpk` 放到一个可 HTTP 访问的目录，用 `appcenter-cli install-fpk --env` 静默升级，配合飞牛计划任务定时执行。

### 版本号规则

`manifest` 的 `version` 与引擎镜像 tag **解耦**，当前为 `0.5.7`（对应引擎 `1.5.2`）：

| 包版本 | 对应引擎 | 用途 |
|---|---|---|
| 0.5.x | 1.5.2 | 只改配置/图标/nginx，末位 +1 |
| 0.6.0 | 1.6.0 | 升级引擎镜像时跟着抬 |

飞牛靠版本号**递增**判断升级安装；同版本不允许覆盖安装。

## 更新说明

各版本的改动详见 [CHANGELOG.md](CHANGELOG.md)。最近几个版本：

| 版本 | 要点 |
|---|---|
| **0.5.7** | 修复卸载失败（手动 `docker compose up -d` 未指定项目名导致容器脱离管理）；新增 `tools/fv-uninstall-fix.sh` 用于修复已卡住的卸载状态 |
| 0.5.6 | 修复网关容器无限重启（残留 `app.sock`）；存储卷默认 `auto` 自动挂载全部 `/volN`；保存设置即自动重建容器；新增 `tools/fv-repair.sh` |
| 0.5.5 | 修复 Excel / CSV 打开后无限转圈（网关层改写前端 `credentials: 'omit'`） |
| 0.5.4 | 支持自定义字体（挂到 `${TRIM_PKGVAR}/fonts`） |
| 0.5.3 | 入口精简为只保留「用 FileView 打开」 |
| 0.5.2 | 首个可安装版本 |

## 已知限制

- **Excel / CSV 首次打开需强制刷新一次**：上游 FileView 前端取文件时用了 `credentials: 'omit'`，在带鉴权的网关下会取不到文件。本包已在网关层用 `sub_filter` 改写回默认行为，但该 JS 带 hash 被浏览器缓存，需强刷（`Ctrl+F5`）一次后生效。
- 大图纸（几十 MB 的 DWG）渲染性能官方无指标，建议实测。
- 扩展名列表受约 500 字符上限约束，无法全量注册。
