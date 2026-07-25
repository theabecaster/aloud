import XCTest
@testable import Aloud

// The model spells numbers out; these lock in how they get written back.
// Half of this file is the other half's insurance: for every conversion there
// are cases that must come through untouched, because a normalizer that
// rewrites prose is worse than no normalizer at all.
final class NumberNormalizerTests: XCTestCase {
    private func en(_ s: String) -> String { NumberNormalizer.normalize(s, lexicon: .english) }
    private func es(_ s: String) -> String { NumberNormalizer.normalize(s, lexicon: .spanish) }
    private func fr(_ s: String) -> String { NumberNormalizer.normalize(s, lexicon: .french) }
    private func de(_ s: String) -> String { NumberNormalizer.normalize(s, lexicon: .german) }
    private func pt(_ s: String) -> String { NumberNormalizer.normalize(s, lexicon: .portuguese) }

    // MARK: times

    func testMeridiem() {
        XCTAssertEqual(en("Can we get the report at three p.m.?"),
                       "Can we get the report at 3 PM?")
        XCTAssertEqual(en("call me at nine am"), "call me at 9 AM")
        XCTAssertEqual(en("it starts at seven thirty p.m. sharp"),
                       "it starts at 7:30 PM sharp")
        XCTAssertEqual(en("eleven forty five a.m."), "11:45 AM")
    }

    func testBareTimes() {
        XCTAssertEqual(en("let's meet at three thirty"), "let's meet at 3:30")
        XCTAssertEqual(en("three o'clock works"), "3 o'clock works")
        XCTAssertEqual(en("half past four"), "4:30")
        XCTAssertEqual(en("quarter past five"), "5:15")
        XCTAssertEqual(en("quarter to five"), "4:45")
        XCTAssertEqual(en("quarter to one"), "12:45")
        XCTAssertEqual(en("half past four p.m."), "4:30 PM")
    }

    // MARK: plain numbers

    func testCardinals() {
        XCTAssertEqual(en("forty two"), "42")
        XCTAssertEqual(en("twenty"), "20")
        XCTAssertEqual(en("one hundred"), "100")
        XCTAssertEqual(en("two hundred and five"), "205")
        XCTAssertEqual(en("three thousand five hundred"), "3500")
        XCTAssertEqual(en("we hired twenty five people"), "we hired 25 people")
    }

    func testMillionsKeepTheirWord() {
        XCTAssertEqual(en("two million"), "2 million")
        XCTAssertEqual(en("three billion"), "3 billion")
    }

    func testSmallNumbersStayWords() {
        XCTAssertEqual(en("one of them left"), "one of them left")
        XCTAssertEqual(en("no one showed up"), "no one showed up")
        XCTAssertEqual(en("give me two"), "give me two")
        XCTAssertEqual(en("she is five"), "she is five")
        XCTAssertEqual(en("at one point I thought so"), "at one point I thought so")
    }

    func testSmallNumbersWithAQuantity() {
        XCTAssertEqual(en("it took five minutes"), "it took 5 minutes")
        XCTAssertEqual(en("three degrees colder"), "3 degrees colder")
    }

    func testProseIsUntouched() {
        XCTAssertEqual(en("a hundred times better"), "a hundred times better")
        XCTAssertEqual(en("between three and five"), "between three and five")
        XCTAssertEqual(en("I'll second the motion"), "I'll second the motion")
        XCTAssertEqual(en("first of all, thanks"), "first of all, thanks")
        XCTAssertEqual(en("one on one for a second"), "one on one for a second")
        XCTAssertEqual(en("nothing numeric here at all"), "nothing numeric here at all")
    }

    // MARK: money, percent, units

    func testMoney() {
        XCTAssertEqual(en("that's forty two dollars"), "that's $42")
        XCTAssertEqual(en("forty two dollars and fifty cents"), "$42.50")
        XCTAssertEqual(en("one dollar"), "$1")
        XCTAssertEqual(en("twenty euros"), "€20")
        // Weight, not sterling — pounds only ever gain digits.
        XCTAssertEqual(en("twenty pounds of flour"), "20 pounds of flour")
    }

    func testPercent() {
        XCTAssertEqual(en("up twenty percent"), "up 20%")
        XCTAssertEqual(en("up twenty per cent"), "up 20%")
        XCTAssertEqual(en("5 percent"), "5%")
    }

    func testUnits() {
        XCTAssertEqual(en("five kilometers away"), "5 km away")
        XCTAssertEqual(en("sixteen gigabytes"), "16 GB")
        XCTAssertEqual(en("three miles"), "3 miles")
    }

    func testDecimals() {
        XCTAssertEqual(en("three point one four"), "3.14")
        XCTAssertEqual(en("version two point one"), "version 2.1")
    }

    // MARK: dates and years

    func testDates() {
        XCTAssertEqual(en("July twenty fifth"), "July 25")
        XCTAssertEqual(en("july second"), "July 2")
        XCTAssertEqual(en("the twenty fifth of July"), "the 25th of July")
    }

    func testOrdinals() {
        XCTAssertEqual(en("the twenty first attempt"), "the 21st attempt")
        XCTAssertEqual(en("the thirty second time"), "the 32nd time")
        XCTAssertEqual(en("the fifteenth"), "the 15th")
    }

    func testYears() {
        XCTAssertEqual(en("in twenty twenty six"), "in 2026")
        XCTAssertEqual(en("nineteen eighty four"), "1984")
        XCTAssertEqual(en("two thousand twenty six"), "2026")
    }

    func testDigitRun() {
        XCTAssertEqual(en("five five five one two three four"), "5551234")
        // Too short to be anything but words.
        XCTAssertEqual(en("one two three"), "one two three")
    }

    // MARK: already written in digits

    func testDigitsAreLeftAlone() {
        XCTAssertEqual(en("meet at 3 PM"), "meet at 3 PM")
        XCTAssertEqual(en("costs 42 dollars"), "costs $42")
        XCTAssertEqual(en("427.62 exactly"), "427.62 exactly")
    }

    // MARK: live-typing tail

    func testHoldTailLeavesTheLastPhrase() {
        XCTAssertEqual(NumberNormalizer.normalize("meet me at three", lexicon: .english,
                                                  holdTail: true),
                       "meet me at three")
        XCTAssertEqual(NumberNormalizer.normalize("forty two people and three",
                                                  lexicon: .english, holdTail: true),
                       "42 people and three")
    }

    // MARK: Spanish

    func testSpanish() {
        XCTAssertEqual(es("cuarenta y dos euros"), "42 euros")
        XCTAssertEqual(es("veinticinco de julio"), "25 de julio")
        XCTAssertEqual(es("cinco de mayo"), "5 de mayo")
        XCTAssertEqual(es("subió un veinte por ciento"), "subió un 20 %")
        XCTAssertEqual(es("dos mil veintiséis"), "2026")
        XCTAssertEqual(es("tres coma uno cuatro"), "3,14")
        XCTAssertEqual(es("a las tres"), "a las 3")
        XCTAssertEqual(es("ciento veinte"), "120")
    }

    func testSpanishProse() {
        XCTAssertEqual(es("uno de ellos se fue"), "uno de ellos se fue")
        XCTAssertEqual(es("mil gracias"), "mil gracias")
        XCTAssertEqual(es("cinco y seis"), "cinco y seis")
    }

    // MARK: French

    func testFrench() {
        XCTAssertEqual(fr("quatre-vingt-dix-neuf euros"), "99 euros")
        XCTAssertEqual(fr("soixante-quinze"), "75")
        XCTAssertEqual(fr("vingt et un jours"), "21 jours")
        XCTAssertEqual(fr("trois heures"), "3 heures")
        XCTAssertEqual(fr("vingt pour cent"), "20 %")
        XCTAssertEqual(fr("trois virgule cinq"), "3,5")
    }

    func testFrenchProse() {
        XCTAssertEqual(fr("un de ces jours"), "un de ces jours")
        XCTAssertEqual(fr("mille mercis"), "mille mercis")
    }

    // MARK: German

    func testGerman() {
        XCTAssertEqual(de("zweiundvierzig Euro"), "42 Euro")
        XCTAssertEqual(de("einundzwanzig Tage"), "21 Tage")
        XCTAssertEqual(de("dreihundertfünf"), "305")
        XCTAssertEqual(de("um drei Uhr"), "um 3 Uhr")
        XCTAssertEqual(de("halb drei"), "halb 3")
        XCTAssertEqual(de("zwanzig Prozent"), "20 %")
        XCTAssertEqual(de("zweitausendsechsundzwanzig"), "2026")
    }

    func testGermanProse() {
        // Words that merely start like a number are not numbers.
        XCTAssertEqual(de("Achtung, bitte"), "Achtung, bitte")
        XCTAssertEqual(de("ein Freund von mir"), "ein Freund von mir")
        XCTAssertEqual(de("tausend Dank"), "tausend Dank")
    }

    // MARK: Portuguese

    func testPortuguese() {
        XCTAssertEqual(pt("quarenta e dois reais"), "42 reais")
        XCTAssertEqual(pt("vinte e cinco de julho"), "25 de julho")
        XCTAssertEqual(pt("cento e vinte"), "120")
        XCTAssertEqual(pt("vinte por cento"), "20%")
        XCTAssertEqual(pt("três vírgula cinco"), "3,5")
    }

    func testPortugueseProse() {
        XCTAssertEqual(pt("um dos meus amigos"), "um dos meus amigos")
        XCTAssertEqual(pt("mil desculpas"), "mil desculpas")
    }

    // MARK: sentences, end to end
    //
    // Whole utterances, because the constructs have to cooperate: a number in
    // one place must not spoil the reading of the next.

    func testSentences() {
        XCTAssertEqual(en("eighty five degrees at three thirty p.m. on July fourth"),
                       "85 degrees at 3:30 PM on July 4")
        XCTAssertEqual(en("I woke up at six and left at seven fifteen"),
                       "I woke up at 6 and left at 7:15")
        XCTAssertEqual(en("she turned twenty one last May second"),
                       "she turned 21 last May 2")
        XCTAssertEqual(en("five hundred and twenty three point four"), "523.4")
        XCTAssertEqual(en("it's twenty past six"), "it's 6:20")
        XCTAssertEqual(en("ten to nine tomorrow"), "8:50 tomorrow")
        // A range is not a time — thirty is not an hour.
        XCTAssertEqual(en("there are twenty to thirty people"), "there are 20 to 30 people")
        XCTAssertEqual(en("I have five to do"), "I have five to do")
    }

    func testEnglishProseAtLength() {
        for sentence in ["I have one more thing to say", "one or two of us are going",
                         "give me a second", "on the one hand it works",
                         "he came in second place", "I said no a thousand times",
                         "there were like a million people", "nine to five job",
                         "a quarter of the team", "third time's the charm",
                         "add two and two", "call me back in five"] {
            XCTAssertEqual(en(sentence), sentence, "rewrote prose: \(sentence)")
        }
    }

    func testOtherLanguageProseAtLength() {
        for sentence in ["uno o dos amigos", "hace un año", "una de las cosas",
                         "el primero de mayo", "no tengo ni una"] {
            XCTAssertEqual(es(sentence), sentence, "rewrote prose: \(sentence)")
        }
        for sentence in ["un ami à moi", "le premier mai", "il y a un an",
                         "quelques centaines de personnes"] {
            XCTAssertEqual(fr(sentence), sentence, "rewrote prose: \(sentence)")
        }
        for sentence in ["ein paar Leute", "vor einem Jahr", "es ist Viertel nach drei"] {
            XCTAssertEqual(de(sentence), sentence, "rewrote prose: \(sentence)")
        }
        for sentence in ["um dia desses", "primeiro de maio", "há um ano",
                         "são sete e meia"] {
            XCTAssertEqual(pt(sentence), sentence, "rewrote prose: \(sentence)")
        }
    }

    func testLongerSentencesInOtherLanguages() {
        XCTAssertEqual(es("el veintiuno de septiembre de dos mil veinticuatro"),
                       "el 21 de septiembre de 2024")
        XCTAssertEqual(es("son las siete y media"), "son las 7 y media")
        XCTAssertEqual(es("cuesta mil quinientos"), "cuesta 1500")
        XCTAssertEqual(fr("il est trois heures et demie"), "il est 3 heures et demie")
        XCTAssertEqual(fr("quatre-vingts euros"), "80 euros")
        XCTAssertEqual(fr("soixante-dix pour cent"), "70 %")
        XCTAssertEqual(de("neunzehnhundertvierundachtzig"), "1984")
        XCTAssertEqual(de("sieben Uhr dreißig"), "7 Uhr 30")
        XCTAssertEqual(pt("vinte e um de setembro de dois mil e vinte e quatro"),
                       "21 de setembro de 2024")
        XCTAssertEqual(pt("duzentos e cinquenta reais"), "250 reais")
    }

    // MARK: language routing

    func testUnsupportedLanguageIsUntouched() {
        XCTAssertEqual(NumberNormalizer.normalize("veertig euro", languages: ["nl"]),
                       "veertig euro")
    }

    func testDeclaredLanguagePicksTheLexicon() {
        XCTAssertEqual(NumberNormalizer.normalize("forty two dollars", languages: ["en"]),
                       "$42")
    }
}
