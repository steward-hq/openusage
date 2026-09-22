import Foundation

/// Parses the rendered semantic labels from Meta's usage dashboard into OpenUsage's normalized
/// progress lines. A partial page yields the valid meter only; no usable meter is a typed failure.
enum MuseUsageMapper {
    static func lines(
        from text: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [MetricLine] {
        let normalized = text.replacingOccurrences(of: "\u{202F}", with: " ")
        let sessionBlock = block(in: normalized, startingAt: "Current usage", endingAt: "Weekly limit")
        let weeklyBlock = block(in: normalized, startingAt: "Weekly limit", endingAt: nil)

        var lines: [MetricLine] = []
        if let sessionBlock, let used = percent(in: sessionBlock, label: "Current usage") {
            lines.append(.progress(
                label: "Session",
                used: ProviderParse.clampPercent(used),
                limit: 100,
                format: .percent,
                resetsAt: resetDate(in: sessionBlock, now: now, calendar: calendar),
                periodDurationMs: MetricPeriod.sessionMs
            ))
        }
        if let weeklyBlock, let used = percent(in: weeklyBlock, label: "Weekly limit") {
            lines.append(.progress(
                label: "Weekly",
                used: ProviderParse.clampPercent(used),
                limit: 100,
                format: .percent,
                resetsAt: resetDate(in: weeklyBlock, now: now, calendar: calendar),
                periodDurationMs: MetricPeriod.weekMs
            ))
        }
        guard !lines.isEmpty else { throw MuseDashboardUsageError.invalidPage }
        return lines
    }

    private static func block(in text: String, startingAt label: String, endingAt nextLabel: String?) -> String? {
        guard let start = text.range(of: label, options: .caseInsensitive) else { return nil }
        let tail = text[start.lowerBound...]
        if let nextLabel, let end = tail.range(of: nextLabel, options: .caseInsensitive) {
            return String(tail[..<end.lowerBound])
        }
        return String(tail)
    }

    private static func percent(in block: String, label: String) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let number = "(-?\\d+(?:\\.\\d+)?)"
        let patterns = [
            "(?is)\\b\(escaped)\\b\\s*\(number)\\s*%",
            "(?is)\\b\(escaped)\\b\\s*\(number)\\s*(?:of|/)"
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: block, range: NSRange(block.startIndex..., in: block)
                  ),
                  let range = Range(match.range(at: 1), in: block),
                  let value = Double(block[range])
            else { continue }
            return value
        }
        return nil
    }

    private static func resetDate(in block: String, now: Date, calendar: Calendar) -> Date? {
        guard let expression = try? NSRegularExpression(
            pattern: "(?im)\\bResets(?:\\s+at)?\\s+([^\\r\\n]+)"
        ), let match = expression.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
           let range = Range(match.range(at: 1), in: block)
        else { return nil }

        var label = block[range].trimmingCharacters(in: .whitespacesAndNewlines)
        if label.lowercased().hasPrefix("today at ") {
            label = String(label.dropFirst("today at ".count))
        }
        return date(fromResetLabel: label, now: now, calendar: calendar)
    }

    private static func date(fromResetLabel label: String, now: Date, calendar: Calendar) -> Date? {
        let locale = Locale(identifier: "en_US_POSIX")
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        formatter.dateFormat = "h:mm a"
        if let parsed = formatter.date(from: label) {
            let time = calendar.dateComponents([.hour, .minute, .second], from: parsed)
            var day = calendar.dateComponents([.year, .month, .day], from: now)
            day.timeZone = calendar.timeZone
            day.hour = time.hour
            day.minute = time.minute
            day.second = time.second
            guard let candidate = calendar.date(from: day) else { return nil }
            return candidate > now ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate)
        }

        formatter.dateFormat = "MMM d 'at' h:mm a"
        guard let parsed = formatter.date(from: label) else { return nil }
        let reset = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: parsed)
        var components = reset
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = calendar.component(.year, from: now)
        guard let candidate = calendar.date(from: components) else { return nil }
        if candidate > now { return candidate }
        components.year = (components.year ?? 0) + 1
        return calendar.date(from: components)
    }
}
