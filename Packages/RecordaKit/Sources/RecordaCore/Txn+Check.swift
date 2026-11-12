import Foundation
import GRDB

public struct DatabaseCheckReport: Sendable, Equatable {
    /// Descrição de cada problema encontrado (e corrigido).
    public var problems: [String] = []
    public var isClean: Bool { problems.isEmpty }
}

extension Txn {

    /// Verifica a integridade da coleção e corrige o que for possível.
    public func checkDatabase() throws -> DatabaseCheckReport {
        var report = DatabaseCheckReport()

        let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check")
        if integrity != ["ok"] {
            report.problems.append("O arquivo do banco apresenta corrupção: \(integrity.prefix(3).joined(separator: "; "))")
        }

        // Baralho padrão e predefinição padrão precisam existir.
        if try Deck.fetchCount(db) == 0 {
            var fallback = Deck(id: 1, name: "Padrão")
            try saveDeck(&fallback)
            report.problems.append("Não havia nenhum baralho; o baralho padrão foi recriado.")
        }
        if try DeckConfig.fetchOne(db, key: 1) == nil {
            var preset = DeckConfig(id: 1, name: "Padrão")
            try saveDeckConfig(&preset)
            report.problems.append("A predefinição padrão foi recriada.")
        }
        let fallbackDeck = try Int64.fetchOne(db, sql: "SELECT id FROM decks WHERE kind NOT LIKE '%filtered%' ORDER BY id LIMIT 1") ?? 1

        // Notas com tipo inexistente.
        let orphanNotes = try Int64.fetchAll(db, sql: "SELECT id FROM notes WHERE mid NOT IN (SELECT id FROM notetypes)")
        if !orphanNotes.isEmpty {
            try removeNotes(orphanNotes)
            report.problems.append("\(orphanNotes.count) nota(s) com tipo de nota inexistente foram removidas.")
        }

        // Cards sem nota.
        let orphanCards = try Int64.fetchAll(db, sql: "SELECT id FROM cards WHERE nid NOT IN (SELECT id FROM notes)")
        if !orphanCards.isEmpty {
            for chunk in orphanCards.chunked(500) {
                for id in chunk { try addGrave(id, .card) }
                try db.execute(sql: "DELETE FROM cards WHERE id IN (\(Txn.idList(chunk)))")
            }
            report.problems.append("\(orphanCards.count) card(s) sem nota foram removidos.")
        }

        // Cards em baralhos inexistentes.
        let lostCards = try Int.fetchOne(db, sql: "SELECT count(*) FROM cards WHERE did NOT IN (SELECT id FROM decks)") ?? 0
        if lostCards > 0 {
            try db.execute(sql: "UPDATE cards SET did = ?, mod = ?, usn = -1 WHERE did NOT IN (SELECT id FROM decks)",
                           arguments: [fallbackDeck, nowSecs])
            report.problems.append("\(lostCards) card(s) estavam em baralhos inexistentes e foram movidos para o baralho padrão.")
        }
        let badOrigin = try Int.fetchOne(db, sql: "SELECT count(*) FROM cards WHERE odid != 0 AND odid NOT IN (SELECT id FROM decks)") ?? 0
        if badOrigin > 0 {
            try db.execute(sql: "UPDATE cards SET odid = ?, mod = ?, usn = -1 WHERE odid != 0 AND odid NOT IN (SELECT id FROM decks)",
                           arguments: [fallbackDeck, nowSecs])
            report.problems.append("\(badOrigin) card(s) tinham baralho de origem inválido.")
        }
        // Cards marcados como "em baralho filtrado" mas que estão em baralho normal.
        let strayFiltered = try Card.fetchAll(db, sql: """
            SELECT c.* FROM cards c JOIN decks d ON d.id = c.did
            WHERE c.odid != 0 AND d.kind NOT LIKE '%filtered%'
            """)
        if !strayFiltered.isEmpty {
            for var card in strayFiltered {
                card.removeFromFilteredDeck()
                try saveCard(&card)
            }
            report.problems.append("\(strayFiltered.count) card(s) tinham estado de baralho filtrado inconsistente.")
        }

        // Baralhos que apontam para predefinições inexistentes ou sem os ancestrais.
        let configIDs = Set(try Int64.fetchAll(db, sql: "SELECT id FROM deck_config"))
        var fixedDecks = 0
        for var deck in try Deck.fetchAll(db) {
            if let configID = deck.configID, !configIDs.contains(configID) {
                deck.normal?.configID = 1
                try saveDeck(&deck)
                fixedDecks += 1
            }
            if let parentName = deck.parentName, try self.deck(named: parentName) == nil {
                _ = try getOrCreateDeck(named: parentName)
                fixedDecks += 1
            }
        }
        if fixedDecks > 0 { report.problems.append("\(fixedDecks) baralho(s) com configuração ou hierarquia inválida foram corrigidos.") }

        // Notas: número de campos, campo de ordenação e checksum.
        var fixedNotes = 0
        var missingCards = 0
        let notetypes = Dictionary(uniqueKeysWithValues: try allNotetypes().map { ($0.id, $0) })
        let noteIDs = try Int64.fetchAll(db, sql: "SELECT id FROM notes")
        for chunk in noteIDs.chunked(500) {
            let notes = try Note.filter(sql: "id IN (\(Txn.idList(chunk)))").fetchAll(db)
            for var note in notes {
                guard let notetype = notetypes[note.mid] else { continue }
                var values = note.fields
                var changed = false
                if values.count != notetype.fields.count {
                    if values.count < notetype.fields.count {
                        values += Array(repeating: "", count: notetype.fields.count - values.count)
                    } else {
                        // Junta o excedente no último campo para não perder conteúdo.
                        let extra = values[notetype.fields.count...].filter { !$0.isEmpty }
                        values = Array(values.prefix(notetype.fields.count))
                        if !extra.isEmpty { values[values.count - 1] += " " + extra.joined(separator: " ") }
                    }
                    changed = true
                }
                let sortValue = Txn.sortFieldValue(values, notetype: notetype)
                let checksum = Hashing.fieldChecksum(values.first ?? "")
                if changed || sortValue != note.sfld || checksum != note.csum {
                    note.fields = values
                    note.sfld = sortValue
                    note.csum = checksum
                    note.mod = nowSecs
                    note.usn = -1
                    try note.update(db)
                    fixedNotes += 1
                }
                if try Int.fetchOne(db, sql: "SELECT count(*) FROM cards WHERE nid = ?", arguments: [note.id]) == 0 {
                    let created = try generateMissingCards(for: note, notetype: notetype, deckID: fallbackDeck)
                    if created == 0 {
                        let position = try reserveNewPositions(1)
                        try Card(id: try nextID(in: "cards"), nid: note.id, did: fallbackDeck, ord: 0, mod: nowSecs,
                                 due: Int64(position)).insert(db)
                    }
                    missingCards += 1
                }
            }
        }
        if fixedNotes > 0 { report.problems.append("\(fixedNotes) nota(s) com campos ou índices inconsistentes foram corrigidas.") }
        if missingCards > 0 { report.problems.append("\(missingCards) nota(s) estavam sem cards; os cards foram recriados.") }

        // Valores de agendamento fora da faixa.
        let badValues = try Int.fetchOne(db, sql: "SELECT count(*) FROM cards WHERE ivl < 0 OR reps < 0 OR lapses < 0 OR (type = 2 AND factor < 1300 AND factor != 0)") ?? 0
        if badValues > 0 {
            try db.execute(sql: """
                UPDATE cards SET ivl = max(ivl, 0), reps = max(reps, 0), lapses = max(lapses, 0),
                    factor = CASE WHEN type = 2 AND factor < 1300 AND factor != 0 THEN 1300 ELSE factor END,
                    mod = ?, usn = -1
                WHERE ivl < 0 OR reps < 0 OR lapses < 0 OR (type = 2 AND factor < 1300 AND factor != 0)
                """, arguments: [nowSecs])
            report.problems.append("\(badValues) card(s) tinham valores de agendamento inválidos.")
        }

        // Posição do próximo card novo.
        let maxPosition = try Int.fetchOne(db, sql: "SELECT max(due) FROM cards WHERE type = 0 AND due < 1000000000") ?? 0
        let nextPosition: Int = try config(ConfigKey.nextNewPosition) ?? 0
        if nextPosition <= maxPosition { try setConfig(ConfigKey.nextNewPosition, maxPosition + 1) }

        // Revlog de cards inexistentes não atrapalha, mas tags não usadas são limpas.
        try clearUnusedTags()
        let tagRows = try String.fetchAll(db, sql: "SELECT DISTINCT tags FROM notes WHERE tags != ''")
        var tags = Set<String>()
        for row in tagRows { for tag in row.split(separator: " ") { tags.insert(String(tag)) } }
        try registerTags(Array(tags))

        return report
    }
}

extension Collection {
    /// Verifica a coleção e compacta o arquivo do banco.
    public func checkAndOptimize() throws -> DatabaseCheckReport {
        let report = try write { txn in try txn.checkDatabase() }
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            try db.execute(sql: "ANALYZE")
        }
        return report
    }
}
