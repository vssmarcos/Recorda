# Recorda — onde parou e o que falta

Estado em 12/11/2026. **Nada foi compilado nem testado**: a máquina é Windows, sem Swift/Xcode.
Todo o código Swift foi escrito "às cegas"; o primeiro passo em um Mac é compilar e rodar os testes.

## 1. O que existe

`Packages/RecordaKit` (Swift Package, domínio sem UI):

| Módulo | Estado | Conteúdo |
|---|---|---|
| RecordaTemplates | escrito | parser de templates, cloze (aninhado, image occlusion), type-answer, tags de áudio/TTS, LaTeX→MathJax |
| RecordaCore | escrito | modelos, esquema SQLite (GRDB), `Collection`/`Txn`, notas, cards, baralhos, predefinições, tipos de nota, tags, mídia, renderização, check database |
| RecordaSearch | escrito | parser da sintaxe de busca → SQL, ordenação |
| RecordaScheduler | escrito | FSRS-6, máquina de estados (FSRS e SM-2), fuzz, balanceamento, filas, responder/desfazer, enterrar/suspender, baralhos filtrados, estudo personalizado, otimizador, simulador |
| RecordaPackaging | escrito | importar .apkg/.colpkg (legado e formato novo zstd+protobuf), exportar, CSV, backups |
| RecordaStats | escrito | todas as agregações dos gráficos + card info |
| RecordaSync | escrito | protocolo `SyncTransport`, `SyncEngine` (usn/mtime), transporte em memória |

Testes escritos: Core, Templates, Search, Scheduler (FSRS com vetores de referência, SM-2, filas, ponta a ponta), Packaging.

Documentos: `ARCHITECTURE.md`, `DECISIONS.md` (ambos precisam de ajustes, ver item 5).

A aritmética do FSRS foi conferida com um porte em Python que reproduz a sequência de referência
`[0, 2, 11, 46, 163, 498, 0, 0, 2, 4, 7, 12, 21]`. É a única parte verificada por execução.

## 2. Correções pendentes (pequenas, fazer primeiro)

Estas quatro alterações foram decididas mas **não chegaram a ser aplicadas**. Os testes já escritos contam com elas.

1. **`RecordaCore/Txn+Notes.swift`, `sortFieldValue`** — colapsar espaços repetidos antes do `trim`
   (senão `"França <img src=mapa.png>"` vira `"França  mapa.png"` com dois espaços):
   ```swift
   var text = HTMLText.stripPreservingMedia(Cloze.stripMarkup(raw)).replacingOccurrences(of: "\n", with: " ")
   while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
   return text.trimmingCharacters(in: .whitespacesAndNewlines)
   ```
2. **`RecordaPackaging/PackageExporter.swift`, `gather`** — gravar sempre a chave `fsrs` na exportação
   (o importador trata coleção sem essa chave como SM-2). Nos dois ramos (coleção completa e
   `.apkg` com agendamento):
   ```swift
   data.config[ConfigKey.fsrsEnabled] = try txn.fsrsEnabled() ? "true" : "false"
   ```
   No ramo com agendamento, tirar `ConfigKey.fsrsEnabled` da lista do `for key in [...]`.
3. **`RecordaPackaging/Zstd.swift`** — detectar fluxo truncado. Em `decompress` e `decompressFile`:
   guardar o valor devolvido por `ZSTD_decompressStream` em `var pending = 1` (atribuir quando não for erro)
   e, ao final, `if pending != 0 { throw PackagingError.decompressionFailed("dados incompletos") }`.
4. **`Package.swift`** — declara os alvos `RecordaStatsTests` e `RecordaSyncTests`, mas as pastas não existem.
   O SwiftPM falha com alvo sem fontes: criar os testes (item 4) ou remover as duas linhas.

## 3. Primeira compilação (em um Mac)

```bash
cd Packages/RecordaKit
swift build
swift test
```

Pontos onde é mais provável aparecer erro de compilação:

- **Concorrência do Swift 6**: closures `@Sendable` em `Collection.readAsync/writeAsync` e no `SyncEngine`;
  `static let` com `NSRegularExpression`. Se travar, uma saída temporária é
  `swiftLanguageModes: [.v5]` no `Package.swift`.
- **APIs de terceiros escritas de memória**: GRDB 7 (`DatabaseFunction`, `DatabaseCollation`,
  `StatementArguments + [...]`, `checkpoint`), ZIPFoundation (`Archive(url:accessMode:)`,
  `addEntry(with:fileURL:compressionMethod:)`, `extract`), zstd (`import libzstd`, produto `libzstd`).
- **Inferência de tipos** em subscripts de `Row` dentro de inicializadores (`Card(id: row["id"], ...)`).
- Variável local com o mesmo nome de um método de `Txn` (`deck`, `card`, `note`, `config`, `timing`):
  já corrigi os casos que vi, usando `self.`; pode haver outros.

Riscos de lógica a conferir quando os testes rodarem:

- Números de campo do protobuf das predefinições (`AnkiSource.deckConfigData`): escritos de memória.
  Validar importando um `.apkg`/`.colpkg` real exportado por um Anki recente.
- O otimizador do FSRS usa diferenças finitas + Adam (não é o algoritmo do fsrs-rs). Só adota o resultado
  se a perda melhorar; conferir se converge com um histórico real.
- Testar importação com arquivos reais do Anki (legado e novo) e abrir no Anki um `.apkg` exportado pelo app.

## 4. O que falta construir

### 4.1 Testes que faltam
- `Tests/RecordaStatsTests`: `stats(scope:period:)` e `cardInfo`.
- `Tests/RecordaSyncTests`: dois `Collection` + `InMemorySyncTransport` (primeiro envio, incremental,
  conflito por `mod`, exclusões, `fullSyncRequired`, mídia).

### 4.2 App iOS (nada foi escrito)
Estrutura planejada em `ARCHITECTURE.md`: `App/`, `ShareExtension/`, `Widget/`, `project.yml` (XcodeGen).

- **Projeto**: `project.yml` com 3 targets, App Group `group.app.recorda`, entitlements de iCloud/CloudKit,
  `Info.plist` (tipos de documento `.apkg`/`.colpkg`/`.csv`/`.txt` para "Abrir com", permissões de câmera,
  microfone e fotos).
- **Recursos**: MathJax local, `card.html`/`card.css`/`card.js`. O `card.js` precisa definir
  `recordaPlay(side, index)`, `recordaTypeKey`, `recordaTypeChanged`, reexecutar `<script>` do conteúdo
  injetado e `anki.imageOcclusion.setup()` (desenha as máscaras a partir dos `<div class="cloze…" data-shape…>`).
- **Base**: `RecordaApp`, contêiner de dependências (abre a `Collection` no App Group), preferências,
  `Localizable.xcstrings` (pt-BR). As mensagens de erro e nomes padrão do domínio estão fixos em
  português dentro do pacote; mover para Localizable se quiser tradução.
- **Baralhos**: lista em árvore (`txn.deckTree()`), criar/renomear/mover/excluir/exportar, tela de parabéns
  (`congratsInfo`), estudo personalizado (`customStudy`), baralhos filtrados.
- **Revisão**: `WKWebView` + `WKURLSchemeHandler` para mídia, botões com `txn.outcomes(for:)` e
  `IntervalFormat`, `txn.answer`, pilha de `UndoStep`, gestos/zonas de toque, whiteboard (PencilKit),
  áudio (AVAudioPlayer, AVSpeechSynthesizer, gravação), temporizador, avanço automático, timebox,
  atalhos de teclado. Reconstruir a fila com `txn.studyQueue(deckID:)` após cada resposta.
- **Editor**: adicionar/editar nota, editor rico, tags com autocompletar, campos fixos, duplicatas
  (`duplicateNoteIDs`), mídia (`collection.addMedia` — chamar **fora** de transações), editor de image
  occlusion, editor de tipos de nota (`updateNotetype` com `fieldOrigins`/`templateOrigins`).
- **Navegador**: `searchCards`/`searchNotes`, barra lateral, buscas salvas (`ConfigKey.savedSearches`),
  ações em lote (já existem no domínio).
- **Estatísticas**: Swift Charts sobre `CollectionStats`.
- **Opções de baralho**: edição de `DeckConfigData`, `FSRSOptimizer.optimize`, `FSRSSimulator`,
  `setFSRSEnabled`, dias fáceis.
- **Importar/exportar**: telas sobre `PackageImporter`, `PackageExporter`, `TextImporter`,
  `BackupManager`, `checkMedia`, `checkAndOptimize`, `emptyCards`.
- **Sync**: `CloudKitTransport` implementando `SyncTransport` (zona própria no banco privado,
  `recordZoneChanges`, `modifyRecords`, `CKAsset` para mídia e payloads grandes) + UI de conflito
  (enviar/baixar tudo).
- **Extras**: Share Extension (grava em `inbox/*.json` no App Group; o app incorpora ao abrir), Widget
  (lê `widget.json`), lembrete diário (notificações locais), configurações, acessibilidade, onboarding
  com baralho de exemplo.

### 4.3 Lacunas conhecidas no domínio
- Sem exportação de notas em texto/CSV (só importação).
- `ConfigKey.rescheduleOnParamChange`, `timeboxSecs` e `fsrsShortTermWithSteps` estão declarados mas não usados.
- A busca usa `LIKE` do SQLite: sem distinção de maiúsculas só para ASCII ("É" ≠ "é").
- Balanceamento de carga conta as revisões da coleção inteira, não por predefinição.
- Chaves `_local.*` (estado do sync) vão junto nas exportações `.colpkg`.

## 5. Documentação a acertar
- `ARCHITECTURE.md` cita tabelas `fields`/`templates` e arquivo `SM2.swift` que não existem
  (campos e modelos ficam no JSON de `notetypes.config`; o SM-2 está em `StateMachine.swift`), e diz que
  Templates depende de Core (é o contrário).
- `DECISIONS.md`: acrescentar o otimizador próprio, o comportamento do FSRS sem passos de aprendizado,
  a cópia nativa `recorda.sqlite` dentro do `.colpkg`, e a reutilização de tipos de nota idênticos na importação.
- Escrever `README.md` e `FEATURES.md` só depois que o app existir; hoje nenhum item da lista pode ser
  marcado como implementado de ponta a ponta.
