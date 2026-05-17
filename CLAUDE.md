# CLAUDE.md — session notes for ClipboardOnly

Append-only working log. Most recent session at top.

---

## 2026-05-18 — v1.2.9 (re-issued): privacy menu items unclickable

### Key decisions

1. **Bug report**: items inside the "隐私过滤" menu section couldn't be clicked — neither the "启用隐私过滤" checkbox nor the 7 per-type rows responded.

2. **Root cause**: `makePrivacyEnabledItem` / `makePrivacySubItem` set the menu item's `view` to a plain `NSView` container with an interactive `NSButton` as a *subview*. `NSMenu` delivers mouse events only to the menu item's *top-level* view during tracking — it does not run them through the normal window hit-test → subview dispatch. So the plain container received `mouseDown:` and did nothing; the `NSButton` subview never saw the click. The disclosure-arrow row and the Obsidian row already worked because they use `ClickableMenuItemView`, which *is* the top-level view and overrides `mouseDown:` to fire its action.

3. **Fix**: rewrote both builders to make the whole row a `ClickableMenuItemView` (the proven pattern). Added a generic `clickPayload: Any?` to `ClickableMenuItemView` so the type-toggle handler can recover which `PrivacyFilterType` was clicked (previously read off the `NSButton`'s `identifier`). Toggle handlers now call `refreshMenuDisplay()` to redraw in place — menu stays open. Enabled row shows a `checkmark` SF Symbol when on; sub-rows keep the colored swatch.

4. **Version**: per user, merged into **v1.2.9** — no version bump (pbxproj stays 1.2.9 / build 129). The existing `v1.2.9` tag + GitHub release were re-pointed to the new commit, with a rebuilt zip.

### Files modified

- `ClipboardOnly/MenuBarController.swift`: added `ClickableMenuItemView.clickPayload`; rewrote `makePrivacyEnabledItem` + `makePrivacySubItem` to use `ClickableMenuItemView`; `togglePrivacyFilterButton` / `togglePrivacyFilterTypeButton` signatures changed (now take `Any` / `ClickableMenuItemView`, read `clickPayload`, call `refreshMenuDisplay()`).

### Notes

- `docs/project-overview.html` — a Codegraph-generated project overview webpage was created this session; left untracked, not part of this commit.
- The `swift`-script end-to-end test of `PrivacyFilter.filter()` was prepared but the user verified the fix manually instead.

---

## 2026-05-14 / 15 — v1.2.8: screencapture race fix + early popup

### Key decisions

1. **Root cause of "无法保存截屏" dialog**: macOS 26.4+ changed `screencapture`'s write flow. It now writes the screenshot to a dot-prefixed temp file (e.g. `.截屏…png`) and waits **~55 seconds** doing metadata/Biome work before doing the final `rename` that drops the leading dot. v1.2.7's handler grabbed and deleted the dotfile immediately, causing screencapture's later rename to fail and surface the OS dialog. Confirmed via `log show --predicate "process == 'screencapture'"` — error message: *"Failed to move screenshot from .截屏…png to 截屏…png"*.

2. **Rejected approach: dotfile filter in `ScreenshotWatcher`**. Filtering out dotfiles at the watcher level would make the popup wait the full 55s for the rename event. Bad UX.

3. **Chosen approach: read-but-don't-delete + FIFO dedup in `MenuBarController`**. Watcher still sees dotfiles. Handler reads the image content into memory (dotfile is fully written by the time FSEvents fires) but leaves the file on disk. A `pendingDotfileBaseNames` FIFO (cap 64) records the post-rename name. When the rename eventually fires and FSEvents delivers the non-dotfile event, we recognise it via the FIFO and silently `removeItem` — no second pipeline run.

4. **Root cause of "OCR popup feels slow"**: the floating thumbnail panel was shown *after* the full pipeline finished (privacy mask + 1568px resize + PNG encode + pasteboard write ≈ 2-3s on retina screenshots). User had noticed this was a regression introduced around v1.2.4 (when the 1568px resize was added), NOT a macOS 26.4 issue as initially suspected.

5. **Chosen fix: decouple popup from pipeline**. `showManualOCRPanel` is now called the moment the CGImage decodes (~0.8s after the shutter), with no `changeCount`. The OCR button stays inert (guarded by `manualOCRChangeCount == nil`) until the pipeline commits a real changeCount via a second `showManualOCRPanel` call that also swaps the thumbnail to the post-mask image. Privacy guarantee unchanged — only perceived latency.

6. **`clipboardMode == false` (pass-through)**: also needed dotfile handling. New behavior: skip dotfile event entirely (`return`), let screencapture's rename complete, then move the non-dotfile to `originalLocation` on the rename event.

7. **Video (.mov / .mp4) branch**: untouched. `screencapture -V` streams directly to the final name, no dotfile pattern observed. Added defensive `if isDotfile { return }` just in case.

### Files modified

- `ClipboardOnly/MenuBarController.swift`:
  - Added `pendingDotfileBaseNames` FIFO + `recordPendingDotfile` / `consumePendingDotfile` helpers near the `manualOCRPanelController` ivars.
  - Rewrote `handleNewFile` to compute `isDotfile` / `nonDotName` up front, dedup post-rename events, and conditionally skip the `removeItem` for dotfiles.
  - Made `showManualOCRPanel`'s `changeCount` parameter optional. Added an early call in `handleNewFile` (image branch) right after `loadedScreenshotImage` succeeds. `writeAndHandleImage` now calls it a second time to commit the real changeCount + post-mask thumbnail; on failure path it dismisses to avoid stranding a stale popup.

- `ClipboardOnly.xcodeproj/project.pbxproj`: `MARKETING_VERSION` 1.2.7 → 1.2.8, `CURRENT_PROJECT_VERSION` 126 → 128.

- `README.md`: added "Notes on macOS 26.4+" section between Features and Install, bilingual (EN + 中文), explaining the screencapture behavior change and v1.2.8's accommodation.

- `ClipboardOnly/ScreenshotWatcher.swift`: **untouched in the final state**. Earlier in the session I added a dotfile filter here, then reverted — the dedup logic lives in MenuBarController instead.

### Shipped

- Commit `ac5edb3` "Fix screencapture race on macOS 26.4+ and surface popup faster" — pushed to `main`.
- Commit `7de8b9e` "Document macOS 26.4+ screencapture behavior change" — pushed to `main`.
- Tag `v1.2.8` pushed.
- GitHub release: https://github.com/akb4q/ClipboardOnly/releases/tag/v1.2.8 (bilingual notes, `/tmp/ClipboardOnly-v1.2.8.zip` 235 KB attached).
- `/Applications/ClipboardOnly.app` replaced with v1.2.8 build 128 (running).

### Open items / known issues

- **`writeImageToClipboard` is still synchronous on the main path.** Resize-to-1568 + PNG encode can take 0.5-1s for retina screenshots. v1.2.8 hides this from the popup, but it still delays clipboard availability for Cmd+V. Could be moved to a background queue if it becomes a complaint.
- **Brief unmasked thumbnail visible** when privacy filter is on: the early popup shows the raw thumbnail; ~1-2s later the post-mask thumbnail replaces it. Acceptable for now (user just saw the unmasked screenshot during selection). Documented as a trade-off in the v1.2.8 commit message.
- **`pendingDotfileBaseNames` FIFO is unbounded by time, only by count (cap 64).** If 64 dotfiles ever pile up without rename, oldest entry gets dropped → that one's eventual rename event won't be deduped and will be silently `removeItem`'d on its own. Not currently reachable since you take at most one screenshot per minute and screencapture renames within 55s.
- **Codex handoff `/tmp/codex-handoff-memory.md` for Tier 1 memory optimizations** — still untouched. Out of scope for this session.

### Context for next session

- macOS 26.4.1 on user's machine. Apple Silicon. Disk currently 47 GiB free (was 11 GiB earlier — cleanup is sticky for now).
- Project root: `/Users/zhuyunjiang/Documents/Documents - jimu/Claude Code Project/Projects/ClipboardOnly` (iCloud-synced — Release builds need `-derivedDataPath /tmp/cbo-build` outside iCloud or codesign fails on xattr).
- **Don't trust the parent dir for builds**: earlier in the session `xcodebuild` from `~/Documents/.../ClipboardOnly` with default derived data path deadlocked for 20 min. Always use `-derivedDataPath /tmp/cbo-build` and `-quiet`.
- Bundle id: `com.akb4q.clipboard-only`. Defaults are at `defaults read com.akb4q.clipboard-only`.
- Build → replace `/Applications` pipeline (proven this session):
  ```bash
  cd "<repo>" && xcodebuild -project ClipboardOnly.xcodeproj -scheme ClipboardOnly \
    -configuration Release -derivedDataPath /tmp/cbo-build -quiet build
  pkill -x ClipboardOnly; sleep 1
  rm -rf /Applications/ClipboardOnly.app
  cp -R /tmp/cbo-build/Build/Products/Release/ClipboardOnly.app /Applications/
  xattr -cr /Applications/ClipboardOnly.app
  open /Applications/ClipboardOnly.app
  ```
- Diagnostic command for any future "无法保存截屏" / "screenshot not intercepted" report:
  ```bash
  /usr/bin/log show --last 5m --predicate "process == 'screencapture'" --info \
    | grep -iE "error|failed|move|rename"
  ls -la ~/.clipboard_only/intercept/   # should be empty in steady state
  defaults read com.apple.screencapture | grep -E "location|target"
  ```
- User communicates in Simplified Chinese. **Do not use Traditional Chinese** in release notes / commit messages / UI (got corrected once in a prior session).
