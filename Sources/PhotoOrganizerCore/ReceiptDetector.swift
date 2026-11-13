import Foundation
import CoreGraphics
import Vision

/// Two-stage gated OCR receipt detector using Apple Vision `VNRecognizeTextRequest`.
public struct ReceiptDetector: Sendable {
    private static let gateIdentifiers: Set<String> = [
        "document", "receipt", "paper", "text", "invoice", "menu",
        "sign", "letter", "page", "book", "newspaper", "screenshot",
        "whiteboard", "label", "ticket", "card"
    ]

    private static let receiptKeywords: [String] = [
        "SUBTOTAL", "SUB-TOTAL", "TOTAL", "NET TOTAL", "GRAND TOTAL",
        "TAX", "GST", "VAT", "SERVICE CHARGE", "RECEIPT", "INVOICE",
        "VISA", "MASTERCARD", "AMEX", "CASH", "CHANGE", "QTY",
        "AMOUNT", "TENDERED", "BALANCE", "PAID", "CHECK #"
    ]

    public init() {}

    /// Stage 1 gate: only run heavy OCR when Vision scene classification hints at text/paper/documents.
    public static func shouldRunOCR(classifications: [String: Float], minimumConfidence: Float = 0.15) -> Bool {
        for (identifier, confidence) in classifications {
            guard confidence >= minimumConfidence else { continue }
            let lower = identifier.lowercased()
            if gateIdentifiers.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// Stage 2: Runs on-device OCR via `VNRecognizeTextRequest` and applies receipt heuristics.
    public func isReceipt(cgImage: CGImage) -> Bool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return false
        }

        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return Self.isReceiptText(lines: lines)
    }

    /// Evaluates extracted OCR lines for currency/price columns and receipt signature keywords.
    public static func isReceiptText(lines: [String]) -> Bool {
        guard !lines.isEmpty else { return false }

        let combinedUpper = lines.joined(separator: "\n").uppercased()

        var matchedKeywords = 0
        for keyword in receiptKeywords {
            if combinedUpper.contains(keyword) {
                matchedKeywords += 1
            }
        }

        let pricePattern = #"(?:(?:\$|SGD|USD|RM|MYR|EUR|GBP|JPY|¥|£|€)\s*\d[\d,]*(?:\.\d{2})?|\b\d{1,5}\.\d{2}\b)"#
        let priceRegex = try? NSRegularExpression(pattern: pricePattern, options: [.caseInsensitive])

        var priceLineMatches = 0
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let regex = priceRegex, regex.firstMatch(in: line, range: range) != nil {
                priceLineMatches += 1
            }
        }

        if matchedKeywords >= 2 && priceLineMatches >= 1 {
            return true
        }
        if matchedKeywords >= 1 && priceLineMatches >= 3 {
            return true
        }
        return false
    }
}
