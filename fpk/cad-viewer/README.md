# CAD 预览页 —— **已迁出到独立应用**

这个目录原来放着 FileView 内置的 CAD（DWG/DXF）预览页（基于开源的
[mlightcad/cad-viewer](https://github.com/mlightcad/cad-viewer) + LibreDWG）。

**0.5.58 起它已经彻底移出本应用**，源码、构建脚本、资源、入口、nginx 路由、
闸门的 `/raw` 端点全部删除。

## CAD 图纸现在去哪了

请装**独立的飞牛应用**「CAD 查看器」（fnos-cadviewer）：

- 仓库：<https://github.com/bug-yu/fnos-cadviewer>
- 下载：<https://github.com/bug-yu/fnos-cadviewer/releases/latest>

它做得比这里原来那份**更多**：

| | 本目录原来的版本（≤0.5.57） | 独立应用（fnos-cadviewer） |
|---|---|---|
| 右键预览 | ✅ 简易查看器 | ✅ 简易查看器 |
| 桌面图标 | ❌ 没有 | ✅ **完整版**（菜单 / 功能区 / 命令行 / 状态栏） |
| 打开 NAS 图纸 | ✅ | ✅ 走官方 `pickUserFile` / `openAppAuth` 授权 |
| 本地文件 | ✅ | ✅ |
| 字体 | 86 个 SHX | **101 个字体文件** |

## 为什么移出

1. **体积**：CAD 页要带字体（54 MB）+ LibreDWG WASM（9.5 MB）。
   内置在 FileView 里 → FileView 的包从 **231 KB 涨到 54.6 MB**（×236）。
   独立成应用后，FileView 回到 **~231 KB**，CAD 那 55 MB 只在需要的人那里装。
2. **职责**：FileView 是「全格式预览」，CAD 是其中一个专业子集，
   两者的发版节奏、依赖栈（Vue 3 / element-plus / LibreDWG）、
   许可（GPL-3.0）都不一样。
3. **避免两份**：两个应用都内置一份 cad-viewer 的话，字体与 WASM 要打两遍，
   而且两份会各自漂版本。

## 想看原来的实现？

在本仓库的 git 历史里：

```bash
git log --oneline -- fpk/cad-viewer | head
git show <最后一个包含它的提交>:fpk/cad-viewer/build.py
```
