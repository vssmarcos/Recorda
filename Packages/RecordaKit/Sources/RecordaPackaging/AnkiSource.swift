import Foundation
import GRDB
import RecordaCore

/// Conversões entre os valores numéricos usados nos arquivos de coleção e os enums do app.
enum WireEnums {
    static func gatherPriority(_ raw: Int) -> NewCardGatherPriority {
        switch raw {
        case 1: return .lowestPosition
        case 2: return .highestPosition
        case 3: return .randomNotes
        case 4: return .randomCards
        case 5: return .deckThenRandomNotes
        default: return .deck
        }
    }

    static func raw(_ value: NewCardGatherPriority) -> Int {
        switch value {
        case .deck: return 0
        case .lowestPosition: return 1
        case .highestPosition: return 2
        case .randomNotes: return 3
        case .randomCards: return 4
        case .deckThenRandomNotes: return 5
        }
    }

    static func reviewOrder(_ raw: Int) -> ReviewCardOrder {
        switch raw {
        case 1: return .dayThenDeck
        case 2: return .deckThenDay
        case 3: return .intervalsAscending
        case 4: return .intervalsDescending
        case 5: return .easeAscending
        case 6: return .easeDescending
        case 7: return .retrievabilityAscending
        case 8: return .random
        case 9: return .added
        case 10: return .reverseAdded
        case 11: return .retrievabilityDescending
        default: return .day
        }
    }

    static func raw(_ value: ReviewCardOrder) -> Int {
        switch value {
        case .day: return 0
        case .dayThenDeck: return 1
        case .deckThenDay: return 2
        case .intervalsAscending: return 3
        case .intervalsDescending: return 4
        case .easeAscending: return 5
        case .easeDescending: return 6
        case .retrievabilityAscending: return 7
        case .random: return 8
        case .added: return 9
        case .reverseAdded: return 10
        case .retrievabilityDescending: return 11
        }
    }

    /// Tipo padrão de origem: nos arquivos, 0 = desconhecido e os demais vêm deslocados em 1.
    static func stockKind(_ raw: Int) -> StockNotetype? {
        raw >= 1 ? StockNotetype(rawValue: raw - 1) : nil
    }

    static func raw(_ value: StockNotetype?) -> Int {
        value.map { $0.rawValue + 1 } ?? 0
    }

    static func round4(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
}

/// Acesso tolerante a dicionários JSON.
struct JSONObject {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    init?(text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.raw = object
    }

    func int(_ key: String) -> Int? {
        if let number = raw[key] as? NSNumber { return number.intValue }
        if let text = raw[key] as? String { return Int(text) }
        return nil
    }

    func int64(_ key: String) -> Int64? {
        if let number = raw[key] as? NSNumber { return number.int64Value }
        if let text = raw[key] as? String { return Int64(text) }
        return nil
    }

    func double(_ key: String) -> Double? {
        (raw[key] as? NSNumber)?.doubleValue
    }

    func bool(_ key: String) -> Bool? {
        (raw[key] as? NSNumber)?.boolValue
    }

    func string(_ key: String) -> String? { raw[key] as? String }

    func object(_ key: String) -> JSONObject? {
        (raw[key] as? [String: Any]).map(JSONObject.init)
    }

    func objects(_ key: String) -> [JSONObject] {
        (raw[key] as? [[String: Any]] ?? []).map(JSONObject.init)
    }

    func doubles(_ key: String) -> [Double]? {
        (raw[key] as? [NSNumber])?.map(\.doubleValue)
    }

    func array(_ key: String) -> [Any]? { raw[key] as? [Any] }
}

/// Uma coleção no formato do Anki (esquema legado v11 ou v18), aberta para leitura.
struct AnkiSource {
    let queue: DatabaseQueue
    var crt: Int64 = 0
    var schemaVersion: Int = 11
    var notetypes: [Notetype] = []
    var decks: [Deck] = []
    var deckConfigs: [DeckConfig] = []
    /// Configurações globais: chave → JSON.
    var config: [String: String] = [:]

    static func open(at url: URL) throws -> AnkiSource {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            // O esquema novo declara colunas com esta ordenação.
            db.add(collation: DatabaseCollation("unicase") { lhs, rhs in lhs.caseInsensitiveCompare(rhs) })
        }
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: configuration)
        } catch {
            throw PackagingError.invalidPackage("a coleção não é um banco SQLite válido")
        }
        var source = AnkiSource(queue: queue)
        try queue.read { db in
            guard try db.tableExists("col"), try db.tableExists("notes"), try db.tableExists("cards") else {
                throw PackagingError.invalidPackage("tabelas da coleção ausentes")
            }
            guard let col = try Row.fetchOne(db, sql: "SELECT * FROM col LIMIT 1") else {
                throw PackagingError.invalidPackage("coleção vazia")
            }
            source.crt = col["crt"] ?? 0
            source.schemaVersion = col["ver"] ?? 11
            if try db.tableExists("notetypes") && db.tableExists("deck_config") {
                try source.readModern(db)
            } else {
                try source.readLegacy(col)
            }
        }
        return source
    }

    // MARK: Esquema legado (JSON na tabela `col`)

    private mutating func readLegacy(_ col: Row) throws {
        let modelsText: String = col["models"] ?? "{}"
        let decksText: String = col["decks"] ?? "{}"
        let dconfText: String = col["dconf"] ?? "{}"
        let confText: String = col["conf"] ?? "{}"

        if let models = JSONObject(text: modelsText) {
            for key in models.raw.keys.sorted() {
                guard let model = models.object(key) else { continue }
                notetypes.append(AnkiSource.notetype(fromLegacy: model, fallbackID: Int64(key) ?? 0))
            }
        }
        if let all = JSONObject(text: decksText) {
            for key in all.raw.keys.sorted() {
                guard let deck = all.object(key) else { continue }
                decks.append(AnkiSource.deck(fromLegacy: deck, fallbackID: Int64(key) ?? 0))
            }
        }
        if let all = JSONObject(text: dconfText) {
            for key in all.raw.keys.sorted() {
                guard let conf = all.object(key) else { continue }
                deckConfigs.append(AnkiSource.deckConfig(fromLegacy: conf, fallbackID: Int64(key) ?? 0))
            }
        }
        if let conf = JSONObject(text: confText) {
            for (key, value) in conf.raw {
                if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                   let text = String(data: data, encoding: .utf8) {
                    config[key] = text
                }
            }
        }
    }

    static func notetype(fromLegacy model: JSONObject, fallbackID: Int64) -> Notetype {
        var config = NotetypeConfig()
        config.kind = model.int("type") == 1 ? .cloze : .standard
        config.sortFieldIdx = model.int("sortf") ?? 0
        config.css = model.string("css") ?? Notetype.defaultCSS
        config.latexPre = model.string("latexPre") ?? Notetype.defaultLatexPre
        config.latexPost = model.string("latexPost") ?? "\\end{document}"
        config.latexSvg = model.bool("latexsvg") ?? false
        config.originalStockKind = WireEnums.stockKind(model.int("originalStockKind") ?? 0)

        let fields = model.objects("flds").sorted { ($0.int("ord") ?? 0) < ($1.int("ord") ?? 0) }
        config.fields = fields.enumerated().map { index, field in
            NoteField(ord: index, name: field.string("name") ?? "Campo \(index + 1)",
                      sticky: field.bool("sticky") ?? false, rtl: field.bool("rtl") ?? false,
                      fontName: field.string("font") ?? "Arial", fontSize: field.int("size") ?? 20,
                      plainText: field.bool("plainText") ?? false,
                      description: field.string("description") ?? "", tag: field.int("tag"))
        }
        let templates = model.objects("tmpls").sorted { ($0.int("ord") ?? 0) < ($1.int("ord") ?? 0) }
        config.templates = templates.enumerated().map { index, template in
            CardTemplate(ord: index, name: template.string("name") ?? "Card \(index + 1)",
                         qfmt: template.string("qfmt") ?? "", afmt: template.string("afmt") ?? "",
                         browserQfmt: template.string("bqfmt") ?? "", browserAfmt: template.string("bafmt") ?? "",
                         targetDeckID: template.int64("did") ?? 0)
        }
        return Notetype(id: model.int64("id") ?? fallbackID, name: model.string("name") ?? "Tipo de nota",
                        mtimeSecs: model.int64("mod") ?? 0, usn: model.int("usn") ?? -1, config: config)
    }

    static func deck(fromLegacy deck: JSONObject, fallbackID: Int64) -> Deck {
        var common = DeckCommon()
        common.collapsed = deck.bool("collapsed") ?? false
        common.browserCollapsed = deck.bool("browserCollapsed") ?? false
        common.desc = deck.string("desc") ?? ""
        let kind: DeckKind
        if deck.int("dyn") == 1 {
            var filtered = FilteredDeck()
            filtered.reschedule = deck.bool("resched") ?? true
            var terms: [FilteredSearchTerm] = []
            for term in deck.array("terms") ?? [] {
                guard let parts = term as? [Any], parts.count >= 3 else { continue }
                let search = parts[0] as? String ?? ""
                let limit = (parts[1] as? NSNumber)?.intValue ?? 100
                let order = FilteredOrder(rawValue: (parts[2] as? NSNumber)?.intValue ?? 1) ?? .random
                terms.append(FilteredSearchTerm(search: search, limit: limit, order: order))
            }
            if !terms.isEmpty { filtered.terms = terms }
            filtered.previewAgainSecs = deck.int("previewAgainSecs") ?? 60
            filtered.previewHardSecs = deck.int("previewHardSecs") ?? 600
            filtered.previewGoodSecs = deck.int("previewGoodSecs") ?? 0
            kind = .filtered(filtered)
        } else {
            var normal = NormalDeck()
            normal.configID = deck.int64("conf") ?? 1
            normal.newLimit = deck.int("newLimit")
            normal.reviewLimit = deck.int("reviewLimit")
            kind = .normal(normal)
        }
        let name = Deck.normalizedName((deck.string("name") ?? "Baralho").replacingOccurrences(of: "\u{1f}", with: Deck.separator))
        return Deck(id: deck.int64("id") ?? fallbackID, name: name.isEmpty ? "Baralho" : name,
                    mtimeSecs: deck.int64("mod") ?? 0, usn: deck.int("usn") ?? -1, common: common, kind: kind)
    }

    static func deckConfig(fromLegacy conf: JSONObject, fallbackID: Int64) -> DeckConfig {
        var data = DeckConfigData()
        if let new = conf.object("new") {
            data.newPerDay = new.int("perDay") ?? data.newPerDay
            data.learnSteps = new.doubles("delays") ?? data.learnSteps
            if let ints = new.doubles("ints") {
                if ints.count > 0 { data.graduatingIntervalGood = Int(ints[0]) }
                if ints.count > 1 { data.graduatingIntervalEasy = Int(ints[1]) }
            }
            if let factor = new.double("initialFactor") { data.initialEase = factor / 1000.0 }
            if let order = new.int("order") { data.newCardInsertOrder = order == 0 ? .random : .due }
            data.buryNew = new.bool("bury") ?? false
        }
        if let rev = conf.object("rev") {
            data.reviewsPerDay = rev.int("perDay") ?? data.reviewsPerDay
            data.easyMultiplier = rev.double("ease4") ?? data.easyMultiplier
            data.intervalMultiplier = rev.double("ivlFct") ?? data.intervalMultiplier
            data.maximumReviewInterval = rev.int("maxIvl") ?? data.maximumReviewInterval
            data.hardMultiplier = rev.double("hardFactor") ?? data.hardMultiplier
            data.buryReviews = rev.bool("bury") ?? false
        }
        if let lapse = conf.object("lapse") {
            data.relearnSteps = lapse.doubles("delays") ?? data.relearnSteps
            data.lapseMultiplier = lapse.double("mult") ?? data.lapseMultiplier
            data.minimumLapseInterval = lapse.int("minInt") ?? data.minimumLapseInterval
            data.leechThreshold = lapse.int("leechFails") ?? data.leechThreshold
            if let action = lapse.int("leechAction") { data.leechAction = action == 0 ? .suspend : .tagOnly }
        }
        data.capAnswerTimeToSecs = conf.int("maxTaken") ?? data.capAnswerTimeToSecs
        data.showTimer = (conf.int("timer") ?? 0) != 0
        if let autoplay = conf.bool("autoplay") { data.disableAutoplay = !autoplay }
        if let replay = conf.bool("replayq") { data.skipQuestionWhenReplayingAnswer = !replay }

        // Chaves adicionais gravadas por versões recentes.
        if let v = conf.int("newMix"), let mix = ReviewMix(rawValue: v) { data.newMix = mix }
        if let v = conf.int("interdayLearningMix"), let mix = ReviewMix(rawValue: v) { data.interdayLearningMix = mix }
        if let v = conf.int("reviewOrder") { data.reviewOrder = WireEnums.reviewOrder(v) }
        if let v = conf.int("newSortOrder"), let order = NewCardSortOrder(rawValue: v) { data.newCardSortOrder = order }
        if let v = conf.int("newGatherPriority") { data.newCardGatherPriority = WireEnums.gatherPriority(v) }
        data.buryInterdayLearning = conf.bool("buryInterdayLearning") ?? data.buryInterdayLearning
        if let v = conf.double("desiredRetention"), v > 0.5, v < 1 { data.desiredRetention = WireEnums.round4(v) }
        for key in ["fsrsParams6", "fsrsParams5", "fsrsWeights"] {
            if let params = conf.doubles(key), [17, 19, 21].contains(params.count) {
                data.fsrsParams = params.map(WireEnums.round4)
                break
            }
        }
        if let days = conf.doubles("easyDaysPercentages"), days.count == 7 { data.easyDaysPercentages = days }
        data.stopTimerOnAnswer = conf.bool("stopTimerOnAnswer") ?? data.stopTimerOnAnswer
        data.secondsToShowQuestion = conf.double("secondsToShowQuestion") ?? data.secondsToShowQuestion
        data.secondsToShowAnswer = conf.double("secondsToShowAnswer") ?? data.secondsToShowAnswer
        if let v = conf.int("questionAction"), let action = AutoAdvanceQuestionAction(rawValue: v) { data.questionAction = action }
        if let v = conf.int("answerAction"), let action = AutoAdvanceAnswerAction(rawValue: v) { data.answerAction = action }
        data.waitForAudio = conf.bool("waitForAudio") ?? data.waitForAudio
        data.paramSearch = conf.string("paramSearch") ?? conf.string("weightSearch") ?? ""
        data.newCardsIgnoreReviewLimit = conf.bool("newCardsIgnoreReviewLimit") ?? data.newCardsIgnoreReviewLimit

        return DeckConfig(id: conf.int64("id") ?? fallbackID, name: conf.string("name") ?? "Predefinição",
                          mtimeSecs: conf.int64("mod") ?? 0, usn: conf.int("usn") ?? -1, config: data)
    }

    // MARK: Esquema novo (tabelas próprias, blobs protobuf)

    private mutating func readModern(_ db: Database) throws {
        // Tipos de nota
        var fieldsByType: [Int64: [NoteField]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT ntid, ord, name, config FROM fields ORDER BY ntid, ord") {
            let message = ProtoMessage(row["config"] ?? Data())
            let ntid: Int64 = row["ntid"]
            let field = NoteField(
                ord: row["ord"], name: row["name"],
                sticky: message.bool(1) ?? false, rtl: message.bool(2) ?? false,
                fontName: message.string(3) ?? "Arial", fontSize: message.int(4) ?? 20,
                plainText: message.bool(6) ?? false, description: message.string(5) ?? "",
                tag: message.int(10))
            fieldsByType[ntid, default: []].append(field)
        }
        var templatesByType: [Int64: [CardTemplate]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT ntid, ord, name, config FROM templates ORDER BY ntid, ord") {
            let message = ProtoMessage(row["config"] ?? Data())
            let ntid: Int64 = row["ntid"]
            let template = CardTemplate(
                ord: row["ord"], name: row["name"],
                qfmt: message.string(1) ?? "", afmt: message.string(2) ?? "",
                browserQfmt: message.string(3) ?? "", browserAfmt: message.string(4) ?? "",
                targetDeckID: Int64(message.int(5) ?? 0))
            templatesByType[ntid, default: []].append(template)
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, name, mtime_secs, usn, config FROM notetypes") {
            let message = ProtoMessage(row["config"] ?? Data())
            let id: Int64 = row["id"]
            var config = NotetypeConfig()
            config.kind = message.int(1) == 1 ? .cloze : .standard
            config.sortFieldIdx = message.int(2) ?? 0
            config.css = message.string(3) ?? Notetype.defaultCSS
            config.latexPre = message.string(5) ?? Notetype.defaultLatexPre
            config.latexPost = message.string(6) ?? "\\end{document}"
            config.latexSvg = message.bool(7) ?? false
            config.originalStockKind = WireEnums.stockKind(message.int(9) ?? 0)
            config.fields = fieldsByType[id] ?? []
            config.templates = templatesByType[id] ?? []
            var notetype = Notetype(id: id, name: row["name"], mtimeSecs: row["mtime_secs"], usn: row["usn"], config: config)
            notetype.renumber()
            notetypes.append(notetype)
        }

        // Baralhos
        for row in try Row.fetchAll(db, sql: "SELECT id, name, mtime_secs, usn, common, kind FROM decks") {
            let commonMessage = ProtoMessage(row["common"] ?? Data())
            let kindMessage = ProtoMessage(row["kind"] ?? Data())
            var common = DeckCommon()
            common.collapsed = commonMessage.bool(1) ?? false
            common.browserCollapsed = commonMessage.bool(2) ?? false
            let kind: DeckKind
            if let filteredMessage = kindMessage.message(2) {
                var filtered = FilteredDeck()
                filtered.reschedule = filteredMessage.bool(1) ?? false
                let terms = filteredMessage.messages(2).map { term in
                    FilteredSearchTerm(search: term.string(1) ?? "", limit: term.int(2) ?? 100,
                                       order: FilteredOrder(rawValue: term.int(3) ?? 0) ?? .random)
                }
                if !terms.isEmpty { filtered.terms = terms }
                filtered.previewAgainSecs = filteredMessage.int(6) ?? 60
                filtered.previewHardSecs = filteredMessage.int(5) ?? 600
                filtered.previewGoodSecs = filteredMessage.int(7) ?? 0
                kind = .filtered(filtered)
            } else {
                var normal = NormalDeck()
                if let normalMessage = kindMessage.message(1) {
                    normal.configID = Int64(normalMessage.int(1) ?? 1)
                    common.desc = normalMessage.string(4) ?? ""
                    normal.reviewLimit = normalMessage.int(6)
                    normal.newLimit = normalMessage.int(7)
                }
                kind = .normal(normal)
            }
            let rawName: String = row["name"]
            let name = Deck.normalizedName(rawName.replacingOccurrences(of: "\u{1f}", with: Deck.separator))
            decks.append(Deck(id: row["id"], name: name.isEmpty ? "Baralho" : name, mtimeSecs: row["mtime_secs"],
                              usn: row["usn"], common: common, kind: kind))
        }

        // Predefinições
        for row in try Row.fetchAll(db, sql: "SELECT id, name, mtime_secs, usn, config FROM deck_config") {
            let message = ProtoMessage(row["config"] ?? Data())
            deckConfigs.append(DeckConfig(id: row["id"], name: row["name"], mtimeSecs: row["mtime_secs"],
                                          usn: row["usn"], config: AnkiSource.deckConfigData(from: message)))
        }

        // Configurações globais
        if try db.tableExists("config") {
            for row in try Row.fetchAll(db, sql: "SELECT KEY AS k, val FROM config") {
                let key: String = row["k"]
                let value: Data = row["val"] ?? Data()
                if let text = String(data: value, encoding: .utf8) { config[key] = text }
            }
        }
    }

    static func deckConfigData(from message: ProtoMessage) -> DeckConfigData {
        var data = DeckConfigData()
        let learn = message.floats(1)
        let relearn = message.floats(2)
        // Um campo ausente significa "sem passos" apenas se a mensagem tiver outros dados.
        if !message.fields.isEmpty {
            data.learnSteps = learn.map(WireEnums.round4)
            data.relearnSteps = relearn.map(WireEnums.round4)
        }
        for number in [6, 5, 3] {
            let params = message.floats(number)
            if [17, 19, 21].contains(params.count) {
                data.fsrsParams = params.map(WireEnums.round4)
                break
            }
        }
        let easyDays = message.floats(4)
        if easyDays.count == 7 { data.easyDaysPercentages = easyDays.map(WireEnums.round4) }
        data.newPerDay = message.int(9) ?? 0
        data.reviewsPerDay = message.int(10) ?? 0
        if let v = message.float(11), v >= 1.3 { data.initialEase = WireEnums.round4(v) }
        if let v = message.float(12), v >= 1 { data.easyMultiplier = WireEnums.round4(v) }
        if let v = message.float(13), v > 0 { data.hardMultiplier = WireEnums.round4(v) }
        data.lapseMultiplier = WireEnums.round4(message.float(14) ?? 0)
        if let v = message.float(15), v > 0 { data.intervalMultiplier = WireEnums.round4(v) }
        if let v = message.int(16), v > 0 { data.maximumReviewInterval = v }
        if let v = message.int(17), v > 0 { data.minimumLapseInterval = v }
        if let v = message.int(18), v > 0 { data.graduatingIntervalGood = v }
        if let v = message.int(19), v > 0 { data.graduatingIntervalEasy = v }
        data.newCardInsertOrder = message.int(20) == 1 ? .random : .due
        data.leechAction = message.int(21) == 1 ? .tagOnly : .suspend
        if let v = message.int(22) { data.leechThreshold = v }
        data.disableAutoplay = message.bool(23) ?? false
        if let v = message.int(24), v > 0 { data.capAnswerTimeToSecs = v }
        data.showTimer = message.bool(25) ?? false
        data.skipQuestionWhenReplayingAnswer = message.bool(26) ?? false
        data.buryNew = message.bool(27) ?? false
        data.buryReviews = message.bool(28) ?? false
        data.buryInterdayLearning = message.bool(29) ?? false
        data.newMix = ReviewMix(rawValue: message.int(30) ?? 0) ?? .mixWithReviews
        data.interdayLearningMix = ReviewMix(rawValue: message.int(31) ?? 0) ?? .mixWithReviews
        data.newCardSortOrder = NewCardSortOrder(rawValue: message.int(32) ?? 0) ?? .template
        data.reviewOrder = WireEnums.reviewOrder(message.int(33) ?? 0)
        data.newCardGatherPriority = WireEnums.gatherPriority(message.int(34) ?? 0)
        if let v = message.float(37), v > 0.5, v < 1 { data.desiredRetention = WireEnums.round4(v) }
        data.stopTimerOnAnswer = message.bool(38) ?? false
        if let v = message.float(41), v >= 0, v < 3600 { data.secondsToShowQuestion = WireEnums.round4(v) }
        if let v = message.float(42), v >= 0, v < 3600 { data.secondsToShowAnswer = WireEnums.round4(v) }
        return data
    }
}
