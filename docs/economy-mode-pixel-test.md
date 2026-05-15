# Economy Mode — Pixel-Floor Experiment

This document records the empirical experiment behind **Economy Mode** (v1.2.9)
and why its downscale target is **512px**.

[English](#english) · [中文](#中文)

---

## English

### Why this experiment

Claude vision-token cost is roughly `width × height / 750`, so the cheapest
way to cut cost is to send fewer pixels. ClipboardOnly already caps screenshots
at 1568px long edge (Anthropic's max native resolution for non-Opus-4.7
models). Economy Mode wanted to go lower — but how low before recognition
quality breaks? Anthropic publishes only two bounds:

- **< 200px** → hallucination / misreads
- **≥ 1000×1000** → "best"

The 200–1000 range had no public quality curve, so we measured it.

### Method

- **Fixtures**: synthetic, ClipboardOnly-style PNG screenshots in 3 categories
  — `receipt` (structured fields), `mixed` (labels + values), `code` (dense
  symbols, identifiers, secrets).
- **Resolution ladder**: each fixture rendered at 512 / 384 / 320 / 256 / 192 /
  160 / 128 / 96 px long edge (high-quality Lanczos downscale).
- **Readers**: two independent paths — the Codex chat image reader, and
  **Claude Sonnet 4.6** (`claude-sonnet-4-6`, model routing verified).
- **Prompt**: a single fixed JSON-extraction prompt across all sizes;
  "use null if uncertain, do not guess".
- **Scoring**: `pass` = expected fields exact; `partial` = at least one field
  wrong/missing/hallucinated; `fail` = unreadable or mostly wrong.

### Results

Claude Sonnet 4.6:

| Case    | 512px | 384px | 320px | 256px         | 192px        |
| ------- | ----- | ----- | ----- | ------------- | ------------ |
| receipt | pass  | pass  | pass  | partial       | fail         |
| mixed   | —     | pass  | pass  | pass          | partial/fail |
| code    | —     | pass  | pass  | partial       | fail         |

Codex reader (broader ladder):

| Case    | 512px | 384px | 320px      | 256px   | 192px        | ≤160px |
| ------- | ----- | ----- | ---------- | ------- | ------------ | ------ |
| receipt | pass  | pass  | pass-risky | partial | partial/fail | fail   |
| mixed   | pass  | pass  | pass-risky | partial | partial      | fail   |
| code    | pass  | pass  | pass-risky | partial | partial      | fail   |

Representative low-resolution failures:

- `code_192px` — `max_long_edge` misread `1568` → `1048`
- `mixed_192px` — bundle id `com.akb4q.clipboard-only` → `com.ab4y.clipboard-only`
- `code_256px` — API-key chars `abc` → `ctc`, IP `31.42` → `51.42`
- `receipt_256px` — store name and date rewritten

### Conclusion

- **384px** is the observed floor for clean, high-contrast synthetic content.
- **512px** is a reliable economy target for cropped text, receipts, dialogs,
  and small UI snippets — this is why **Economy Mode caps at 512px**.
- **≤ 320px** is unsafe: hallucinations corrupt digits, IDs, IPs, and keys.
- These fixtures are *clean synthetic* screenshots. Real captures
  (anti-aliased small text, Retina artifacts, blur, low contrast) fail
  earlier — treat 384px as a floor, not a target.
- Local Apple Vision OCR and privacy masking still run on the full-resolution
  original; only the LLM-bound image bytes shrink. Economy Mode does not
  degrade ClipboardOnly's own OCR text.

The standard 1568px cap remains the default. Economy Mode is opt-in, for
screenshots already cropped to the relevant text.

---

## 中文

### 为什么做这个实验

Claude 视觉 token 成本约等于 `宽 × 高 / 750`，所以省成本最直接的办法就是少发像素。
ClipboardOnly 已经把截图压到长边 1568px（Anthropic 对非 Opus-4.7 模型的最大原生
分辨率）。省钱模式想压得更低——但低到多少识别质量会崩？Anthropic 官方只给了两条线：

- **< 200px** → 幻觉 / 误读
- **≥ 1000×1000** → "最佳"

200–1000 这个区间没有公开的质量曲线，所以我们自己测了。

### 方法

- **测试图**：合成的、ClipboardOnly 风格的 PNG 截图，分 3 类——`receipt`（结构化
  字段）、`mixed`（标签 + 值）、`code`（密集符号、标识符、密钥）。
- **分辨率梯度**：每张图渲染成长边 512 / 384 / 320 / 256 / 192 / 160 / 128 / 96 px
  （高质量 Lanczos 降采样）。
- **识别方**：两条独立路径——Codex 聊天读图，以及 **Claude Sonnet 4.6**
  （`claude-sonnet-4-6`，已验证模型路由无串档）。
- **Prompt**：所有尺寸用同一份固定的 JSON 抽取 prompt；"不确定就填 null，不要猜"。
- **评分**：`pass` = 预期字段完全正确；`partial` = 至少一个字段错/缺/幻觉；
  `fail` = 不可读或大部分错。

### 结果

Claude Sonnet 4.6：

| 类型    | 512px | 384px | 320px | 256px   | 192px        |
| ------- | ----- | ----- | ----- | ------- | ------------ |
| receipt | pass  | pass  | pass  | partial | fail         |
| mixed   | —     | pass  | pass  | pass    | partial/fail |
| code    | —     | pass  | pass  | partial | fail         |

Codex 读图（更宽的梯度）：

| 类型    | 512px | 384px | 320px      | 256px   | 192px        | ≤160px |
| ------- | ----- | ----- | ---------- | ------- | ------------ | ------ |
| receipt | pass  | pass  | pass-risky | partial | partial/fail | fail   |
| mixed   | pass  | pass  | pass-risky | partial | partial      | fail   |
| code    | pass  | pass  | pass-risky | partial | partial      | fail   |

低分辨率的代表性错误：

- `code_192px` — `max_long_edge` 把 `1568` 误读成 `1048`
- `mixed_192px` — bundle id `com.akb4q.clipboard-only` → `com.ab4y.clipboard-only`
- `code_256px` — API key 字符 `abc` → `ctc`、IP `31.42` → `51.42`
- `receipt_256px` — 店名和日期被改写

### 结论

- **384px** 是干净高对比合成内容的实测地板。
- **512px** 对裁剪过的文字、票据、对话框、小 UI 片段是可靠的经济档——
  这就是**省钱模式压到 512px** 的依据。
- **≤ 320px** 不安全：幻觉会篡改数字、ID、IP、密钥。
- 这些测试图是*干净的合成截图*。真实截图（抗锯齿小字、Retina 伪影、模糊、
  低对比）会更早崩——384px 当地板看，不当目标看。
- 本地 Apple Vision OCR 和隐私遮罩仍跑在原图全分辨率上，只有发给 LLM 的
  图片字节变小。省钱模式不会拖累 ClipboardOnly 自己的 OCR 文字。

标准 1568px 仍是默认值。省钱模式是用户主动开启的选项，针对已裁剪到文字区域的截图。
