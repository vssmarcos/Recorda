import XCTest
@testable import RecordaTemplates

final class TemplateParserTests: XCTestCase {

    func render(_ source: String, _ fields: [String: String], ordinal: Int = 0, answer: Bool = false,
                front: String? = nil, tags: String = "", deck: String = "Pai::Filho") throws -> String {
        let template = try ParsedTemplate(source)
        let context = RenderContext(fields: fields, cardOrdinal: ordinal, isAnswer: answer, frontSide: front,
                                    tags: tags, deckName: deck, cardName: "Card 1", notetypeName: "Básico",
                                    flag: 2, cardID: 42)
        return TemplateRenderer.render(template, context: context)
    }

    func testParsesTextAndReplacements() throws {
        let template = try ParsedTemplate("a {{Frente}} b {{text:hint:Verso}} c")
        XCTAssertEqual(template.nodes, [
            .text("a "), .replacement(key: "Frente", filters: []), .text(" b "),
            .replacement(key: "Verso", filters: ["text", "hint"]), .text(" c"),
        ])
        XCTAssertEqual(template.referencedKeys, ["Frente", "Verso"])
    }

    func testParsesNestedConditionals() throws {
        let template = try ParsedTemplate("{{#A}}x{{^B}}y{{/B}}{{/A}}")
        XCTAssertEqual(template.nodes, [
            .conditional(key: "A", children: [.text("x"), .negated(key: "B", children: [.text("y")])]),
        ])
    }

    func testSyntaxErrors() {
        XCTAssertThrowsError(try ParsedTemplate("{{#A}}sem fim")) { XCTAssertEqual($0 as? TemplateError, .conditionalNotClosed("A")) }
        XCTAssertThrowsError(try ParsedTemplate("texto{{/A}}")) { XCTAssertEqual($0 as? TemplateError, .conditionalNotOpen("A")) }
        XCTAssertThrowsError(try ParsedTemplate("{{#A}}{{/B}}")) {
            XCTAssertEqual($0 as? TemplateError, .mismatchedClose(expected: "A", found: "B"))
        }
        XCTAssertThrowsError(try ParsedTemplate("abc {{Frente"))
    }

    func testCommentsAndLegacyTripleBraces() throws {
        XCTAssertEqual(try render("<!-- {{Nada}} -->{{Frente}}", ["Frente": "oi"]), "<!-- {{Nada}} -->oi")
        XCTAssertEqual(try render("{{{Frente}}}", ["Frente": "<b>oi</b>"]), "<b>oi</b>")
    }

    func testFieldReplacementAndSpecialFields() throws {
        XCTAssertEqual(try render("{{Frente}} / {{Verso}}", ["Frente": "casa", "Verso": "house"]), "casa / house")
        XCTAssertEqual(try render("{{Deck}}|{{Subdeck}}|{{Card}}|{{Type}}|{{Tags}}|{{CardFlag}}", [:], tags: " a b "),
                       "Pai::Filho|Filho|Card 1|Básico|a b|flag2")
        XCTAssertEqual(try render("{{FrontSide}}<hr id=answer>{{Verso}}", ["Verso": "v"], answer: true, front: "FRENTE"),
                       "FRENTE<hr id=answer>v")
        XCTAssertTrue(try render("{{Inexistente}}", [:]).contains("campo desconhecido"))
    }

    func testConditionals() throws {
        let source = "{{#Extra}}[{{Extra}}]{{/Extra}}{{^Extra}}(vazio){{/Extra}}"
        XCTAssertEqual(try render(source, ["Extra": "x"]), "[x]")
        XCTAssertEqual(try render(source, ["Extra": ""]), "(vazio)")
        // Só espaços e quebras contam como vazio.
        XCTAssertEqual(try render(source, ["Extra": " <br> <div></div>&nbsp;"]), "(vazio)")
        XCTAssertTrue(TemplateRenderer.fieldIsEmpty("<br/>"))
        XCTAssertFalse(TemplateRenderer.fieldIsEmpty("<img src=\"a.png\">"))
    }

    func testTextAndHintFilters() throws {
        XCTAssertEqual(try render("{{text:Frente}}", ["Frente": "<b>neg</b> &amp; <i>it</i>"]), "neg & it")
        let hint = try render("{{hint:Dica}}", ["Dica": "pista"])
        XCTAssertTrue(hint.contains("class=\"hint\""))
        XCTAssertTrue(hint.contains("pista"))
        XCTAssertTrue(hint.contains(">Dica</a>"))
        XCTAssertEqual(try render("{{hint:Dica}}", ["Dica": ""]), "")
    }

    func testTTSFilter() throws {
        XCTAssertEqual(try render("{{tts en_US:Frente}}", ["Frente": "<b>hello</b>"]), "[anki:tts lang=en_US]hello[/anki:tts]")
        XCTAssertEqual(try render("{{tts pt_BR voices=Luciana speed=0.8:Frente}}", ["Frente": "olá"]),
                       "[anki:tts lang=pt_BR voices=Luciana speed=0.8]olá[/anki:tts]")
        XCTAssertEqual(try render("{{tts en_US:Frente}}", ["Frente": ""]), "")
    }

    func testTypeFilterLeavesMarker() throws {
        XCTAssertEqual(try render("{{Frente}} {{type:Verso}}", ["Frente": "f", "Verso": "v"]), "f [[type:Verso]]")
        XCTAssertEqual(try render("{{type:cloze:Texto}}", ["Texto": "{{c1::a}}"]), "[[type:cloze:Texto]]")
        let spec = try ParsedTemplate("{{Frente}}{{type:nc:Verso}}").typeAnswerSpec
        XCTAssertEqual(spec, TypeAnswerSpec(field: "Verso", isCloze: false, ignoreCombining: true))
        XCTAssertNil(try ParsedTemplate("{{Frente}}").typeAnswerSpec)
    }

    func testFuriganaFilters() throws {
        let fields = ["Leitura": "日本語[にほんご]を 勉強[べんきょう]"]
        XCTAssertEqual(try render("{{furigana:Leitura}}", fields),
                       "<ruby><rb>日本語</rb><rt>にほんご</rt></ruby>を<ruby><rb>勉強</rb><rt>べんきょう</rt></ruby>")
        XCTAssertEqual(try render("{{kana:Leitura}}", fields), "にほんごをべんきょう")
        XCTAssertEqual(try render("{{kanji:Leitura}}", fields), "日本語を勉強")
        XCTAssertEqual(try render("{{furigana:Leitura}}", ["Leitura": "[sound:a.mp3]"]), "[sound:a.mp3]")
    }

    func testCardGenerationRule() throws {
        let front = try ParsedTemplate("{{#Extra}}{{Frente}}{{/Extra}}")
        XCTAssertFalse(front.rendersFieldContent(nonEmptyFields: ["Frente"]))
        XCTAssertTrue(front.rendersFieldContent(nonEmptyFields: ["Frente", "Extra"]))
        let negated = try ParsedTemplate("{{^Extra}}{{Frente}}{{/Extra}}")
        XCTAssertTrue(negated.rendersFieldContent(nonEmptyFields: ["Frente"]))
        XCTAssertFalse(negated.rendersFieldContent(nonEmptyFields: ["Frente", "Extra"]))
        // Só texto fixo não gera card.
        XCTAssertFalse(try ParsedTemplate("texto fixo {{Deck}}").rendersFieldContent(nonEmptyFields: ["Frente"]))
    }

    func testRenamingAndRemovingFields() throws {
        let template = try ParsedTemplate("{{#Frente}}{{text:Frente}}{{/Frente}} {{Verso}}")
        XCTAssertEqual(template.renamingField("Frente", to: "Pergunta"), "{{#Pergunta}}{{text:Pergunta}}{{/Pergunta}} {{Verso}}")
        XCTAssertEqual(template.renamingField("Frente", to: nil), " {{Verso}}")
    }
}

final class ClozeTests: XCTestCase {

    func testOrdinals() {
        XCTAssertEqual(Cloze.ordinals(in: "{{c1::a}} {{c3::b::dica}} {{c1::c}}"), [1, 3])
        XCTAssertEqual(Cloze.ordinals(in: "{{c1::fora {{c2::dentro}}}}"), [1, 2])
        XCTAssertEqual(Cloze.ordinals(in: "sem omissão"), [])
        XCTAssertEqual(Cloze.ordinals(in: "{{c0::inválido}}"), [])
        XCTAssertEqual(Cloze.nextOrdinal(in: ["{{c2::a}}", "{{c5::b}}"]), 6)
        XCTAssertEqual(Cloze.nextOrdinal(in: ["nada"]), 1)
    }

    func testQuestionAndAnswerRendering() {
        let text = "A capital da {{c1::França}} é {{c2::Paris::cidade}}."
        XCTAssertEqual(Cloze.render(text, ordinal: 1, isAnswer: false),
                       "A capital da <span class=\"cloze\" data-cloze=\"França\" data-ordinal=\"1\">[...]</span> é <span class=\"cloze-inactive\" data-ordinal=\"2\">Paris</span>.")
        XCTAssertEqual(Cloze.render(text, ordinal: 2, isAnswer: false),
                       "A capital da <span class=\"cloze-inactive\" data-ordinal=\"1\">França</span> é <span class=\"cloze\" data-cloze=\"Paris\" data-ordinal=\"2\">[cidade]</span>.")
        XCTAssertEqual(Cloze.render(text, ordinal: 2, isAnswer: true),
                       "A capital da <span class=\"cloze-inactive\" data-ordinal=\"1\">França</span> é <span class=\"cloze\" data-ordinal=\"2\">Paris</span>.")
    }

    func testNestedCloze() {
        let text = "{{c1::um {{c2::dois}} três}}"
        // Card 1: tudo oculto de uma vez.
        XCTAssertEqual(Cloze.render(text, ordinal: 1, isAnswer: false),
                       "<span class=\"cloze\" data-cloze=\"um dois três\" data-ordinal=\"1\">[...]</span>")
        // Card 2: só a parte interna.
        XCTAssertEqual(Cloze.render(text, ordinal: 2, isAnswer: false),
                       "<span class=\"cloze-inactive\" data-ordinal=\"1\">um <span class=\"cloze\" data-cloze=\"dois\" data-ordinal=\"2\">[...]</span> três</span>")
        XCTAssertEqual(Cloze.activeTexts(text, ordinal: 2), ["dois"])
        XCTAssertEqual(Cloze.activeTexts(text, ordinal: 1), ["um dois três"])
        XCTAssertEqual(Cloze.stripMarkup(text), "um dois três")
    }

    func testMalformedClozeIsLeftAsText() {
        XCTAssertEqual(Cloze.render("{{c1::sem fim", ordinal: 1, isAnswer: false), "{{c1::sem fim")
        XCTAssertEqual(Cloze.render("solto }} aqui", ordinal: 1, isAnswer: false), "solto }} aqui")
        XCTAssertEqual(Cloze.render("texto simples", ordinal: 1, isAnswer: true), "texto simples")
    }

    func testImageOcclusionShapes() {
        let text = "{{c1::image-occlusion:rect:left=.1:top=.2:width=.3:height=.4}}{{c2::image-occlusion:ellipse:left=.5:top=.5:rx=.1:ry=.2}}"
        let question = Cloze.render(text, ordinal: 1, isAnswer: false)
        XCTAssertTrue(question.contains("<div class=\"cloze\" data-ordinal=\"1\" data-shape=\"rect\" data-left=\".1\" data-top=\".2\" data-width=\".3\" data-height=\".4\"></div>"))
        XCTAssertTrue(question.contains("<div class=\"cloze-inactive\" data-ordinal=\"2\" data-shape=\"ellipse\""))
        let answer = Cloze.render(text, ordinal: 1, isAnswer: true)
        XCTAssertTrue(answer.contains("class=\"cloze-highlight\" data-ordinal=\"1\""))
        XCTAssertEqual(Cloze.ordinals(in: text), [1, 2])
    }

    func testClozeFilterInTemplate() throws {
        let template = try ParsedTemplate("{{cloze:Texto}}{{#c2}} (segunda){{/c2}}")
        XCTAssertEqual(template.clozeFields, ["Texto"])
        let fields = ["Texto": "{{c1::um}} e {{c2::dois}}"]
        let first = TemplateRenderer.render(template, context: RenderContext(fields: fields, cardOrdinal: 0))
        XCTAssertTrue(first.contains("data-cloze=\"um\""))
        XCTAssertFalse(first.contains("(segunda)"))
        let second = TemplateRenderer.render(template, context: RenderContext(fields: fields, cardOrdinal: 1))
        XCTAssertTrue(second.contains("data-cloze=\"dois\""))
        XCTAssertTrue(second.hasSuffix(" (segunda)"))
    }
}

final class TypeAnswerTests: XCTestCase {

    func testExactMatch() {
        XCTAssertEqual(TypeAnswer.compareHTML(expected: "casa", typed: "casa"),
                       "<code id=\"typeans\"><span class=\"typeGood\">casa</span></code>")
        // Espaços nas pontas e forma de normalização não importam.
        XCTAssertEqual(TypeAnswer.compareHTML(expected: "  café ", typed: "cafe\u{301}"),
                       "<code id=\"typeans\"><span class=\"typeGood\">café</span></code>")
    }

    func testEmptyTypedShowsExpectedOnly() {
        XCTAssertEqual(TypeAnswer.compareHTML(expected: "a < b", typed: "  "), "<code id=\"typeans\">a &lt; b</code>")
    }

    func testDiffSegments() {
        let result = TypeAnswer.diff(expected: "gato", typed: "gado")
        XCTAssertEqual(result.typed, [.good("ga"), .bad("d"), .missed("-"), .good("o")])
        XCTAssertEqual(result.expected, [.good("ga"), .missed("t"), .good("o")])

        let missing = TypeAnswer.diff(expected: "abc", typed: "ac")
        XCTAssertEqual(missing.typed, [.good("a"), .missed("-"), .good("c")])
        XCTAssertEqual(missing.expected, [.good("a"), .missed("b"), .good("c")])

        let extra = TypeAnswer.diff(expected: "ac", typed: "abc")
        XCTAssertEqual(extra.typed, [.good("a"), .bad("b"), .good("c")])
        XCTAssertEqual(extra.expected, [.good("ac")])
    }

    func testComparisonHTMLHighlightsDifferences() {
        let html = TypeAnswer.compareHTML(expected: "gato", typed: "gado")
        XCTAssertTrue(html.contains("<span class=\"typeBad\">d</span>"))
        XCTAssertTrue(html.contains("<span class=\"typeMissed\">t</span>"))
        XCTAssertTrue(html.contains("typearrow"))
    }

    func testIgnoringDiacritics() {
        XCTAssertEqual(TypeAnswer.compareHTML(expected: "ação", typed: "acao", ignoreCombining: true),
                       "<code id=\"typeans\"><span class=\"typeGood\">ação</span></code>")
        XCTAssertTrue(TypeAnswer.compareHTML(expected: "ação", typed: "acao").contains("typeBad"))
    }

    func testExpectedTextFromField() {
        let plain = TypeAnswerSpec(field: "Verso", isCloze: false, ignoreCombining: false)
        XCTAssertEqual(TypeAnswer.expectedText(fieldValue: "<b>casa</b>&nbsp;grande<br>", spec: plain, cardOrdinal: 0), "casa grande")
        let cloze = TypeAnswerSpec(field: "Texto", isCloze: true, ignoreCombining: false)
        XCTAssertEqual(TypeAnswer.expectedText(fieldValue: "{{c1::um}} {{c2::dois}} {{c1::três}}", spec: cloze, cardOrdinal: 0), "um, três")
        XCTAssertEqual(TypeAnswer.expectedText(fieldValue: "{{c1::igual}} e {{c1::igual}}", spec: cloze, cardOrdinal: 0), "igual")
    }

    func testMarkerReplacement() {
        let question = TypeAnswer.questionHTML("antes [[type:Verso]] depois")
        XCTAssertTrue(question.contains("<input type=\"text\" id=\"typeans\""))
        XCTAssertFalse(question.contains("[[type"))
        let answer = TypeAnswer.answerHTML("x [[type:Verso]] y", expected: "a$1b", typed: "a$1b")
        // Caracteres especiais de substituição não podem ser interpretados.
        XCTAssertTrue(answer.contains("a$1b"))
        XCTAssertEqual(TypeAnswer.removingMarker("a[[type:cloze:Texto]]b"), "ab")
    }
}

final class AVTagTests: XCTestCase {

    func testExtractsSoundAndTTS() {
        let html = "Olá [sound:ola.mp3] mundo [anki:tts lang=en_US speed=1.5]hello[/anki:tts]"
        let result = AVTags.extract(from: html, side: "q")
        XCTAssertEqual(result.tags, [
            .sound(filename: "ola.mp3"),
            .tts(text: "hello", lang: "en-US", voices: [], speed: 1.5),
        ])
        XCTAssertFalse(result.html.contains("[sound:"))
        XCTAssertTrue(result.html.contains("recordaPlay('q', 0)"))
        XCTAssertTrue(result.html.contains("recordaPlay('q', 1)"))
        XCTAssertEqual(AVTags.strip(html), "Olá  mundo ")
        XCTAssertEqual(AVTags.extract(from: "sem áudio", side: "a").tags, [])
    }

    func testLatexConversion() {
        XCTAssertEqual(LatexMarkup.toMathJax("a [$]x^2[/$] b"), "a \\(x^2\\) b")
        XCTAssertEqual(LatexMarkup.toMathJax("[$$]\\frac{1}{2}[/$$]"), "\\[\\frac{1}{2}\\]")
        XCTAssertEqual(LatexMarkup.toMathJax("[latex]E=mc^2[/latex]"), "\\(E=mc^2\\)")
        XCTAssertEqual(LatexMarkup.toMathJax("sem fórmula"), "sem fórmula")
    }
}
