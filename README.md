**ClipboardOnly**
is a Screenshot Utility for Mac.
A small tool born from a simple frustration: every screenshot automatically creates a file you didn't ask for. This utility gives you back control — choose whether to save a file at all, and optionally run OCR on whatever you've captured.

<img width="397" height="798" alt="image" src="https://github.com/user-attachments/assets/8b5c7d01-7138-4db5-9399-1811cad3c25f" />


## Features

- **Clipboard-only mode** — intercepts screenshots so they go straight to the clipboard instead of cluttering your Desktop.
- **Auto OCR** — runs Apple Vision OCR on every screenshot and copies the recognized text. Works with Chinese (Simplified / Traditional) and English.
- **Privacy Filter** *(new in v1.1.0)* — automatically detects and redacts sensitive content in both OCR text and the screenshot image itself:
  - 🟥 API Keys (OpenAI, Stripe, GitHub, AWS, Slack, Google …)
  - 🟧 Credit Card Numbers
  - 🟦 Email Addresses
  - 🟩 Phone Numbers (China / US)
  - 🟪 ID Card Numbers (中国身份证)
  - 🟨 IP Addresses
  - 🟫 Passwords (`password: …`, `密码：…`)

  Matches in OCR text are replaced with placeholders (e.g. `[API_KEY]`); matches in screenshots are covered with per-type colored rectangles. A multi-line token heuristic handles long keys split across OCR lines.
- **Manual OCR panel** — when auto-OCR is off, a small floating thumbnail lets you trigger OCR on demand.
- **Launch at login** toggle.
- **Bilingual UI** — automatically follows system language (中文 / English).

## Install

Grab the latest `.zip` from the [Releases](https://github.com/akb4q/ClipboardOnly/releases) page, unzip, and drag `ClipboardOnly.app` into `/Applications`.

### First launch — bypassing Gatekeeper

Because the app is not signed with an Apple Developer ID, macOS will block it on first launch with a *"Apple could not verify… is free of malware"* dialog. Choose **either** workaround:

**Option A — Terminal (one line):**

```bash
xattr -cr /Applications/ClipboardOnly.app
```

Then double-click the app normally.

**Option B — System Settings:**

1. Try to open the app once (you'll get the block dialog — click **Done**).
2. Open **System Settings → Privacy & Security**.
3. Scroll to the bottom; you'll see *"ClipboardOnly was blocked…"* — click **Open Anyway**.
4. Confirm with your password / Touch ID.

> 由于 app 未经 Apple Developer ID 签名，首次运行会被 Gatekeeper 拦截。任选一种解决方式：
>
> **方式 A — 终端一行命令：** `xattr -cr /Applications/ClipboardOnly.app`，然后正常双击。
>
> **方式 B — 系统设置：** 先双击触发拦截弹窗 → 打开「系统设置 → 隐私与安全性」→ 滚到底部点「仍要打开」→ 输入密码确认。

## Contributors

Built collaboratively with the help of:

- [Claude Code](https://claude.com/claude-code) (Anthropic) — primary implementation
- [OpenAI Codex](https://openai.com/codex) — code review
