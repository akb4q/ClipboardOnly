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
    func mask(_ image: NSImage, completion: @escaping (NSImage?) -> Void) {
        guard let cgImage = image.cgImage else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        recognizeAndFilter(in: cgImage) { [weak self] rects in
            let masked = self?.applyMask(to: cgImage, rects: rects)
            DispatchQueue.main.async { completion(masked) }
        }
    }

    // MARK: – OCR + filter, only mask matched regions

    private struct RedactionRect {
        let rect: CGRect
        let type: PrivacyFilterType
    }

    private func recognizeAndFilter(in cgImage: CGImage, completion: @escaping ([RedactionRect]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = false // faster; content accuracy less important here

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            completion(sensitiveRects)
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

    // MARK: – Draw redaction rectangles

    private func applyMask(to cgImage: CGImage, rects: [RedactionRect]) -> NSImage? {
        guard !rects.isEmpty else {
            // Nothing to mask — return original wrapped in NSImage
            return NSImage(cgImage: cgImage, size: .zero)
        }

        let width  = cgImage.width
        let height = cgImage.height

        // Force a known-good 32-bit BGRA layout. Reusing the source image's
        // bitmapInfo can fail on uncommon screenshot color spaces (e.g. P3,
        // 16-bit). If the redaction context can't be created, fail closed —
        // returning nil signals upstream NOT to fall back to the original image.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // Draw original image.
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Vision bounding boxes use normalized coordinates with origin at bottom-left.
        // Core Graphics also has origin at bottom-left, so only scale is needed.
        for redaction in rects {
            let normRect = redaction.rect
            let pixelRect = CGRect(
                x: normRect.minX * CGFloat(width)  - padding,
                y: normRect.minY * CGFloat(height) - padding,
                width:  normRect.width  * CGFloat(width)  + padding * 2,
                height: normRect.height * CGFloat(height) + padding * 2
            ).intersection(CGRect(x: 0, y: 0, width: width, height: height))

            ctx.setFillColor(redaction.type.redactionColor.cgColor)
            ctx.fill(pixelRect)
        }

        guard let maskedCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: maskedCG, size: NSSize(width: width, height: height))
    }
}

// MARK: – NSImage helper

private extension NSImage {
    var cgImage: CGImage? {
        guard let data = tiffRepresentation,
              let rep  = NSBitmapImageRep(data: data) else { return nil }
        return rep.cgImage
    }
}
