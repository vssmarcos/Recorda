import Foundation
import GRDB
import RecordaCore
import RecordaScheduler
import RecordaSearch

public enum StatsPeriod: Int, Sendable, CaseIterable {
    case month, year, all

    /// Número de dias coberto (`nil` = todo o histórico).
    public var days: Int? {
        switch self {
        case .month: return 31
        case .year: return 365
        case .all: return nil
        }
    }
}

public enum StatsScope: Sendable, Equatable {
    case collection
    case deck(DeckID)
    case search(String)
}

public struct TodayStats: Sendable, Equatable {
    public var answers = 0
    public var seconds = 0.0
    public var againCount = 0
    public var learning = 0
    public var review = 0
    public var relearning = 0
    public var filtered = 0
    public var matureTotal = 0
    public var matureCorrect = 0

    public var correctRate: Double? { answers > 0 ? Double(answers - againCount) / Double(answers) : nil }
    public var matureRate: Double? { matureTotal > 0 ? Double(matureCorrect) / Double(matureTotal) : nil }
}

public struct ForecastDay: Sendable, Equatable, Identifiable {
    /// 0 = hoje (inclui atrasados), 1 = amanhã…
    public var day: Int
    public var young: Int
    public var mature: Int
    public var id: Int { day }
    public var total: Int { young + mature }
}

public struct ReviewDay: Sendable, Equatable, Identifiable {
    /// 0 = hoje, -1 = ontem…
    public var day: Int
    public var learning = 0
    public var relearning = 0
    public var young = 0
    public var mature = 0
    public var filtered = 0
    public var seconds = 0.0
    public var id: Int { day }
    public var total: Int { learning + relearning + young + mature + filtered }
}

public struct CardCountStats: Sendable, Equatable {
    public var new = 0
    public var learning = 0
    public var relearning = 0
    public var young = 0
    public var mature = 0
    public var suspended = 0
    public var buried = 0
    public var total: Int { new + learning + relearning + young + mature + suspended + buried }
}

public struct HistogramBin: Sendable, Equatable, Identifiable {
    /// Limite inferior da faixa.
    public var lower: Double
    public var upper: Double
    public var count: Int
    public var id: Double { lower }
}

public struct Histogram: Sendable, Equatable {
    public var bins: [HistogramBin]
    public var average: Double?
    public var median: Double?
    public var count: Int
}

public struct HourStats: Sendable, Equatable, Identifiable {
    public var hour: Int
    public var total: Int
    public var correct: Int
    public var id: Int { hour }
    public var correctRate: Double { total > 0 ? Double(correct) / Double(total) : 0 }
}

public struct ButtonStats: Sendable, Equatable, Identifiable {
    public enum Group: Int, Sendable, CaseIterable { case learning, young, mature }
    public var group: Group
    /// 1 Errei … 4 Fácil.
    public var ease: Int
    public var count: Int
    public var id: Int { group.rawValue * 10 + ease }
}

public struct RetentionRow: Sendable, Equatable, Identifiable {
    public enum Span: Int, Sendable, CaseIterable { case today, yesterday, week, month, year, all }
    public var span: Span
    public var youngPassed = 0
    public var youngFailed = 0
    public var maturePassed = 0
    public var matureFailed = 0
    public var id: Int { span.rawValue }

    public var youngRate: Double? { rate(youngPassed, youngFailed) }
    public var matureRate: Double? { rate(maturePassed, matureFailed) }
    public var totalRate: Double? { rate(youngPassed + maturePassed, youngFailed + matureFailed) }

    private func rate(_ passed: Int, _ failed: Int) -> Double? {
        passed + failed > 0 ? Double(passed) / Double(passed + failed) : nil
    }
}

public struct AddedDay: Sendable, Equatable, Identifiable {
    public var day: Int
    public var count: Int
    public var id: Int { day }
}

public struct CollectionStats: Sendable, Equatable {
    public var today = TodayStats()
    public var forecast: [ForecastDay] = []
    /// Revisões que vencem amanhã.
    public var dueTomorrow = 0
    public var reviews: [ReviewDay] = []
    /// Dia → número de respostas, para o calendário (últimos 365 dias).
    public var calendar: [Int: Int] = [:]
    public var counts = CardCountStats()
    public var intervals = Histogram(bins: [], average: nil, median: nil, count: 0)
    public var ease = Histogram(bins: [], average: nil, median: nil, count: 0)
    public var difficulty = Histogram(bins: [], average: nil, median: nil, count: 0)
    public var stability = Histogram(bins: [], average: nil, median: nil, count: 0)
    public var retrievability = Histogram(bins: [], average: nil, median: nil, count: 0)
    public var hours: [HourStats] = []
    public var buttons: [ButtonStats] = []
    public var retention: [RetentionRow] = []
    public var added: [AddedDay] = []
    public var fsrsEnabled = false
    /// Dias estudados e sequência atual.
    public var daysStudied = 0
    public var currentStreak = 0
    public var longestStreak = 0
}

public struct CardInfo: Sendable, Equatable {
    public var card: Card
    public var noteID: NoteID
    public var deckName: String
    public var originalDeckName: String?
    public var notetypeName: String
    public var templateName: String
    public var sortField: String
    public var added: Date
    public var firstReview: Date?
    public var latestReview: Date?
    /// Data de vencimento (revisão/aprendizado) ou `nil` para cards novos.
    public var due: Date?
    public var newPosition: Int?
    public var averageSeconds: Double
    public var totalSeconds: Double
    public var stability: Double?
    public var difficulty: Double?
    public var retrievability: Double?
    public var revlog: [RevlogEntry]
}

extension Txn {

    // MARK: Escopo

    private func cardFilter(_ scope: StatsScope) throws -> (sql: String, arguments: [DatabaseValue]) {
        switch scope {
        case .collection:
            return ("1", [])
        case .deck(let id):
            let ids = Txn.idList(try deckAndChildIDs(id))
            return ("(c.did IN (\(ids)) OR c.odid IN (\(ids)))", [])
        case .search(let query):
            let sql = try searchSQL(query)
            return (sql.whereClause, sql.arguments)
        }
    }

    private static func histogram(_ values: [Double], binWidth: Double, minimum: Double? = nil, maximum: Double? = nil) -> Histogram {
        guard !values.isEmpty else { return Histogram(bins: [], average: nil, median: nil, count: 0) }
        let sorted = values.sorted()
        let low = minimum ?? (sorted[0] / binWidth).rounded(.down) * binWidth
        let high = maximum ?? sorted[sorted.count - 1]
        let binCount = max(1, min(400, Int(((high - low) / binWidth).rounded(.down)) + 1))
        var counts = [Int](repeating: 0, count: binCount)
        for value in sorted {
            let index = min(binCount - 1, max(0, Int(((value - low) / binWidth).rounded(.down))))
            counts[index] += 1
        }
        let bins = counts.enumerated().map { index, count in
            HistogramBin(lower: low + Double(index) * binWidth, upper: low + Double(index + 1) * binWidth, count: count)
        }
        let average = sorted.reduce(0, +) / Double(sorted.count)
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return Histogram(bins: bins, average: average, median: median, count: sorted.count)
    }

    /// Escolhe uma largura de faixa que resulte em um número razoável de barras.
    private static func niceBinWidth(maximum: Double, targetBins: Int = 40) -> Double {
        let raw = max(maximum, 1) / Double(targetBins)
        for step in [1.0, 2, 5, 7, 10, 14, 30, 60, 90, 180, 365] where step >= raw { return step }
        return 365
    }

    // MARK: Estatísticas

    public func stats(scope: StatsScope, period: StatsPeriod) throws -> CollectionStats {
        var stats = CollectionStats()
        let timing = try self.timing()
        let today = timing.today
        let filter = try cardFilter(scope)
        let filterArgs = StatementArguments(filter.arguments)
        let scoped = filter.sql != "1"
        let revlogScope = scoped ? "AND r.cid IN (SELECT c.id FROM cards c JOIN notes n ON n.id = c.nid WHERE \(filter.sql))" : ""
        let dayExpr = "(-((\(timing.nextDayAt) - r.id / 1000 - 1) / 86400))"
        let fsrsOn = try fsrsEnabled()
        stats.fsrsEnabled = fsrsOn
        let periodDays = period.days
        let decay = try searchContext().fsrsDecay

        // --- Hoje ---
        let todayStartMs = (timing.nextDayAt - 86_400) * 1000
        if let row = try Row.fetchOne(db, sql: """
            SELECT count(*) AS n, COALESCE(sum(r.time), 0) AS ms,
                COALESCE(sum(r.ease = 1), 0) AS again,
                COALESCE(sum(r.type = 0), 0) AS lrn, COALESCE(sum(r.type = 1), 0) AS rev,
                COALESCE(sum(r.type = 2), 0) AS relrn, COALESCE(sum(r.type = 3), 0) AS filt,
                COALESCE(sum(r.type = 1 AND r.lastIvl >= 21), 0) AS mtotal,
                COALESCE(sum(r.type = 1 AND r.lastIvl >= 21 AND r.ease > 1), 0) AS mcorrect
            FROM revlog r WHERE r.id >= ? AND r.ease > 0 \(revlogScope)
            """, arguments: [todayStartMs] + filterArgs) {
            stats.today = TodayStats(answers: row["n"], seconds: Double(row["ms"] as Int) / 1000.0, againCount: row["again"],
                                     learning: row["lrn"], review: row["rev"], relearning: row["relrn"], filtered: row["filt"],
                                     matureTotal: row["mtotal"], matureCorrect: row["mcorrect"])
        }

        // --- Previsão de vencimentos ---
        let realDue = "(CASE WHEN c.odid != 0 AND c.odue != 0 THEN c.odue ELSE c.due END)"
        let horizon = periodDays ?? 36_500
        let forecastRows = try Row.fetchAll(db, sql: """
            SELECT max(0, \(realDue) - \(today)) AS d, sum(c.ivl < 21) AS y, sum(c.ivl >= 21) AS m
            FROM cards c JOIN notes n ON n.id = c.nid
            WHERE c.queue IN (2, 3) AND \(realDue) - \(today) <= ? AND (\(filter.sql))
            GROUP BY d ORDER BY d
            """, arguments: [horizon] + filterArgs)
        stats.forecast = forecastRows.map { ForecastDay(day: $0["d"], young: $0["y"] ?? 0, mature: $0["m"] ?? 0) }
        stats.dueTomorrow = stats.forecast.first(where: { $0.day == 1 })?.total ?? 0

        // --- Revisões por dia ---
        let earliestDay = periodDays.map { -($0 - 1) } ?? -100_000
        let reviewRows = try Row.fetchAll(db, sql: """
            SELECT \(dayExpr) AS d,
                sum(r.type = 0) AS lrn, sum(r.type = 2) AS relrn,
                sum(r.type = 1 AND r.lastIvl < 21) AS young, sum(r.type = 1 AND r.lastIvl >= 21) AS mature,
                sum(r.type = 3) AS filt, sum(r.time) AS ms
            FROM revlog r WHERE r.ease > 0 \(revlogScope)
            GROUP BY d HAVING d >= ? ORDER BY d
            """, arguments: filterArgs + [earliestDay])
        stats.reviews = reviewRows.map { row in
            ReviewDay(day: row["d"], learning: row["lrn"] ?? 0, relearning: row["relrn"] ?? 0, young: row["young"] ?? 0,
                      mature: row["mature"] ?? 0, filtered: row["filt"] ?? 0, seconds: Double(row["ms"] as Int? ?? 0) / 1000.0)
        }

        // --- Calendário e sequências (sempre o histórico inteiro do escopo) ---
        let calendarRows = try Row.fetchAll(db, sql: """
            SELECT \(dayExpr) AS d, count(*) AS n FROM revlog r WHERE r.ease > 0 \(revlogScope) GROUP BY d ORDER BY d
            """, arguments: filterArgs)
        var studiedDays: [Int] = []
        for row in calendarRows {
            let day: Int = row["d"]
            studiedDays.append(day)
            if day > -366 { stats.calendar[day] = row["n"] }
        }
        stats.daysStudied = studiedDays.count
        var longest = 0, run = 0
        var previous: Int?
        for day in studiedDays {
            if let previous, day == previous + 1 { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previous = day
        }
        stats.longestStreak = longest
        // A sequência atual conta até hoje ou, se hoje ainda não houve estudo, até ontem.
        let studiedSet = Set(studiedDays)
        var cursor = studiedSet.contains(0) ? 0 : -1
        var streak = 0
        while studiedSet.contains(cursor) {
            streak += 1
            cursor -= 1
        }
        stats.currentStreak = streak

        // --- Contagem de cards ---
        if let row = try Row.fetchOne(db, sql: """
            SELECT
                COALESCE(sum(c.queue >= 0 AND c.type = 0), 0) AS new,
                COALESCE(sum(c.queue >= 0 AND c.type = 1), 0) AS lrn,
                COALESCE(sum(c.queue >= 0 AND c.type = 3), 0) AS relrn,
                COALESCE(sum(c.queue >= 0 AND c.type = 2 AND c.ivl < 21), 0) AS young,
                COALESCE(sum(c.queue >= 0 AND c.type = 2 AND c.ivl >= 21), 0) AS mature,
                COALESCE(sum(c.queue = -1), 0) AS susp,
                COALESCE(sum(c.queue IN (-2, -3)), 0) AS buried
            FROM cards c JOIN notes n ON n.id = c.nid WHERE \(filter.sql)
            """, arguments: filterArgs) {
            stats.counts = CardCountStats(new: row["new"], learning: row["lrn"], relearning: row["relrn"], young: row["young"],
                                          mature: row["mature"], suspended: row["susp"], buried: row["buried"])
        }

        // --- Intervalos, facilidade, FSRS ---
        let reviewCards = try Row.fetchAll(db, sql: """
            SELECT c.ivl, c.factor, c.data, \(realDue) AS due FROM cards c JOIN notes n ON n.id = c.nid
            WHERE c.type = 2 AND c.queue != -1 AND (\(filter.sql))
            """, arguments: filterArgs)
        var intervals: [Double] = [], eases: [Double] = [], difficulties: [Double] = [], stabilities: [Double] = [], recalls: [Double] = []
        for row in reviewCards {
            let ivl: Int = row["ivl"]
            intervals.append(Double(ivl))
            let factor: Int = row["factor"]
            if factor > 0 { eases.append(Double(factor) / 10.0) }
            let dataText: String = row["data"] ?? ""
            if !dataText.isEmpty {
                let data = CardData.decode(dataText)
                if let s = data.s, let d = data.d, s > 0 {
                    stabilities.append(s)
                    difficulties.append((d - 1.0) / 9.0 * 100.0)
                    let due: Int64 = row["due"]
                    let elapsed = Double(max(0, today - (Int(due) - ivl)))
                    recalls.append(pow(1.0 + (pow(0.9, -1.0 / decay) - 1.0) * elapsed / s, -decay) * 100.0)
                }
            }
        }
        let intervalCap = period == .all ? (intervals.max() ?? 0) : Double(periodDays ?? 365)
        let shownIntervals = intervals.filter { $0 <= intervalCap }
        stats.intervals = Txn.histogram(shownIntervals, binWidth: Txn.niceBinWidth(maximum: shownIntervals.max() ?? 1), minimum: 0)
        if !intervals.isEmpty {
            // Média e mediana consideram todos os cards, não só os exibidos.
            let all = Txn.histogram(intervals, binWidth: 1, minimum: 0)
            stats.intervals.average = all.average
            stats.intervals.median = all.median
            stats.intervals.count = all.count
        }
        stats.ease = Txn.histogram(eases, binWidth: 10, minimum: 130)
        stats.difficulty = Txn.histogram(difficulties, binWidth: 5, minimum: 0, maximum: 100)
        let stabilityCap = period == .all ? (stabilities.max() ?? 0) : Double(periodDays ?? 365)
        let shownStabilities = stabilities.filter { $0 <= stabilityCap }
        stats.stability = Txn.histogram(shownStabilities, binWidth: Txn.niceBinWidth(maximum: shownStabilities.max() ?? 1), minimum: 0)
        stats.retrievability = Txn.histogram(recalls, binWidth: 5, minimum: 0, maximum: 100)

        // --- Por hora ---
        let cutoffMs = periodDays.map { (timing.nextDayAt - Int64($0) * 86_400) * 1000 } ?? 0
        let zoneOffset = collection.clock.timeZone().secondsFromGMT(for: now)
        let hourRows = try Row.fetchAll(db, sql: """
            SELECT ((r.id / 1000 + ?) / 3600) % 24 AS h, count(*) AS n, sum(r.ease > 1) AS ok
            FROM revlog r WHERE r.id > ? AND r.ease > 0 AND r.type IN (0, 1, 2) \(revlogScope) GROUP BY h
            """, arguments: [zoneOffset, cutoffMs] + filterArgs)
        var hourMap: [Int: HourStats] = [:]
        for row in hourRows {
            let hour: Int = row["h"]
            hourMap[hour] = HourStats(hour: hour, total: row["n"], correct: row["ok"] ?? 0)
        }
        stats.hours = (0..<24).map { hourMap[$0] ?? HourStats(hour: $0, total: 0, correct: 0) }

        // --- Botões ---
        let buttonRows = try Row.fetchAll(db, sql: """
            SELECT (CASE WHEN r.type IN (0, 2) THEN 0 WHEN r.lastIvl < 21 THEN 1 ELSE 2 END) AS g, r.ease AS e, count(*) AS n
            FROM revlog r WHERE r.id > ? AND r.ease BETWEEN 1 AND 4 AND r.type IN (0, 1, 2) \(revlogScope) GROUP BY g, e
            """, arguments: [cutoffMs] + filterArgs)
        var buttonMap: [Int: Int] = [:]
        for row in buttonRows {
            let group: Int = row["g"]
            let ease: Int = row["e"]
            buttonMap[group * 10 + ease] = row["n"]
        }
        for group in ButtonStats.Group.allCases {
            for ease in 1...4 {
                stats.buttons.append(ButtonStats(group: group, ease: ease, count: buttonMap[group.rawValue * 10 + ease] ?? 0))
            }
        }

        // --- Retenção real ---
        for span in RetentionRow.Span.allCases {
            let from: Int64
            var to = Int64.max
            switch span {
            case .today: from = todayStartMs
            case .yesterday:
                from = todayStartMs - 86_400_000
                to = todayStartMs
            case .week: from = todayStartMs - 6 * 86_400_000
            case .month: from = todayStartMs - 29 * 86_400_000
            case .year: from = todayStartMs - 364 * 86_400_000
            case .all: from = 0
            }
            var item = RetentionRow(span: span)
            if let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(sum(r.lastIvl < 21 AND r.ease > 1), 0) AS yp, COALESCE(sum(r.lastIvl < 21 AND r.ease = 1), 0) AS yf,
                    COALESCE(sum(r.lastIvl >= 21 AND r.ease > 1), 0) AS mp, COALESCE(sum(r.lastIvl >= 21 AND r.ease = 1), 0) AS mf
                FROM revlog r WHERE r.type = 1 AND r.ease > 0 AND r.id >= ? AND r.id < ? \(revlogScope)
                """, arguments: [from, to] + filterArgs) {
                item.youngPassed = row["yp"]
                item.youngFailed = row["yf"]
                item.maturePassed = row["mp"]
                item.matureFailed = row["mf"]
            }
            stats.retention.append(item)
        }

        // --- Cards adicionados ---
        let addedRows = try Row.fetchAll(db, sql: """
            SELECT (-((\(timing.nextDayAt) - c.id / 1000 - 1) / 86400)) AS d, count(*) AS n
            FROM cards c JOIN notes n ON n.id = c.nid WHERE (\(filter.sql)) GROUP BY d HAVING d >= ? AND d <= 0 ORDER BY d
            """, arguments: filterArgs + [earliestDay])
        stats.added = addedRows.map { AddedDay(day: $0["d"], count: $0["n"]) }

        return stats
    }

    // MARK: Informações do card

    public func cardInfo(_ cardID: CardID) throws -> CardInfo {
        let card = try self.card(cardID)
        let note = try self.note(card.nid)
        let timing = try self.timing()
        let notetype = try notetypeIfExists(note.mid)
        let deck = try deckIfExists(card.did)
        let original: Deck? = try card.odid != 0 ? deckIfExists(card.odid) : nil
        let revlog = try RevlogEntry.filter(sql: "cid = ?", arguments: [cardID]).order(sql: "id").fetchAll(db)
        let answers = revlog.filter { $0.ease > 0 }
        let totalMs = answers.reduce(0) { $0 + $1.time }

        var templateName = "Card \(card.ord + 1)"
        if let notetype {
            if notetype.isCloze {
                templateName = "Omissão \(card.ord + 1)"
            } else if notetype.templates.indices.contains(card.ord) {
                templateName = notetype.templates[card.ord].name
            }
        }

        var due: Date?
        var position: Int?
        let realDue = card.odid != 0 && card.odue != 0 ? card.odue : card.due
        switch card.type {
        case .new:
            position = Int(realDue)
        case .review:
            due = timing.date(forDay: Int(realDue))
        case .learning, .relearning:
            due = realDue > 1_000_000_000 ? Date(timeIntervalSince1970: TimeInterval(realDue)) : timing.date(forDay: Int(realDue))
        }

        let data = card.cardData
        var retrievability: Double?
        if card.type == .review, let s = data.s, s > 0 {
            let preset = try deckConfig(forDeck: card.homeDeckID)
            let fsrs = FSRS(parameters: preset.config.fsrsParams)
            let elapsed = Double(max(0, timing.today - (Int(realDue) - card.ivl)))
            retrievability = fsrs.retrievability(elapsedDays: elapsed, stability: s)
        }

        return CardInfo(
            card: card, noteID: note.id, deckName: deck?.name ?? "", originalDeckName: original?.name,
            notetypeName: notetype?.name ?? "", templateName: templateName, sortField: note.sfld,
            added: Date(timeIntervalSince1970: TimeInterval(card.id) / 1000),
            firstReview: answers.first.map { Date(timeIntervalSince1970: TimeInterval($0.id) / 1000) },
            latestReview: answers.last.map { Date(timeIntervalSince1970: TimeInterval($0.id) / 1000) },
            due: due, newPosition: position,
            averageSeconds: answers.isEmpty ? 0 : Double(totalMs) / Double(answers.count) / 1000.0,
            totalSeconds: Double(totalMs) / 1000.0,
            stability: data.s, difficulty: data.d, retrievability: retrievability, revlog: revlog)
    }
}
