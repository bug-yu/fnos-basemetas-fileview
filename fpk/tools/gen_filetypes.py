"""从 FileView 官方《支持格式列表》生成 app/ui/config 的 fileTypes。

⚠️ 重要限制（2026-09-26 实测踩坑）：
   飞牛应用中心把入口的扩展名列表写进一个 **限长 500 字符** 的数据库列。
   一旦超长，**安装直接失败**，界面只报"服务异常"，真相只在日志里：
       /var/log/trim_app_center/error.log
       error="ERROR: value too long for type character varying(500) (SQLSTATE 22001)"
   实测：243 个扩展名（拼接约 1300 字符）→ 安装必失败；
         27 个扩展名（约 140 字符）→ 正常安装。
   因此本脚本**默认只生成「精简清单」**，并在生成前做长度门禁。

用法：
   python gen_filetypes.py                  # 生成精简清单（推荐）
   python gen_filetypes.py --full           # FileView 全部 243 种（⚠️ 装不上，仅供比对挑选）
   python gen_filetypes.py --dry            # 只打印，不写文件
   python gen_filetypes.py --max-chars 300  # 自定义长度上限（默认 400）
"""

import json
import os
import sys

# ============================================================
# 精简清单：按「对本项目（工程单位）的价值」排序
# 取舍原则：
#   1. 飞牛没有原生预览能力的 → 必留（图纸、版式、三维、压缩包、Visio、导图、专业图像）
#   2. 飞牛自带 Office 预览/相册/播放器已够用的 → 只留主流格式
#   3. 音视频与常见位图（jpg/png/mp4…）→ 不注册，交给飞牛原生应用
#   4. 小众编程语言（.lhs/.hrl/.gvy…）→ 不注册，几乎用不到还挤占字符额度
# ============================================================
CURATED_GROUPS = {
    # ⚠️ CAD 图纸（dwg/dxf）**已从这里移除** —— 它们改由独立的 cad-viewer 页面承接
    #    （见下面 build_config 里的 basemetas-fileview.cad 入口）。
    #    原因：FileView 引擎自带的 cad2x 对多重引线、面域边框、字体还原都不行。
    "版式文档（必留）": ["pdf", "ofd"],
    "Word / 文档": ["doc", "docx", "wps", "rtf"],
    "Excel / 表格": ["xls", "xlsx", "csv", "et", "ods"],
    "PowerPoint / 演示": ["ppt", "pptx", "dps", "odp"],
    "压缩包": ["zip", "rar", "7z", "tar", "tgz", "gz", "jar"],
    "Visio / 流程图 / 思维导图": [
        "vsd", "vsdm", "vsdx", "vssx", "vstx", "bpmn", "drawio", "xmind",
    ],
    "三维模型": [
        "gltf", "glb", "obj", "stl", "fbx", "ply", "dae", "wrl", "3ds", "3mf", "3dm",
    ],
    "专业图像": ["psd", "tga", "emf", "wmf", "tif", "tiff"],
    "电子书": ["epub"],
    "纯文本 / 数据": ["txt", "md", "json", "xml", "yaml", "conf", "log", "sql"],
    "常用脚本": ["sh", "py", "js"],
}

# ============================================================
# FileView 官方完整清单（243 项）—— 仅用于比对 / 挑选
# ⚠️ 整份生成会超出飞牛 500 字符上限，安装必失败（见文件头说明）
# ============================================================
FULL_GROUPS = {
    "Word / 文档类": ["doc", "docx", "dot", "dotx", "dotm", "docm", "wps", "wpt", "rtf"],
    "纯文本 / 标记语言": [
        "txt", "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdx",
        "html", "htm", "xml", "xsd", "xsl", "xslt",
        "tex", "ltx", "bib", "cls", "sty", "ins", "dtx", "rst", "log", "conf",
    ],
    "Excel / 表格类": [
        "xls", "xlsx", "xlsm", "xlt", "xltx", "xltm", "ods", "ots", "fods",
        "xla", "xlam", "et", "ett", "csv",
    ],
    "PowerPoint / 演示类": [
        "ppt", "pptx", "dps", "dpt", "pptm", "pot", "potx", "potm", "odp", "otp", "fodp",
    ],
    "版式文档（PDF / OFD）": ["pdf", "ofd"],
    "图片": [
        "jpg", "jpeg", "png", "webp", "gif", "svg",
        "bmp", "psd", "tif", "tiff", "tga", "emf", "wmf",
    ],
    "音频": ["mp3", "m4a", "wav", "aac", "ogg", "flac", "ac3", "au", "wma", "aif", "aifc", "aiff"],
    "视频": ["mp4", "webm", "avi", "m4v", "mpg", "mpeg", "m2v", "m4p", "ogv", "wmv"],
    "压缩包": ["zip", "jar", "rar", "7z", "tar", "tgz", "gz"],
    # ⚠️ 原本这里还有 "CAD / 工程图纸": ["dwg", "dxf"] —— 已移除，
    #    改由独立的 cad-viewer 入口承接（见 build_config）。
    "三维模型": ["gltf", "glb", "obj", "stl", "fbx", "ply", "dae", "wrl", "3ds", "3mf", "3dm"],
    "Visio / 流程图 / 思维导图": [
        "vsd", "vsdm", "vsdx", "vssm", "vssx", "vstm", "vstx", "bpmn", "drawio", "xmind",
    ],
    "代码 · 前端": ["js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte", "css", "scss", "sass", "less"],
    "代码 · Java 系": ["java", "jsp", "jspx", "jhtml", "tag", "groovy", "gvy", "gsh", "grvy", "scala", "sc", "kt", "kts"],
    "代码 · C / C++": ["c", "cpp", "cc", "cxx", "h", "hpp", "hxx", "hh"],
    "代码 · C# / .NET": ["cs", "cshtml", "razor"],
    "代码 · Python": ["py", "pyw", "pyt", "pyx", "pyo", "rpy"],
    "代码 · Go": ["go", "gomod", "gohtml"],
    "代码 · PHP": ["php", "php3", "php4", "php5", "phtml", "phpt"],
    "代码 · Ruby": ["rb", "rake", "thor", "ru"],
    "代码 · 其他语言": [
        "lua", "r", "rmd", "rnw", "rs", "swift", "dart",
        "pl", "pm", "t", "pod", "erl", "hrl", "ex", "exs", "hs", "lhs",
    ],
    "Shell / 脚本": ["sh", "bash", "zsh", "fish", "ksh", "csh", "tcsh", "cmd"],
    "汇编": ["asm", "s"],
    "Objective-C": ["m", "mm", "objc", "objcpp"],
    "配置 / 数据": [
        "json", "geojson", "ldjson", "json5", "yaml", "yml",
        "sql", "pgsql", "sqlite", "db", "db3", "dsql",
        "gradle", "cmake", "gyp", "tf", "tfvars", "hcl",
        "ejs", "jade", "pug", "vbhtml", "schema", "http", "rest", "nginx",
        "dockerfile", "gitignore", "bashrc", "bash_profile",
    ],
    "电子书": ["epub"],
}


def collect(groups):
    seen = set()
    ordered = []
    for items in groups.values():
        for ext in items:
            ext = ext.strip().lower().lstrip(".")
            if ext and ext not in seen:
                seen.add(ext)
                ordered.append(ext)
    return ordered


def build_config(exts):
    """只保留「用 FileView 打开」一个入口。

    为什么删掉原来的桌面入口 `basemetas-fileview.main`：
      1. 它的唯一作用是打开 FileView 的欢迎页（展示支持格式/样例），对日常使用没有价值；
      2. 应用设置里会因此多出一张卡片（访问端口/访问路径/自定义 URL 各一行），
         而"访问路径"显示的只是内部实现路径（不写 url 时飞牛会显示 `/`），纯噪音；
      3. 这个应用真正的用法就是"右键 → 用 FileView 打开"，一个入口足够。

    注意：入口删掉后，manifest 里的 `desktop_applaunchname` 也一并去掉
    （文档说明该字段仅在"存在多个入口"时用于指定卡片打开的入口）。
    欢迎页仍可直接访问：/app/basemetas-fileview（nginx 里 302 到 /preview/welcome）。
    """
    return {
        ".url": {
            "basemetas-fileview.view": {
                "title": "用 FileView 打开",
                "icon": "images/icon_{0}.png",
                # type=iframe：在飞牛 fnOS 桌面窗口内打开（官文：「需要在飞牛 fnOS 桌面窗口内
                #   打开应用时，使用 iframe」）。0.5.26 起由 url 改为 iframe —— 右键「用 FileView
                #   打开」不再跳浏览器新标签页，而是嵌在飞牛桌面里，与飞牛自带「Office 预览」同形态。
                #   官方「注册文件打开方式」的示例用的正是 iframe + noDisplay。
                "type": "iframe",
                "protocol": "",
                "gatewayPrefix": "/app/basemetas-fileview",
                "gatewaySocket": "app.sock",
                # 这个入口的 url 必须保留：飞牛在它后面追加 ?path=，
                # 少了它文件路径参数会丢失。
                "url": "/app/basemetas-fileview/preview/view",
                "allUsers": True,
                "fileTypes": exts,
                "noDisplay": True,
                # 入口设置里的「访问端口 / 访问路径 / 自定义 URL」是框架为入口渲染的，
                # 而本应用的入口地址由统一网关决定、用户**不应该**去改它（改错了预览就打不开）。
                #
                # ⚠️ 这三个 `*Perm` 字段**官方文档里完全没有** —— 是照着一个**已发布的第三方应用**
                #    （`fygo-browser`，Chrome 浏览器）的 `ui/config` 抄来的（2026-10-07）。
                #    真正把「访问端口 / 访问路径 / 自定义 URL」三行藏起来的就是它们；
                #    官方文档只记了 accessPerm 的 editable/readonly/hidden 三态。
                # ⚠️ 不要用 accessPerm=hidden —— 那会把**整个入口**一起隐藏（实测）。
                #
                # accessPerm 用 editable：「桌面访问」保持**可选**
                #   （管理员可以选「仅管理员」或「设备内所有用户」；
                #     用 readonly 会把它变灰不可点 —— 用户明确要求可选）。
                "control": {
                    "accessPerm": "editable",
                    "portPerm": "hidden",
                    "pathPerm": "hidden",
                    "fullUrlPerm": "hidden"
                },
            },
            # ── CAD 图纸：走**独立**的 cad-viewer 页面 ────────────────────────
            # 为什么单独一个入口（而不是让 FileView 转）：
            #   FileView 引擎自带的 cad2x 对 **多重引线**、**面域边框**、**字体** 还原都不行；
            #   cad-viewer（+ LibreDWG + 86 个 SHX 字体）这三项都正常（真机对比过）。
            # 页面与资源：app/docker/cad/（由 fpk/cad-viewer/build.py 生成）
            # 文件读取：走 /cad/api/raw —— **必须过闸门**（由闸门自己做 ACL 判定）。
            "basemetas-fileview.cad": {
                "title": "用 CAD 预览打开",
                "icon": "images/icon_{0}.png",
                "type": "iframe",
                "protocol": "",
                "gatewayPrefix": "/app/basemetas-fileview",
                "gatewaySocket": "app.sock",
                "url": "/app/basemetas-fileview/cad/",
                "allUsers": True,
                "fileTypes": ["dwg", "dxf"],
                "noDisplay": True,
                "control": {
                    "accessPerm": "editable",
                    "portPerm": "hidden",
                    "pathPerm": "hidden",
                    "fullUrlPerm": "hidden"
                },
            },
        }
    }


def main():
    use_full = "--full" in sys.argv
    dry = "--dry" in sys.argv
    force = "--force" in sys.argv
    max_chars = 400
    if "--max-chars" in sys.argv:
        max_chars = int(sys.argv[sys.argv.index("--max-chars") + 1])

    groups = FULL_GROUPS if use_full else CURATED_GROUPS
    exts = collect(groups)

    joined = ",".join(exts)
    as_json = json.dumps(exts, ensure_ascii=False, separators=(",", ":"))
    print(f"{'完整清单（--full）' if use_full else '精简清单'}：{len(exts)} 个扩展名")
    for name, items in groups.items():
        print(f"  {name:<28} {len(items):>3}")
    print()
    print(f"逗号拼接长度：{len(joined)} 字符（飞牛上限约 500）")
    print(f"JSON 编码长度：{len(as_json)} 字符")
    print(f"长度门禁：{'✅ 通过' if len(joined) <= max_chars else '❌ 超限'}（阈值 {max_chars}）")

    if len(joined) > max_chars and not force:
        print()
        print("❌ 已阻止生成：扩展名列表过长会让飞牛安装直接失败（character varying(500)）。")
        print("   请删减 gen_filetypes.py 里 CURATED_GROUPS 的条目；确要继续加 --force。")
        return 1

    config = build_config(exts)
    text = json.dumps(config, ensure_ascii=False, indent=2) + "\n"
    if dry:
        print()
        print(text)
        return 0

    here = os.path.dirname(os.path.abspath(__file__))
    target = os.path.normpath(os.path.join(here, "..", "basemetas-fileview", "app", "ui", "config"))
    # ⚠️ newline="\n" 必须写：默认的文本模式在 Windows 上会把 \n 转成 \r\n，
    #    而这个文件会被打进 .fpk（git 侧有 eol=lf 规则，但打包用的是**工作区**）。
    with open(target, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print()
    print("已写入：", target)
    print("文件大小：", os.path.getsize(target), "字节")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
