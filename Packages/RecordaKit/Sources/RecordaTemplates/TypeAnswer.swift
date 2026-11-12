import Foundation

/// Suporte a `{{type:Campo}}`: campo de digitação na frente e comparação colorida no verso.
public enum TypeAnswer {

    private static let markerRegex = try! NSRegularExpression(pattern: "\\[\\[type:[^\\]]+\\]\\]")

    public static func containsMarker(_ html: String) -> Bool {
        html.contains("[[type:")
    }

    /// Texto esperado, sem HTML, a partir do conteúdo do campo.
    public static func expectedText(fieldValue: String, spec: TypeAnswerSpec, cardOrdinal: Int) -> String {
        var raw = fieldValue
        if spec.isCloze {
            let parts = Cloze.activeTexts(fieldValue, ordinal: cardOrdinal + 1)
            // Se todas as omissões forem iguais, basta digitar uma vez.
            if Set(parts).count == 1 { raw = parts[0] } else { raw = parts.joined(separator: ", ") }
        }
        return normalize(PlainText.stripKeepingBreaks(raw).replacingOccurrences(of: "\n", with: " "))
    }

    static func normalize(_ text: String) -> String {
        var value = text.precomposedStringWithCanonicalMapping
        value = value.replacingOccurrences(of: "\u{00a0}", with: " ")
        while value.contains("  ") { value = value.replacingOccurrences(of: "  ", with: " ") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Frente: troca o marcador por um `<input>`.
    public static func questionHTML(_ html: String, fontFamily: String = "Arial", fontSize: Int = 20) -> String {
        let input = """
        <center><input type="text" id="typeans" autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false" \
        onkeypress="recordaTypeKey(event);" oninput="recordaTypeChanged(this.value);" \
        style="font-family: '\(fontFamily)'; font-size: \(fontSize)px;"></center>
        """
        return replaceMarker(in: html, with: input)
    }

    /// Verso: troca o marcador pela comparação entre o digitado e o esperado.
    public static func answerHTML(_ html: String, expected: String, typed: String, ignoreCombining: Bool = false,
                                  fontFamily: String = "Arial", fontSize: Int = 20) -> String {
        let comparison = compareHTML(expected: expected, typed: typed, ignoreCombining: ignoreCombining)
        let block = "<div style=\"font-family: '\(fontFamily)'; font-size: \(fontSize)px\">\(comparison)</div>"
        return replaceMarker(in: html, with: block)
    }

    /// Remove o marcador (para pré-visualizações e navegador).
    public static func removingMarker(_ html: String) -> String {
        replaceMarker(in: html, with: "")
    }

    private static func replaceMarker(in html: String, with replacement: String) -> String {
        guard containsMarker(html) else { return html }
        return markerRegex.stringByReplacingMatches(
            in: html, range: NSRange(html.startIndex..., in: html),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    // MARK: Diff

    public enum Segment: Equatable, Sendable {
        case good(String)
        case bad(String)
        case missed(String)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive], locale: nil)
    }

    /// Calcula os segmentos do texto digitado e do esperado usando a maior subsequência comum.
    public static func diff(expected: String, typed: String, ignoreCombining: Bool = false) -> (typed: [Segment], expected: [Segment]) {
        let a = Array(typed)
        let b = Array(expected)
        let keyA = ignoreCombining ? a.map { fold(String($0)) } : a.map { String($0) }
        let keyB = ignoreCombining ? b.map { fold(String($0)) } : b.map { String($0) }
        let n = a.count, m = b.count

        // Tabela de LCS (sufixos).
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if keyA[i] == keyB[j] {
                        table[i][j] = table[i + 1][j + 1] + 1
                    } else {
                        table[i][j] = max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
        }

        var typedSegments: [Segment] = []
        var expectedSegments: [Segment] = []

        func appendTyped(good: Bool, _ ch: Character) {
            if good, case .good(let s)? = typedSegments.last {
                typedSegments[typedSegments.count - 1] = .good(s + String(ch))
            } else if !good, case .bad(let s)? = typedSegments.last {
                typedSegments[typedSegments.count - 1] = .bad(s + String(ch))
            } else {
                typedSegments.append(good ? .good(String(ch)) : .bad(String(ch)))
            }
        }
        func appendExpected(good: Bool, _ ch: Character) {
            if good, case .good(let s)? = expectedSegments.last {
                expectedSegments[expectedSegments.count - 1] = .good(s + String(ch))
            } else if !good, case .missed(let s)? = expectedSegments.last {
                expectedSegments[expectedSegments.count - 1] = .missed(s + String(ch))
            } else {
                expectedSegments.append(good ? .good(String(ch)) : .missed(String(ch)))
            }
        }
        /// Marca, no texto digitado, um trecho que faltou.
        func appendGap() {
            if case .missed(let s)? = typedSegments.last {
                typedSegments[typedSegments.count - 1] = .missed(s + "-")
            } else {
                typedSegments.append(.missed("-"))
            }
        }

        var i = 0, j = 0
        while i < n && j < m {
            if keyA[i] == keyB[j] {
                appendTyped(good: true, a[i])
                appendExpected(good: true, b[j])
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                appendTyped(good: false, a[i])
                i += 1
            } else {
                appendGap()
                appendExpected(good: false, b[j])
                j += 1
            }
        }
        while i < n { appendTyped(good: false, a[i]); i += 1 }
        while j < m { appendGap(); appendExpected(good: false, b[j]); j += 1 }
        return (typedSegments, expectedSegments)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func spans(_ segments: [Segment]) -> String {
        segments.map { segment -> String in
            switch segment {
            case .good(let s): return "<span class=\"typeGood\">\(escape(s))</span>"
            case .bad(let s): return "<span class=\"typeBad\">\(escape(s))</span>"
            case .missed(let s): return "<span class=\"typeMissed\">\(escape(s))</span>"
            }
        }.joined()
    }

    public static func compareHTML(expected rawExpected: String, typed rawTyped: String, ignoreCombining: Bool = false) -> String {
        let expected = normalize(rawExpected)
        let typed = normalize(rawTyped)
        if typed.isEmpty {
            return "<code id=\"typeans\">\(escape(expected))</code>"
        }
        let same = ignoreCombining ? fold(expected) == fold(typed) : expected == typed
        if same {
            return "<code id=\"typeans\"><span class=\"typeGood\">\(escape(expected))</span></code>"
        }
        let result = diff(expected: expected, typed: typed, ignoreCombining: ignoreCombining)
        return "<code id=\"typeans\">\(spans(result.typed))<br><span id=\"typearrow\">&darr;</span><br>\(spans(result.expected))</code>"
    }
}
