[English](README.md) | **中文**

---

**ClipboardOnly**
是一款 Mac 截图工具。
它源于一个简单的烦恼：每次截图都会自动生成一个你没要的文件。这个小工具把控制权还给你——自己决定要不要保存文件，并可选地对截到的内容做 OCR 文字识别。


<img width="592" height="810" alt="clip-current" src="https://github.com/user-attachments/assets/d900bcaa-320e-48af-b8f0-77164de17874" />




## 功能

- **仅复制到剪贴板** — 拦截截图，让它直接进剪贴板，不再在桌面堆文件。
- **自动 OCR** — 对每张截图跑 Apple Vision OCR 并复制识别出的文字。支持中文（简体 / 繁体）和英文。
- **隐私过滤** *(v1.1.0 新增)* — 自动检测并遮蔽 OCR 文本和截图图片本身里的敏感内容：
  - 🟥 API Key（OpenAI、Stripe、GitHub、AWS、Slack、Google ……）
  - 🟧 信用卡号
  - 🟦 邮箱地址
  - 🟩 手机 / 电话号码
  - 🟪 身份证号
  - 🟨 IP 地址
  - 🟫 密码（`password: …`、`密码：…`）

  OCR 文本里命中的内容会替换成占位符（如 `[API_KEY]`）；截图里命中的区域会按类型盖上不同颜色的矩形。多行 token 启发式可处理被 OCR 拆成多行的长密钥。
- **手动 OCR 浮窗** — 关闭自动 OCR 时，会出现一个浮动的小缩略图，可按需手动触发 OCR。
- **粘贴为文件路径（用于 CLI）** *(v1.2.0 新增)* — 终端无法粘贴图片数据，所以把截图 `Cmd+V` 进 Claude Code 等 CLI 工具会什么都得不到。开启此项后，每张截图会额外缓存为文件（`~/Library/Caches/<bundle>/clip-current.png`），剪贴板同时携带图片和绝对路径。在终端里 `Cmd+V` 得到的是路径，Claude Code 会直接读取该图片。默认关闭，这样粘贴进 Slack / 邮件 / 图片编辑器仍和以前一样。缓存是单文件滚动的——任何时刻最多只有一个文件，会在下次截图前、任何外部写剪贴板时、退出时、启动时清除。
- **省钱模式** *(v1.2.9 新增)* — 把发送给 LLM 的截图长边压到 512 像素（而非标准的 1568），Claude 视觉 token 成本下降约 89%。默认关闭；适合已裁剪到文字区域的截图，因为整屏或代码截图在 512px 下会变糊。本地 OCR 始终跑在原图全分辨率上，识别出的文字不受影响。
- **发送剪贴板到 Obsidian** *(v1.2.7 新增)* — 一次选定 Obsidian Vault 后，剪贴板里的文字或图片可一键写入 Vault，自动新建笔记；图片保存为同目录 PNG 附件，文字成为笔记正文。可选「写入后打开应用」自动跳转到 Obsidian 查看。
- **开机自启动** 开关。
- **双语界面** — 自动跟随系统语言（中文 / English）。

## 关于 macOS 26.4+

从 macOS 26.4 起，`screencapture` 改变了截图的写盘方式：图片先被写入一个点开头的临时文件（如 `.截屏….png`），最长要等约 **55 秒**——在一批 metadata / Biome 工作完成之后——才 rename 去掉那个点。v1.2.7 里"文件一落盘就拦截并删除"的做法会和这个 rename 抢跑，导致系统弹出 *"无法保存截屏。不能将文件写入到预期目的位置。"*

从 **v1.2.8** 起，ClipboardOnly 改成读取该点文件但把它留在磁盘上，让 `screencapture` 自己完成 rename，再静默清理 rename 后的文件。副作用是这个临时文件每次截图会在 `~/.clipboard_only/intercept/` 里停留最多约一分钟——它在隐藏目录里，Finder 看不到，rename 完成后自动移除。对用户的承诺（"不留截图文件"）不变。

## 安装

从 [Releases](https://github.com/akb4q/ClipboardOnly/releases) 页面下载最新的 `.zip`，解压后把 `ClipboardOnly.app` 拖进 `/Applications`。

### 首次启动 — 绕过 Gatekeeper

由于 app 未经 Apple Developer ID 签名，macOS 首次启动会拦截它，弹出 *"Apple 无法验证……是否含有恶意软件"* 对话框。任选一种解决方式：

**方式 A — 终端（一行命令）：**

```bash
xattr -cr /Applications/ClipboardOnly.app
```

然后正常双击 app。

**方式 B — 系统设置：**

1. 先双击打开一次 app（会弹出拦截对话框——点 **完成**）。
2. 打开 **系统设置 → 隐私与安全性**。
3. 滚到底部，会看到 *"已阻止使用 ClipboardOnly……"*——点 **仍要打开**。
4. 用密码 / 触控 ID 确认。

## 贡献者

在以下工具的协作下共同构建：

- [Claude Code](https://claude.com/claude-code)（Anthropic）— 主要实现
- [OpenAI Codex](https://openai.com/codex)— 代码审查
