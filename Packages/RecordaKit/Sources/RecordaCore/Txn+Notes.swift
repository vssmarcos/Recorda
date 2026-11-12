import Foundation
import GRDB
import RecordaTemplates

extension Txn {

    // MARK: Leitura

    public func note(_ id: NoteID) throws -> Note {
        guard let note = try Note.fetchOne(db, key: id) else { throw CollectionError.notFound("nota \(id)") }
        return note
    }

    public func noteIfExists(_ id: NoteID) throws -> Note? { try Note.fetchOne(db, key: id) }

    public func card(_ id: CardID) throws -> Card {
        guard let card = try Card.fetchOne(db, key: id) else { throw CollectionError.notFound("card \(id)") }
        return card
    }

    public func cardIfExists(_ id: CardID) throws -> Card? { try Card.fetchOne(db, key: id) }

    public func cards(ofNote nid: NoteID) throws -> [Card] {
        try Card.filter(sql: "nid = ?", arguments: [nid]).order(sql: "ord").fetchAll(db)
    }

    public func cards(_ ids: [CardID]) throws -> [Card] {
        var result: [Card] = []
        for chunk in ids.chunked(500) {
            result += try Card.filter(sql: "id IN (\(Txn.idList(chunk)))").fetchAll(db)
        }
        return result
    }

    public func noteIDs(ofCards ids: [CardID]) throws -> [NoteID] {
        var result = Set<NoteID>()
        for chunk in ids.chunked(500) {
            result.formUnion(try Int64.fetchAll(db, sql: "SELECT DISTINCT nid FROM cards WHERE id IN (\(Txn.idList(chunk)))"))
        }
        return Array(result)
    }

    public func cardIDs(ofNotes ids: [NoteID]) throws -> [CardID] {
        var result: [CardID] = []
        for chunk in ids.chunked(500) {
            result += try Int64.fetchAll(db, sql: "SELECT id FROM cards WHERE nid IN (\(Txn.idList(chunk))) ORDER BY nid, ord")
        }
        return result
    }

    public func noteCount() throws -> Int { try Note.fetchCount(db) }
    public func cardCount() throws -> Int { try Card.fetchCount(db) }

    public static func idList(_ ids: some Sequence<Int64>) -> String {
        ids.map(String.init).joined(separator: ",")
    }

    // MARK: Campo de ordenação

    public static func sortFieldValue(_ values: [String], notetype: Notetype) -> String {
        let index = notetype.config.sortFieldIdx
        let raw = index < values.count ? values[index] : (values.first ?? "")
        let text = HTMLText.stripPreservingMedia(Cloze.stripMarkup(raw))
        return text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normaliza a nota antes de gravar: nº de campos, NFC, sfld, csum, mod, usn.
    func prepareForSave(_ note: inout Note, notetype: Notetype) {
        var values = note.fields.map(\.nfc)
        if values.count < notetype.fields.count {
            values += Array(repeating: "", count: notetype.fields.count - values.count)
        } else if values.count > notetype.fields.count {
            values = Array(values.prefix(notetype.fields.count))
        }
        note.fields = values
        note.tags = Note.joinTags(note.tagList)
        note.sfld = Txn.sortFieldValue(values, notetype: notetype)
        note.csum = Hashing.fieldChecksum(values.first ?? "")
        note.mod = nowSecs
        note.usn = -1
    }

    // MARK: Adicionar / atualizar

    /// Baralho onde novas notas podem entrar (baralhos filtrados não recebem cards novos).
    func insertionDeckID(_ requested: DeckID?) throws -> DeckID {
        if let requested, let deck = try Deck.fetchOne(db, key: requested), !deck.isFiltered { return requested }
        if let current: DeckID = try config(ConfigKey.currentDeck),
           let deck = try Deck.fetchOne(db, key: current), !deck.isFiltered { return current }
        return 1
    }

    /// Adiciona a nota e gera seus cards. Lança erro se nenhum card seria gerado.
    @discardableResult
    public func addNote(_ note: inout Note, deckID: DeckID) throws -> [Card] {
        let nt = try notetype(note.mid)
        if note.id == 0 { note.id = try nextID(in: "notes") }
        if note.guid.isEmpty { note.guid = GUID.make() }
        prepareForSave(&note, notetype: nt)
        let ordinals = nt.cardOrdinals(forFields: note.fields)
        guard !ordinals.isEmpty else {
            throw nt.isCloze ? CollectionError.clozeMissing : CollectionError.noCardsGenerated
        }
        try note.insert(db)
        try registerTags(note.tagList)
        _ = try generateMissingCards(for: note, notetype: nt, deckID: deckID)
        return try cards(ofNote: note.id)
    }

    /// Verifica se a nota poderia ser adicionada, sem gravar.
    public func canGenerateCards(fields: [String], notetypeID: NotetypeID) throws -> Bool {
        let nt = try notetype(notetypeID)
        return !nt.cardOrdinals(forFields: fields).isEmpty
    }

    /// Grava alterações na nota e cria os cards que passaram a existir.
    public func updateNote(_ note: inout Note) throws {
        let nt = try notetype(note.mid)
        prepareForSave(&note, notetype: nt)
        try note.update(db)
        try registerTags(note.tagList)
        _ = try generateMissingCards(for: note, notetype: nt, deckID: nil)
    }

    @discardableResult
    func generateMissingCards(for note: Note, notetype nt: Notetype, deckID: DeckID?) throws -> Int {
        let needed = nt.cardOrdinals(forFields: note.fields)
        if needed.isEmpty { return 0 }
        let existingRows = try Row.fetchAll(db, sql: "SELECT ord, did, odid, due, type FROM cards WHERE nid = ?", arguments: [note.id])
        let existing = Set(existingRows.map { $0["ord"] as Int })
        let missing = needed.filter { !existing.contains($0) }
        if missing.isEmpty { return 0 }

        var fallbackDeck = deckID
        if fallbackDeck == nil, let row = existingRows.first {
            let odid: Int64 = row["odid"]
            fallbackDeck = odid != 0 ? odid : (row["did"] as Int64)
        }
        let baseDeck = try insertionDeckID(fallbackDeck)

        // Irmãos compartilham a posição; reaproveita a de um card ainda novo, se houver.
        var position: Int?
        if let row = existingRows.first(where: { ($0["type"] as Int) == CardType.new.rawValue }) {
            position = Int(row["due"] as Int64)
        }
        if position == nil {
            let preset = try deckConfig(forDeck: baseDeck)
            let next = try reserveNewPositions(1)
            position = preset.config.newCardInsertOrder == .random ? Int.random(in: 1...max(next, 1000)) : next
        }

        var nextID = try self.nextID(in: "cards")
        for ord in missing {
            var target = baseDeck
            if !nt.isCloze, ord < nt.templates.count {
                let wanted = nt.templates[ord].targetDeckID
                if wanted != 0, let deck = try Deck.fetchOne(db, key: wanted), !deck.isFiltered { target = wanted }
            }
            while try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cards WHERE id = ?)", arguments: [nextID]) == true {
                nextID += 1
            }
            let card = Card(id: nextID, nid: note.id, did: target, ord: ord, mod: nowSecs, usn: -1,
                            type: .new, queue: .new, due: Int64(position ?? 0))
            try card.insert(db)
            nextID += 1
        }
        return missing.count
    }

    // MARK: Cards

    /// Grava o card atualizando `mod` e `usn`.
    public func saveCard(_ card: inout Card) throws {
        card.mod = nowSecs
        card.usn = -1
        try card.update(db)
    }

    public func setFlag(_ flag: Int, cardIDs: [CardID]) throws {
        for chunk in cardIDs.chunked(500) {
            try db.execute(sql: """
                UPDATE cards SET flags = (flags & ~7) | ?, mod = ?, usn = -1 WHERE id IN (\(Txn.idList(chunk)))
                """, arguments: [flag & 7, nowSecs])
        }
    }

    // MARK: Remoção

    public func removeNotes(_ ids: [NoteID]) throws {
        for chunk in ids.chunked(500) {
            let list = Txn.idList(chunk)
            let cardIDs = try Int64.fetchAll(db, sql: "SELECT id FROM cards WHERE nid IN (\(list))")
            for cid in cardIDs { try addGrave(cid, .card) }
            for nid in chunk { try addGrave(nid, .note) }
            try db.execute(sql: "DELETE FROM cards WHERE nid IN (\(list))")
            try db.execute(sql: "DELETE FROM notes WHERE id IN (\(list))")
        }
    }

    /// Remove cards; notas que ficarem sem cards também são removidas.
    public func removeCards(_ ids: [CardID]) throws {
        for chunk in ids.chunked(500) {
            let list = Txn.idList(chunk)
            let noteIDs = try Int64.fetchAll(db, sql: "SELECT DISTINCT nid FROM cards WHERE id IN (\(list))")
            for cid in chunk { try addGrave(cid, .card) }
            try db.execute(sql: "DELETE FROM cards WHERE id IN (\(list))")
            if !noteIDs.isEmpty {
                let orphans = try Int64.fetchAll(db, sql: """
                    SELECT id FROM notes WHERE id IN (\(Txn.idList(noteIDs)))
                    AND NOT EXISTS (SELECT 1 FROM cards WHERE cards.nid = notes.id)
                    """)
                for nid in orphans { try addGrave(nid, .note) }
                if !orphans.isEmpty {
                    try db.execute(sql: "DELETE FROM notes WHERE id IN (\(Txn.idList(orphans)))")
                }
            }
        }
    }

    // MARK: Cards vazios

    public struct EmptyCardReport: Sendable {
        public var noteID: NoteID
        public var sortField: String
        public var cardIDs: [CardID]
        public var ordinals: [Int]
        /// Verdadeiro se todos os cards da nota estão vazios.
        public var wouldDeleteNote: Bool
    }

    /// Cards que não seriam mais gerados com o conteúdo atual das notas.
    public func emptyCards() throws -> [EmptyCardReport] {
        var reports: [EmptyCardReport] = []
        let notetypes = Dictionary(uniqueKeysWithValues: try allNotetypes().map { ($0.id, $0) })
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT n.id, n.mid, n.flds, n.sfld, group_concat(c.id || ':' || c.ord) AS cards
            FROM notes n JOIN cards c ON c.nid = n.id GROUP BY n.id
            """)
        while let row = try cursor.next() {
            let mid: Int64 = row["mid"]
            guard let nt = notetypes[mid] else { continue }
            let flds: String = row["flds"]
            let needed = Set(nt.cardOrdinals(forFields: flds.components(separatedBy: Note.fieldSeparator)))
            let cardList: String = row["cards"]
            var emptyIDs: [CardID] = []
            var emptyOrds: [Int] = []
            var total = 0
            for item in cardList.split(separator: ",") {
                let parts = item.split(separator: ":")
                guard parts.count == 2, let cid = Int64(parts[0]), let ord = Int(parts[1]) else { continue }
                total += 1
                if !needed.contains(ord) {
                    emptyIDs.append(cid)
                    emptyOrds.append(ord)
                }
            }
            if !emptyIDs.isEmpty {
                reports.append(EmptyCardReport(noteID: row["id"], sortField: row["sfld"], cardIDs: emptyIDs,
                                               ordinals: emptyOrds, wouldDeleteNote: emptyIDs.count == total))
            }
        }
        return reports
    }

    // MARK: Duplicatas

    /// Notas do mesmo tipo cujo primeiro campo é igual (ignorando HTML).
    public func duplicateNoteIDs(firstField: String, notetypeID: NotetypeID, excluding noteID: NoteID? = nil) throws -> [NoteID] {
        let stripped = HTMLText.stripPreservingMedia(firstField.nfc)
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let csum = Hashing.fieldChecksum(firstField.nfc)
        let rows = try Row.fetchAll(db, sql: "SELECT id, flds FROM notes WHERE csum = ? AND mid = ? AND id != ?",
                                    arguments: [csum, notetypeID, noteID ?? 0])
        return rows.compactMap { row -> NoteID? in
            let flds: String = row["flds"]
            let first = flds.components(separatedBy: Note.fieldSeparator).first ?? ""
            return HTMLText.stripPreservingMedia(first) == stripped ? (row["id"] as Int64) : nil
        }
    }

    public struct DuplicateGroup: Sendable {
        public var value: String
        public var noteIDs: [NoteID]
    }

    /// Agrupa notas com o mesmo conteúdo no campo indicado (dentro do conjunto `noteIDs`, se dado).
    public func findDuplicates(fieldName: String, among noteIDs: [NoteID]? = nil) throws -> [DuplicateGroup] {
        let notetypes = try allNotetypes()
        var fieldIndex: [NotetypeID: Int] = [:]
        for nt in notetypes {
            if let index = nt.fieldIndex(named: fieldName) { fieldIndex[nt.id] = index }
        }
        if fieldIndex.isEmpty { return [] }
        let allowed: Set<NoteID>? = noteIDs.map { Set($0) }
        var groups: [String: [NoteID]] = [:]
        var order: [String] = []
        let cursor = try Row.fetchCursor(db, sql: "SELECT id, mid, flds FROM notes WHERE mid IN (\(Txn.idList(fieldIndex.keys)))")
        while let row = try cursor.next() {
            let id: Int64 = row["id"]
            if let allowed, !allowed.contains(id) { continue }
            let mid: Int64 = row["mid"]
            guard let index = fieldIndex[mid] else { continue }
            let flds: String = row["flds"]
            let parts = flds.components(separatedBy: Note.fieldSeparator)
            guard index < parts.count else { continue }
            let value = HTMLText.stripPreservingMedia(parts[index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            if groups[value] == nil { order.append(value) }
            groups[value, default: []].append(id)
        }
        return order.compactMap { value in
            guard let ids = groups[value], ids.count > 1 else { return nil }
            return DuplicateGroup(value: value, noteIDs: ids)
        }
    }

    // MARK: Tags

    public func registerTags(_ tags: [String]) throws {
        for tag in tags where !tag.isEmpty {
            try db.execute(sql: "INSERT OR IGNORE INTO tags (tag, usn, collapsed) VALUES (?, -1, 0)", arguments: [tag])
        }
    }

    public func allTags() throws -> [String] {
        try String.fetchAll(db, sql: "SELECT tag FROM tags ORDER BY tag COLLATE NOCASE")
    }

    /// Remove do registro as tags que nenhuma nota usa.
    @discardableResult
    public func clearUnusedTags() throws -> Int {
        var used = Set<String>()
        let cursor = try String.fetchCursor(db, sql: "SELECT DISTINCT tags FROM notes WHERE tags != ''")
        while let tags = try cursor.next() {
            for tag in tags.split(separator: " ") { used.insert(tag.lowercased()) }
        }
        var removed = 0
        for tag in try allTags() where !used.contains(tag.lowercased()) {
            try db.execute(sql: "DELETE FROM tags WHERE tag = ?", arguments: [tag])
            removed += 1
        }
        return removed
    }

    private func mutateNotes(_ noteIDs: [NoteID], _ change: (inout Note) -> Bool) throws -> Int {
        var changed = 0
        for chunk in noteIDs.chunked(500) {
            let notes = try Note.filter(sql: "id IN (\(Txn.idList(chunk)))").fetchAll(db)
            for var note in notes {
                if change(&note) {
                    note.mod = nowSecs
                    note.usn = -1
                    try note.update(db)
                    changed += 1
                }
            }
        }
        return changed
    }

    @discardableResult
    public func addTags(_ tags: [String], toNotes noteIDs: [NoteID]) throws -> Int {
        let clean = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return 0 }
        try registerTags(clean)
        return try mutateNotes(noteIDs) { note in
            let before = note.tags
            for tag in clean { note.addTag(tag) }
            return note.tags != before
        }
    }

    @discardableResult
    public func removeTags(_ tags: [String], fromNotes noteIDs: [NoteID]) throws -> Int {
        let clean = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return 0 }
        return try mutateNotes(noteIDs) { note in
            let before = note.tags
            for tag in clean { note.removeTag(tag) }
            return note.tags != before
        }
    }

    /// Renomeia uma tag (e suas filhas `tag::sub`) em todas as notas.
    @discardableResult
    public func renameTag(_ old: String, to new: String) throws -> Int {
        let newName = new.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard !newName.isEmpty, !old.isEmpty else { return 0 }
        let oldLower = old.lowercased()
        let ids = try Int64.fetchAll(db, sql: "SELECT id FROM notes WHERE tags LIKE ? ESCAPE '\\'",
                                     arguments: ["%" + Txn.escapeLike(old) + "%"])
        var registered: [String] = []
        let changed = try mutateNotes(ids) { note in
            var list = note.tagList
            var touched = false
            for i in list.indices {
                let lower = list[i].lowercased()
                if lower == oldLower {
                    list[i] = newName
                    touched = true
                } else if lower.hasPrefix(oldLower + "::") {
                    list[i] = newName + list[i].dropFirst(old.count)
                    touched = true
                }
                if touched { registered.append(list[i]) }
            }
            if touched { note.tagList = list }
            return touched
        }
        try db.execute(sql: "DELETE FROM tags WHERE tag = ? OR tag LIKE ? ESCAPE '\\'",
                       arguments: [old, Txn.escapeLike(old) + "::%"])
        try registerTags(Array(Set(registered)) + [newName])
        return changed
    }

    /// Remove uma tag (e filhas) de todas as notas.
    @discardableResult
    public func deleteTag(_ tag: String) throws -> Int {
        let lower = tag.lowercased()
        let ids = try Int64.fetchAll(db, sql: "SELECT id FROM notes WHERE tags LIKE ? ESCAPE '\\'",
                                     arguments: ["%" + Txn.escapeLike(tag) + "%"])
        let changed = try mutateNotes(ids) { note in
            let before = note.tagList
            let after = before.filter { $0.lowercased() != lower && !$0.lowercased().hasPrefix(lower + "::") }
            if after.count != before.count { note.tagList = after; return true }
            return false
        }
        try db.execute(sql: "DELETE FROM tags WHERE tag = ? OR tag LIKE ? ESCAPE '\\'",
                       arguments: [tag, Txn.escapeLike(tag) + "::%"])
        return changed
    }

    public static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: Buscar e substituir

    /// Substitui texto nos campos das notas. Devolve o número de notas alteradas.
    @discardableResult
    public func findAndReplace(noteIDs: [NoteID], search: String, replacement: String, isRegex: Bool,
                               matchCase: Bool, fieldName: String?) throws -> Int {
        guard !search.isEmpty else { return 0 }
        let pattern = isRegex ? search : NSRegularExpression.escapedPattern(for: search)
        let template = isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if !matchCase { options.insert(.caseInsensitive) }
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: pattern, options: options) }
        catch { throw CollectionError.invalidInput("Expressão regular inválida: \(search)") }

        let notetypes = Dictionary(uniqueKeysWithValues: try allNotetypes().map { ($0.id, $0) })
        return try mutateNotes(noteIDs) { note in
            guard let nt = notetypes[note.mid] else { return false }
            var values = note.fields
            var touched = false
            for index in values.indices {
                if let fieldName {
                    guard index < nt.fields.count, nt.fields[index].name.caseInsensitiveCompare(fieldName) == .orderedSame else { continue }
                }
                let original = values[index]
                let replaced = regex.stringByReplacingMatches(
                    in: original, range: NSRange(original.startIndex..., in: original), withTemplate: template)
                if replaced != original {
                    values[index] = replaced
                    touched = true
                }
            }
            if touched {
                note.fields = values
                note.sfld = Txn.sortFieldValue(values, notetype: nt)
                note.csum = Hashing.fieldChecksum(values.first ?? "")
            }
            return touched
        }
    }

    // MARK: Mudar tipo de nota

    /// Converte notas para outro tipo.
    ///
    /// - Parameters:
    ///   - fieldMap: para cada campo do tipo novo, o índice do campo antigo (ou `nil` para deixar vazio).
    ///   - templateMap: para cada modelo novo, o índice do modelo antigo cujo card é reaproveitado
    ///     (ou `nil`). Cards de modelos antigos não mapeados são excluídos. Ignorado se algum dos tipos for cloze.
    public func changeNotetype(noteIDs: [NoteID], to newID: NotetypeID, fieldMap: [Int?], templateMap: [Int?]) throws {
        let newType = try notetype(newID)
        let notetypes = Dictionary(uniqueKeysWithValues: try allNotetypes().map { ($0.id, $0) })
        for chunk in noteIDs.chunked(200) {
            let notes = try Note.filter(sql: "id IN (\(Txn.idList(chunk)))").fetchAll(db)
            for var note in notes {
                guard let oldType = notetypes[note.mid], oldType.id != newID else { continue }
                let oldValues = note.fields
                var newValues: [String] = []
                for (index, _) in newType.fields.enumerated() {
                    if index < fieldMap.count, let source = fieldMap[index], source < oldValues.count {
                        newValues.append(oldValues[source])
                    } else {
                        newValues.append("")
                    }
                }
                note.mid = newID
                note.fields = newValues
                prepareForSave(&note, notetype: newType)
                try note.update(db)

                if !oldType.isCloze && !newType.isCloze {
                    let existing = try cards(ofNote: note.id)
                    var keep: [CardID: Int] = [:]
                    for (newOrd, source) in templateMap.enumerated() where newOrd < newType.templates.count {
                        if let source, let card = existing.first(where: { $0.ord == source }) { keep[card.id] = newOrd }
                    }
                    let toDelete = existing.filter { keep[$0.id] == nil }.map(\.id)
                    if !toDelete.isEmpty {
                        for cid in toDelete { try addGrave(cid, .card) }
                        try db.execute(sql: "DELETE FROM cards WHERE id IN (\(Txn.idList(toDelete)))")
                    }
                    for (cid, ord) in keep {
                        try db.execute(sql: "UPDATE cards SET ord = ?, mod = ?, usn = -1 WHERE id = ?",
                                       arguments: [ord + 100_000, nowSecs, cid])
                    }
                    try db.execute(sql: "UPDATE cards SET ord = ord - 100000 WHERE nid = ? AND ord >= 100000", arguments: [note.id])
                } else if newType.isCloze && !oldType.isCloze {
                    // De padrão para cloze: mantém só o primeiro card; os demais são gerados pelas omissões.
                    let existing = try cards(ofNote: note.id)
                    let extra = existing.dropFirst().map(\.id)
                    if !extra.isEmpty {
                        for cid in extra { try addGrave(cid, .card) }
                        try db.execute(sql: "DELETE FROM cards WHERE id IN (\(Txn.idList(extra)))")
                    }
                    try db.execute(sql: "UPDATE cards SET ord = 0, mod = ?, usn = -1 WHERE nid = ?", arguments: [nowSecs, note.id])
                } else if oldType.isCloze && !newType.isCloze {
                    // De cloze para padrão: cards além do número de modelos são excluídos.
                    let extra = try Int64.fetchAll(db, sql: "SELECT id FROM cards WHERE nid = ? AND ord >= ?",
                                                   arguments: [note.id, newType.templates.count])
                    if !extra.isEmpty {
                        for cid in extra { try addGrave(cid, .card) }
                        try db.execute(sql: "DELETE FROM cards WHERE id IN (\(Txn.idList(extra)))")
                    }
                }
                _ = try generateMissingCards(for: note, notetype: newType, deckID: nil)
                // Uma nota nunca fica sem cards.
                if try Int.fetchOne(db, sql: "SELECT count(*) FROM cards WHERE nid = ?", arguments: [note.id]) == 0 {
                    let did = try insertionDeckID(nil)
                    let position = try reserveNewPositions(1)
                    try Card(id: try nextID(in: "cards"), nid: note.id, did: did, ord: 0, mod: nowSecs,
                             due: Int64(position)).insert(db)
                }
            }
        }
        try markSchemaModified()
    }
}

extension Array {
    /// Divide o array em blocos de até `size` elementos.
    public func chunked(_ size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
