**English** | [中文](README.zh-CN.md)

---

**ClipboardOnly**
is a Screenshot Utility for Mac.
A small tool born from a simple frustration: every screenshot automatically creates a file you didn't ask for. This utility gives you back control — choose whether to save a file at all, and optionally run OCR on whatever you've captured.


<img width="592" height="810" alt="clip-current" src="https://github.com/user-attachments/assets/d900bcaa-320e-48af-b8f0-77164de17874" />




## Features

- **Clipboard-only mode** — intercepts screenshots so they go straight to the clipboard instead of cluttering your Desktop.
- **Auto OCR** — runs Apple Vision OCR on every screenshot and copies the recognized text. Works with Chinese (Simplified / Traditional) and English.
- **Privacy Filter** *(new in v1.1.0)* — automatically detects and redacts sensitive content in both OCR text and the screenshot image itself:
  - 🟥 API Keys (OpenAI, Stripe, GitHub, AWS, Slack, Google …)
  - 🟧 Credit Card Numbers
  - 🟦 Email Addresses
  - 🟩 Phone Numbers
  - 🟪 ID Card Numbers
  - 🟨 IP Addresses
  - 🟫 Passwords (`password: …`, `密码：…`)

  Matches in OCR text are replaced with placeholders (e.g. `[API_KEY]`); matches in screenshots are covered with per-type colored rectangles. A multi-line token heuristic handles long keys split across OCR lines.
- **Manual OCR panel** — when auto-OCR is off, a small floating thumbnail lets you trigger OCR on demand.
- **Paste as File Path (for CLI)** *(new in v1.2.0)* — terminals can't paste image data, so `Cmd+V`-ing a screenshot into Claude Code or other CLI tools gives you nothing. Toggle this on and each screenshot is also cached to a file (`~/Library/Caches/<bundle>/clip-current.png`); the clipboard carries both the image and the absolute path. `Cmd+V` in a terminal yields the path, and Claude Code reads the image directly. Off by default so pasting into Slack / Mail / image editors still works as before. The cache is single-file rolling — at most one file ever exists, cleared before the next screenshot, on any external clipboard write, on quit, and at launch.
- **Economy Mode** *(new in v1.2.9)* — caps the screenshot sent to LLMs at 512px long edge instead of the standard 1568px, cutting Claude vision-token cost by roughly 89%. Off by default; best for screenshots already cropped to the relevant text, since full-screen or code captures will blur at 512px. Local OCR always runs on the full-resolution original, so recognized text is unaffected.
- **Send Clipboard to Obsidian** *(new in v1.2.7)* — pick any Obsidian vault once, then any clipboard text or image can be one-clicked into the vault as a new note. Images are saved as PNG attachments alongside the note; text becomes the note body. Optionally auto-open the new note in Obsidian after save.
- **Launch at login** toggle.
- **Bilingual UI** — automatically follows system language (中文 / English).

## Notes on macOS 26.4+

Starting with macOS 26.4, `screencapture` changed how it writes screenshots: the image is first saved to a dot-prefixed temp file (e.g. `.截屏….png`) and only renamed (dropping the leading dot) up to **~55 seconds later**, after a batch of metadata / Biome work finishes. The original "intercept the file the moment it lands and delete it" approach in v1.2.7 raced this rename and surfaced the system dialog *"无法保存截屏。不能将文件写入到预期目的位置。"*

From **v1.2.8** onward, ClipboardOnly reads the dotfile but leaves it on disk for `screencapture` to finish with, then silently cleans up the renamed file. As a side-effect the temp file lives in `~/.clipboard_only/intercept/` for up to a minute per screenshot — it's in a hidden directory, invisible in Finder, and removed automatically once the rename completes. The user-facing promise ("no leftover screenshot files") is unchanged.

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

## Contributors

Built collaboratively with the help of:

- [Claude Code](https://claude.com/claude-code) (Anthropic) — primary implementation
- [OpenAI Codex](https://openai.com/codex) — code review
