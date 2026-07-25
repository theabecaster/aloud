import Foundation

// Inverse text normalization, part one: the words.
//
// The speech model spells numbers out — "three p.m.", "veinticinco de julio",
// "zweiundvierzig Euro" — because that is literally what was said. Nobody
// types them that way, so a deterministic pass turns spoken number phrases
// back into digits (NumberNormalizer builds the written forms on top of this
// file's parse).
//
// Everything here is whole-token lookup against a fixed per-language table.
// A word the table doesn't know ends the phrase, so unknown text is never
// touched — the failure mode is "left as the model wrote it", never a wrong
// rewrite.

struct NumberLexicon: Sendable {
    enum Code: String, Sendable { case en, es, fr, de, pt }

    let code: Code
    /// 0…19 plus whatever else the language writes as one word (Spanish
    /// "veintidós", Portuguese "dezoito").
    let units: [String: Int]
    /// 20, 30, … 90.
    let tens: [String: Int]
    /// hundred / thousand / million / billion and their translations.
    let scales: [String: Int]
    /// "and", "y", "et", "und", "e" — glue inside a single number.
    let connectors: Set<String>
    /// English only joins with "and" after a hundred ("two hundred and five");
    /// the Romance languages also join tens to units ("treinta y dos").
    let connectorNeedsHundred: Bool
    /// French adds teens onto 60 and 80 ("soixante-quinze", "quatre-vingt-dix").
    let additiveTeens: Set<Int>
    /// French multiplies "quatre" by "vingt".
    let vigesimal: Bool
    /// Ordinal words. Only English fills these: elsewhere the ordinal words
    /// collide with everyday nouns ("segundo", "quarto", "second") and dates
    /// are spoken as plain cardinals anyway.
    let ordinals: [String: Int]
    /// Ordinals that are too ordinary a word to convert on their own — only
    /// accepted when a month makes the date obvious ("July second").
    let weakOrdinals: Set<String>
    /// "point", "coma", "virgule", "Komma", "vírgula".
    let decimalWords: Set<String>
    let decimalSeparator: String
    /// Determiners that block a phrase starting on a bare scale word, so
    /// "a hundred times better" stays prose.
    let articles: Set<String>
    /// Folded month word → the form to write.
    let months: [String: String]
    /// "percent", "por ciento", "pour cent", "Prozent", "por cento".
    let percentPhrases: [[String]]
    /// French, Spanish and German put a space before the sign.
    let percentSpaced: Bool
    /// Currency word → symbol. English only; elsewhere the word stays and just
    /// the number becomes digits, which is how those languages write it.
    let currencies: [String: String]
    /// Currency subunit ("cents") that folds into the decimal.
    let centsWords: Set<String>
    /// Unit word → abbreviation, for the handful that are unambiguous.
    let unitAbbrevs: [String: String]
    /// Words that make a small number a quantity: "five minutes" is "5
    /// minutes", but a bare "five" stays a word.
    let triggerWords: Set<String>
    /// Words *before* a small number that do the same — "at three", "um drei",
    /// "a las tres".
    let leadingTriggers: Set<String>
    /// The word that links a day to its month: "the 25th **of** July",
    /// "25 **de** julio". German writes the link as a period, so it has none.
    let dateLinks: Set<String>
    /// German writes whole numbers as one word; the parser decomposes them.
    let compoundWords: Bool

    // MARK: lookup

    func unit(_ word: String) -> Int? {
        if let v = units[word] { return v }
        // A bare scale word ("tausend") belongs to the scale rules, which know
        // that "tausend Dank" is emphasis rather than 1000 of anything.
        guard compoundWords, scales[word] == nil else { return nil }
        return Self.germanValue(word, in: self)
    }

    // MARK: languages

    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func table(_ pairs: [String: Int]) -> [String: Int] {
        Dictionary(pairs.map { (fold($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    private static func set(_ words: [String]) -> Set<String> { Set(words.map(fold)) }

    static func named(_ code: Code) -> NumberLexicon {
        switch code {
        case .en: return english
        case .es: return spanish
        case .fr: return french
        case .de: return german
        case .pt: return portuguese
        }
    }

    /// The lexicon to use for a transcript, or nil when the language isn't one
    /// the tables cover — in which case the transcript is left alone.
    static func resolve(languages: [String], text: String) -> NumberLexicon? {
        let declared = languages.compactMap { Code(rawValue: String($0.prefix(2)).lowercased()) }
        if declared.count == 1 { return named(declared[0]) }
        guard let detected = LanguageDetection.code(for: text),
              let code = Code(rawValue: String(detected.prefix(2)).lowercased()) else { return nil }
        guard declared.isEmpty || declared.contains(code) else { return nil }
        return named(code)
    }

    // MARK: English

    static let english = NumberLexicon(
        code: .en,
        units: table([
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
            "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
            "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
            "seventeen": 17, "eighteen": 18, "nineteen": 19,
        ]),
        tens: table(["twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
                     "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]),
        scales: table(["hundred": 100, "thousand": 1_000,
                       "million": 1_000_000, "billion": 1_000_000_000]),
        connectors: set(["and"]),
        connectorNeedsHundred: true,
        additiveTeens: [],
        vigesimal: false,
        ordinals: table([
            "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
            "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
            "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
            "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
            "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
            "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
        ]),
        // "second" and "third" earn their keep as nouns and verbs far more
        // often than as dates; "first" leads sentences. They convert only next
        // to a month.
        weakOrdinals: set(["first", "second", "third", "fourth", "fifth", "sixth",
                           "seventh", "eighth", "ninth"]),
        decimalWords: set(["point"]),
        decimalSeparator: ".",
        articles: set(["a", "an", "the", "per", "few"]),
        months: months(["January", "February", "March", "April", "May", "June", "July",
                        "August", "September", "October", "November", "December"]),
        percentPhrases: [["percent"], ["per", "cent"]],
        percentSpaced: false,
        // Pounds are flour as often as they are sterling, so they stay a unit.
        currencies: ["dollars": "$", "dollar": "$", "euros": "€", "euro": "€"],
        centsWords: set(["cents", "cent"]),
        unitAbbrevs: ["kilometers": "km", "kilometres": "km", "kilometer": "km",
                      "kilometre": "km", "kilograms": "kg", "kilogram": "kg",
                      "centimeters": "cm", "centimetres": "cm", "millimeters": "mm",
                      "millimetres": "mm", "gigabytes": "GB", "megabytes": "MB",
                      "kilobytes": "KB", "terabytes": "TB", "megahertz": "MHz",
                      "gigahertz": "GHz", "milliseconds": "ms"],
        triggerWords: set([
            "percent", "dollars", "euros", "pounds", "cents", "minutes", "seconds",
            "hours", "days", "weeks", "months", "years", "degrees", "times",
            "people", "miles", "feet", "inches", "meters", "metres", "grams",
            "ounces", "liters", "litres", "pages", "items", "copies", "kilometers",
            "kilometres", "kilograms", "gigabytes", "megabytes", "kilobytes",
            "terabytes", "milliseconds", "percentage", "million", "billion",
            "thousand",
        ]),
        leadingTriggers: set(["at", "around", "until", "till", "version", "chapter",
                             "step", "page", "room", "line", "row", "apartment",
                             "suite"]),
        dateLinks: set(["of"]),
        compoundWords: false)

    // MARK: Spanish

    static let spanish = NumberLexicon(
        code: .es,
        units: table([
            "cero": 0, "uno": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4,
            "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10,
            "once": 11, "doce": 12, "trece": 13, "catorce": 14, "quince": 15,
            "dieciséis": 16, "diecisiete": 17, "dieciocho": 18, "diecinueve": 19,
            "veintiuno": 21, "veintiún": 21, "veintiuna": 21, "veintidós": 22,
            "veintitrés": 23, "veinticuatro": 24, "veinticinco": 25, "veintiséis": 26,
            "veintisiete": 27, "veintiocho": 28, "veintinueve": 29,
        ]),
        tens: table(["veinte": 20, "treinta": 30, "cuarenta": 40, "cincuenta": 50,
                     "sesenta": 60, "setenta": 70, "ochenta": 80, "noventa": 90,
                     "cien": 100, "ciento": 100, "doscientos": 200, "doscientas": 200,
                     "trescientos": 300, "trescientas": 300, "cuatrocientos": 400,
                     "cuatrocientas": 400, "quinientos": 500, "quinientas": 500,
                     "seiscientos": 600, "seiscientas": 600, "setecientos": 700,
                     "setecientas": 700, "ochocientos": 800, "ochocientas": 800,
                     "novecientos": 900, "novecientas": 900]),
        scales: table(["mil": 1_000, "millón": 1_000_000, "millones": 1_000_000,
                       "billón": 1_000_000_000_000, "billones": 1_000_000_000_000]),
        connectors: set(["y"]),
        connectorNeedsHundred: false,
        additiveTeens: [],
        vigesimal: false,
        ordinals: [:], weakOrdinals: [],
        decimalWords: set(["coma"]),
        decimalSeparator: ",",
        articles: set(["un", "una", "el", "la", "los", "las", "unos", "unas"]),
        months: months(["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
                        "agosto", "septiembre", "octubre", "noviembre", "diciembre"]),
        percentPhrases: [["por", "ciento"]],
        percentSpaced: true,
        currencies: [:],
        centsWords: [],
        unitAbbrevs: [:],
        triggerWords: set([
            "euros", "dólares", "pesos", "céntimos", "minutos", "segundos",
            "horas", "días", "semanas", "meses", "años", "grados", "veces",
            "personas", "kilómetros", "metros", "kilos", "kilogramos", "gramos",
            "litros", "páginas", "millones", "mil", "ciento",
        ]),
        leadingTriggers: set(["las", "la", "sobre", "hacia", "desde", "hasta",
                             "versión", "capítulo", "paso", "página"]),
        dateLinks: set(["de"]),
        compoundWords: false)

    // MARK: French

    static let french = NumberLexicon(
        code: .fr,
        units: table([
            "zéro": 0, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4,
            "cinq": 5, "six": 6, "sept": 7, "huit": 8, "neuf": 9, "dix": 10,
            "onze": 11, "douze": 12, "treize": 13, "quatorze": 14, "quinze": 15,
            "seize": 16,
        ]),
        tens: table(["vingt": 20, "vingts": 20, "trente": 30, "quarante": 40,
                     "cinquante": 50, "soixante": 60, "septante": 70, "octante": 80,
                     "huitante": 80, "nonante": 90]),
        scales: table(["cent": 100, "cents": 100, "mille": 1_000,
                       "million": 1_000_000, "millions": 1_000_000,
                       "milliard": 1_000_000_000, "milliards": 1_000_000_000]),
        connectors: set(["et"]),
        connectorNeedsHundred: false,
        additiveTeens: [60, 80],
        vigesimal: true,
        ordinals: [:], weakOrdinals: [],
        decimalWords: set(["virgule"]),
        decimalSeparator: ",",
        articles: set(["un", "une", "le", "la", "les", "des", "quelques"]),
        months: months(["janvier", "février", "mars", "avril", "mai", "juin", "juillet",
                        "août", "septembre", "octobre", "novembre", "décembre"]),
        percentPhrases: [["pour", "cent"]],
        percentSpaced: true,
        currencies: [:],
        centsWords: [],
        unitAbbrevs: [:],
        triggerWords: set([
            "euros", "dollars", "centimes", "minutes", "secondes", "heures",
            "jours", "semaines", "mois", "ans", "années", "degrés", "fois",
            "personnes", "kilomètres", "mètres", "kilos", "kilogrammes",
            "grammes", "litres", "pages", "millions", "milliards", "mille",
        ]),
        leadingTriggers: set(["vers", "depuis", "version", "chapitre", "étape",
                             "page"]),
        dateLinks: set(["de"]),
        compoundWords: false)

    // MARK: German

    static let german = NumberLexicon(
        code: .de,
        units: table([
            "null": 0, "eins": 1, "ein": 1, "eine": 1, "zwei": 2, "zwo": 2, "drei": 3,
            "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
            "zehn": 10, "elf": 11, "zwölf": 12, "dreizehn": 13, "vierzehn": 14,
            "fünfzehn": 15, "sechzehn": 16, "siebzehn": 17, "achtzehn": 18,
            "neunzehn": 19,
        ]),
        tens: table(["zwanzig": 20, "dreißig": 30, "vierzig": 40, "fünfzig": 50,
                     "sechzig": 60, "siebzig": 70, "achtzig": 80, "neunzig": 90]),
        scales: table(["hundert": 100, "tausend": 1_000, "million": 1_000_000,
                       "millionen": 1_000_000, "milliarde": 1_000_000_000,
                       "milliarden": 1_000_000_000]),
        connectors: set(["und"]),
        connectorNeedsHundred: true,
        additiveTeens: [],
        vigesimal: false,
        ordinals: [:], weakOrdinals: [],
        decimalWords: set(["komma"]),
        decimalSeparator: ",",
        articles: set(["ein", "eine", "einen", "der", "die", "das", "paar"]),
        months: months(["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli",
                        "August", "September", "Oktober", "November", "Dezember"]),
        percentPhrases: [["prozent"]],
        percentSpaced: true,
        currencies: [:],
        centsWords: [],
        unitAbbrevs: [:],
        triggerWords: set([
            "euro", "euros", "dollar", "minuten", "sekunden", "stunden", "tage",
            "wochen", "monate", "jahre", "grad", "mal", "personen", "leute",
            "kilometer", "meter", "kilogramm", "kilo", "gramm", "liter", "seiten",
            "uhr", "millionen", "milliarden", "tausend", "prozent",
        ]),
        leadingTriggers: set(["um", "gegen", "ab", "seit", "bis", "halb", "version",
                             "kapitel", "schritt", "seite"]),
        dateLinks: [],
        compoundWords: true)

    // MARK: Portuguese

    static let portuguese = NumberLexicon(
        code: .pt,
        units: table([
            "zero": 0, "um": 1, "uma": 1, "dois": 2, "duas": 2, "três": 3,
            "quatro": 4, "cinco": 5, "seis": 6, "sete": 7, "oito": 8, "nove": 9,
            "dez": 10, "onze": 11, "doze": 12, "treze": 13, "catorze": 14,
            "quatorze": 14, "quinze": 15, "dezesseis": 16, "dezasseis": 16,
            "dezessete": 17, "dezassete": 17, "dezoito": 18, "dezenove": 19,
            "dezanove": 19,
        ]),
        tens: table(["vinte": 20, "trinta": 30, "quarenta": 40, "cinquenta": 50,
                     "sessenta": 60, "setenta": 70, "oitenta": 80, "noventa": 90,
                     "cem": 100, "cento": 100, "duzentos": 200, "duzentas": 200,
                     "trezentos": 300, "trezentas": 300, "quatrocentos": 400,
                     "quatrocentas": 400, "quinhentos": 500, "quinhentas": 500,
                     "seiscentos": 600, "seiscentas": 600, "setecentos": 700,
                     "setecentas": 700, "oitocentos": 800, "oitocentas": 800,
                     "novecentos": 900, "novecentas": 900]),
        scales: table(["mil": 1_000, "milhão": 1_000_000, "milhões": 1_000_000,
                       "bilhão": 1_000_000_000, "bilhões": 1_000_000_000]),
        connectors: set(["e"]),
        connectorNeedsHundred: false,
        additiveTeens: [],
        vigesimal: false,
        ordinals: [:], weakOrdinals: [],
        decimalWords: set(["vírgula"]),
        decimalSeparator: ",",
        articles: set(["um", "uma", "o", "a", "os", "as", "uns", "umas"]),
        months: months(["janeiro", "fevereiro", "março", "abril", "maio", "junho",
                        "julho", "agosto", "setembro", "outubro", "novembro",
                        "dezembro"]),
        percentPhrases: [["por", "cento"]],
        percentSpaced: false,
        currencies: [:],
        centsWords: [],
        unitAbbrevs: [:],
        triggerWords: set([
            "reais", "euros", "dólares", "centavos", "minutos", "segundos",
            "horas", "dias", "semanas", "meses", "anos", "graus", "vezes",
            "pessoas", "quilômetros", "quilómetros", "metros", "quilos", "gramas",
            "litros", "páginas", "milhões", "mil", "cento",
        ]),
        leadingTriggers: set(["às", "as", "desde", "até", "versão", "capítulo",
                             "passo", "página"]),
        dateLinks: set(["de"]),
        compoundWords: false)

    private static func months(_ names: [String]) -> [String: String] {
        Dictionary(names.map { (fold($0), $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: German compounds

    // German writes a whole number as one word ("zweiundvierzig",
    // "dreihundertfünf"), so the token itself has to be taken apart. The
    // decomposition must consume the entire word: "achtung" starts like
    // "acht" but leaves "ung" behind, so it is not a number and nothing is
    // touched.
    private static func germanValue(_ word: String, in lex: NumberLexicon) -> Int? {
        guard word.count >= 3 else { return nil }
        return germanParse(Substring(word), lex)
    }

    private static func germanParse(_ word: Substring, _ lex: NumberLexicon) -> Int? {
        if word.isEmpty { return nil }
        // Largest scale first, so "zweitausenddreihundert" splits at "tausend".
        for (suffix, scale) in [("milliarden", 1_000_000_000), ("milliarde", 1_000_000_000),
                                ("millionen", 1_000_000), ("million", 1_000_000),
                                ("tausend", 1_000), ("hundert", 100)] {
            guard let r = word.range(of: suffix, options: .backwards) else { continue }
            let head = word[word.startIndex..<r.lowerBound]
            let tail = word[r.upperBound...]
            let multiplier: Int
            if head.isEmpty { multiplier = 1 } else if let m = germanParse(head, lex) { multiplier = m } else { continue }
            let remainder: Int
            if tail.isEmpty { remainder = 0 } else if let r2 = germanParse(tail, lex) { remainder = r2 } else { continue }
            return multiplier * scale + remainder
        }
        // "einundzwanzig" — unit, "und", tens. Always in that order.
        if let r = word.range(of: "und") {
            let unit = String(word[word.startIndex..<r.lowerBound])
            let tens = String(word[r.upperBound...])
            if let u = lex.units[unit], u < 10, let t = lex.tens[tens] { return t + u }
        }
        let key = String(word)
        return lex.units[key] ?? lex.tens[key]
    }
}

// MARK: - parsing a phrase

/// One spoken number found in the text, with where it sits.
struct NumberPhrase {
    var value: Int
    var isOrdinal: Bool
    var tokenCount: Int
    var startedOnScale: Bool
    /// The phrase was already written in digits — reformat it if a construct
    /// applies, otherwise leave it exactly as it is.
    var wasDigits: Bool
    var start: Int          // token index
    var end: Int            // token index, exclusive
    var range: Range<String.Index>
}

enum SpokenNumberParser {
    /// Parse the longest number phrase starting at `i`, or nil.
    static func parse(_ toks: [SpokenToken], from i: Int, lex: NumberLexicon,
                      allowScaleStart: Bool, allowWeakOrdinal: Bool = false) -> NumberPhrase? {
        if let digits = toks[i].digits {
            return NumberPhrase(value: digits, isOrdinal: false, tokenCount: 1,
                                startedOnScale: false, wasDigits: true, start: i, end: i + 1,
                                range: toks[i].range)
        }
        var total = 0          // completed scale groups
        var current = 0        // the group being built
        var index = i
        var seen = false
        var ordinal = false
        var startedOnScale = false

        while index < toks.count {
            let word = toks[index].folded
            // A connector only ever glues a number to a smaller part of the
            // same number: "two hundred and five", "treinta y dos". "three and
            // five" is two numbers and must stay that way.
            if lex.connectors.contains(word) {
                let base = current > 0 ? current : total
                guard seen, base > 0, base % 10 == 0,
                      !(lex.connectorNeedsHundred && base % 100 != 0),
                      index + 1 < toks.count,
                      let next = peekValue(toks[index + 1], lex), next < base else { break }
                index += 1
                continue
            }
            if let v = lex.unit(word) {
                if current == 0 && !seen { current = v }
                // "twenty two", "five hundred and twenty three", "soixante-quinze".
                else if current > 0, current % 10 == 0,
                        v < 10 || lex.additiveTeens.contains(current % 100) { current += v }
                else if current > 0, current % 100 == 0, v < 100 { current += v }   // "two hundred twelve"
                else if current == 0, total > 0 { current = v }
                else { break }
            } else if let t = lex.tens[word] {
                if lex.vigesimal, current > 0, current < 10, t == 20 {
                    current *= t                      // quatre-vingt
                } else if current == 0 {
                    current = t
                } else if current % 100 == 0, current > 0, t < 100 {
                    current += t                      // "cento vinte"
                } else { break }
            } else if let s = lex.scales[word] {
                if s == 100 {
                    if current == 0 {
                        guard !seen, allowScaleStart else { break }
                        current = 100
                        startedOnScale = true
                    } else if current < 100 {
                        current *= 100
                    } else { break }
                } else {
                    let multiplier: Int
                    if current > 0 { multiplier = current }
                    else if !seen {
                        guard allowScaleStart else { break }
                        multiplier = 1
                        startedOnScale = true
                    } else { multiplier = 1 }
                    // Scales must descend: "thousand … thousand" is two numbers.
                    if total > 0 && total % s != 0 && total < s { break }
                    total += multiplier * s
                    current = 0
                }
            } else if let o = ordinalValue(word, lex, phraseStart: !seen,
                                           allowWeak: allowWeakOrdinal) {
                if o < 10, current > 0, current % 10 == 0, current < 100 { current += o }
                else if current == 0 { current = o }
                else { break }
                ordinal = true
                seen = true
                index += 1
                break
            } else { break }
            seen = true
            index += 1
        }

        guard seen, index > i else { return nil }
        return NumberPhrase(value: total + current, isOrdinal: ordinal,
                            tokenCount: index - i, startedOnScale: startedOnScale,
                            wasDigits: false, start: i, end: index,
                            range: toks[i].range.lowerBound..<toks[index - 1].range.upperBound)
    }

    /// Ordinals that double as everyday words are only offered when they sit
    /// inside a bigger number ("twenty first"); on their own the caller has to
    /// see a month before it accepts them.
    private static func ordinalValue(_ word: String, _ lex: NumberLexicon,
                                     phraseStart: Bool, allowWeak: Bool) -> Int? {
        guard let v = lex.ordinals[word] else { return nil }
        if phraseStart, !allowWeak, lex.weakOrdinals.contains(word) { return nil }
        return v
    }

    private static func peekValue(_ tok: SpokenToken, _ lex: NumberLexicon) -> Int? {
        let w = tok.folded
        return lex.unit(w) ?? lex.tens[w] ?? lex.ordinals[w]
    }
}

/// A word of the transcript, with the slice of the original it came from.
struct SpokenToken {
    let raw: String
    let folded: String
    let range: Range<String.Index>
    /// The value when the word is already written in digits.
    let digits: Int?

    static func tokenize(_ text: String) -> [SpokenToken] {
        var tokens: [SpokenToken] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i].isLetter || text[i].isNumber else { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, text[j].isLetter || text[j].isNumber || text[j] == "'" {
                // A trailing apostrophe belongs to the punctuation, not the word.
                if text[j] == "'" {
                    let after = text.index(after: j)
                    guard after < text.endIndex, text[after].isLetter else { break }
                }
                j = text.index(after: j)
            }
            let raw = String(text[i..<j])
            tokens.append(SpokenToken(raw: raw, folded: NumberLexicon.fold(raw),
                                      range: i..<j,
                                      digits: raw.allSatisfy(\.isNumber) ? Int(raw) : nil))
            i = j
        }
        return tokens
    }
}
