import Foundation
import GRDB

extension Card {
    /// Fila correspondente ao tipo do card quando ele não está suspenso/enterrado.
    public var naturalQueue: CardQueue {
        switch type {
        case .new: return .new
        case .review: return .review
        case .learning, .relearning: return due > 1_000_000_000 ? .learning : .dayLearning
        }
    }

    /// Devolve o card ao baralho de origem, restaurando o vencimento original.
    public mutating func removeFromFilteredDeck() {
        guard odid != 0 else { return }
        did = odid
        if odue != 0 { due = odue }
        odid = 0
        odue = 0
        if queue.rawValue >= 0 { queue = naturalQueue }
    }
}

extension Deck {
    /// Normaliza um nome de baralho: remove espaços e níveis vazios.
    public static func normalizedName(_ raw: String) -> String {
        raw.components(separatedBy: Deck.separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: Deck.separator)
    }

    /// Ordenação hierárquica, sem diferenciar maiúsculas.
    public static func hierarchicalOrder(_ a: Deck, _ b: Deck) -> Bool {
        let ca = a.components, cb = b.components
        for (x, y) in zip(ca, cb) {
            let result = x.localizedCaseInsensitiveCompare(y)
            if result != .orderedSame { return result == .orderedAscending }
        }
        return ca.count < cb.count
    }
}

extension Txn {

    // MARK: Leitura

    public func allDecks() throws -> [Deck] {
        try Deck.fetchAll(db).sorted(by: Deck.hierarchicalOrder)
    }

    public func deck(_ id: DeckID) throws -> Deck {
        guard let deck = try Deck.fetchOne(db, key: id) else { throw CollectionError.notFound("baralho \(id)") }
        return deck
    }

    public func deckIfExists(_ id: DeckID) throws -> Deck? { try Deck.fetchOne(db, key: id) }

    public func deck(named name: String) throws -> Deck? {
        try Deck.filter(sql: "name = ? COLLATE NOCASE", arguments: [Deck.normalizedName(name)]).fetchOne(db)
    }

    /// O baralho e todos os seus descendentes.
    public func deckAndChildren(_ id: DeckID) throws -> [Deck] {
        let root = try deck(id)
        let children = try Deck.filter(sql: "name LIKE ? ESCAPE '\\'",
                                       arguments: [Txn.escapeLike(root.name) + Deck.separator + "%"]).fetchAll(db)
        return [root] + children.sorted(by: Deck.hierarchicalOrder)
    }

    public func deckAndChildIDs(_ id: DeckID) throws -> [DeckID] {
        try deckAndChildren(id).map(\.id)
    }

    /// Ancestrais, do mais próximo da raiz ao pai imediato.
    public func parents(of deck: Deck) throws -> [Deck] {
        var result: [Deck] = []
        let parts = deck.components
        guard parts.count > 1 else { return [] }
        for depth in 1..<parts.count {
            let name = parts.prefix(depth).joined(separator: Deck.separator)
            if let parent = try self.deck(named: name) { result.append(parent) }
        }
        return result
    }

    public func currentDeckID() throws -> DeckID {
        if let id: DeckID = try config(ConfigKey.currentDeck), try deckIfExists(id) != nil { return id }
        return try Int64.fetchOne(db, sql: "SELECT id FROM decks ORDER BY id LIMIT 1") ?? 1
    }

    public func setCurrentDeck(_ id: DeckID) throws {
        try setConfig(ConfigKey.currentDeck, id)
    }

    // MARK: Criar / gravar

    public func saveDeck(_ deck: inout Deck) throws {
        deck.mtimeSecs = nowSecs
        deck.usn = -1
        try deck.save(db)
    }

    /// Garante que todos os ancestrais de `name` existam.
    private func ensureParents(of name: String) throws {
        let parts = name.components(separatedBy: Deck.separator)
        guard parts.count > 1 else { return }
        for depth in 1..<parts.count {
            let parentName = parts.prefix(depth).joined(separator: Deck.separator)
            if let parent = try deck(named: parentName) {
                if parent.isFiltered { throw CollectionError.filteredDeckCannotHaveChildren }
            } else {
                var parent = Deck(id: try nextID(in: "decks"), name: parentName)
                try saveDeck(&parent)
            }
        }
    }

    /// Cria um baralho novo. Lança erro se o nome já existir.
    @discardableResult
    public func addDeck(named rawName: String, filtered: FilteredDeck? = nil) throws -> Deck {
        let name = Deck.normalizedName(rawName)
        guard !name.isEmpty else { throw CollectionError.invalidInput("O nome do baralho não pode ficar vazio.") }
        if try deck(named: name) != nil { throw CollectionError.deckNameExists(name) }
        try ensureParents(of: name)
        var created = Deck(id: try nextID(in: "decks"), name: name)
        if let filtered { created.kind = .filtered(filtered) }
        try saveDeck(&created)
        return created
    }

    /// Devolve o baralho com esse nome, criando-o (e os ancestrais) se preciso.
    public func getOrCreateDeck(named rawName: String) throws -> Deck {
        let name = Deck.normalizedName(rawName)
        if let existing = try deck(named: name) { return existing }
        return try addDeck(named: name.isEmpty ? "Padrão" : name)
    }

    /// Nome livre a partir de uma base ("Sessão filtrada", "Sessão filtrada 2"...).
    public func availableDeckName(_ base: String) throws -> String {
        var candidate = base
        var suffix = 2
        while try deck(named: candidate) != nil {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    // MARK: Renomear / mover

    public func renameDeck(_ id: DeckID, to rawName: String) throws {
        let newName = Deck.normalizedName(rawName)
        guard !newName.isEmpty else { throw CollectionError.invalidInput("O nome do baralho não pode ficar vazio.") }
        let family = try deckAndChildren(id)
        guard var root = family.first else { return }
        let oldName = root.name
        if oldName == newName { return }
        if newName.lowercased().hasPrefix(oldName.lowercased() + Deck.separator) {
            throw CollectionError.invalidInput("Um baralho não pode ser movido para dentro de si mesmo.")
        }
        if let clash = try deck(named: newName), clash.id != id { throw CollectionError.deckNameExists(newName) }
        try ensureParents(of: newName)
        root.name = newName
        try saveDeck(&root)
        for var child in family.dropFirst() {
            child.name = newName + child.name.dropFirst(oldName.count)
            try saveDeck(&child)
        }
    }

    /// Move o baralho para dentro de `parentID` (ou para a raiz, com `nil`).
    public func reparentDeck(_ id: DeckID, under parentID: DeckID?) throws {
        let moving = try self.deck(id)
        var newName = moving.shortName
        if let parentID {
            let parent = try self.deck(parentID)
            if parent.isFiltered { throw CollectionError.filteredDeckCannotHaveChildren }
            if parent.id == id || parent.isDescendant(ofName: moving.name) {
                throw CollectionError.invalidInput("Um baralho não pode ser movido para dentro de si mesmo.")
            }
            newName = parent.name + Deck.separator + moving.shortName
        }
        if newName.caseInsensitiveCompare(moving.name) == .orderedSame { return }
        try renameDeck(id, to: newName)
    }

    // MARK: Excluir

    /// Exclui o baralho, seus sub-baralhos e os cards contidos.
    /// Cards em baralhos filtrados voltam para a origem em vez de serem excluídos.
    public func removeDeck(_ id: DeckID) throws {
        let family = try deckAndChildren(id)
        for deck in family {
            if deck.isFiltered {
                try emptyFilteredDeck(deck.id)
            } else {
                let cardIDs = try Int64.fetchAll(db, sql: "SELECT id FROM cards WHERE did = ? OR odid = ?",
                                                 arguments: [deck.id, deck.id])
                try removeCards(cardIDs)
            }
            try db.execute(sql: "DELETE FROM decks WHERE id = ?", arguments: [deck.id])
            try addGrave(deck.id, .deck)
        }
        if try Deck.fetchCount(db) == 0 {
            var fallback = Deck(id: 1, name: "Padrão")
            try saveDeck(&fallback)
        }
    }

    /// Devolve todos os cards de um baralho filtrado aos baralhos de origem.
    public func emptyFilteredDeck(_ id: DeckID) throws {
        let cards = try Card.filter(sql: "did = ? AND odid != 0", arguments: [id]).fetchAll(db)
        for var card in cards {
            card.removeFromFilteredDeck()
            try saveCard(&card)
        }
    }

    /// Move cards para outro baralho (tirando-os de baralhos filtrados, se for o caso).
    public func moveCards(_ ids: [CardID], toDeck deckID: DeckID) throws {
        let target = try deck(deckID)
        guard !target.isFiltered else {
            throw CollectionError.invalidInput("Não é possível mover cards manualmente para um baralho filtrado.")
        }
        for chunk in ids.chunked(500) {
            let cards = try Card.filter(sql: "id IN (\(Txn.idList(chunk)))").fetchAll(db)
            for var card in cards {
                card.removeFromFilteredDeck()
                if card.did == deckID {
                    try saveCard(&card)
                    continue
                }
                card.did = deckID
                try saveCard(&card)
            }
        }
    }

    public func cardCount(inDeckTree id: DeckID) throws -> Int {
        let ids = try deckAndChildIDs(id)
        return try Int.fetchOne(db, sql: "SELECT count(*) FROM cards WHERE did IN (\(Txn.idList(ids)))") ?? 0
    }

    // MARK: Predefinições

    public func allDeckConfigs() throws -> [DeckConfig] {
        try DeckConfig.order(sql: "name COLLATE NOCASE").fetchAll(db)
    }

    public func deckConfig(_ id: DeckConfigID) throws -> DeckConfig {
        if let config = try DeckConfig.fetchOne(db, key: id) { return config }
        if let fallback = try DeckConfig.fetchOne(db, key: 1) { return fallback }
        var created = DeckConfig(id: 1, name: "Padrão")
        try saveDeckConfig(&created)
        return created
    }

    /// Predefinição em vigor para um baralho. Baralhos filtrados usam a do baralho de origem de cada card;
    /// quando chamado diretamente com um filtrado, devolve a predefinição padrão.
    public func deckConfig(forDeck deckID: DeckID) throws -> DeckConfig {
        if let deck = try deckIfExists(deckID), let configID = deck.configID {
            return try deckConfig(configID)
        }
        return try deckConfig(1)
    }

    public func saveDeckConfig(_ config: inout DeckConfig) throws {
        if config.id == 0 { config.id = try nextID(in: "deck_config") }
        config.mtimeSecs = nowSecs
        config.usn = -1
        try config.save(db)
    }

    @discardableResult
    public func addDeckConfig(named name: String, cloning source: DeckConfigID? = nil) throws -> DeckConfig {
        var config = DeckConfig(id: 0, name: name)
        if let source { config.config = try deckConfig(source).config }
        try saveDeckConfig(&config)
        return config
    }

    /// Remove a predefinição; os baralhos que a usavam passam para a padrão.
    public func removeDeckConfig(_ id: DeckConfigID) throws {
        guard id != 1 else { throw CollectionError.invalidInput("A predefinição padrão não pode ser excluída.") }
        for var deck in try Deck.fetchAll(db) where deck.configID == id {
            deck.normal?.configID = 1
            try saveDeck(&deck)
        }
        try db.execute(sql: "DELETE FROM deck_config WHERE id = ?", arguments: [id])
        try addGrave(id, .deckConfig)
        try markSchemaModified()
    }

    public func setDeckConfig(_ configID: DeckConfigID, forDecks deckIDs: [DeckID]) throws {
        for id in deckIDs {
            var target = try self.deck(id)
            guard target.normal != nil else { continue }
            target.normal?.configID = configID
            try saveDeck(&target)
        }
    }

    /// Quantos baralhos usam cada predefinição.
    public func deckConfigUsage() throws -> [DeckConfigID: Int] {
        var usage: [DeckConfigID: Int] = [:]
        for deck in try Deck.fetchAll(db) {
            if let id = deck.configID { usage[id, default: 0] += 1 }
        }
        return usage
    }
}
