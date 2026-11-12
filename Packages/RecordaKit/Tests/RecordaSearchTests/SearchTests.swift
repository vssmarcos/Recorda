import XCTest
import GRDB
import RecordaCore
@testable import RecordaSearch

final class SearchParserTests: XCTestCase {

    func testEmptyAndWildcard() throws {
        XCTAssertEqual(try SearchParser.parse(""), .all)
        XCTAssertEqual(try SearchParser.parse("   "), .all)
        XCTAssertEqual(try SearchParser.parse("*"), .all)
    }

    func testImplicitAndExplicitOperators() throws {
        XCTAssertEqual(try SearchParser.parse("cão gato"), .and([.text("cão"), .text("gato")]))
        XCTAssertEqual(try SearchParser.parse("cão and gato"), .and([.text("cão"), .text("gato")]))
        XCTAssertEqual(try SearchParser.parse("cão or gato"), .or([.text("cão"), .text("gato")]))
        XCTAssertEqual(try SearchParser.parse("cão OR gato rato"), .or([.text("cão"), .and([.text("gato"), .text("rato")])]))
    }

    func testNegationAndGroups() throws {
        XCTAssertEqual(try SearchParser.parse("-gato"), .not(.text("gato")))
        XCTAssertEqual(try SearchParser.parse("-(a or b) c"),
                       .and([.not(.or([.text("a"), .text("b")])), .text("c")]))
        XCTAssertEqual(try SearchParser.parse("-tag:difícil"), .not(.keyed(key: "tag", value: "difícil")))
        // Hífen no meio de palavra não é negação.
        XCTAssertEqual(try SearchParser.parse("guarda-chuva"), .text("guarda-chuva"))
    }

    func testQuotesAndPrefixes() throws {
        XCTAssertEqual(try SearchParser.parse("\"um cão\""), .text("um cão"))
        XCTAssertEqual(try SearchParser.parse("deck:\"Meu baralho\""), .keyed(key: "deck", value: "Meu baralho"))
        XCTAssertEqual(try SearchParser.parse("\"deck:Meu baralho\""), .keyed(key: "deck", value: "Meu baralho"))
        XCTAssertEqual(try SearchParser.parse("frente:olá"), .keyed(key: "frente", value: "olá"))
        XCTAssertEqual(try SearchParser.parse("prop:ivl>=10"), .keyed(key: "prop", value: "ivl>=10"))
        XCTAssertEqual(try SearchParser.parse("\"or\""), .text("or"))
        XCTAssertEqual(try SearchParser.parse("a\\:b"), .text("a:b"))
    }

    func testErrors() {
        XCTAssertThrowsError(try SearchParser.parse("(a b")) { XCTAssertEqual($0 as? SearchError, .unbalancedParenthesis) }
        XCTAssertThrowsError(try SearchParser.parse("a b)")) { XCTAssertEqual($0 as? SearchError, .unbalancedParenthesis) }
        XCTAssertThrowsError(try SearchParser.parse("\"sem fim")) { XCTAssertEqual($0 as? SearchError, .unterminatedQuote) }
        XCTAssertThrowsError(try SearchParser.parse("or a"))
        XCTAssertThrowsError(try SearchParser.parse("a or"))
    }

    func testLikePatternConversion() {
        XCTAssertEqual(SearchSQLWriter.likePattern("a*b"), "a%b")
        XCTAssertEqual(SearchSQLWriter.likePattern("100%"), "100\\%")
        XCTAssertEqual(SearchSQLWriter.likePattern("a_b"), "a_b")
        XCTAssertEqual(SearchSQLWriter.likePattern("a\\_b"), "a\\_b")
        XCTAssertEqual(SearchSQLWriter.likePattern("a\\*b"), "a*b")
    }
}

final class SearchExecutionTests: XCTestCase {

    var clock: TestClock!
    var collection: Collection!
    var ids: [String: CardID] = [:]

    override func setUpWithError() throws {
        clock = TestClock()
        collection = try Collection(inMemoryWithMediaFolder: nil, clock: clock.clock)
        ids = [:]
        try collection.write { txn in
            let basic = try XCTUnwrap(try txn.notetype(named: "Básico"))
            let cloze = try XCTUnwrap(try txn.notetype(named: "Omissão de palavras"))
            let animals = try txn.addDeck(named: "Animais")
            let birds = try txn.addDeck(named: "Animais::Aves")

            func add(_ key: String, _ fields: [String], type: Notetype, deck: DeckID, tags: [String] = []) throws {
                var note = Note(id: 0, guid: "", mid: type.id)
                note.fields = fields
                note.tagList = tags
                let cards = try txn.addNote(&note, deckID: deck)
                for card in cards { self.ids["\(key)\(card.ord)"] = card.id }
            }
            try add("cão", ["cão", "dog"], type: basic, deck: animals.id, tags: ["mamífero", "fácil"])
            try add("gato", ["gato", "cat <b>preto</b>"], type: basic, deck: animals.id, tags: ["mamífero"])
            try add("arara", ["arara", "macaw"], type: basic, deck: birds.id, tags: ["ave::tropical"])
            try add("água", ["água 100%", "water"], type: basic, deck: 1)
            try add("cloze", ["O {{c1::sol}} e a {{c2::lua}}", ""], type: cloze, deck: 1, tags: ["astro"])

            // Estados variados.
            var review = try txn.card(try XCTUnwrap(self.ids["cão0"]))
            review.type = .review
            review.queue = .review
            review.ivl = 30
            review.factor = 2300
            review.due = 0
            review.lapses = 2
            review.reps = 9
            review.cardData = CardData(s: 40, d: 6)
            try txn.saveCard(&review)

            var future = try txn.card(try XCTUnwrap(self.ids["gato0"]))
            future.type = .review
            future.queue = .review
            future.ivl = 5
            future.factor = 2600
            future.due = 3
            try txn.saveCard(&future)

            var suspended = try txn.card(try XCTUnwrap(self.ids["arara0"]))
            suspended.queue = .suspended
            suspended.userFlag = 3
            try txn.saveCard(&suspended)

            try RevlogEntry(id: txn.nowMillis - 1000, cid: review.id, ease: 1, ivl: 30, lastIvl: 20, factor: 2300, time: 4000, type: .review).insert(txn.db)
            try RevlogEntry(id: txn.nowMillis - 500, cid: future.id, ease: 3, ivl: 5, lastIvl: 2, factor: 2600, time: 4000, type: .review).insert(txn.db)
        }
    }

    func search(_ query: String) throws -> Set<String> {
        let found = Set(try collection.read { try $0.searchCards(query) })
        return Set(ids.filter { found.contains($0.value) }.keys)
    }

    func testPlainText() throws {
        XCTAssertEqual(try search(""), Set(ids.keys))
        XCTAssertEqual(try search("gato"), ["gato0"])
        XCTAssertEqual(try search("GATO"), ["gato0"])
        XCTAssertEqual(try search("dog or macaw"), ["cão0", "arara0"])
        XCTAssertEqual(try search("-gato -cão -sol"), ["arara0", "água0"])
        XCTAssertEqual(try search("\"cat <b>preto\""), ["gato0"])
        XCTAssertEqual(try search("ar*ra"), ["arara0"])
        // "%" é literal, não curinga.
        XCTAssertEqual(try search("100%"), ["água0"])
        XCTAssertEqual(try search("10%0"), [])
    }

    func testDeckSearch() throws {
        XCTAssertEqual(try search("deck:Animais"), ["cão0", "gato0", "arara0"])
        XCTAssertEqual(try search("deck:Animais::Aves"), ["arara0"])
        XCTAssertEqual(try search("deck:animais::*"), ["arara0"])
        XCTAssertEqual(try search("-deck:Animais"), ["água0", "cloze0", "cloze1"])
        XCTAssertEqual(try search("deck:Inexistente"), [])
    }

    func testTagSearch() throws {
        XCTAssertEqual(try search("tag:mamífero"), ["cão0", "gato0"])
        XCTAssertEqual(try search("tag:mam*"), ["cão0", "gato0"])
        XCTAssertEqual(try search("tag:ave"), ["arara0"])
        XCTAssertEqual(try search("tag:ave::tropical"), ["arara0"])
        XCTAssertEqual(try search("tag:none"), ["água0"])
        XCTAssertEqual(try search("tag:mamífero -tag:fácil"), ["gato0"])
    }

    func testNotetypeCardAndFieldSearch() throws {
        XCTAssertEqual(try search("note:Básico"), ["cão0", "gato0", "arara0", "água0"])
        XCTAssertEqual(try search("\"note:Omissão de palavras\""), ["cloze0", "cloze1"])
        XCTAssertEqual(try search("card:2"), ["cloze1"])
        XCTAssertEqual(try search("\"card:Card 1\""), ["cão0", "gato0", "arara0", "água0"])
        XCTAssertEqual(try search("Verso:dog"), ["cão0"])
        XCTAssertEqual(try search("verso:d*"), ["cão0"])
        XCTAssertEqual(try search("Frente:dog"), [])
        XCTAssertEqual(try search("\"Verso extra:\""), ["cloze0", "cloze1"])
        XCTAssertEqual(try search("\"Verso:re:^(dog|water)$\""), ["cão0", "água0"])
        XCTAssertEqual(try search("CampoQueNãoExiste:x"), [])
    }

    func testStateFlagAndProperties() throws {
        XCTAssertEqual(try search("is:new"), ["arara0", "água0", "cloze0", "cloze1"])
        XCTAssertEqual(try search("is:review"), ["cão0", "gato0"])
        XCTAssertEqual(try search("is:due"), ["cão0"])
        XCTAssertEqual(try search("is:suspended"), ["arara0"])
        XCTAssertEqual(try search("flag:3"), ["arara0"])
        XCTAssertEqual(try search("flag:0 is:review"), ["cão0", "gato0"])
        XCTAssertEqual(try search("prop:ivl>=10"), ["cão0"])
        XCTAssertEqual(try search("prop:ivl<10 is:review"), ["gato0"])
        XCTAssertEqual(try search("prop:due=3"), ["gato0"])
        XCTAssertEqual(try search("prop:due<=0"), ["cão0"])
        XCTAssertEqual(try search("prop:ease>2.5"), ["gato0"])
        XCTAssertEqual(try search("prop:lapses>1"), ["cão0"])
        XCTAssertEqual(try search("prop:reps=9"), ["cão0"])
        XCTAssertEqual(try search("prop:s>30"), ["cão0"])
        XCTAssertEqual(try search("prop:d>=6"), ["cão0"])
    }

    func testHistorySearches() throws {
        XCTAssertEqual(try search("rated:1"), ["cão0", "gato0"])
        XCTAssertEqual(try search("rated:1:1"), ["cão0"])
        XCTAssertEqual(try search("rated:7:3"), ["gato0"])
        XCTAssertEqual(try search("added:1"), Set(ids.keys))
        XCTAssertEqual(try search("edited:1"), Set(ids.keys))
        clock.advance(days: 3)
        XCTAssertEqual(try search("added:1"), [])
        XCTAssertEqual(try search("added:5"), Set(ids.keys))
        XCTAssertEqual(try search("rated:2"), [])
    }

    func testRegexWordAndDiacritics() throws {
        XCTAssertEqual(try search("re:^g.to"), ["gato0"])
        XCTAssertEqual(try search("\"re:c\\d::\""), ["cloze0", "cloze1"])
        XCTAssertEqual(try search("w:cat"), ["gato0"])
        XCTAssertEqual(try search("w:ca"), [])
        XCTAssertEqual(try search("nc:agua"), ["água0"])
        XCTAssertEqual(try search("nc:cao"), ["cão0"])
    }

    func testIdsAndInvalidTerms() throws {
        let gato = try XCTUnwrap(ids["gato0"])
        let cao = try XCTUnwrap(ids["cão0"])
        XCTAssertEqual(try search("cid:\(gato),\(cao)"), ["gato0", "cão0"])
        XCTAssertEqual(try search("did:1"), ["água0", "cloze0", "cloze1"])
        XCTAssertThrowsError(try search("is:voando"))
        XCTAssertThrowsError(try search("prop:ivl~3"))
        XCTAssertThrowsError(try search("flag:9"))
        XCTAssertThrowsError(try search("rated:x"))
    }

    func testNoteSearchAndSorting() throws {
        let notes = try collection.read { try $0.searchNotes("note:Omissão*") }
        XCTAssertEqual(notes.count, 1)

        let sorted = try collection.read { try $0.searchCards("note:Básico", sort: SearchSort(column: .sortField, ascending: true)) }
        let names = try collection.read { txn in try sorted.map { try txn.note(try txn.card($0).nid).sfld } }
        // O SQLite ordena por bytes (NOCASE só trata ASCII), então "água" vem depois de "gato".
        XCTAssertEqual(names, ["arara", "cão", "gato", "água 100%"])

        let byInterval = try collection.read { try $0.searchCards("is:review", sort: SearchSort(column: .interval, ascending: false)) }
        XCTAssertEqual(byInterval, [try XCTUnwrap(ids["cão0"]), try XCTUnwrap(ids["gato0"])])
    }
}
