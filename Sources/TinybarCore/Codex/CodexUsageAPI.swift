import Foundation

/// Helpers the Codex and Claude limit mappings share.
enum CodexUsageAPI {
    struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    static func formatPlan(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pro": "Pro"
        case "plus": "Plus"
        case "team": "Team"
        case "business": "Business"
        case "enterprise": "Enterprise"
        case "edu": "Edu"
        case "free": "Free"
        default: raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }
}

func parseISODate(_ raw: String) -> Date? {
    if let d = parseUTCTimestamp(raw) { return d }
    // Foundation normalizes invalid dates and ignores suffix garbage; validate before falling back.
    let syntax = #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):?[0-5][0-9])\z"#
    guard raw.range(of: syntax, options: .regularExpression) != nil,
          parseUTCTimestamp(String(raw.prefix(19)) + "Z") != nil else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: raw) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
}

/// `2026-10-15T07:52:26.877Z`, the shape both CLIs log on every line, without a formatter: the
/// log parsers read hundreds of thousands of them. nil for anything else (offsets, no `Z`).
func parseUTCTimestamp(_ raw: String) -> Date? {
    var utf8 = raw.utf8.makeIterator()
    var bytes: [UInt8] = []
    bytes.reserveCapacity(24)
    while let b = utf8.next() {
        guard bytes.count < 32 else { return nil }
        bytes.append(b)
    }
    guard bytes.count >= 20, bytes.last == UInt8(ascii: "Z"), bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
          bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":")
    else { return nil }
    func num(_ from: Int, _ count: Int) -> Int? {
        var n = 0
        for i in from..<(from + count) {
            let d = Int(bytes[i]) - 48
            guard (0...9).contains(d) else { return nil }
            n = n * 10 + d
        }
        return n
    }
    guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2),
          let s = num(17, 2), (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61
    else { return nil }
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
    let monthDays = mo == 2 ? (leap ? 29 : 28) : ([4, 6, 9, 11].contains(mo) ? 30 : 31)
    guard d <= monthDays else { return nil }
    var fraction = 0.0
    if bytes.count > 20 {
        guard bytes[19] == UInt8(ascii: "."), bytes.count > 21 else { return nil }
        var scale = 0.1
        for i in 20..<(bytes.count - 1) {
            let digit = Int(bytes[i]) - 48
            guard (0...9).contains(digit) else { return nil }
            fraction += Double(digit) * scale
            scale /= 10
        }
    } else if bytes[19] != UInt8(ascii: "Z") {
        return nil
    }
    // Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's days_from_civil).
    let yy = mo <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146_097 + doe - 719_468
    return Date(timeIntervalSince1970: Double(days * 86400 + h * 3600 + mi * 60 + s) + fraction)
}
