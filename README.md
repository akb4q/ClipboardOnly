**ClipboardOnly**
is a Screenshot Utility for Mac.
A small tool born from a simple frustration: every screenshot automatically creates a file you didn't ask for. This utility gives you back control — choose whether to save a file at all, and optionally run OCR on whatever you've captured.

<img width="303" height="355" alt=" Clipboard Only (don&#39;t save file)" src="https://github.com/user-attachments/assets/2b22ce2d-d34b-4650-8039-fb1737234332" />

## Features

- **Clipboard-only mode** — intercepts screenshots so they go straight to the clipboard instead of cluttering your Desktop.
- **Auto OCR** — runs Apple Vision OCR on every screenshot and copies the recognized text. Works with Chinese (Simplified / Traditional) and English.
- **Privacy Filter** *(new in v1.1.0)* — automatically detects and redacts sensitive content in both OCR text and the screenshot image itself:
  - 🔴 API Keys (OpenAI, Stripe, GitHub, AWS, Slack, Google …)
  - 🟠 Credit Card Numbers
  - 🔵 Email Addresses
  - 🟢 Phone Numbers (China / US)
  - 🟣 ID Card Numbers (中国身份证)
  - 🩵 IP Addresses
  - 🩷 Passwords (`password: …`, `密码：…`)

  Matches in OCR text are replaced with placeholders (e.g. `[API_KEY]`); matches in screenshots are covered with per-type colored rectangles. A multi-line token heuristic handles long keys split across OCR lines.
- **Manual OCR panel** — when auto-OCR is off, a small floating thumbnail lets you trigger OCR on demand.
- **Launch at login** toggle.
- **Bilingual UI** — automatically follows system language (中文 / English).

## Install

Grab the latest `.zip` from the [Releases](https://github.com/akb4q/ClipboardOnly/releases) page, unzip, and drag `ClipboardOnly.app` into `/Applications`.

> First launch may need right-click → Open to bypass Gatekeeper.

## Contributors

Built collaboratively with the help of:

- [Claude Code](https://claude.com/claude-code) (Anthropic) — primary implementation
- [OpenAI Codex](https://openai.com/codex) — code review
