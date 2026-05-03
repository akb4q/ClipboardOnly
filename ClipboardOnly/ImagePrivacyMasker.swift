// ImagePrivacyMasker.swift — Vision-based screenshot text redaction

import AppKit
import Vision
import CoreGraphics

extension PrivacyFilterType {
    var redactionColor: NSColor {
        switch self {
        case .apiKey:
            return NSColor.systemRed
        case .creditCard:
            return NSColor.systemOrange
        case .email:
            return NSColor.systemBlue
        case .phone:
            return NSColor.systemGreen
        case .idCard:
            return NSColor.systemPurple
        case .ipAddress:
            return NSColor.systemTeal
        case .password:
            return NSColor.systemPink
        }
    }
}

// MARK: – ImagePrivacyMasker

final class ImagePrivacyMasker {

    var filter: PrivacyFilter

    // Extra pixels added around each bounding box to ensure full coverage.
    private let padding: CGFloat = 4

    init(filter: PrivacyFilter = .loadFromDefaults()) {
        self.filter = filter
    }

    /// Returns a new image with sensitive regions covered by solid black rectangles.
    /// Runs on a background thread; completion is called on the main thread.
    func mask(
        _ cgImage: CGImage,
        retainedData: Data? = nil,
        maxOutputLongEdge: CGFloat? = nil,
        completion: @escaping (CGImage?) -> Void
    ) {
        recognizeAndFilter(in: cgImage, retainedData: retainedData) { [weak self, retainedData] rects in
            let masked = withExtendedLifetime(retainedData) {
                self?.applyMask(to: cgImage, rects: rects, maxOutputLongEdge: maxOutputLongEdge)
            }
            DispatchQueue.main.async { completion(masked) }
        }
    }

    // MARK: – OCR + filter, only mask matched regions

    private struct RedactionRect {
        let rect: CGRect
        let type: PrivacyFilterType
    }

    private func recognizeAndFilter(
        in cgImage: CGImage,
        retainedData: Data?,
        completion: @escaping ([RedactionRect]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, retainedData] in
            autoreleasepool {
                withExtendedLifetime(retainedData) {
                    guard let self else { completion([]); return }

                    var sensitiveRects: [RedactionRect] = []

                    let request = VNRecognizeTextRequest { [weak self] request, _ in
                        guard let self,
                              let observations = request.results as? [VNRecognizedTextObservation]
                        else { return }

                        var recognizedLines: [(observation: VNRecognizedTextObservation, candidate: VNRecognizedText, text: String)] = []

                        for obs in observations {
                            guard let candidate = obs.topCandidates(1).first else { continue }
                            let recognized = candidate.string
                            recognizedLines.append((obs, candidate, recognized))
                            let result = self.filter.filter(recognized)
                            guard result.didMatch else { continue }

                            // For each matched fragment, map its NSRange (in `recognized`)
                            // to a String.Range and ask Vision for the precise bounding box.
                            // Fall back to the full observation box if Vision can't provide one.
                            var addedObsBox = false
                            for match in result.matches {
                                if let stringRange = Range(match.nsRange, in: recognized),
                                   let box = try? candidate.boundingBox(for: stringRange) {
                                    sensitiveRects.append(RedactionRect(rect: box.boundingBox, type: match.type))
                                } else if !addedObsBox {
                                    sensitiveRects.append(RedactionRect(rect: obs.boundingBox, type: match.type))
                                    addedObsBox = true
                                }
                            }
                        }

                        sensitiveRects.append(contentsOf: self.detectMultilineTokenRects(in: recognizedLines))
                        if self.filter.enabledTypes.contains(.password) {
                            sensitiveRects.append(contentsOf: self.detectPasswordLabelValueRects(in: recognizedLines))
                        }
                    }
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                    request.usesLanguageCorrection = false // faster; content accuracy less important here

                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try? handler.perform([request])
                    completion(sensitiveRects)
                }
            }
        }
    }

    private func detectMultilineTokenRects(
        in lines: [(observation: VNRecognizedTextObservation, candidate: VNRecognizedText, text: String)]
    ) -> [RedactionRect] {
        let sorted = lines.sorted {
            if abs($0.observation.boundingBox.midY - $1.observation.boundingBox.midY) > 0.01 {
                return $0.observation.boundingBox.midY > $1.observation.boundingBox.midY
            }
            return $0.observation.boundingBox.minX < $1.observation.boundingBox.minX
        }

        var rects: [RedactionRect] = []
        var maskingTokenBlock = false
        var previousRect: CGRect?

        for line in sorted {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let startsToken = looksLikeAPIKeyStart(text)
            let continuesToken = maskingTokenBlock
                && isLikelyTokenContinuation(text)
                && isVerticallyNear(previousRect, line.observation.boundingBox)

            if startsToken || continuesToken {
                rects.append(RedactionRect(rect: line.observation.boundingBox, type: .apiKey))
                maskingTokenBlock = true
                previousRect = line.observation.boundingBox
            } else if maskingTokenBlock, text.isEmpty {
                continue
            } else {
                maskingTokenBlock = false
                previousRect = nil
            }
        }

        return rects
    }

    private func looksLikeAPIKeyStart(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("sk-") || lower.hasPrefix("sk_") { return true }
        if lower.hasPrefix("pk_live_") || lower.hasPrefix("pk_test_") { return true }
        if lower.hasPrefix("ghp_") || lower.hasPrefix("gho_") { return true }
        if lower.hasPrefix("xox") || text.hasPrefix("AKIA") || text.hasPrefix("AIza") { return true }
        return false
    }

    private func isLikelyTokenContinuation(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.count >= 18 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_ .")
        let scalars = compact.unicodeScalars
        let allowedCount = scalars.filter { allowed.contains($0) }.count
        return Double(allowedCount) / Double(max(scalars.count, 1)) > 0.9
    }

    private func isVerticallyNear(_ previous: CGRect?, _ current: CGRect) -> Bool {
        guard let previous else { return true }
        let gap = previous.minY - current.maxY
        return gap >= -0.02 && gap < max(previous.height, current.height) * 1.8
    }

    // MARK: – Form-field label/value pairing
    //
    // The OCR-text regex catches "密碼: hunter2" and even "密碼\n hunter2" once
    // observations are joined, but the IMAGE masker filters per-observation —
    // when a form puts the "密碼" label and the input value in two visually
    // separate cells, neither line matches the password regex on its own and
    // the value is never redacted on the pixel image.
    //
    // detectPasswordLabelValueRects fills the gap: find a label-only
    // observation, then redact the spatially nearest value-shaped observation
    // directly below it (form field below label) or to the right of it (form
    // field beside label). Tight thresholds keep this from firing on prose.

    // Pattern uses literal characters only. NSRegularExpression's ICU engine
    // does NOT accept Swift's `\u{XXXX}` escape — see compileRegex docs. The
    // helper crashes loud on any malformed pattern at launch, so this property
    // can be non-optional.
    private static let passwordLabelOnlyRegex: NSRegularExpression = compileRegex(
        #"^\s*(?:密码|密碼|口令|password|passwd|passcode|pwd)\s*[:：=]?\s*$"#,
        options: [.caseInsensitive]
    )

    private func detectPasswordLabelValueRects(
        in lines: [(observation: VNRecognizedTextObservation, candidate: VNRecognizedText, text: String)]
    ) -> [RedactionRect] {
        let labelRegex = Self.passwordLabelOnlyRegex

        var rects: [RedactionRect] = []
        for label in lines {
            let labelText = label.text
            let labelRange = NSRange(labelText.startIndex..., in: labelText)
            guard labelRegex.firstMatch(in: labelText, range: labelRange) != nil else { continue }

            guard let value = nearestValueObservation(forLabel: label.observation, in: lines) else { continue }
            rects.append(RedactionRect(rect: value.observation.boundingBox, type: .password))
        }
        return rects
    }

    private func nearestValueObservation(
        forLabel labelBox: VNRecognizedTextObservation,
        in lines: [(observation: VNRecognizedTextObservation, candidate: VNRecognizedText, text: String)]
    ) -> (observation: VNRecognizedTextObservation, candidate: VNRecognizedText, text: String)? {
        let lb = labelBox.boundingBox
        // Vision: normalized coords, origin bottom-left. "Visually below" = lower midY.
        // Limit search to a tight window so we don't grab unrelated form fields.
        let verticalReach: CGFloat = 0.08    // ~8% of image height
        let horizontalReach: CGFloat = 0.20  // ~20% of image width

        var best: (line: (observation: VNRecognizedTextObservation, candidate: VNRecognizedText, text: String), score: CGFloat)?

        for candidate in lines {
            let cb = candidate.observation.boundingBox
            if cb == lb { continue }

            let trimmed = candidate.text.trimmingCharacters(in: .whitespaces)
            guard looksLikeFormValue(trimmed) else { continue }

            // Pair A: value sits BELOW label, roughly same X column.
            let isBelow = cb.midY < lb.midY
            let xOverlapsBelow = max(cb.minX, lb.minX) < min(cb.maxX, lb.maxX) + 0.02
            let yGap = lb.minY - cb.maxY
            if isBelow, xOverlapsBelow, yGap > -0.02, yGap < verticalReach {
                let score = yGap + abs(cb.midX - lb.midX) * 0.5
                if best == nil || score < best!.score { best = (candidate, score) }
                continue
            }

            // Pair B: value sits TO THE RIGHT of label, roughly same Y row.
            let yOverlap = max(cb.minY, lb.minY) < min(cb.maxY, lb.maxY)
            let xGap = cb.minX - lb.maxX
            if yOverlap, xGap > -0.02, xGap < horizontalReach {
                let score = xGap + abs(cb.midY - lb.midY) * 0.5
                if best == nil || score < best!.score { best = (candidate, score) }
            }
        }
        return best?.line
    }

    private func looksLikeFormValue(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        guard (4...64).contains(compact.count) else { return false }
        // Reject obvious labels / prose: must contain at least one digit OR a
        // password-shaped special character. Pure-letter words ("please",
        // "required") are filtered out so we don't mask sentence fragments.
        let hasDigit = compact.contains(where: { $0.isNumber })
        let specials: Set<Character> = ["!", "@", "#", "$", "%", "^", "&", "*", "_", "-", "+", "=", "?", "/", "\\", "."]
        let hasSpecial = compact.contains(where: { specials.contains($0) })
        guard hasDigit || hasSpecial else { return false }
        // Reject if it itself looks like a label (starts with another known label keyword).
        let lower = text.lowercased()
        for keyword in ["password", "passwd", "pwd", "passcode", "口令", "密码", "密碼"] {
            if lower.hasPrefix(keyword) { return false }
        }
        return true
    }

    // MARK: – Draw redaction rectangles

    private func applyMask(
        to cgImage: CGImage,
        rects: [RedactionRect],
        maxOutputLongEdge: CGFloat?
    ) -> CGImage? {
        return autoreleasepool {
            let sourceWidth = cgImage.width
            let sourceHeight = cgImage.height
            let outputSize = Self.outputSize(
                width: sourceWidth,
                height: sourceHeight,
                maxLongEdge: maxOutputLongEdge
            )

            guard !rects.isEmpty else {
                guard outputSize.width != sourceWidth || outputSize.height != sourceHeight else {
                    return cgImage
                }
                return Self.draw(cgImage, width: outputSize.width, height: outputSize.height)
            }

            // Force a known-good 32-bit BGRA layout. Reusing the source image's
            // bitmapInfo can fail on uncommon screenshot color spaces (e.g. P3,
            // 16-bit). If the redaction context can't be created, fail closed —
            // returning nil signals upstream NOT to fall back to the original image.
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let ctx = CGContext(
                data: nil,
                width: outputSize.width, height: outputSize.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else { return nil }

            // Draw original image.
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height))

            // Vision bounding boxes use normalized coordinates with origin at bottom-left.
            // Core Graphics also has origin at bottom-left, so only scale is needed.
            for redaction in rects {
                let normRect = redaction.rect
                let pixelRect = CGRect(
                    x: normRect.minX * CGFloat(outputSize.width)  - padding,
                    y: normRect.minY * CGFloat(outputSize.height) - padding,
                    width:  normRect.width  * CGFloat(outputSize.width)  + padding * 2,
                    height: normRect.height * CGFloat(outputSize.height) + padding * 2
                ).intersection(CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height))

                ctx.setFillColor(redaction.type.redactionColor.cgColor)
                ctx.fill(pixelRect)
            }

            return ctx.makeImage()
        }
    }

    private static func outputSize(
        width: Int,
        height: Int,
        maxLongEdge: CGFloat?
    ) -> (width: Int, height: Int) {
        guard let maxLongEdge else { return (width, height) }
        let longEdge = CGFloat(max(width, height))
        guard longEdge > maxLongEdge else { return (width, height) }

        let scale = maxLongEdge / longEdge
        return (
            Int((CGFloat(width) * scale).rounded()),
            Int((CGFloat(height) * scale).rounded())
        )
    }

    private static func draw(_ cgImage: CGImage, width: Int, height: Int) -> CGImage? {
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
