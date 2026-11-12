import Foundation
import GRDB
import RecordaTemplates

/// Cache de templates já analisados (a análise é pura e depende só do texto).
final class TemplateCache: @unchecked Sendable {
    static let shared = TemplateCache()
    private let lock = NSLock()
    private var cache: [String: ParsedTemplate?] = [:]

    func parsed(_ source: String) -> ParsedTemplate? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[source] { return hit }
        let parsed = try? ParsedTemplate(source)
        if cache.count > 500 { cache.removeAll() }
        cache[source] = parsed
        return parsed
    }
}

public enum ImageOcclusionField: Int, Sendable {
    case occlusions = 0, image, header, backExtra, comments
}

extension Notetype {

    static let clozeCSS = """
    .card {
        font-family: arial;
        font-size: 20px;
        text-align: center;
        color: black;
        background-color: white;
    }
    .cloze {
        font-weight: bold;
        color: blue;
    }
    .nightMode .cloze {
        color: lightblue;
    }
    """

    static let imageOcclusionCSS = """
    .card {
        font-family: arial;
        font-size: 20px;
        text-align: center;
        color: black;
        background-color: white;
    }
    #image-occlusion-container {
        position: relative;
        display: inline-block;
        max-width: 100%;
    }
    #image-occlusion-container img {
        max-width: 100%;
        display: block;
    }
    #image-occlusion-canvas {
        position: absolute;
        top: 0;
        left: 0;
        width: 100%;
        height: 100%;
    }
    :root {
        --inactive-shape-color: #ffeba2;
        --active-shape-color: #ff8e8e;
        --inactive-shape-border: 1px #212121;
        --active-shape-border: 1px #212121;
        --highlight-shape-color: #ff8e8e00;
        --highlight-shape-border: 1px #ff8e8e;
    }
    """

    /// Cria (sem gravar) um dos tipos de nota padrão.
    public static func stock(_ kind: StockNotetype, id: NotetypeID = 0) -> Notetype {
        var config = NotetypeConfig()
        config.originalStockKind = kind
        let answerSeparator = "\n\n<hr id=answer>\n\n"
        let name: String
        switch kind {
        case .basic:
            name = "Básico"
            config.fields = [NoteField(ord: 0, name: "Frente"), NoteField(ord: 1, name: "Verso")]
            config.templates = [
                CardTemplate(ord: 0, name: "Card 1", qfmt: "{{Frente}}", afmt: "{{FrontSide}}\(answerSeparator){{Verso}}"),
            ]
        case .basicAndReversed:
            name = "Básico (e card invertido)"
            config.fields = [NoteField(ord: 0, name: "Frente"), NoteField(ord: 1, name: "Verso")]
            config.templates = [
                CardTemplate(ord: 0, name: "Card 1", qfmt: "{{Frente}}", afmt: "{{FrontSide}}\(answerSeparator){{Verso}}"),
                CardTemplate(ord: 1, name: "Card 2", qfmt: "{{Verso}}", afmt: "{{FrontSide}}\(answerSeparator){{Frente}}"),
            ]
        case .basicOptionalReversed:
            name = "Básico (card invertido opcional)"
            config.fields = [NoteField(ord: 0, name: "Frente"), NoteField(ord: 1, name: "Verso"),
                             NoteField(ord: 2, name: "Adicionar inverso")]
            config.templates = [
                CardTemplate(ord: 0, name: "Card 1", qfmt: "{{Frente}}", afmt: "{{FrontSide}}\(answerSeparator){{Verso}}"),
                CardTemplate(ord: 1, name: "Card 2",
                             qfmt: "{{#Adicionar inverso}}{{Verso}}{{/Adicionar inverso}}",
                             afmt: "{{FrontSide}}\(answerSeparator){{Frente}}"),
            ]
        case .basicTyping:
            name = "Básico (digite a resposta)"
            config.fields = [NoteField(ord: 0, name: "Frente"), NoteField(ord: 1, name: "Verso")]
            config.templates = [
                CardTemplate(ord: 0, name: "Card 1", qfmt: "{{Frente}}\n\n{{type:Verso}}",
                             afmt: "{{Frente}}\(answerSeparator){{type:Verso}}"),
            ]
        case .cloze:
            name = "Omissão de palavras"
            config.kind = .cloze
            config.css = clozeCSS
            config.fields = [NoteField(ord: 0, name: "Texto"), NoteField(ord: 1, name: "Verso extra")]
            config.templates = [
                CardTemplate(ord: 0, name: "Omissão", qfmt: "{{cloze:Texto}}", afmt: "{{cloze:Texto}}<br>\n{{Verso extra}}"),
            ]
        case .imageOcclusion:
            name = "Oclusão de imagem"
            config.kind = .cloze
            config.css = imageOcclusionCSS
            config.fields = [
                NoteField(ord: 0, name: "Oclusão", tag: ImageOcclusionField.occlusions.rawValue),
                NoteField(ord: 1, name: "Imagem", tag: ImageOcclusionField.image.rawValue),
                NoteField(ord: 2, name: "Cabeçalho", tag: ImageOcclusionField.header.rawValue),
                NoteField(ord: 3, name: "Verso extra", tag: ImageOcclusionField.backExtra.rawValue),
                NoteField(ord: 4, name: "Comentários", tag: ImageOcclusionField.comments.rawValue),
            ]
            let body = """
            {{#Cabeçalho}}<div>{{Cabeçalho}}</div>{{/Cabeçalho}}
            <div style="display: none">{{cloze:Oclusão}}</div>
            <div id="image-occlusion-container">
            {{Imagem}}
            <canvas id="image-occlusion-canvas"></canvas>
            </div>
            <script>
            try { anki.imageOcclusion.setup(); } catch (exc) { document.getElementById("err").innerHTML = "Erro ao carregar a oclusão de imagem.<br><br>" + exc; }
            </script>
            <div id="err"></div>
            """
            config.templates = [
                CardTemplate(ord: 0, name: "Oclusão de imagem", qfmt: body,
                             afmt: body + "\n<div><button id=\"toggle\">Alternar máscaras</button></div>\n{{#Verso extra}}<div>{{Verso extra}}</div>{{/Verso extra}}"),
            ]
        }
        return Notetype(id: id, name: name, config: config)
    }

    /// Índice do campo com o rótulo de Image Occlusion dado.
    public func imageOcclusionFieldIndex(_ field: ImageOcclusionField) -> Int? {
        fields.firstIndex { $0.tag == field.rawValue } ?? (field.rawValue < fields.count ? field.rawValue : nil)
    }

    // MARK: Edição estrutural (em memória)

    /// Renomeia um campo e atualiza as referências nos modelos.
    public mutating func renameField(at index: Int, to newName: String) {
        guard fields.indices.contains(index) else { return }
        let old = fields[index].name
        guard old != newName else { return }
        config.fields[index].name = newName
        rewriteTemplates(renaming: old, to: newName)
    }

    /// Remove um campo e as referências a ele nos modelos.
    public mutating func removeField(at index: Int) {
        guard fields.indices.contains(index), fields.count > 1 else { return }
        let old = fields[index].name
        config.fields.remove(at: index)
        rewriteTemplates(renaming: old, to: nil)
        if config.sortFieldIdx == index { config.sortFieldIdx = 0 }
        else if config.sortFieldIdx > index { config.sortFieldIdx -= 1 }
        renumber()
    }

    private mutating func rewriteTemplates(renaming old: String, to newName: String?) {
        for i in config.templates.indices {
            if let parsed = try? ParsedTemplate(config.templates[i].qfmt) {
                config.templates[i].qfmt = parsed.renamingField(old, to: newName)
            }
            if let parsed = try? ParsedTemplate(config.templates[i].afmt) {
                config.templates[i].afmt = parsed.renamingField(old, to: newName)
            }
        }
    }

    /// Erros de sintaxe ou campos inexistentes nos modelos (para o editor).
    public func templateProblems() -> [String] {
        var problems: [String] = []
        let known = Set(fieldNames).union(["FrontSide", "Tags", "Type", "Deck", "Subdeck", "Card", "CardFlag", "CardID"])
        for template in templates {
            for (label, source) in [("frente", template.qfmt), ("verso", template.afmt)] {
                do {
                    let parsed = try ParsedTemplate(source)
                    for key in parsed.referencedKeys.sorted() where !key.isEmpty && !known.contains(key) {
                        if isCloze, key.hasPrefix("c"), Int(key.dropFirst()) != nil { continue }
                        problems.append("\(template.name) (\(label)): campo “\(key)” não existe.")
                    }
                    if label == "frente" && isCloze && parsed.clozeFields.isEmpty {
                        problems.append("\(template.name): a frente precisa de {{cloze:Campo}}.")
                    }
                } catch {
                    problems.append("\(template.name) (\(label)): \(error)")
                }
            }
        }
        return problems
    }

    // MARK: Geração de cards

    /// Índices dos cards que a nota deve ter com o conteúdo atual dos campos.
    public func cardOrdinals(forFields values: [String]) -> [Int] {
        var nonEmpty = Set<String>()
        for (index, field) in fields.enumerated() where index < values.count {
            if !TemplateRenderer.fieldIsEmpty(values[index]) { nonEmpty.insert(field.name) }
        }
        if isCloze {
            guard let template = templates.first else { return [] }
            var sources: [String] = []
            if let parsed = TemplateCache.shared.parsed(template.qfmt) {
                for name in parsed.clozeFields {
                    if let index = fieldIndex(named: name), index < values.count { sources.append(values[index]) }
                }
            }
            if sources.isEmpty { sources = values }
            var ordinals = Set<Int>()
            for source in sources { ordinals.formUnion(Cloze.ordinals(in: source)) }
            return ordinals.map { $0 - 1 }.sorted()
        }
        var result: [Int] = []
        for template in templates {
            guard let parsed = TemplateCache.shared.parsed(template.qfmt) else { continue }
            if parsed.rendersFieldContent(nonEmptyFields: nonEmpty) { result.append(template.ord) }
        }
        return result
    }
}

extension Txn {

    public func allNotetypes() throws -> [Notetype] {
        try Notetype.order(sql: "name COLLATE NOCASE").fetchAll(db)
    }

    public func notetype(_ id: NotetypeID) throws -> Notetype {
        guard let nt = try Notetype.fetchOne(db, key: id) else { throw CollectionError.notFound("tipo de nota \(id)") }
        return nt
    }

    public func notetypeIfExists(_ id: NotetypeID) throws -> Notetype? {
        try Notetype.fetchOne(db, key: id)
    }

    public func notetype(named name: String) throws -> Notetype? {
        try Notetype.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchOne(db)
    }

    func uniqueNotetypeName(_ base: String, excluding id: NotetypeID? = nil) throws -> String {
        var name = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Tipo de nota" }
        var candidate = name
        var suffix = 2
        while let existing = try notetype(named: candidate), existing.id != id {
            candidate = "\(name) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    @discardableResult
    public func addStockNotetype(_ kind: StockNotetype) throws -> Notetype {
        var nt = Notetype.stock(kind)
        try addNotetype(&nt)
        return nt
    }

    /// Insere um tipo de nota novo. Se `id` for 0, gera um.
    public func addNotetype(_ nt: inout Notetype) throws {
        guard !nt.fields.isEmpty else { throw CollectionError.lastField }
        guard !nt.templates.isEmpty else { throw CollectionError.lastTemplate }
        if nt.id == 0 { nt.id = try nextID(in: "notetypes") }
        nt.name = try uniqueNotetypeName(nt.name, excluding: nt.id)
        nt.renumber()
        nt.mtimeSecs = nowSecs
        nt.usn = -1
        try nt.insert(db)
    }

    /// Duplica um tipo de nota existente.
    public func cloneNotetype(_ id: NotetypeID, name: String) throws -> Notetype {
        var copy = try notetype(id)
        copy.id = 0
        copy.name = name
        try addNotetype(&copy)
        return copy
    }

    /// Grava alterações em um tipo de nota existente.
    ///
    /// - Parameters:
    ///   - fieldOrigins: para cada campo novo (por posição), o índice que ele tinha antes, ou `nil` se for novo.
    ///   - templateOrigins: idem, para os modelos de card.
    /// Quando ambos são `nil`, assume-se que a estrutura não mudou (só nomes, CSS e conteúdo dos modelos).
    public func updateNotetype(_ updated: Notetype, fieldOrigins: [Int?]? = nil, templateOrigins: [Int?]? = nil) throws {
        var nt = updated
        let old = try notetype(nt.id)
        guard !nt.fields.isEmpty else { throw CollectionError.lastField }
        guard !nt.templates.isEmpty else { throw CollectionError.lastTemplate }
        nt.renumber()
        nt.name = try uniqueNotetypeName(nt.name, excluding: nt.id)

        let identityFields = Array(old.fields.indices).map { Optional($0) }
        let identityTemplates = Array(old.templates.indices).map { Optional($0) }
        let fieldMap = fieldOrigins ?? Array(nt.fields.indices).map { $0 < old.fields.count ? Optional($0) : nil }
        let templateMap = templateOrigins ?? Array(nt.templates.indices).map { $0 < old.templates.count ? Optional($0) : nil }
        let fieldsChanged = fieldMap != identityFields
        let templatesChanged = templateMap != identityTemplates
        let sortChanged = old.config.sortFieldIdx != nt.config.sortFieldIdx

        nt.mtimeSecs = nowSecs
        nt.usn = -1
        try nt.update(db)

        if fieldsChanged || sortChanged {
            let rows = try Row.fetchAll(db, sql: "SELECT id, flds FROM notes WHERE mid = ?", arguments: [nt.id])
            let update = try db.makeStatement(sql: "UPDATE notes SET flds = ?, sfld = ?, csum = ?, mod = ?, usn = -1 WHERE id = ?")
            for row in rows {
                let id: Int64 = row["id"]
                let flds: String = row["flds"]
                let oldValues = flds.components(separatedBy: Note.fieldSeparator)
                var newValues: [String] = []
                for origin in fieldMap {
                    if let origin, origin < oldValues.count { newValues.append(oldValues[origin]) } else { newValues.append("") }
                }
                let sortValue = Txn.sortFieldValue(newValues, notetype: nt)
                try update.execute(arguments: [
                    newValues.joined(separator: Note.fieldSeparator), sortValue,
                    Hashing.fieldChecksum(newValues.first ?? ""), nowSecs, id,
                ])
            }
        }

        if templatesChanged && !nt.isCloze {
            let kept = Set(templateMap.compactMap { $0 })
            let removed = old.templates.indices.filter { !kept.contains($0) }
            if !removed.isEmpty {
                let ids = try Int64.fetchAll(db, sql: """
                    SELECT c.id FROM cards c JOIN notes n ON n.id = c.nid
                    WHERE n.mid = ? AND c.ord IN (\(removed.map(String.init).joined(separator: ",")))
                    """, arguments: [nt.id])
                try removeCards(ids)
            }
            // Renumera em duas fases para não colidir.
            for (newOrd, origin) in templateMap.enumerated() {
                guard let origin, origin != newOrd else { continue }
                try db.execute(sql: """
                    UPDATE cards SET ord = ?, mod = ?, usn = -1
                    WHERE ord = ? AND nid IN (SELECT id FROM notes WHERE mid = ?)
                    """, arguments: [newOrd + 100_000, nowSecs, origin, nt.id])
            }
            try db.execute(sql: """
                UPDATE cards SET ord = ord - 100000
                WHERE ord >= 100000 AND nid IN (SELECT id FROM notes WHERE mid = ?)
                """, arguments: [nt.id])
        }

        if fieldsChanged || templatesChanged {
            try markSchemaModified()
        }
        // Modelos novos ou alterados podem passar a gerar cards.
        if templatesChanged || fieldsChanged || old.templates != nt.templates {
            try generateMissingCards(forNotetype: nt)
        }
    }

    /// Remove o tipo de nota e todas as notas que o usam.
    public func removeNotetype(_ id: NotetypeID) throws {
        guard try Notetype.fetchCount(db) > 1 else { throw CollectionError.lastNotetype }
        let noteIDs = try Int64.fetchAll(db, sql: "SELECT id FROM notes WHERE mid = ?", arguments: [id])
        try removeNotes(noteIDs)
        try db.execute(sql: "DELETE FROM notetypes WHERE id = ?", arguments: [id])
        try addGrave(id, .notetype)
        try markSchemaModified()
    }

    public func noteCount(forNotetype id: NotetypeID) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM notes WHERE mid = ?", arguments: [id]) ?? 0
    }

    /// Cria os cards que faltam para todas as notas de um tipo.
    @discardableResult
    public func generateMissingCards(forNotetype nt: Notetype) throws -> Int {
        var created = 0
        let notes = try Note.filter(sql: "mid = ?", arguments: [nt.id]).fetchAll(db)
        for note in notes {
            created += try generateMissingCards(for: note, notetype: nt, deckID: nil)
        }
        return created
    }
}
