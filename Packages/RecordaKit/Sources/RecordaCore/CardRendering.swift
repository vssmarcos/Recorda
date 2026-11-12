import Foundation
import GRDB
import RecordaTemplates

/// Resultado da renderização dos dois lados de um card.
public struct RenderedCard: Sendable {
    public var cardID: CardID
    public var noteID: NoteID
    public var notetypeID: NotetypeID
    public var cardOrdinal: Int
    public var questionHTML: String
    public var answerHTML: String
    public var css: String
    public var questionAudio: [AVTag]
    public var answerAudio: [AVTag]
    /// Presente quando a frente tem `{{type:...}}`.
    public var typeAnswer: TypeAnswerSpec?
    /// Texto esperado para a resposta digitada.
    public var expectedTypedAnswer: String?
    public var typeFontName: String
    public var typeFontSize: Int
    public var isCloze: Bool
    public var isImageOcclusion: Bool

    /// HTML da frente com o campo de digitação (se houver).
    public var questionForDisplay: String {
        guard typeAnswer != nil else { return questionHTML }
        return TypeAnswer.questionHTML(questionHTML, fontFamily: typeFontName, fontSize: typeFontSize)
    }

    /// HTML do verso com a comparação da resposta digitada (se houver).
    public func answerForDisplay(typed: String) -> String {
        guard let spec = typeAnswer, let expected = expectedTypedAnswer else {
            return TypeAnswer.removingMarker(answerHTML)
        }
        return TypeAnswer.answerHTML(answerHTML, expected: expected, typed: typed,
                                     ignoreCombining: spec.ignoreCombining,
                                     fontFamily: typeFontName, fontSize: typeFontSize)
    }
}

public enum CardRenderer {

    /// Renderiza um card a partir dos objetos já carregados (sem acesso ao banco).
    public static func render(card: Card, note: Note, notetype: Notetype, deckName: String,
                              browserAppearance: Bool = false) -> RenderedCard {
        let templateIndex = notetype.isCloze ? 0 : card.ord
        let template: CardTemplate
        if notetype.templates.indices.contains(templateIndex) {
            template = notetype.templates[templateIndex]
        } else {
            template = CardTemplate(ord: card.ord, name: "?", qfmt: "", afmt: "")
        }
        var qfmt = template.qfmt
        var afmt = template.afmt
        if browserAppearance {
            if !template.browserQfmt.isEmpty { qfmt = template.browserQfmt }
            if !template.browserAfmt.isEmpty { afmt = template.browserAfmt }
        }

        var fields: [String: String] = [:]
        let values = note.fields
        for (index, field) in notetype.fields.enumerated() {
            fields[field.name] = index < values.count ? values[index] : ""
        }
        let cardName = notetype.isCloze ? "Omissão \(card.ord + 1)" : template.name
        var context = RenderContext(fields: fields, cardOrdinal: card.ord, isAnswer: false, frontSide: nil,
                                    tags: note.tags, deckName: deckName, cardName: cardName,
                                    notetypeName: notetype.name, flag: card.userFlag, cardID: card.id)

        func renderSide(_ source: String, side: String) -> (String, [AVTag]) {
            let html: String
            do {
                let parsed = try ParsedTemplate(source)
                html = TemplateRenderer.render(parsed, context: context)
            } catch {
                html = "<div class=\"template-error\">Erro no modelo do card: \(HTMLText.escape("\(error)"))</div>"
            }
            return AVTags.extract(from: LatexMarkup.toMathJax(html), side: side)
        }

        var (question, questionAudio) = renderSide(qfmt, side: "q")
        if TemplateRenderer.fieldIsEmpty(question) {
            question = "<div class=\"template-error\">A frente deste card está em branco.</div>"
        }
        context.isAnswer = true
        context.frontSide = question
        let (answer, answerAudio) = renderSide(afmt, side: "a")

        var typeSpec: TypeAnswerSpec?
        var expected: String?
        var fontName = "Arial"
        var fontSize = 20
        if let spec = TemplateCache.shared.parsed(qfmt)?.typeAnswerSpec,
           let index = notetype.fieldIndex(named: spec.field) {
            typeSpec = spec
            expected = TypeAnswer.expectedText(fieldValue: index < values.count ? values[index] : "",
                                               spec: spec, cardOrdinal: card.ord)
            fontName = notetype.fields[index].fontName
            fontSize = notetype.fields[index].fontSize
        }

        return RenderedCard(cardID: card.id, noteID: note.id, notetypeID: notetype.id, cardOrdinal: card.ord,
                            questionHTML: question, answerHTML: answer, css: notetype.css,
                            questionAudio: questionAudio, answerAudio: answerAudio,
                            typeAnswer: typeSpec, expectedTypedAnswer: expected,
                            typeFontName: fontName, typeFontSize: fontSize,
                            isCloze: notetype.isCloze, isImageOcclusion: notetype.isImageOcclusion)
    }
}

extension Txn {
    public func render(card: Card, browserAppearance: Bool = false) throws -> RenderedCard {
        let loaded = try self.note(card.nid)
        let nt = try notetype(loaded.mid)
        let deckName = try deckIfExists(card.homeDeckID)?.name ?? ""
        return CardRenderer.render(card: card, note: loaded, notetype: nt, deckName: deckName,
                                   browserAppearance: browserAppearance)
    }

    public func render(cardID: CardID) throws -> RenderedCard {
        try render(card: try card(cardID))
    }
}
