import Foundation
import GRDB
import RecordaCore

/// Destino de uma coluna do arquivo de texto.
public enum TextColumnTarget: Sendable, Equatable, Hashable {
    case ignore
    case field(Int)
    case tags
    case deck
    case notetype
    case guid
}

public enum TextDuplicatePolicy: Int, Sendable, CaseIterable {
    /// Atualiza a nota existente com o mesmo primeiro campo.
    case update
    /// Importa mesmo assim, criando uma duplicata.
    case keepBoth
    /// Ignora a linha.
    case skip
}

public struct TextImportOptions: Sendable {
    public var delimiter: Character
    public var isHTML: Bool
    public var notetypeID: NotetypeID
    public var deckID: DeckID
    public var columns: [TextColumnTarget]
    public var duplicatePolicy: TextDuplicatePolicy = .update
    /// Tags acrescentadas a todas as notas importadas.
    public var extraTags: [String] = []

    public init(delimiter: Character, isHTML: Bool, notetypeID: NotetypeID, deckID: DeckID, columns: [TextColumnTarget]) {
        self.delimiter = delimiter; self.isHTML = isHTML; self.notetypeID = notetypeID
        self.deckID = deckID; self.columns = columns
    }
}

public struct TextImportSummary: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var skippedDuplicates = 0
    public var skippedEmpty = 0
    public var failed = 0
}

/// Resultado da leitura do arquivo, antes de importar.
public struct TextFilePreview: Sendable, Equatable {
    public var delimiter: Character
    public var isHTML: Bool
    public var rows: [[String]]
    public var columnCount: Int
    /// Valores vindos de cabeçalhos `#chave:valor`.
    public var notetypeName: String?
    public var deckName: String?
    public var globalTags: [String]
    public var columnNames: [String]
    public var tagsColumn: Int?
    public var deckColumn: Int?
    public var notetypeColumn: Int?
    public var guidColumn: Int?
}

public enum TextImporter {

    public static let delimiterChoices: [(name: String, character: Character)] = [
        ("Tabulação", "\t"), ("Vírgula", ","), ("Ponto e vírgula", ";"), ("Barra vertical", "|"),
        ("Dois-pontos", ":"), ("Espaço", " "),
    ]

    // MARK: Leitura

    public static func decode(_ data: Data) -> String {
        var bytes = data
        // Remove BOM UTF-8.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        if let text = String(data: bytes, encoding: .utf16) { return text }
        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    static func delimiter(named name: String) -> Character? {
        switch name.lowercased().trimmingCharacters(in: .whitespaces) {
        case "tab", "\\t": return "\t"
        case "comma", ",": return ","
        case "semicolon", ";": return ";"
        case "pipe", "|": return "|"
        case "colon", ":": return ":"
        case "space", " ": return " "
        default: return name.count == 1 ? name.first : nil
        }
    }

    static func detectDelimiter(_ lines: [Substring]) -> Character {
        let sample = lines.prefix(10)
        for candidate: Character in ["\t", ";", ",", "|"] {
            let counts = sample.map { line in line.filter { $0 == candidate }.count }
            if let first = counts.first, first > 0, counts.allSatisfy({ $0 > 0 }) { return candidate }
        }
        for candidate: Character in ["\t", ";", ",", "|"] where sample.contains(where: { $0.contains(candidate) }) {
            return candidate
        }
        return "\t"
    }

    /// Divide o texto em registros, respeitando aspas (com `""` como escape) e quebras de linha dentro delas.
    static func parseRecords(_ text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        let chars = Array(text)
        var index = 0

        func endField() {
            record.append(field)
            field = ""
            fieldStarted = false
        }
        func endRecord() {
            endField()
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
            record = []
        }

        while index < chars.count {
            let ch = chars[index]
            if inQuotes {
                if ch == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && !fieldStarted {
                inQuotes = true
                fieldStarted = true
            } else if ch == delimiter {
                endField()
            } else if ch == "\n" || ch == "\r\n" {
                endRecord()
            } else if ch == "\r" {
                endRecord()
            } else {
                field.append(ch)
                fieldStarted = true
            }
            index += 1
        }
        if fieldStarted || !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }

    /// Lê cabeçalhos e registros do arquivo.
    public static func preview(text rawText: String, delimiter forced: Character? = nil) -> TextFilePreview {
        var headerDelimiter: Character?
        var isHTML: Bool?
        var notetypeName: String?
        var deckName: String?
        var globalTags: [String] = []
        var columnNames: [String] = []
        var tagsColumn: Int?, deckColumn: Int?, notetypeColumn: Int?, guidColumn: Int?

        // Cabeçalhos: linhas iniciais no formato "#chave:valor".
        var body = Substring(rawText)
        while body.hasPrefix("#") {
            let lineEnd = body.firstIndex(where: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) ?? body.endIndex
            let line = body[body.startIndex..<lineEnd].dropFirst()
            guard let colon = line.firstIndex(of: ":") else { break }
            let key = line[line.startIndex..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var recognized = true
            switch key {
            case "separator": headerDelimiter = delimiter(named: value)
            case "html": isHTML = value.lowercased() == "true"
            case "notetype": notetypeName = value
            case "deck": deckName = value
            case "tags": globalTags = value.split(separator: " ").map(String.init)
            case "columns":
                let separator = headerDelimiter ?? forced ?? "\t"
                columnNames = value.split(separator: separator, omittingEmptySubsequences: false).map { String($0) }
            case "tags column": tagsColumn = Int(value).map { $0 - 1 }
            case "deck column": deckColumn = Int(value).map { $0 - 1 }
            case "notetype column": notetypeColumn = Int(value).map { $0 - 1 }
            case "guid column": guidColumn = Int(value).map { $0 - 1 }
            default: recognized = false
            }
            if !recognized { break }
            body = lineEnd < body.endIndex ? body[body.index(after: lineEnd)...] : Substring()
        }

        let lines = body.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
        let chosen = forced ?? headerDelimiter ?? detectDelimiter(lines)
        let rows = parseRecords(String(body), delimiter: chosen)
        let columnCount = rows.map(\.count).max() ?? 0
        let html = isHTML ?? rows.prefix(20).contains { row in
            row.contains { $0.range(of: "<[a-zA-Z/][^>]*>", options: .regularExpression) != nil }
        }
        return TextFilePreview(delimiter: chosen, isHTML: html, rows: rows, columnCount: columnCount,
                               notetypeName: notetypeName, deckName: deckName, globalTags: globalTags,
                               columnNames: columnNames, tagsColumn: tagsColumn, deckColumn: deckColumn,
                               notetypeColumn: notetypeColumn, guidColumn: guidColumn)
    }

    /// Mapeamento sugerido: colunas em ordem para os campos; a coluna seguinte ao último campo vira tags.
    public static func suggestedColumns(preview: TextFilePreview, notetype: Notetype) -> [TextColumnTarget] {
        var targets: [TextColumnTarget] = []
        var nextField = 0
        for column in 0..<preview.columnCount {
            if column == preview.tagsColumn { targets.append(.tags); continue }
            if column == preview.deckColumn { targets.append(.deck); continue }
            if column == preview.notetypeColumn { targets.append(.notetype); continue }
            if column == preview.guidColumn { targets.append(.guid); continue }
            if column < preview.columnNames.count, let index = notetype.fieldIndex(named: preview.columnNames[column]) {
                targets.append(.field(index))
                continue
            }
            if nextField < notetype.fields.count {
                targets.append(.field(nextField))
                nextField += 1
            } else if preview.tagsColumn == nil && !targets.contains(.tags) {
                targets.append(.tags)
            } else {
                targets.append(.ignore)
            }
        }
        return targets
    }

    // MARK: Importação

    static func prepareValue(_ raw: String, isHTML: Bool) -> String {
        if isHTML { return raw }
        return HTMLText.escape(raw).replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
    }

    public static func importRows(_ rows: [[String]], into collection: Collection, options: TextImportOptions) throws -> TextImportSummary {
        var summary = TextImportSummary()
        try collection.write { txn in
            let defaultType = try txn.notetype(options.notetypeID)
            var typesByName: [String: Notetype] = [:]
            for notetype in try txn.allNotetypes() { typesByName[notetype.name.lowercased()] = notetype }

            for row in rows {
                var notetype = defaultType
                var deckID = options.deckID
                var tags = options.extraTags
                var guid: String?
                var values: [Int: String] = [:]

                // Colunas que escolhem tipo de nota/baralho são lidas primeiro.
                for (column, target) in options.columns.enumerated() where column < row.count {
                    let cell = row[column].trimmingCharacters(in: .whitespacesAndNewlines)
                    switch target {
                    case .notetype:
                        if let found = typesByName[cell.lowercased()] { notetype = found }
                    case .deck:
                        if !cell.isEmpty { deckID = try txn.getOrCreateDeck(named: cell).id }
                    case .tags:
                        tags += cell.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
                    case .guid:
                        if !cell.isEmpty { guid = cell }
                    case .field, .ignore:
                        break
                    }
                }
                for (column, target) in options.columns.enumerated() where column < row.count {
                    if case .field(let index) = target, index < notetype.fields.count {
                        values[index] = prepareValue(row[column], isHTML: options.isHTML)
                    }
                }
                var fields = [String](repeating: "", count: notetype.fields.count)
                for (index, value) in values { fields[index] = value }
                if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    summary.skippedEmpty += 1
                    continue
                }

                // Nota existente: pelo GUID, se houver; senão, pelo primeiro campo.
                var existingID: NoteID?
                if let guid {
                    existingID = try Int64.fetchOne(txn.db, sql: "SELECT id FROM notes WHERE guid = ?", arguments: [guid])
                }
                if existingID == nil {
                    existingID = try txn.duplicateNoteIDs(firstField: fields[0], notetypeID: notetype.id).first
                }

                if let existingID, guid != nil || options.duplicatePolicy != .keepBoth {
                    if guid == nil && options.duplicatePolicy == .skip {
                        summary.skippedDuplicates += 1
                        continue
                    }
                    var note = try txn.note(existingID)
                    guard note.mid == notetype.id else {
                        summary.skippedDuplicates += 1
                        continue
                    }
                    var merged = note.fields
                    // Só substitui os campos que vieram no arquivo.
                    for (index, value) in values where index < merged.count { merged[index] = value }
                    let mergedTags = Note.joinTags(note.tagList + tags)
                    if merged != note.fields || mergedTags != note.tags {
                        note.fields = merged
                        note.tags = mergedTags
                        try txn.updateNote(&note)
                        summary.updated += 1
                    } else {
                        summary.skippedDuplicates += 1
                    }
                    continue
                }

                var note = Note(id: 0, guid: guid ?? "", mid: notetype.id)
                note.fields = fields
                note.tagList = tags
                do {
                    try txn.addNote(&note, deckID: deckID)
                    summary.added += 1
                } catch is CollectionError {
                    summary.failed += 1
                }
            }
        }
        return summary
    }
}
