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

    /// Stage 2: Runs on-device OCR via `VNRecognizeTextRequest` and returns structured receipt metadata if matched.
    public func detectReceipt(cgImage: CGImage) -> ReceiptMetadata? {
        let lines = recognizeLines(in: cgImage)
        return Self.parseReceiptMetadata(lines: lines)
    }

    /// Stage 2: Runs on-device OCR via `VNRecognizeTextRequest` and applies receipt heuristics.
    public func isReceipt(cgImage: CGImage) -> Bool {
        Self.isReceiptText(lines: recognizeLines(in: cgImage))
    }

    private func recognizeLines(in cgImage: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }

    /// Parses merchant name, currency symbol, and total amount from OCR lines when receipt heuristics match.
    public static func parseReceiptMetadata(lines: [String]) -> ReceiptMetadata? {
        guard isReceiptText(lines: lines) else { return nil }

        let ignoredMerchantPrefixes = ["DATE", "TEL", "RECEIPT", "INVOICE", "TAX", "QTY", "TABLE", "ORDER", "TIME"]
        var merchantName: String?
        for rawLine in lines.prefix(5) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()
            let letterCount = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard letterCount >= 3 else { continue }
            if ignoredMerchantPrefixes.contains(where: { upper.hasPrefix($0) }) { continue }
            merchantName = trimmed
            break
        }

        let pricePattern = #"(?:(S\$|US\$|\$|SGD|USD|RM|MYR|EUR|GBP|JPY|¥|£|€)\s*(\d[\d,]*(?:\.\d{2})?)|()(\d[\d,]*\.\d{2}))"#
        let priceRegex = try? NSRegularExpression(pattern: pricePattern, options: [.caseInsensitive])

        func extractPrice(from line: String) -> (symbol: String?, amount: Double)? {
            guard let priceRegex else { return nil }
            let range = NSRange(line.startIndex..., in: line)
            let matches = priceRegex.matches(in: line, range: range)
            guard let lastMatch = matches.last else { return nil }

            let symGroup: Int
            let amtGroup: Int
            if lastMatch.range(at: 2).location != NSNotFound {
                symGroup = 1
                amtGroup = 2
            } else if lastMatch.range(at: 4).location != NSNotFound {
                symGroup = 3
                amtGroup = 4
            } else {
                return nil
            }

            guard let amountRange = Range(lastMatch.range(at: amtGroup), in: line) else {
                return nil
            }
            let cleanedNumber = line[amountRange].replacingOccurrences(of: ",", with: "")
            guard let value = Double(cleanedNumber) else { return nil }
            var symbol: String?
            if lastMatch.range(at: symGroup).location != NSNotFound,
               let symRange = Range(lastMatch.range(at: symGroup), in: line) {
                let rawSym = String(line[symRange]).uppercased()
                if !rawSym.isEmpty {
                    symbol = rawSym
                }
            }
            return (symbol, value)
        }

        let totalMarkers = ["GRAND TOTAL", "NET TOTAL", "AMOUNT DUE", "TOTAL", "NETT", "PAID"]
        var resolvedTotal: Double?
        var resolvedCurrency: String?
        var maxPriceSeen: Double?
        var maxPriceCurrency: String?

        for line in lines {
            let upper = line.uppercased()
            if let extracted = extractPrice(from: line) {
                if maxPriceSeen == nil || extracted.amount > maxPriceSeen! {
                    maxPriceSeen = extracted.amount
                    maxPriceCurrency = extracted.symbol ?? maxPriceCurrency
                }
                let isSubtotal = upper.contains("SUBTOTAL") || upper.contains("SUB-TOTAL")
                let isTaxOnly = (upper.contains("TAX") || upper.contains("GST"))
                    && !upper.contains("GRAND") && !upper.contains("INCL")
                if !isSubtotal && !isTaxOnly && totalMarkers.contains(where: { upper.contains($0) }) {
                    if resolvedTotal == nil || extracted.amount >= resolvedTotal! {
                        resolvedTotal = extracted.amount
                        resolvedCurrency = extracted.symbol ?? resolvedCurrency
                    }
                }
            }
        }

        return ReceiptMetadata(
            merchantName: merchantName,
            totalAmount: resolvedTotal ?? maxPriceSeen,
            currencySymbol: resolvedCurrency ?? maxPriceCurrency
        )
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

        let pricePattern = #"(?:(?:S\$|US\$|\$|SGD|USD|RM|MYR|EUR|GBP|JPY|¥|£|€)\s*\d[\d,]*(?:\.\d{2})?|\b\d{1,5}\.\d{2}\b)"#
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
