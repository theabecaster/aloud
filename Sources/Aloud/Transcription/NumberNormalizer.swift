import Foundation

// Inverse text normalization, part two: the written forms.
//
// SpokenNumbers finds the number phrases; this file decides how each one
// should be written — 3 PM, July 25, $42.50, 20%, 5 km, 3.14 — using only the
// words immediately around it. Nothing is inferred: a construct applies when
// its trigger word is actually there, otherwise the phrase falls through to
// the plain rule below.
//
// The plain rule is deliberately timid. A number of ten or more, or one that
// took more than a word to say, becomes digits ("forty two" → 42). A single
// small number stays a word unless something makes it a quantity, because
// "one of them" and "no one" are not "1 of them" and "no 1".
//
// English gets the full set of written forms. The other four shipped
// languages get digits, percentages and decimals and keep their own words for
// currencies and units — that is how those languages are written, and a rule
// that can't misfire can't invent foreign-looking text.
enum NumberNormalizer {

    /// - Parameter holdTail: during live typing the last phrase is still being
    ///   spoken — "three" may yet become "three thirty". Leaving the trailing
    ///   phrase alone until the next update keeps the typed text from churning.
    static func normalize(_ text: String, languages: [String], holdTail: Bool = false) -> String {
        guard let lexicon = NumberLexicon.resolve(languages: languages, text: text) else { return text }
        return normalize(text, lexicon: lexicon, holdTail: holdTail)
    }

    static func normalize(_ text: String, lexicon: NumberLexicon, holdTail: Bool = false) -> String {
        guard text.contains(where: { $0.isLetter }) else { return text }
        var builder = Builder(text: text, lexicon: lexicon, holdTail: holdTail)
        return builder.run()
    }

    // MARK: -

    private struct Edit {
        let range: Range<String.Index>
        let replacement: String
    }

    private struct Builder {
        let text: String
        let lexicon: NumberLexicon
        let holdTail: Bool
        private var toks: [SpokenToken] = []
        private var phrases: [NumberPhrase] = []
        private var edits: [Edit] = []

        init(text: String, lexicon: NumberLexicon, holdTail: Bool) {
            self.text = text
            self.lexicon = lexicon
            self.holdTail = holdTail
        }

        mutating func run() -> String {
            toks = SpokenToken.tokenize(text)
            guard !toks.isEmpty else { return text }
            collectPhrases()
            guard !phrases.isEmpty else { return text }

            var k = 0
            while k < phrases.count {
                // In a live preview the last phrase may still be growing.
                if holdTail, phrases[k].end == toks.count { break }
                k = emitDigitRun(k) ?? emitDecimal(k) ?? emitMinutesPastHour(k)
                    ?? emitHalfPast(k) ?? emitTime(k)
                    ?? emitPercent(k) ?? emitMoney(k) ?? emitUnit(k) ?? emitDate(k)
                    ?? emitYear(k) ?? emitPlain(k) ?? (k + 1)
            }
            guard !edits.isEmpty else { return text }
            // Constructs may reach backwards ("half past four" starts two words
            // before its number), so the edits aren't necessarily in text
            // order and two of them can want the same words. First one wins.
            var applied: [Edit] = []
            for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                if let last = applied.last, edit.range.lowerBound < last.range.upperBound { continue }
                applied.append(edit)
            }
            var result = text
            for edit in applied.reversed() { result.replaceSubrange(edit.range, with: edit.replacement) }
            return result
        }

        // MARK: phrases

        private mutating func collectPhrases() {
            var i = 0
            while i < toks.count {
                // "a hundred times better" is prose; "one hundred" is a number.
                let previous = i > 0 ? toks[i - 1].folded : ""
                let allowScaleStart = !lexicon.articles.contains(previous)
                if let phrase = SpokenNumberParser.parse(toks, from: i, lex: lexicon,
                                                         allowScaleStart: allowScaleStart,
                                                         allowWeakOrdinal: isDateContext(at: i)),
                   isNumber(phrase) {
                    phrases.append(phrase)
                    i = phrase.end
                } else {
                    i += 1
                }
            }
        }

        /// "mil gracias", "tausend Dank", "a thousand times" — a scale word on
        /// its own is usually emphasis, not arithmetic. It only counts as a
        /// number when something it could be counting follows.
        private func isNumber(_ phrase: NumberPhrase) -> Bool {
            guard phrase.startedOnScale, phrase.tokenCount == 1 else { return true }
            guard phrase.end < toks.count else { return false }
            let next = toks[phrase.end].folded
            return lexicon.triggerWords.contains(next) || lexicon.currencies[next] != nil
                || lexicon.unitAbbrevs[next] != nil
        }

        /// A month either side makes an everyday ordinal a date: "July second",
        /// "the second of July".
        private func isDateContext(at i: Int) -> Bool {
            if i > 0, lexicon.months[toks[i - 1].folded] != nil { return true }
            guard i + 2 < toks.count, lexicon.dateLinks.contains(toks[i + 1].folded) else { return false }
            return lexicon.months[toks[i + 2].folded] != nil
        }

        // MARK: constructs
        //
        // Each returns the next phrase index when it applied, nil to pass.

        // Seven or more single digits in a row is a phone number, an account
        // number or a code being read out — never prose.
        private mutating func emitDigitRun(_ k: Int) -> Int? {
            var end = k
            var digits = ""
            while end < phrases.count, phrases[end].value < 10, phrases[end].value >= 0,
                  phrases[end].tokenCount == 1, !phrases[end].isOrdinal,
                  end == k || adjacent(phrases[end - 1], phrases[end]) {
                digits += String(phrases[end].value)
                end += 1
            }
            guard digits.count >= 7 else { return nil }
            replace(phrases[k].range.lowerBound..<phrases[end - 1].range.upperBound, digits)
            return end
        }

        // "three point one four" → 3.14, in the language's own separator.
        private mutating func emitDecimal(_ k: Int) -> Int? {
            guard !phrases[k].isOrdinal, k + 1 < phrases.count else { return nil }
            let word = phrases[k].end
            guard word < toks.count, lexicon.decimalWords.contains(toks[word].folded),
                  plainGap(after: phrases[k].end - 1), plainGap(after: word),
                  phrases[k + 1].start == word + 1, !phrases[k + 1].isOrdinal else { return nil }

            var fraction = String(phrases[k + 1].value)
            var end = k + 2
            // "one four" after the point is 14, not 1 then 4.
            while end < phrases.count, phrases[end].value < 10, phrases[end].tokenCount == 1,
                  !phrases[end].isOrdinal, adjacent(phrases[end - 1], phrases[end]) {
                fraction += String(phrases[end].value)
                end += 1
            }
            let written = "\(phrases[k].value)\(lexicon.decimalSeparator)\(fraction)"
            replace(phrases[k].range.lowerBound..<phrases[end - 1].range.upperBound, written)
            return end
        }

        // "twenty past six" → 6:20, "ten to nine" → 8:50.
        private mutating func emitMinutesPastHour(_ k: Int) -> Int? {
            guard lexicon.code == .en, k + 1 < phrases.count else { return nil }
            let spoken = phrases[k]
            // Only the offsets people actually say: "twenty past six" is a
            // time, "nine to five" is a job.
            guard !spoken.isOrdinal, spoken.value >= 5, spoken.value <= 30,
                  spoken.value % 5 == 0,
                  let relationToken = nextToken(after: spoken) else { return nil }
            let relation = toks[relationToken].folded
            guard relation == "past" || relation == "to" else { return nil }
            let hourPhrase = phrases[k + 1]
            guard hourPhrase.start == relationToken + 1, !hourPhrase.isOrdinal,
                  hourPhrase.value >= 1, hourPhrase.value <= 12,
                  plainGap(after: relationToken) else { return nil }
            var hour = hourPhrase.value
            var minute = spoken.value
            if relation == "to" {
                minute = 60 - minute
                hour = hour == 1 ? 12 : hour - 1
            }
            var written = String(format: "%d:%02d", hour, minute)
            var end = hourPhrase.range.upperBound
            if let (marker, upper) = meridiem(after: end) {
                written += " \(marker)"
                end = upper
            }
            replace(spoken.range.lowerBound..<end, written)
            return k + 2
        }

        // "half past four" → 4:30. English only: the other languages phrase
        // this in ways that read fine with the hour simply in digits.
        private mutating func emitHalfPast(_ k: Int) -> Int? {
            guard lexicon.code == .en, phrases[k].value >= 1, phrases[k].value <= 12,
                  phrases[k].tokenCount == 1, phrases[k].start >= 2 else { return nil }
            let relation = toks[phrases[k].start - 1].folded
            let part = toks[phrases[k].start - 2].folded
            let minute: Int
            switch (part, relation) {
            case ("half", "past"): minute = 30
            case ("quarter", "past"): minute = 15
            case ("quarter", "to"): minute = 45
            default: return nil
            }
            var hour = phrases[k].value
            if relation == "to" { hour = hour == 1 ? 12 : hour - 1 }
            var written = String(format: "%d:%02d", hour, minute)
            var end = phrases[k].range.upperBound
            if let (marker, upper) = meridiem(after: end) {
                written += " \(marker)"
                end = upper
            }
            replace(toks[phrases[k].start - 2].range.lowerBound..<end, written)
            return k + 1
        }

        // "three p.m." → 3 PM, "three thirty" → 3:30, "three o'clock" → 3 o'clock.
        private mutating func emitTime(_ k: Int) -> Int? {
            guard lexicon.code == .en, !phrases[k].isOrdinal, !phrases[k].startedOnScale,
                  phrases[k].value >= 0, phrases[k].value <= 24,
                  phrases[k].tokenCount <= 2 else { return nil }
            let hour = phrases[k].value
            var last = k
            var minutes: Int?
            // A minute has to look like one: "three thirty" but not "three six".
            if k + 1 < phrases.count, adjacent(phrases[k], phrases[k + 1]),
               !phrases[k + 1].isOrdinal, phrases[k + 1].tokenCount <= 2,
               phrases[k + 1].value >= 10, phrases[k + 1].value <= 59 {
                minutes = phrases[k + 1].value
                last = k + 1
            }
            var end = phrases[last].range.upperBound
            let written: String
            if let (marker, upper) = meridiem(after: end), hour >= 1, hour <= 12 {
                written = (minutes.map { String(format: "%d:%02d", hour, $0) } ?? "\(hour)")
                    + " \(marker)"
                end = upper
            } else if minutes == nil, let upper = oClock(after: end), hour >= 1, hour <= 12 {
                written = "\(hour) o'clock"
                end = upper
            } else if let minutes, hour >= 1, hour <= 12 {
                // "three thirty" with nothing else to go on. Leaving it alone
                // isn't an option: the minute is over ten, so it would digitize
                // on its own and read "three 30".
                written = String(format: "%d:%02d", hour, minutes)
            } else {
                return nil
            }
            replace(phrases[k].range.lowerBound..<end, written)
            return last + 1
        }

        // "twenty percent" → 20%; Spanish, French and German keep the space.
        private mutating func emitPercent(_ k: Int) -> Int? {
            guard !phrases[k].isOrdinal else { return nil }
            for words in lexicon.percentPhrases {
                guard let end = consume(words, after: phrases[k]) else { continue }
                replace(phrases[k].range.lowerBound..<end,
                        numberText(phrases[k]) + (lexicon.percentSpaced ? " %" : "%"))
                return k + 1
            }
            return nil
        }

        // "forty two dollars" → $42, with "and fifty cents" folded in.
        private mutating func emitMoney(_ k: Int) -> Int? {
            guard !phrases[k].isOrdinal, !phrases[k].startedOnScale,
                  let unitToken = nextToken(after: phrases[k]),
                  let symbol = lexicon.currencies[toks[unitToken].folded] else { return nil }
            var written = "\(symbol)\(phrases[k].value)"
            var end = toks[unitToken].range.upperBound
            var next = k + 1
            if next < phrases.count, phrases[next].value >= 0, phrases[next].value <= 99,
               phrases[next].start <= unitToken + 2, phrases[next].start > unitToken,
               let centsToken = nextToken(after: phrases[next]),
               lexicon.centsWords.contains(toks[centsToken].folded) {
                written = String(format: "%@%d.%02d", symbol, phrases[k].value, phrases[next].value)
                end = toks[centsToken].range.upperBound
                next += 1
            }
            replace(phrases[k].range.lowerBound..<end, written)
            return next
        }

        // "five kilometers" → 5 km, for the handful of units whose short form
        // is unambiguous. Every other unit keeps its word and only the number
        // changes.
        private mutating func emitUnit(_ k: Int) -> Int? {
            guard !phrases[k].isOrdinal, !phrases[k].startedOnScale,
                  let unitToken = nextToken(after: phrases[k]),
                  let abbreviation = lexicon.unitAbbrevs[toks[unitToken].folded] else { return nil }
            replace(phrases[k].range.lowerBound..<toks[unitToken].range.upperBound,
                    "\(phrases[k].value) \(abbreviation)")
            return k + 1
        }

        // "July twenty fifth" → July 25; "the twenty fifth of July" keeps the
        // ordinal, because that is how the sentence reads.
        private mutating func emitDate(_ k: Int) -> Int? {
            let phrase = phrases[k]
            guard phrase.value >= 1, phrase.value <= 31, !phrase.startedOnScale,
                  phrase.tokenCount <= 2 else { return nil }
            if phrase.start > 0, let month = lexicon.months[toks[phrase.start - 1].folded],
               plainGap(after: phrase.start - 1) {
                replace(toks[phrase.start - 1].range.lowerBound..<phrase.range.upperBound,
                        "\(month) \(phrase.value)")
                return k + 1
            }
            // "the twenty fifth of July", "cinco de mayo", "5. Mai".
            guard let linkToken = nextToken(after: phrase),
                  lexicon.dateLinks.contains(toks[linkToken].folded),
                  linkToken + 1 < toks.count, plainGap(after: linkToken),
                  let month = lexicon.months[toks[linkToken + 1].folded] else { return nil }
            let day = phrase.isOrdinal ? ordinalText(phrase.value) : String(phrase.value)
            replace(phrase.range.lowerBound..<toks[linkToken + 1].range.upperBound,
                    "\(day) \(toks[linkToken].raw) \(month)")
            return k + 1
        }

        // "nineteen eighty four" → 1984, "twenty twenty six" → 2026. Two
        // numbers said back to back are a year far more often than they are
        // two numbers, and "19 84" would be nobody's intent.
        private mutating func emitYear(_ k: Int) -> Int? {
            guard k + 1 < phrases.count, adjacent(phrases[k], phrases[k + 1]),
                  !phrases[k].isOrdinal, !phrases[k + 1].isOrdinal,
                  !phrases[k].wasDigits, !phrases[k + 1].wasDigits,
                  phrases[k].value >= 13, phrases[k].value <= 20, phrases[k].tokenCount == 1,
                  phrases[k + 1].value >= 10, phrases[k + 1].value <= 99,
                  phrases[k + 1].tokenCount <= 2 else { return nil }
            replace(phrases[k].range.lowerBound..<phrases[k + 1].range.upperBound,
                    String(phrases[k].value * 100 + phrases[k + 1].value))
            return k + 2
        }

        private mutating func emitPlain(_ k: Int) -> Int? {
            let phrase = phrases[k]
            guard !phrase.wasDigits, shouldDigitize(phrase) else { return nil }
            replace(phrase.range, numberText(phrase))
            return k + 1
        }

        // MARK: plain-number policy

        private func shouldDigitize(_ phrase: NumberPhrase) -> Bool {
            if phrase.isOrdinal { return phrase.value >= 10 }
            if phrase.value >= 10 || phrase.tokenCount > 1 { return true }
            // "at one point I thought" is not a decimal that lost its tail.
            if let next = nextToken(after: phrase),
               lexicon.decimalWords.contains(toks[next].folded) { return false }
            // A single small number needs a reason: a unit, a currency, a
            // count of something — or a word like "at" in front of it.
            if let next = nextToken(after: phrase),
               lexicon.triggerWords.contains(toks[next].folded) { return true }
            return hasLeadingTrigger(phrase)
        }

        private func hasLeadingTrigger(_ phrase: NumberPhrase) -> Bool {
            guard phrase.start > 0, plainGap(after: phrase.start - 1) else { return false }
            return lexicon.leadingTriggers.contains(toks[phrase.start - 1].folded)
        }

        /// Digits — except that millions and billions keep their word, because
        /// nobody wants to read 2000000.
        private func numberText(_ phrase: NumberPhrase) -> String {
            if phrase.isOrdinal { return ordinalText(phrase.value) }
            let lastWord = toks[phrase.end - 1].folded
            if let scale = lexicon.scales[lastWord], scale >= 1_000_000,
               phrase.value >= scale, phrase.value % scale == 0 {
                return "\(phrase.value / scale) \(toks[phrase.end - 1].raw)"
            }
            return String(phrase.value)
        }

        private func ordinalText(_ value: Int) -> String {
            guard lexicon.code == .en else { return String(value) }
            let suffix: String
            switch (value % 100, value % 10) {
            case (11, _), (12, _), (13, _): suffix = "th"
            case (_, 1): suffix = "st"
            case (_, 2): suffix = "nd"
            case (_, 3): suffix = "rd"
            default: suffix = "th"
            }
            return "\(value)\(suffix)"
        }

        // MARK: text helpers

        private mutating func replace(_ range: Range<String.Index>, _ replacement: String) {
            edits.append(Edit(range: range, replacement: replacement))
        }

        /// Nothing but spaces between two phrases — a comma or a line break
        /// means they are separate thoughts.
        private func adjacent(_ a: NumberPhrase, _ b: NumberPhrase) -> Bool {
            a.end == b.start && plainGap(after: a.end - 1)
        }

        private func plainGap(after tokenIndex: Int) -> Bool {
            guard tokenIndex >= 0, tokenIndex + 1 < toks.count else { return true }
            let gap = toks[tokenIndex].range.upperBound..<toks[tokenIndex + 1].range.lowerBound
            return text[gap].allSatisfy { $0 == " " || $0 == "\t" || $0 == "-" }
        }

        private func nextToken(after phrase: NumberPhrase) -> Int? {
            guard phrase.end < toks.count, plainGap(after: phrase.end - 1) else { return nil }
            return phrase.end
        }

        /// The end of `words` if they follow the phrase verbatim.
        private func consume(_ words: [String], after phrase: NumberPhrase) -> String.Index? {
            var index = phrase.end
            for word in words {
                guard index < toks.count, toks[index].folded == word,
                      plainGap(after: index - 1) else { return nil }
                index += 1
            }
            return toks[index - 1].range.upperBound
        }

        private func meridiem(after index: String.Index) -> (String, String.Index)? {
            guard index <= text.endIndex,
                  let match = Self.meridiemPattern.firstMatch(
                    in: text, options: [.anchored],
                    range: NSRange(index..<text.endIndex, in: text)),
                  let range = Range(match.range, in: text),
                  let letter = Range(match.range(at: 1), in: text) else { return nil }
            return (text[letter].uppercased() + "M", range.upperBound)
        }

        private func oClock(after index: String.Index) -> String.Index? {
            guard let match = Self.oClockPattern.firstMatch(
                in: text, options: [.anchored],
                range: NSRange(index..<text.endIndex, in: text)),
                  let range = Range(match.range, in: text) else { return nil }
            return range.upperBound
        }

        // "p.m.", "pm", "P M." — all the ways the model writes it.
        static let meridiemPattern = try! NSRegularExpression(
            pattern: "(?i)[ \\t]*\\b([ap])[ \\t]*\\.?[ \\t]*m\\.?(?![\\p{L}])")
        static let oClockPattern = try! NSRegularExpression(
            pattern: "(?i)[ \\t]*\\bo'?[ \\t]?clock\\b")
    }
}
