# Handoff: ClipboardOnly 隐私过滤功能

## 背景

ClipboardOnly 是一款 macOS 菜单栏应用，主要功能是拦截 macOS 系统截图并自动复制到剪贴板，已内置 Vision OCR。

本次改动新增**隐私过滤**功能，分两层：

1. **文本过滤** — 对剪贴板写入的 OCR 文本，按 regex 规则把敏感内容替换为占位符（如 `[API_KEY]`、`[CREDIT_CARD]`）
2. **图像遮掩** — 对截图本身，在像素层面用纯黑矩形覆盖文字区域，防止图像泄漏

请基于此 Handoff 对实现做 code review，关注点见文末。

---

## 项目结构

```
ClipboardOnly/
├── ClipboardOnlyApp.swift       # @main 入口（未改动）
├── MenuBarController.swift      # 主控制器（已改动，集成点）
├── ScreenshotWatcher.swift      # FSEvents 监听（未改动）
├── ShortcutPanel.swift          # 快捷键面板（未改动）
├── AppMenuView.swift            # SwiftUI 菜单视图（未改动）
├── L10n.swift                   # 本地化（已改动）
├── PrivacyFilter.swift          # ★ 新增：文本过滤引擎
└── ImagePrivacyMasker.swift     # ★ 新增：图像遮掩引擎
```

⚠️ **未完成步骤：** 两个新 `.swift` 文件需要在 Xcode 中手动加入 target（File → Add Files to "ClipboardOnly"…），否则不会被编译。

---

## 模块一：PrivacyFilter（文本过滤）

**文件：** `ClipboardOnly/PrivacyFilter.swift`

### 核心 API

```swift
struct PrivacyFilter {
    var enabledTypes: Set<PrivacyFilterType>
    func filter(_ text: String) -> FilterResult
    static func loadFromDefaults() -> PrivacyFilter
    func saveToDefaults()
}

struct FilterResult {
    let output: String         // 替换后的文本
    let matches: [FilterMatch] // 命中详情
    var didMatch: Bool
    var summary: [PrivacyFilterType: Int]
}
```

### 支持类型与 regex

| 类型 | 占位符 | 正则 |
|------|--------|------|
| `apiKey` | `[API_KEY]` | OpenAI/Anthropic `sk-…`、Stripe `pk_(live\|test)_…`、GitHub `ghp_…`/`gho_…`、AWS `AKIA…`、Slack `xox[baprs]-…`、Google `AIza…`、通用 `Bearer/token/api_key = …` |
| `creditCard` | `[CREDIT_CARD]` | 16 位（4/5/3/6 开头）含可选空格/横线分隔 |
| `email` | `[EMAIL]` | 标准邮箱 |
| `phone` | `[PHONE]` | 中国大陆手机 `1[3-9]\d{9}` + 美式电话 |
| `idCard` | `[ID_CARD]` | 中国身份证 `\d{17}[\dXx]` |
| `ipAddress` | `[IP_ADDRESS]` | IPv4 |

### 关键实现细节

- `filter()` 收集所有 regex 命中范围，**按起始位置降序**排序后从后向前替换，避免索引漂移
- 对**重叠匹配**做去重：保留先遇到的（实际上是后位置的，因为已降序）
- 规则集是 `static let` 静态字典，编译时构建一次
- 持久化：`enabledTypes` 用 `JSONEncoder` 序列化到 UserDefaults key `"privacyFilterEnabledTypes"`

### 已知限制

- ⚠️ 无 Luhn 校验，信用卡可能误判
- ⚠️ 无中国大陆手机号上下文判断（连续 11 位数字都会被替换）
- ⚠️ Bearer token 通用规则可能误伤代码片段
- ❌ 暂未实现人名检测（NLTagger 中文误判率高，已搁置）

---

## 模块二：ImagePrivacyMasker（图像遮掩）

**文件：** `ClipboardOnly/ImagePrivacyMasker.swift`

### 核心 API

```swift
enum ImageMaskMode: String, Codable {
    case allText        // 遮掩所有文字区域，不读内容（VNDetectTextRectanglesRequest）
    case sensitiveOnly  // OCR 后只遮掩命中 filter 的区域（VNRecognizeTextRequest）
}

final class ImagePrivacyMasker {
    var mode: ImageMaskMode
    var filter: PrivacyFilter
    func mask(_ image: NSImage, completion: @escaping (NSImage?) -> Void)
}
```

### 实现要点

- Vision 请求跑在 `DispatchQueue.global(qos: .userInitiated)`，completion 回到 main
- bounding box 转像素坐标：Vision 归一化坐标 (0–1)，原点左下；CG 原点左下，**只需缩放无需翻转**
- 每个 box 向外扩 **4px** padding（参考 Handoff.md 建议），避免边缘字符漏掉
- 用 `CGContext` 重绘原图 + `ctx.fill()` 黑色矩形（**不用模糊**，避免可逆风险）
- `sensitiveOnly` 模式下，对每个 `VNRecognizedTextObservation` 调用 `topCandidates(1).first` 后跑过滤；命中时**优先用 `candidate.boundingBox(for:)` 获取字符级 box**，失败回落到整个 observation box
- 持久化：`mode.rawValue` 存 UserDefaults key `"imageMaskMode"`

### 已知限制

- ⚠️ `sensitiveOnly` 模式下，`candidate.boundingBox(for: range)` 在中文场景下可能返回不准确范围；fallback 到整行遮掩
- ⚠️ `allText` 模式比完整 OCR 快，但对密集文字（如代码截图）仍有几百毫秒延迟，**block 主流程**直到完成才写入剪贴板
- ❌ 不处理非文本敏感信息（人脸、二维码等）

---

## 模块三：MenuBarController 集成点

**文件：** `ClipboardOnly/MenuBarController.swift`

### 新增 @Published 属性

```swift
@Published var privacyFilterEnabled: Bool   // UserDefaults: "privacyFilterEnabled"
@Published var imageMaskEnabled: Bool        // UserDefaults: "imageMaskEnabled"
@Published var imageMaskMode: ImageMaskMode  // UserDefaults: "imageMaskMode"

private var privacyFilter: PrivacyFilter
private var masker: ImagePrivacyMasker
```

### 新增菜单项（在 `populateMenu` 中，autoOCR 下方）

```
✓ 隐私过滤（文字替换）       ← privacyFilterEnabled
   API Key                    ← 子选项（toggle）
   信用卡号
   邮箱地址
   手机/电话
   身份证号
   IP 地址
✓ 遮掩截图中的文字            ← imageMaskEnabled
   遮掩所有文字               ← MaskMode 单选
   仅遮掩敏感内容
```

### 数据流改动

**截图处理（`handleNewFile`）：**

```
原流程: 截图 → writeImageToClipboard → OCR → writeTextToClipboard
新流程: 截图
        ↓
        [imageMaskEnabled?]
        ├─ 是 → masker.mask() → 遮掩后图像 ─┐
        └─ 否 → 原图 ─────────────────────────┤
        ↓                                      │
        writeAndHandleImage(image) ←──────────┘
        ↓
        writeImageToClipboard
        ↓
        [autoOCREnabled?]
        ├─ 是 → startOCRForClipboardImage
        └─ 否 → showManualOCRPanel
```

**OCR 文本输出（`startOCRForClipboardImage` 和 `triggerManualOCR`）：**

```swift
let finalText = self.privacyFilterEnabled
    ? self.privacyFilter.filter(normalizedText).output
    : normalizedText
self.writeTextToClipboard(finalText)
self.lastOCRText = finalText
```

新增的私有 helper `writeAndHandleImage(_:)` 把"写剪贴板 + 触发 OCR + 通知"封装在一起，避免重复代码。

---

## 模块四：L10n 新增 key

**文件：** `ClipboardOnly/L10n.swift`

新增 13 个 key，中英文都已填写：

```swift
case privacyFilter, privacyFilterRedacted
case privacyFilterAPIKey, privacyFilterCreditCard, privacyFilterEmail
case privacyFilterPhone, privacyFilterIDCard, privacyFilterIP
case imageMask, imageMaskAll, imageMaskSensitive
```

> 注：`privacyFilterRedacted`（"已过滤 N 处敏感内容"）目前未在 UI 中使用，预留作通知/状态显示。

---

## Review 关注点

请重点审查以下方面：

### 正确性
1. **`PrivacyFilter.filter()` 的范围去重逻辑** — 多个 regex 命中重叠区间时是否会丢失替换或越界
2. **`ImagePrivacyMasker` 坐标系转换** — Vision 的 normalized rect 到 CGContext pixel rect 是否真的不需要 Y 翻转（在 macOS 上）
3. **`MenuBarController.init()`** — `privacyFilter` 和 `masker` 在 `super.init()` 之后被重新赋值，期间是否有时序问题
4. **`@Published` `didSet` 中调用 `rebuildMenu()`** 的线程安全（已用 `DispatchQueue.main.async` 包裹，但 `imageMaskMode.didSet` 直接同步调了 `masker.saveToDefaults()`）

### 安全性
5. **regex 是否存在 ReDoS 风险**（特别是 `apiKey` 那个用 `|` 联合的长 pattern）
6. **遮掩后的图像是否真的不可逆** — `CGContext` 是否有可能保留原像素

### 性能
7. **大截图（4K+）的遮掩延迟** — 当前实现 block 截图→剪贴板的关键路径，是否需要先放原图、再异步替换？
8. **`PrivacyFilter` 每次都重新跑 regex** — OCR 文本短一般无所谓，但若用户截大段日志可能慢

### 代码风格
9. 与现有项目风格一致性（命名、注释、`@MainActor` 标注、`[weak self]` 使用）
10. 是否有可以用更简洁 Swift 写法的地方

### 测试覆盖
11. 没有单元测试 — 是否需要为 `PrivacyFilter` 加 XCTest（regex 正确性、边界 case）
12. 是否有手测脚本/示例图片可以验证

---

## 验证步骤

1. 把 `PrivacyFilter.swift`、`ImagePrivacyMasker.swift` 加入 Xcode target
2. Build & Run
3. 菜单栏图标 → 检查新出现的"隐私过滤（文字替换）""遮掩截图中的文字"两个开关
4. 测试场景：
   - 截一张含 API key（如 `sk-abc123def456ghi789jkl012mno345pqr`）的图，开"隐私过滤" + autoOCR，验证剪贴板里被替换为 `[API_KEY]`
   - 同上，开"遮掩所有文字"，验证图像里所有文字区域都是黑块
   - 关闭某个子规则（如关掉 email），验证邮箱不再被替换

---

## 改动清单

```
新增:
  ClipboardOnly/PrivacyFilter.swift         (~155 行)
  ClipboardOnly/ImagePrivacyMasker.swift    (~165 行)

修改:
  ClipboardOnly/MenuBarController.swift     (+~110 行)
  ClipboardOnly/L10n.swift                  (+~25 行)
```

无第三方依赖，仅使用 Foundation / AppKit / Vision / NaturalLanguage（NaturalLanguage 当前未实际调用，import 可移除）。