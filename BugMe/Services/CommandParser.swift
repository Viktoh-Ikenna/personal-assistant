import Foundation

struct ParsedTask: Equatable {
    var title: String
    var dueDate: Date
    var intervalMinutes: Int
    var recurrence: Recurrence = .none
    var allocatedMinutes: Int = 0
}

enum VoiceCommand: Equatable {
    case add(ParsedTask)
    case complete(String)
    case list
    case checkIn
    case start(String)
    case pause
    case unknown
}

/// Offline natural-language parsing for things like
/// "bug me to call mom at 5pm every 10 minutes", "pay rent on the 1st of every month"
/// or "I finished the laundry".
enum CommandParser {

    static func parse(_ raw: String, defaultInterval: Int, now: Date = .now) -> VoiceCommand {
        let text = clean(raw)
        guard !text.isEmpty else { return .unknown }

        if matches(#"^(?:let'?s\s+)?(?:do\s+(?:my|a|the)\s+|start\s+(?:my\s+)?)?(?:morning\s+|evening\s+|daily\s+)?check[\s-]?in\b"#, text) {
            return .checkIn
        }
        if matches(#"^(?:stop|pause|end|break)(?:\s+(?:the\s+|my\s+)?(?:timer|tracking|working|clock|it))?(?:\s+(?:now|please))?$|^(?:i'?m\s+)?taking\s+a\s+break$"#, text) {
            return .pause
        }
        if let m = firstMatch(#"^(?:start|begin|resume)\s+(?:working\s+on\s+|(?:the\s+)?timer\s+(?:for|on)\s+|on\s+)?(.+)$|^(?:work\s+on|i'?m\s+(?:starting|working\s+on))\s+(.+)$"#, in: text),
           let query = (group(m, 1, in: text) ?? group(m, 2, in: text))?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            return .start(query)
        }
        if matches(#"^(?:what(?:'s|\s+is|\s+are|\s+do\s+i\s+have)|list|show|read|tell\s+me)\b"#, text),
           matches(#"\b(?:list|tasks?|bugs?|have|to\s*-?do|left|on|plate)\b"#, text) {
            return .list
        }
        if let m = firstMatch(#"^(?:i\s+(?:just\s+|already\s+)?(?:finished|completed|did|paid)|finished|completed|done\s+with|mark)\s+(.+?)(?:\s+(?:as\s+)?(?:done|complete|completed|finished))?$"#, in: text),
           let query = group(m, 1, in: text)?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            return .complete(query)
        }
        if let task = parseTask(text, defaultInterval: defaultInterval, now: now) {
            return .add(task)
        }
        return .unknown
    }

    static func parseTask(_ raw: String, defaultInterval: Int, now: Date = .now) -> ParsedTask? {
        var text = clean(raw)

        // Strip the "assistant" phrasing.
        text = replace(#"^(?:hey|ok|okay)[,\s]+"#, in: text)
        text = replace(#"^bug\s?me[,:!]\s*"#, in: text)
        text = replace(#"^(?:please\s+)?(?:can\s+you\s+)?(?:bug|remind|nag|ping|pester)\s+me\s+(?:to|about|that|of)?\s*"#, in: text)
        text = replace(#"^(?:add|create|new)\s+(?:a\s+)?(?:new\s+)?(?:monthly\s+|weekly\s+|daily\s+)?(?:task|bug|reminder|to\s*-?do)\s*(?:to|for|:)?\s*"#, in: text)
        text = replace(#"^i\s+(?:need|have|want|got)\s+to\s+|^i\s+(?:must|should)\s+"#, in: text)
        text = replace(#"\s*(?:,\s*)?(?:please|for me)$"#, in: text)
        text = normalizeNumbers(text)

        // Repeats: "on the 1st of every month", "every month", "monthly", "every week", "every monday", "daily".
        var recurrence = Recurrence.none
        var dayOfMonth: Int?
        let ord = #"(\d{1,2})(?:st|nd|rd|th)?"#
        if let m = firstMatch(#"\b(?:on\s+)?the\s+"# + ord + #"\s+(?:of\s+)?(?:every|each|the|a)\s+month\b"#, in: text) {
            recurrence = .monthly
            dayOfMonth = group(m, 1, in: text).flatMap(Int.init)
            text = removing(m, from: text)
        } else if let m = firstMatch(#"\b(?:(?:every|each|a)\s+month|monthly)(?:\s+on\s+the\s+"# + ord + #")?\b"#, in: text) {
            recurrence = .monthly
            dayOfMonth = group(m, 1, in: text).flatMap(Int.init)
            text = removing(m, from: text)
        } else if let m = firstMatch(#"\bevery\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)s?\b"#, in: text) {
            recurrence = .weekly
            let day = group(m, 1, in: text)?.lowercased() ?? ""
            let isToday = Calendar.current.weekdaySymbols[Calendar.current.component(.weekday, from: now) - 1].lowercased() == day
            text = (text as NSString).replacingCharacters(in: m.range, with: isToday ? "today" : "on " + day)
        } else if let m = firstMatch(#"\b(?:(?:every|each|a)\s+week|weekly)\b"#, in: text) {
            recurrence = .weekly
            text = removing(m, from: text)
        } else if let m = firstMatch(#"\b(?:every|each)\s+(morning|afternoon|evening|night)\b"#, in: text) {
            recurrence = .daily
            let part = group(m, 1, in: text)?.lowercased() ?? "morning"
            text = (text as NSString).replacingCharacters(in: m.range, with: part == "night" ? "tonight" : "this \(part)")
        } else if let m = firstMatch(#"\b(?:(?:every|each|a)\s+day|daily)\b"#, in: text) {
            recurrence = .daily
            text = removing(m, from: text)
        }
        if dayOfMonth == nil, let m = firstMatch(#"\bon\s+the\s+(\d{1,2})(?:st|nd|rd|th)\b"#, in: text) {
            dayOfMonth = group(m, 1, in: text).flatMap(Int.init)
            text = removing(m, from: text)
        }
        if let d = dayOfMonth, !(1...31).contains(d) { dayOfMonth = nil }

        // Time budget: "for 30 minutes", "takes an hour".
        var allocated = 0
        if let m = firstMatch(#"\b(?:for|takes?|lasting|needs?)\s+(?:about\s+|around\s+|roughly\s+)?(\d+)\s*(minutes?|mins?|hours?|hrs?)\b"#, in: text),
           let n = group(m, 1, in: text).flatMap(Int.init), let unit = group(m, 2, in: text)?.lowercased() {
            allocated = min(unit.hasPrefix("h") ? n * 60 : n, 24 * 60)
            text = removing(m, from: text)
        }

        // Nag interval: "every 10 minutes", "every hour".
        var interval = defaultInterval
        if let m = firstMatch(#"\b(?:every|each)\s+(\d+)\s*(minutes?|mins?|m|hours?|hrs?|h)\b"#, in: text),
           let n = group(m, 1, in: text).flatMap(Int.init), let unit = group(m, 2, in: text)?.lowercased() {
            interval = unit.hasPrefix("h") ? n * 60 : n
            text = removing(m, from: text)
        } else if let m = firstMatch(#"\b(?:every|each)\s+(minute|hour)\b"#, in: text) {
            interval = group(m, 1, in: text)?.lowercased() == "hour" ? 60 : 1
            text = removing(m, from: text)
        }
        interval = max(1, min(interval, 24 * 60))

        var due = extractDue(&text, dayOfMonth: dayOfMonth, now: now) ?? now
        if due < now {
            if recurrence == .none {
                due = now
            } else {
                let anchor = Calendar.current.component(.day, from: due)
                while due < now { due = recurrence.next(after: due, anchorDay: anchor) }
            }
        }

        // Tidy up what's left into a title.
        text = replace(#"\s+"#, in: text, with: " ")
        for _ in 0..<2 {
            text = replace(#"\s*\b(?:at|by|on|around|in|every|starting|and|of|for)\s*$"#, in: text)
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-!?"))
        }
        text = replace(#"^(?:to|about|that)\s+"#, in: text)
        guard !text.isEmpty else { return nil }
        let title = text.prefix(1).uppercased() + text.dropFirst()
        return ParsedTask(title: title, dueDate: due, intervalMinutes: interval, recurrence: recurrence, allocatedMinutes: allocated)
    }

    // MARK: - Dates

    private static func extractDue(_ text: inout String, dayOfMonth: Int?, now: Date) -> Date? {
        let cal = Calendar.current

        // Relative: "in 20 minutes", "in 2 hours".
        if dayOfMonth == nil,
           let m = firstMatch(#"\bin\s+(\d+)\s*(minutes?|mins?|hours?|hrs?)\b"#, in: text),
           let n = group(m, 1, in: text).flatMap(Int.init), let unit = group(m, 2, in: text)?.lowercased() {
            text = removing(m, from: text)
            return now.addingTimeInterval(TimeInterval(unit.hasPrefix("h") ? n * 3600 : n * 60))
        }

        // Day words.
        var dayOffset: Int?
        var defaultHour: Int?
        if let m = firstMatch(#"\b(tomorrow(?:\s+(?:morning|afternoon|evening|night))?|tonight|today|this\s+(?:morning|afternoon|evening))\b"#, in: text),
           let word = group(m, 1, in: text)?.lowercased() {
            dayOffset = word.hasPrefix("tomorrow") ? 1 : 0
            if word.contains("morning") { defaultHour = 9 }
            else if word.contains("afternoon") { defaultHour = 15 }
            else if word.contains("evening") { defaultHour = 19 }
            else if word.contains("night") { defaultHour = 20 }
            text = removing(m, from: text)
        }

        // Weekdays: "on friday", "next monday".
        if dayOffset == nil,
           let m = firstMatch(#"\b(?:on\s+|next\s+|this\s+|by\s+)?(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#, in: text),
           let name = group(m, 1, in: text)?.lowercased() {
            let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            let target = (names.firstIndex(of: name) ?? 0) + 1   // Calendar weekday: Sunday = 1
            var offset = (target - cal.component(.weekday, from: now) + 7) % 7
            if offset == 0 { offset = 7 }
            dayOffset = offset
            defaultHour = 9
            text = removing(m, from: text)
        }

        // Times.
        var hour: Int?
        var minute = 0
        var meridiem: String?
        if let m = firstMatch(#"\b(?:at\s+|by\s+)?(noon|midday|midnight)\b"#, in: text) {
            hour = group(m, 1, in: text)?.lowercased() == "midnight" ? 0 : 12
            meridiem = "explicit"
            text = removing(m, from: text)
        } else if let m = firstMatch(#"(?:\b(?:at|by|around)\s+)?\b(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s?m\b\.?"#, in: text) {
            hour = group(m, 1, in: text).flatMap(Int.init)
            minute = group(m, 2, in: text).flatMap(Int.init) ?? 0
            meridiem = group(m, 3, in: text)?.lowercased()
            text = removing(m, from: text)
        } else if let m = firstMatch(#"\b(?:at|by|around)\s+(\d{1,2})(?::(\d{2}))?\b(?!\s*(?:minutes?|mins?|hours?|hrs?|%))"#, in: text) {
            hour = group(m, 1, in: text).flatMap(Int.init)
            minute = group(m, 2, in: text).flatMap(Int.init) ?? 0
            text = removing(m, from: text)
        }
        if let h = hour, h > 23 || minute > 59 { hour = nil; minute = 0 }

        if dayOfMonth != nil || dayOffset != nil || hour != nil {
            let day: Date
            if let dom = dayOfMonth {
                day = Recurrence.date(day: dom, monthOf: now, timeFrom: cal.startOfDay(for: now))
            } else {
                day = cal.date(byAdding: .day, value: dayOffset ?? 0, to: cal.startOfDay(for: now))!
            }
            let futureDay = dayOfMonth != nil || (dayOffset ?? 0) >= 1
            func at(_ h: Int, _ d: Date) -> Date { cal.date(bySettingHour: h, minute: minute, second: 0, of: d)! }

            var result: Date
            if var h = hour {
                if meridiem == "p" { if h < 12 { h += 12 }; result = at(h, day) }
                else if meridiem == "a" { if h == 12 { h = 0 }; result = at(h, day) }
                else if meridiem != nil || h > 12 || h == 0 { result = at(h, day) }
                else if let dh = defaultHour, dh >= 12, h < 12 { result = at(h + 12, day) }   // "tonight at 8"
                else if futureDay { result = at(h < 7 ? h + 12 : h, day) }                    // "tomorrow at 3" → 3 PM
                else {
                    // Ambiguous "at 5": the next 5 o'clock still ahead. PM only for 1–10.
                    let options = h == 12 ? [12] : (h <= 10 ? [h, h + 12] : [h])
                    result = options.map { at($0, day) }.first { $0 > now }
                        ?? at(options[0], cal.date(byAdding: .day, value: 1, to: day)!)
                }
            } else if let dh = defaultHour {
                minute = 0
                result = at(dh, day)
            } else {
                result = futureDay ? at(9, day) : now
            }

            if let dom = dayOfMonth, result <= now {
                result = Recurrence.monthly.next(after: result, anchorDay: dom)
            } else if dayOffset == nil, dayOfMonth == nil, hour != nil, result <= now {
                result = cal.date(byAdding: .day, value: 1, to: result)!
            }
            return result
        }

        // Fallback: let the system detect things like "on december 3".
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = text as NSString
            if let m = detector.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), var date = m.date {
                text = ns.replacingCharacters(in: m.range, with: " ")
                text = replace(#"\b(?:on|at|by)\s*$"#, in: text.trimmingCharacters(in: .whitespaces))
                while date <= now { date = cal.date(byAdding: .day, value: 1, to: date)! }
                return date
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespaces)
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "twenty five": 25, "twenty-five": 25,
        "thirty": 30, "forty": 40, "forty five": 45, "forty-five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
    ]

    private static let ordinalWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "fifteenth": 15, "twentieth": 20, "last": 31,
    ]

    private static func normalizeNumbers(_ input: String) -> String {
        var text = input
        text = replace(#"\b(?:half\s+an?\s+hour|half\s+hour|30\s+mins?)\b"#, in: text, with: "30 minutes")
        text = replace(#"\b(?:a\s+)?quarter\s+(?:of\s+an\s+)?hour\b"#, in: text, with: "15 minutes")
        text = replace(#"\ban?\s+hour\b"#, in: text, with: "1 hour")
        text = replace(#"\ba\s+minute\b"#, in: text, with: "1 minute")
        text = replace(#"\ba\s+couple\s+(?:of\s+)?(minutes|hours)\b"#, in: text, with: "2 $1")
        text = replace(#"\ba\s+few\s+minutes\b"#, in: text, with: "5 minutes")
        for (word, n) in numberWords.sorted(by: { $0.key.count > $1.key.count }) {
            text = replace(#"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\s+(minutes?|mins?|hours?|hrs?)\b"#, in: text, with: "\(n) $1")
        }
        // "the first of every month" → "the 1st of every month"
        for (word, n) in ordinalWords {
            text = replace(#"\bthe\s+"# + word + #"\b(?!\s+(?:time|thing))"#, in: text, with: "the \(n)th")
        }
        return text
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        firstMatch(pattern, in: text) != nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        regex(pattern)?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in text: String) -> String? {
        let r = m.range(at: i)
        guard r.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: r)
    }

    private static func removing(_ m: NSTextCheckingResult, from text: String) -> String {
        (text as NSString).replacingCharacters(in: m.range, with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func replace(_ pattern: String, in text: String, with template: String = "") -> String {
        guard let re = regex(pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }
}
