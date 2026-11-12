import Foundation

public indirect enum TemplateNode: Sendable, Equatable {
    case text(String)
    /// `{{filtro2:filtro1:Campo}}` — `filters` na ordem em que aparecem (o mais à direita é aplicado primeiro).
    case replacement(key: String, filters: [String])
    case conditional(key: String, children: [TemplateNode])
    case negated(key: String, children: [TemplateNode])
}

public enum TemplateError: Error, Equatable, Sendable, CustomStringConvertible {
    case unclosedTag(String)
    case conditionalNotClosed(String)
    case conditionalNotOpen(String)
    case mismatchedClose(expected: String, found: String)

    public var description: String {
        switch self {
        case .unclosedTag(let t): return "Tag não fechada: {{\(t)"
        case .conditionalNotClosed(let t): return "Faltou {{/\(t)}}"
        case .conditionalNotOpen(let t): return "{{/\(t)}} sem abertura correspondente"
        case .mismatchedClose(let expected, let found): return "Esperava {{/\(expected)}}, encontrou {{/\(found)}}"
        }
    }
}

public struct ParsedTemplate: Sendable, Equatable {
    public let nodes: [TemplateNode]

    public init(nodes: [TemplateNode]) { self.nodes = nodes }

    public init(_ source: String) throws {
        let tokens = try ParsedTemplate.tokenize(source)
        var index = 0
        self.nodes = try ParsedTemplate.parse(tokens, &index, open: nil)
    }

    // MARK: Tokenização

    enum Token: Equatable {
        case text(String)
        case replacement(String)
        case open(String)
        case openNegated(String)
        case close(String)
    }

    static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        var rest = Substring(source)
        var pendingText = ""

        func flushText() {
            if !pendingText.isEmpty {
                tokens.append(.text(pendingText))
                pendingText = ""
            }
        }

        while !rest.isEmpty {
            // Comentários HTML passam intactos (handlebars dentro deles não são interpretados).
            if rest.hasPrefix("<!--") {
                if let end = rest.range(of: "-->") {
                    pendingText += rest[rest.startIndex..<end.upperBound]
                    rest = rest[end.upperBound...]
                } else {
                    pendingText += rest
                    rest = Substring()
                }
                continue
            }
            if rest.hasPrefix("{{") {
                guard let end = rest.range(of: "}}") else {
                    throw TemplateError.unclosedTag(String(rest.dropFirst(2).prefix(30)))
                }
                var body = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound])
                var after = rest[end.upperBound...]
                // Sintaxe legada {{{Campo}}}.
                if body.hasPrefix("{") && after.hasPrefix("}") {
                    body.removeFirst()
                    after = after.dropFirst()
                }
                rest = after
                body = body.trimmingCharacters(in: .whitespacesAndNewlines)
                flushText()
                if body.hasPrefix("#") {
                    tokens.append(.open(String(body.dropFirst()).trimmingCharacters(in: .whitespaces)))
                } else if body.hasPrefix("^") {
                    tokens.append(.openNegated(String(body.dropFirst()).trimmingCharacters(in: .whitespaces)))
                } else if body.hasPrefix("/") {
                    tokens.append(.close(String(body.dropFirst()).trimmingCharacters(in: .whitespaces)))
                } else {
                    tokens.append(.replacement(body))
                }
                continue
            }
            // Avança até o próximo ponto de interesse.
            let nextBrace = rest.range(of: "{{")?.lowerBound
            let nextComment = rest.range(of: "<!--")?.lowerBound
            var stop = rest.endIndex
            if let nextBrace, nextBrace < stop { stop = nextBrace }
            if let nextComment, nextComment < stop { stop = nextComment }
            if stop == rest.startIndex {
                // Não deveria ocorrer, mas garante progresso.
                pendingText.append(rest.removeFirst())
            } else {
                pendingText += rest[rest.startIndex..<stop]
                rest = rest[stop...]
            }
        }
        flushText()
        return tokens
    }

    // MARK: Árvore

    static func parse(_ tokens: [Token], _ index: inout Int, open: String?) throws -> [TemplateNode] {
        var nodes: [TemplateNode] = []
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            switch token {
            case .text(let text):
                nodes.append(.text(text))
            case .replacement(let body):
                nodes.append(ParsedTemplate.replacementNode(body))
            case .open(let key):
                let children = try parse(tokens, &index, open: key)
                nodes.append(.conditional(key: key, children: children))
            case .openNegated(let key):
                let children = try parse(tokens, &index, open: key)
                nodes.append(.negated(key: key, children: children))
            case .close(let key):
                guard let open else { throw TemplateError.conditionalNotOpen(key) }
                guard open == key else { throw TemplateError.mismatchedClose(expected: open, found: key) }
                return nodes
            }
        }
        if let open { throw TemplateError.conditionalNotClosed(open) }
        return nodes
    }

    static func replacementNode(_ body: String) -> TemplateNode {
        var parts = body.components(separatedBy: ":")
        let key = (parts.popLast() ?? "").trimmingCharacters(in: .whitespaces)
        let filters = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return .replacement(key: key, filters: filters)
    }

    // MARK: Consultas

    /// Nomes de todos os campos referenciados (substituições e condicionais).
    public var referencedKeys: Set<String> {
        var keys = Set<String>()
        func walk(_ nodes: [TemplateNode]) {
            for node in nodes {
                switch node {
                case .text: break
                case .replacement(let key, _): keys.insert(key)
                case .conditional(let key, let children), .negated(let key, let children):
                    keys.insert(key)
                    walk(children)
                }
            }
        }
        walk(nodes)
        return keys
    }

    /// Campos usados com o filtro `cloze:`.
    public var clozeFields: [String] {
        var result: [String] = []
        func walk(_ nodes: [TemplateNode]) {
            for node in nodes {
                switch node {
                case .text: break
                case .replacement(let key, let filters):
                    if filters.contains("cloze") && !result.contains(key) { result.append(key) }
                case .conditional(_, let children), .negated(_, let children):
                    walk(children)
                }
            }
        }
        walk(nodes)
        return result
    }

    /// Primeiro `{{type:...}}` do template, se houver.
    public var typeAnswerSpec: TypeAnswerSpec? {
        func walk(_ nodes: [TemplateNode]) -> TypeAnswerSpec? {
            for node in nodes {
                switch node {
                case .text: continue
                case .replacement(let key, let filters):
                    if filters.first == "type" {
                        return TypeAnswerSpec(field: key, isCloze: filters.contains("cloze"),
                                              ignoreCombining: filters.contains("nc"))
                    }
                case .conditional(_, let children), .negated(_, let children):
                    if let found = walk(children) { return found }
                }
            }
            return nil
        }
        return walk(nodes)
    }

    /// Verdadeiro se o template, com os campos não vazios dados, exibiria o conteúdo de ao menos um campo.
    /// É a regra usada para decidir se um card deve ser gerado.
    public func rendersFieldContent(nonEmptyFields: Set<String>) -> Bool {
        func walk(_ nodes: [TemplateNode]) -> Bool {
            for node in nodes {
                switch node {
                case .text: continue
                case .replacement(let key, _):
                    if nonEmptyFields.contains(key) { return true }
                case .conditional(let key, let children):
                    if nonEmptyFields.contains(key) && walk(children) { return true }
                case .negated(let key, let children):
                    if !nonEmptyFields.contains(key) && walk(children) { return true }
                }
            }
            return false
        }
        return walk(nodes)
    }

    /// Renomeia (ou remove, com `newName == nil`) as referências a um campo e devolve o template como texto.
    public func renamingField(_ old: String, to newName: String?) -> String {
        func emit(_ nodes: [TemplateNode]) -> String {
            var out = ""
            for node in nodes {
                switch node {
                case .text(let text):
                    out += text
                case .replacement(let key, let filters):
                    if key == old {
                        guard let newName else { continue }
                        out += "{{" + (filters + [newName]).joined(separator: ":") + "}}"
                    } else {
                        out += "{{" + (filters + [key]).joined(separator: ":") + "}}"
                    }
                case .conditional(let key, let children):
                    if key == old {
                        if let newName { out += "{{#\(newName)}}" + emit(children) + "{{/\(newName)}}" }
                        else { out += emit(children) }
                    } else {
                        out += "{{#\(key)}}" + emit(children) + "{{/\(key)}}"
                    }
                case .negated(let key, let children):
                    if key == old {
                        if let newName { out += "{{^\(newName)}}" + emit(children) + "{{/\(newName)}}" }
                        else { out += emit(children) }
                    } else {
                        out += "{{^\(key)}}" + emit(children) + "{{/\(key)}}"
                    }
                }
            }
            return out
        }
        return emit(nodes)
    }
}

public struct TypeAnswerSpec: Sendable, Equatable {
    public var field: String
    public var isCloze: Bool
    public var ignoreCombining: Bool
    public init(field: String, isCloze: Bool, ignoreCombining: Bool) {
        self.field = field; self.isCloze = isCloze; self.ignoreCombining = ignoreCombining
    }
}
