import Foundation
import GRDB

public typealias NoteID = Int64
public typealias CardID = Int64
public typealias DeckID = Int64
public typealias NotetypeID = Int64
public typealias DeckConfigID = Int64

// MARK: - Card

public enum CardType: Int, Codable, Sendable, CaseIterable {
    case new = 0, learning = 1, review = 2, relearning = 3
}

public enum CardQueue: Int, Codable, Sendable, CaseIterable {
    case userBuried = -3, schedBuried = -2, suspended = -1
    case new = 0, learning = 1, review = 2, dayLearning = 3, preview = 4
}

/// Estado de memória FSRS guardado em `cards.data`.
public struct CardData: Codable, Sendable, Equatable {
    /// Estabilidade (dias).
    public var s: Double?
    /// Dificuldade (1–10).
    public var d: Double?
    /// Retenção desejada em vigor na última resposta.
    public var dr: Double?
    /// Momento (epoch s) da última revisão.
    public var lrt: Int64?
    /// Posição original de card novo (restaurada ao "esquecer").
    public var pos: Int?

    public init(s: Double? = nil, d: Double? = nil, dr: Double? = nil, lrt: Int64? = nil, pos: Int? = nil) {
        self.s = s; self.d = d; self.dr = dr; self.lrt = lrt; self.pos = pos
    }

    public static func decode(_ string: String) -> CardData {
        guard !string.isEmpty, let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(CardData.self, from: data) else { return CardData() }
        return value
    }

    public func encoded() -> String {
        if s == nil && d == nil && dr == nil && lrt == nil && pos == nil { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }
}

public struct Card: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "cards"

    public var id: CardID
    public var nid: NoteID
    public var did: DeckID
    public var ord: Int
    public var mod: Int64
    public var usn: Int
    public var type: CardType
    public var queue: CardQueue
    /// Novo: posição. Aprendendo: epoch s. Revisão/interdiário: dia desde a criação da coleção.
    public var due: Int64
    public var ivl: Int
    /// Facilidade em permilagem (2500 = 250 %).
    public var factor: Int
    public var reps: Int
    public var lapses: Int
    /// `repsHoje * 1000 + passosRestantes`.
    public var left: Int
    public var odue: Int64
    public var odid: DeckID
    public var flags: Int
    public var data: String

    public init(id: CardID, nid: NoteID, did: DeckID, ord: Int, mod: Int64 = 0, usn: Int = -1,
                type: CardType = .new, queue: CardQueue = .new, due: Int64 = 0, ivl: Int = 0,
                factor: Int = 0, reps: Int = 0, lapses: Int = 0, left: Int = 0, odue: Int64 = 0,
                odid: DeckID = 0, flags: Int = 0, data: String = "") {
        self.id = id; self.nid = nid; self.did = did; self.ord = ord; self.mod = mod; self.usn = usn
        self.type = type; self.queue = queue; self.due = due; self.ivl = ivl; self.factor = factor
        self.reps = reps; self.lapses = lapses; self.left = left; self.odue = odue; self.odid = odid
        self.flags = flags; self.data = data
    }

    public var cardData: CardData {
        get { CardData.decode(data) }
        set { data = newValue.encoded() }
    }

    /// Sinalizador 0–7 (0 = nenhum).
    public var userFlag: Int {
        get { flags & 0b111 }
        set { flags = (flags & ~0b111) | (newValue & 0b111) }
    }

    public var remainingSteps: Int { left % 1000 }

    /// Baralho "de origem" (o original, se o card estiver em um baralho filtrado).
    public var homeDeckID: DeckID { odid != 0 ? odid : did }

    public var isInFilteredDeck: Bool { odid != 0 }
}

// MARK: - Note

public struct Note: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "notes"
    public static let fieldSeparator = "\u{1f}"

    public var id: NoteID
    public var guid: String
    public var mid: NotetypeID
    public var mod: Int64
    public var usn: Int
    /// Tags separadas por espaço, com espaço no início e no fim (" a b ").
    public var tags: String
    /// Campos unidos por 0x1f.
    public var flds: String
    public var sfld: String
    public var csum: Int64
    public var flags: Int
    public var data: String

    public init(id: NoteID, guid: String, mid: NotetypeID, mod: Int64 = 0, usn: Int = -1,
                tags: String = "", flds: String = "", sfld: String = "", csum: Int64 = 0,
                flags: Int = 0, data: String = "") {
        self.id = id; self.guid = guid; self.mid = mid; self.mod = mod; self.usn = usn
        self.tags = tags; self.flds = flds; self.sfld = sfld; self.csum = csum
        self.flags = flags; self.data = data
    }

    public var fields: [String] {
        get { flds.components(separatedBy: Note.fieldSeparator) }
        set { flds = newValue.joined(separator: Note.fieldSeparator) }
    }

    public var tagList: [String] {
        get { tags.split(separator: " ").map(String.init) }
        set { tags = Note.joinTags(newValue) }
    }

    public static func joinTags(_ list: [String]) -> String {
        var seen = Set<String>()
        var unique: [String] = []
        for raw in list {
            let tag = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
            if tag.isEmpty { continue }
            if seen.insert(tag.lowercased()).inserted { unique.append(tag) }
        }
        if unique.isEmpty { return "" }
        unique.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return " " + unique.joined(separator: " ") + " "
    }

    public func hasTag(_ tag: String) -> Bool {
        tagList.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    public mutating func addTag(_ tag: String) {
        if !hasTag(tag) { tagList = tagList + [tag] }
    }

    public mutating func removeTag(_ tag: String) {
        tagList = tagList.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
    }
}

// MARK: - Revlog

public enum RevlogKind: Int, Codable, Sendable {
    case learning = 0, review = 1, relearning = 2, filtered = 3, manual = 4
}

public struct RevlogEntry: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "revlog"

    /// Epoch em milissegundos.
    public var id: Int64
    public var cid: CardID
    public var usn: Int
    /// 1 Errei, 2 Difícil, 3 Bom, 4 Fácil; 0 para entradas manuais.
    public var ease: Int
    /// Positivo: dias. Negativo: segundos.
    public var ivl: Int
    public var lastIvl: Int
    public var factor: Int
    /// Tempo gasto em milissegundos.
    public var time: Int
    public var type: RevlogKind

    public init(id: Int64, cid: CardID, usn: Int = -1, ease: Int, ivl: Int, lastIvl: Int,
                factor: Int, time: Int, type: RevlogKind) {
        self.id = id; self.cid = cid; self.usn = usn; self.ease = ease; self.ivl = ivl
        self.lastIvl = lastIvl; self.factor = factor; self.time = time; self.type = type
    }
}

// MARK: - Deck

public struct DayCount: Codable, Sendable, Equatable {
    public var day: Int
    public var count: Int
    public init(day: Int = 0, count: Int = 0) { self.day = day; self.count = count }
}

public struct DeckCommon: Codable, Sendable, Equatable {
    public var collapsed: Bool = false
    public var browserCollapsed: Bool = false
    public var desc: String = ""
    /// Dia a que os contadores abaixo se referem.
    public var lastDayStudied: Int = 0
    public var newStudied: Int = 0
    public var reviewStudied: Int = 0
    public var learningStudied: Int = 0
    public var millisecondsStudied: Int = 0
    public init() {}
}

public enum FilteredOrder: Int, Codable, Sendable, CaseIterable {
    case oldestReviewedFirst = 0, random, intervalsAscending, intervalsDescending, lapses, added, due, reverseAdded, retrievabilityAscending
}

public struct FilteredSearchTerm: Codable, Sendable, Equatable {
    public var search: String
    public var limit: Int
    public var order: FilteredOrder
    public init(search: String = "", limit: Int = 100, order: FilteredOrder = .random) {
        self.search = search; self.limit = limit; self.order = order
    }
}

public struct FilteredDeck: Codable, Sendable, Equatable {
    public var reschedule: Bool = true
    public var terms: [FilteredSearchTerm] = [FilteredSearchTerm()]
    /// Atrasos (s) usados na pré-visualização quando `reschedule` é falso: Errei / Difícil / Bom.
    public var previewAgainSecs: Int = 60
    public var previewHardSecs: Int = 600
    public var previewGoodSecs: Int = 0
    public init() {}
}

public struct NormalDeck: Codable, Sendable, Equatable {
    public var configID: DeckConfigID = 1
    /// Limites próprios do baralho (nil = usar a predefinição).
    public var newLimit: Int?
    public var reviewLimit: Int?
    /// Limites "somente hoje".
    public var newLimitToday: DayCount?
    public var reviewLimitToday: DayCount?
    /// Acréscimos de "estudo personalizado" válidos para o dia indicado.
    public var extendNew: DayCount = DayCount()
    public var extendReview: DayCount = DayCount()
    public init() {}
}

public enum DeckKind: Codable, Sendable, Equatable {
    case normal(NormalDeck)
    case filtered(FilteredDeck)
}

public struct Deck: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "decks"
    public static let separator = "::"

    public var id: DeckID
    /// Nome completo, com "::" separando os níveis.
    public var name: String
    public var mtimeSecs: Int64
    public var usn: Int
    public var common: DeckCommon
    public var kind: DeckKind

    enum CodingKeys: String, CodingKey {
        case id, name, mtimeSecs = "mtime_secs", usn, common, kind
    }

    public init(id: DeckID, name: String, mtimeSecs: Int64 = 0, usn: Int = -1,
                common: DeckCommon = DeckCommon(), kind: DeckKind = .normal(NormalDeck())) {
        self.id = id; self.name = name; self.mtimeSecs = mtimeSecs; self.usn = usn
        self.common = common; self.kind = kind
    }

    public var isFiltered: Bool {
        if case .filtered = kind { return true }
        return false
    }

    public var normal: NormalDeck? {
        get { if case .normal(let n) = kind { return n } else { return nil } }
        set { if let newValue { kind = .normal(newValue) } }
    }

    public var filtered: FilteredDeck? {
        get { if case .filtered(let f) = kind { return f } else { return nil } }
        set { if let newValue { kind = .filtered(newValue) } }
    }

    public var configID: DeckConfigID? { normal?.configID }

    public var components: [String] { name.components(separatedBy: Deck.separator) }
    public var shortName: String { components.last ?? name }
    public var level: Int { components.count - 1 }
    public var parentName: String? {
        let parts = components
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: Deck.separator)
    }

    public func isDescendant(ofName other: String) -> Bool {
        name.lowercased().hasPrefix(other.lowercased() + Deck.separator)
    }
}

// MARK: - Deck config (predefinições)

public enum NewCardInsertOrder: Int, Codable, Sendable, CaseIterable { case due = 0, random }
public enum LeechAction: Int, Codable, Sendable, CaseIterable { case suspend = 0, tagOnly }
public enum NewCardGatherPriority: Int, Codable, Sendable, CaseIterable {
    case deck = 0, deckThenRandomNotes, lowestPosition, highestPosition, randomNotes, randomCards
}
public enum NewCardSortOrder: Int, Codable, Sendable, CaseIterable {
    case template = 0, noSort, templateThenRandom, randomNoteThenTemplate, randomCard
}
public enum ReviewMix: Int, Codable, Sendable, CaseIterable { case mixWithReviews = 0, afterReviews, beforeReviews }
public enum ReviewCardOrder: Int, Codable, Sendable, CaseIterable {
    case day = 0, dayThenDeck, deckThenDay, intervalsAscending, intervalsDescending
    case easeAscending, easeDescending, retrievabilityAscending, retrievabilityDescending
    case random, added, reverseAdded
}
public enum AutoAdvanceQuestionAction: Int, Codable, Sendable, CaseIterable { case showAnswer = 0, showReminder }
public enum AutoAdvanceAnswerAction: Int, Codable, Sendable, CaseIterable {
    case buryCard = 0, answerAgain, answerGood, answerHard, showReminder
}

public struct DeckConfigData: Codable, Sendable, Equatable {
    // Limites diários
    public var newPerDay: Int = 20
    public var reviewsPerDay: Int = 200
    public var newCardsIgnoreReviewLimit: Bool = false

    // Cards novos
    public var learnSteps: [Double] = [1, 10]            // minutos
    public var graduatingIntervalGood: Int = 1
    public var graduatingIntervalEasy: Int = 4
    public var newCardInsertOrder: NewCardInsertOrder = .due

    // Lapsos
    public var relearnSteps: [Double] = [10]             // minutos
    public var minimumLapseInterval: Int = 1
    public var leechThreshold: Int = 8
    public var leechAction: LeechAction = .tagOnly

    // Ordem de exibição
    public var newCardGatherPriority: NewCardGatherPriority = .deck
    public var newCardSortOrder: NewCardSortOrder = .template
    public var newMix: ReviewMix = .mixWithReviews
    public var interdayLearningMix: ReviewMix = .mixWithReviews
    public var reviewOrder: ReviewCardOrder = .day

    // Enterrar
    public var buryNew: Bool = false
    public var buryReviews: Bool = false
    public var buryInterdayLearning: Bool = false

    // FSRS
    public var desiredRetention: Double = 0.9
    /// Vazio = parâmetros padrão.
    public var fsrsParams: [Double] = []
    /// Busca usada para selecionar o histórico na otimização (vazio = cards desta predefinição).
    public var paramSearch: String = ""

    // Avançado / SM-2
    public var maximumReviewInterval: Int = 36500
    public var initialEase: Double = 2.5
    public var easyMultiplier: Double = 1.3
    public var hardMultiplier: Double = 1.2
    public var intervalMultiplier: Double = 1.0
    public var lapseMultiplier: Double = 0.0

    /// Segunda a domingo: 1.0 normal, 0.5 reduzido, 0.0 mínimo.
    public var easyDaysPercentages: [Double] = [1, 1, 1, 1, 1, 1, 1]

    // Temporizador e avanço automático
    public var capAnswerTimeToSecs: Int = 60
    public var showTimer: Bool = false
    public var stopTimerOnAnswer: Bool = false
    public var secondsToShowQuestion: Double = 0
    public var secondsToShowAnswer: Double = 0
    public var questionAction: AutoAdvanceQuestionAction = .showAnswer
    public var answerAction: AutoAdvanceAnswerAction = .buryCard
    public var waitForAudio: Bool = true

    // Áudio
    public var disableAutoplay: Bool = false
    public var skipQuestionWhenReplayingAnswer: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeckConfigData()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        newPerDay = v(.newPerDay, d.newPerDay)
        reviewsPerDay = v(.reviewsPerDay, d.reviewsPerDay)
        newCardsIgnoreReviewLimit = v(.newCardsIgnoreReviewLimit, d.newCardsIgnoreReviewLimit)
        learnSteps = v(.learnSteps, d.learnSteps)
        graduatingIntervalGood = v(.graduatingIntervalGood, d.graduatingIntervalGood)
        graduatingIntervalEasy = v(.graduatingIntervalEasy, d.graduatingIntervalEasy)
        newCardInsertOrder = v(.newCardInsertOrder, d.newCardInsertOrder)
        relearnSteps = v(.relearnSteps, d.relearnSteps)
        minimumLapseInterval = v(.minimumLapseInterval, d.minimumLapseInterval)
        leechThreshold = v(.leechThreshold, d.leechThreshold)
        leechAction = v(.leechAction, d.leechAction)
        newCardGatherPriority = v(.newCardGatherPriority, d.newCardGatherPriority)
        newCardSortOrder = v(.newCardSortOrder, d.newCardSortOrder)
        newMix = v(.newMix, d.newMix)
        interdayLearningMix = v(.interdayLearningMix, d.interdayLearningMix)
        reviewOrder = v(.reviewOrder, d.reviewOrder)
        buryNew = v(.buryNew, d.buryNew)
        buryReviews = v(.buryReviews, d.buryReviews)
        buryInterdayLearning = v(.buryInterdayLearning, d.buryInterdayLearning)
        desiredRetention = v(.desiredRetention, d.desiredRetention)
        fsrsParams = v(.fsrsParams, d.fsrsParams)
        paramSearch = v(.paramSearch, d.paramSearch)
        maximumReviewInterval = v(.maximumReviewInterval, d.maximumReviewInterval)
        initialEase = v(.initialEase, d.initialEase)
        easyMultiplier = v(.easyMultiplier, d.easyMultiplier)
        hardMultiplier = v(.hardMultiplier, d.hardMultiplier)
        intervalMultiplier = v(.intervalMultiplier, d.intervalMultiplier)
        lapseMultiplier = v(.lapseMultiplier, d.lapseMultiplier)
        easyDaysPercentages = v(.easyDaysPercentages, d.easyDaysPercentages)
        capAnswerTimeToSecs = v(.capAnswerTimeToSecs, d.capAnswerTimeToSecs)
        showTimer = v(.showTimer, d.showTimer)
        stopTimerOnAnswer = v(.stopTimerOnAnswer, d.stopTimerOnAnswer)
        secondsToShowQuestion = v(.secondsToShowQuestion, d.secondsToShowQuestion)
        secondsToShowAnswer = v(.secondsToShowAnswer, d.secondsToShowAnswer)
        questionAction = v(.questionAction, d.questionAction)
        answerAction = v(.answerAction, d.answerAction)
        waitForAudio = v(.waitForAudio, d.waitForAudio)
        disableAutoplay = v(.disableAutoplay, d.disableAutoplay)
        skipQuestionWhenReplayingAnswer = v(.skipQuestionWhenReplayingAnswer, d.skipQuestionWhenReplayingAnswer)
    }
}

public struct DeckConfig: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "deck_config"

    public var id: DeckConfigID
    public var name: String
    public var mtimeSecs: Int64
    public var usn: Int
    public var config: DeckConfigData

    enum CodingKeys: String, CodingKey { case id, name, mtimeSecs = "mtime_secs", usn, config }

    public init(id: DeckConfigID, name: String, mtimeSecs: Int64 = 0, usn: Int = -1,
                config: DeckConfigData = DeckConfigData()) {
        self.id = id; self.name = name; self.mtimeSecs = mtimeSecs; self.usn = usn; self.config = config
    }
}

// MARK: - Notetype

public enum NotetypeKind: Int, Codable, Sendable { case standard = 0, cloze = 1 }

/// Identifica os tipos de nota padrão (para localização e para o editor de Image Occlusion).
public enum StockNotetype: Int, Codable, Sendable, CaseIterable {
    case basic = 0, basicAndReversed, basicOptionalReversed, basicTyping, cloze, imageOcclusion
}

public struct NoteField: Codable, Sendable, Equatable, Identifiable {
    public var ord: Int
    public var name: String
    public var sticky: Bool
    public var rtl: Bool
    public var fontName: String
    public var fontSize: Int
    public var plainText: Bool
    public var description: String
    /// Rótulo estável usado pelos tipos padrão (ex.: campos do Image Occlusion).
    public var tag: Int?

    public var id: Int { ord }

    public init(ord: Int, name: String, sticky: Bool = false, rtl: Bool = false,
                fontName: String = "Arial", fontSize: Int = 20, plainText: Bool = false,
                description: String = "", tag: Int? = nil) {
        self.ord = ord; self.name = name; self.sticky = sticky; self.rtl = rtl
        self.fontName = fontName; self.fontSize = fontSize; self.plainText = plainText
        self.description = description; self.tag = tag
    }
}

public struct CardTemplate: Codable, Sendable, Equatable, Identifiable {
    public var ord: Int
    public var name: String
    public var qfmt: String
    public var afmt: String
    public var browserQfmt: String
    public var browserAfmt: String
    /// Baralho de destino opcional para cards gerados por este modelo (0 = nenhum).
    public var targetDeckID: DeckID

    public var id: Int { ord }

    public init(ord: Int, name: String, qfmt: String, afmt: String, browserQfmt: String = "",
                browserAfmt: String = "", targetDeckID: DeckID = 0) {
        self.ord = ord; self.name = name; self.qfmt = qfmt; self.afmt = afmt
        self.browserQfmt = browserQfmt; self.browserAfmt = browserAfmt; self.targetDeckID = targetDeckID
    }
}

public struct NotetypeConfig: Codable, Sendable, Equatable {
    public var kind: NotetypeKind = .standard
    public var sortFieldIdx: Int = 0
    public var css: String = Notetype.defaultCSS
    public var latexPre: String = Notetype.defaultLatexPre
    public var latexPost: String = "\\end{document}"
    public var latexSvg: Bool = false
    public var originalStockKind: StockNotetype?
    public var fields: [NoteField] = []
    public var templates: [CardTemplate] = []
    public init() {}
}

public struct Notetype: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "notetypes"

    public static let defaultCSS = """
    .card {
        font-family: arial;
        font-size: 20px;
        text-align: center;
        color: black;
        background-color: white;
    }
    """

    public static let defaultLatexPre = """
    \\documentclass[12pt]{article}
    \\special{papersize=3in,5in}
    \\usepackage[utf8]{inputenc}
    \\usepackage{amssymb,amsmath}
    \\pagestyle{empty}
    \\setlength{\\parindent}{0in}
    \\begin{document}
    """

    public var id: NotetypeID
    public var name: String
    public var mtimeSecs: Int64
    public var usn: Int
    public var config: NotetypeConfig

    enum CodingKeys: String, CodingKey { case id, name, mtimeSecs = "mtime_secs", usn, config }

    public init(id: NotetypeID, name: String, mtimeSecs: Int64 = 0, usn: Int = -1,
                config: NotetypeConfig = NotetypeConfig()) {
        self.id = id; self.name = name; self.mtimeSecs = mtimeSecs; self.usn = usn; self.config = config
    }

    public var fields: [NoteField] {
        get { config.fields }
        set { config.fields = newValue }
    }

    public var templates: [CardTemplate] {
        get { config.templates }
        set { config.templates = newValue }
    }

    public var isCloze: Bool { config.kind == .cloze }
    public var isImageOcclusion: Bool { config.originalStockKind == .imageOcclusion }
    public var fieldNames: [String] { fields.map(\.name) }
    public var css: String { config.css }

    public func fieldIndex(named name: String) -> Int? {
        fields.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Reatribui `ord` de campos e modelos conforme a posição no array.
    public mutating func renumber() {
        for i in config.fields.indices { config.fields[i].ord = i }
        for i in config.templates.indices { config.templates[i].ord = i }
        if config.sortFieldIdx >= config.fields.count { config.sortFieldIdx = 0 }
    }
}

// MARK: - Registros auxiliares

public struct TagRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tags"
    public var tag: String
    public var usn: Int
    public var collapsed: Bool
    public init(tag: String, usn: Int = -1, collapsed: Bool = false) {
        self.tag = tag; self.usn = usn; self.collapsed = collapsed
    }
}

public enum GraveKind: Int, Codable, Sendable { case card = 0, note = 1, deck = 2, notetype = 3, deckConfig = 4 }

public struct Grave: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "graves"
    public var oid: Int64
    public var type: GraveKind
    public var usn: Int
    public init(oid: Int64, type: GraveKind, usn: Int = -1) { self.oid = oid; self.type = type; self.usn = usn }
}

public struct ConfigEntry: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "config"
    public var key: String
    public var usn: Int
    public var mtimeSecs: Int64
    /// JSON.
    public var val: String

    enum CodingKeys: String, CodingKey { case key, usn, mtimeSecs = "mtime_secs", val }

    public init(key: String, usn: Int = -1, mtimeSecs: Int64, val: String) {
        self.key = key; self.usn = usn; self.mtimeSecs = mtimeSecs; self.val = val
    }
}

/// Metadados da coleção (linha única da tabela `col`).
public struct CollectionMeta: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "col"
    public var id: Int64
    /// Criação (epoch s), alinhada à hora de virada do dia.
    public var crt: Int64
    /// Última modificação (epoch ms).
    public var mod: Int64
    /// Última mudança de esquema (epoch ms).
    public var scm: Int64
    public var ver: Int
    public var usn: Int
    /// Última sincronização (epoch ms).
    public var ls: Int64
}
