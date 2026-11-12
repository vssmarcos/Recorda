# Recorda — Arquitetura

Recorda é um app de flashcards para iOS/iPadOS 17+, offline-first, com repetição
espaçada (FSRS por padrão, SM-2 como alternativa) e compatível com os formatos de
arquivo `.apkg` / `.colpkg`. Nome, ícone e identidade visual são próprios.

## 1. Visão geral

```
Recorda/
├── project.yml                  # definição do projeto (XcodeGen) → Recorda.xcodeproj
├── Packages/RecordaKit/         # Swift Package local: todo o domínio, testável sem UI
│   ├── Package.swift
│   ├── Sources/
│   │   ├── RecordaCore/         # modelos, esquema SQLite, Collection (fachada do banco)
│   │   ├── RecordaScheduler/    # FSRS, SM-2, fuzz, filas, respostas (puro, sem banco)
│   │   ├── RecordaTemplates/    # parser/renderizador de templates, cloze, type-answer
│   │   ├── RecordaSearch/       # parser da sintaxe de busca → SQL
│   │   ├── RecordaPackaging/    # importar/exportar .apkg/.colpkg/CSV, mídia, backups
│   │   ├── RecordaStats/        # agregações para os gráficos
│   │   └── RecordaSync/         # protocolo SyncTransport + motor de sync por usn/mtime
│   └── Tests/                   # XCTest por módulo
├── App/                         # target do app (SwiftUI, MVVM)
│   ├── RecordaApp.swift
│   ├── AppState/                # ambiente, contêiner de dependências, preferências
│   ├── Features/
│   │   ├── Decks/               # lista de baralhos, parabéns, estudo personalizado
│   │   ├── Review/              # tela de estudo, WebView, whiteboard, áudio
│   │   ├── Editor/              # adicionar/editar, image occlusion, tipos de nota
│   │   ├── Browser/             # navegador, barra lateral, ações em lote
│   │   ├── Stats/               # Swift Charts
│   │   ├── DeckOptions/         # predefinições, otimização FSRS, simulador
│   │   ├── ImportExport/        # importação, exportação, mídia, backups
│   │   ├── Sync/                # CloudKitTransport + UI
│   │   └── Settings/            # tema, gestos, lembretes, acessibilidade
│   ├── Shared/                  # componentes de UI reutilizáveis
│   └── Resources/               # Localizable.xcstrings, Assets, MathJax, card.js/css
├── ShareExtension/              # target: criar card de texto/imagem compartilhado
├── Widget/                      # target: contagem de cards pendentes (WidgetKit)
└── docs: README.md, FEATURES.md, DECISIONS.md, ARCHITECTURE.md
```

### Dependências externas (três, todas justificadas)

| Pacote | Uso | Por quê |
|---|---|---|
| GRDB.swift | SQLite | pedido no escopo; acesso tipado, migrações, WAL, observação |
| ZIPFoundation | ler/gravar `.apkg`/`.colpkg` | o iOS não expõe API pública de ZIP |
| zstd (facebook/zstd, SwiftPM) | `collection.anki21b` e mídia do formato novo | o framework Compression da Apple não tem zstd |

Nada de analytics, rede só para CloudKit. MathJax é empacotado em `App/Resources/mathjax`.

## 2. Camadas

```
SwiftUI View  →  ViewModel (@Observable, @MainActor)  →  Serviços de domínio (RecordaKit)  →  GRDB/SQLite
```

- **Views** não conhecem SQL nem GRDB; falam só com ViewModels.
- **ViewModels** são `@Observable @MainActor`, recebem `Collection` por injeção e
  chamam o domínio com `async` (o trabalho de banco roda fora da main thread).
- **Domínio** (`RecordaKit`) não importa SwiftUI/UIKit. O agendador é puro: recebe
  estado do card + configuração + relógio e devolve o próximo estado, o que o torna
  testável com vetores de referência.
- **Concorrência (Swift 6)**: `Collection` é uma `final class` `Sendable` que
  encapsula um `DatabasePool` do GRDB (thread-safe). Modelos são `struct Sendable`.

## 3. Modelo de dados

O banco de trabalho espelha o esquema v18 do Anki, para que importação/exportação
sejam conversões diretas e o `revlog` seja compatível byte a byte.

| Tabela | Conteúdo |
|---|---|
| `col` | linha única: `crt` (criação), `mod`, `scm` (mudança de esquema), `ver`, `usn`, `ls` |
| `notes` | `id, guid, mid, mod, usn, tags, flds (separados por 0x1f), sfld, csum, flags, data` |
| `cards` | `id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data` |
| `revlog` | `id (ms), cid, usn, ease, ivl, lastIvl, factor, time, type` |
| `decks` | `id, name, mtime_secs, usn, common (JSON), kind (JSON)` |
| `deck_config` | `id, name, mtime_secs, usn, config (JSON)` — predefinições |
| `notetypes` | `id, name, mtime_secs, usn, config (JSON)` |
| `fields` | `ntid, ord, name, config (JSON)` |
| `templates` | `ntid, ord, name, mtime_secs, usn, config (JSON)` |
| `tags` | `tag, usn, collapsed` |
| `graves` | `oid, type, usn` — exclusões para sync |
| `config` | `key, usn, mtime_secs, val (JSON)` — configurações globais, buscas salvas |
| `media_meta` | `fname, csum, mtime, dirty` — índice da pasta de mídia |

Diferenças deliberadas em relação ao Anki: os blobs `config/common/kind` são JSON
(não protobuf) no banco de trabalho. O importador lê tanto o esquema legado
(v11, JSON dentro de `col`) quanto o v18 (protobuf, decodificado por um leitor
mínimo de wire-format); o exportador grava o esquema legado v11
(`collection.anki2` / `collection.anki21`), que todas as versões do Anki importam.
Ver DECISIONS.md.

Semântica dos campos de `cards` (idêntica à do Anki):

- `type`: 0 novo, 1 aprendendo, 2 revisão, 3 reaprendendo.
- `queue`: 0 novo, 1 aprendendo (intradiário, `due` = epoch s), 2 revisão
  (`due` = nº de dias desde `crt`), 3 aprendendo interdiário, 4 pré-visualização,
  -1 suspenso, -2 enterrado pelo agendador (irmão), -3 enterrado pelo usuário.
- `factor`: facilidade em permilagem (2500 = 250 %).
- `left`: `repsHoje * 1000 + passosRestantes`.
- `odue/odid`: valores originais enquanto o card está em baralho filtrado.
- `data`: JSON com estado FSRS: `{"s": estabilidade, "d": dificuldade, "dr": retenção desejada, "lrt": último review}`.
- `flags & 0b111`: sinalizador 0–7.

`revlog.type`: 0 aprendizado, 1 revisão, 2 reaprendizado, 3 filtrado/antecipado,
4 manual (reagendar/esquecer). `revlog.factor` guarda facilidade (SM-2) ou
dificuldade×... conforme o Anki: com FSRS, o valor é a dificuldade mapeada para
100–1100.

## 4. Agendador

`RecordaScheduler` é dividido em:

- `FSRS.swift` — modelo FSRS-6 (21 parâmetros; aceita 17/19 parâmetros de
  FSRS-4.5/5 por migração): estabilidade/dificuldade iniciais, curva de
  esquecimento, atualização em acerto/lapso/mesmo dia, intervalo a partir da
  retenção desejada.
- `FSRSOptimizer.swift` — otimização dos parâmetros a partir do revlog
  (descida de gradiente com Adam e BPTT implementados à mão, perda log-loss).
- `FSRSSimulator.swift` — simulador de carga de trabalho (Monte Carlo).
- `SM2.swift` — algoritmo legado (facilidade, bônus fácil, intervalo difícil,
  multiplicador, novo intervalo após lapso).
- `Fuzz.swift` — fuzz determinístico por card, balanceamento de carga e dias fáceis.
- `CardStateMachine.swift` — estados (novo → aprendendo → revisão → reaprendendo),
  passos, graduação; calcula os quatro próximos estados (Errei/Difícil/Bom/Fácil).
- `Answering.swift` — aplica a resposta: grava o card, o revlog, sanguessugas,
  enterrar irmãos; retorna um registro de desfazer.
- `Queues.swift` — monta as filas do dia respeitando limites por baralho
  (hierárquicos), "somente hoje", ordem de coleta/exibição e mistura.
- `Timing.swift` — dia atual a partir de `crt`, hora de virada e fuso.

O agendador nunca lê o relógio diretamente: recebe um `SchedClock`, o que permite
testes determinísticos.

## 5. Renderização dos cards

`RecordaTemplates` transforma template + campos em HTML:

1. `TemplateParser` → AST (texto, substituição com filtros, condicional, negação).
2. `TemplateRenderer` aplica filtros (`text`, `hint`, `cloze`, `type`, `tts`,
   `furigana`/`kana`/`kanji`) e campos especiais (`FrontSide`, `Tags`, `Deck`,
   `Subdeck`, `Card`, `Type`, `CardFlag`).
3. `Cloze` trata `{{cN::texto::dica}}`, aninhamento e image occlusion.
4. `TypeAnswer` gera o diff colorido da resposta digitada.
5. O app embrulha o resultado em uma página (`card.html` + CSS do tipo de nota +
   `card.js`) e mostra em `WKWebView`. Mídia é servida por um
   `WKURLSchemeHandler` (`recorda-media://`) direto da pasta de mídia, e MathJax
   vem do bundle. Áudio `[sound:…]` e `[anki:tts]` são extraídos e tocados
   nativamente (AVAudioPlayer / AVSpeechSynthesizer).

## 6. Busca

`RecordaSearch`: `SearchLexer` → `SearchParser` (AST com and/or/not e grupos) →
`SQLWriter` (cláusula `WHERE` + argumentos sobre `cards c JOIN notes n`).
Funções SQL auxiliares registradas no GRDB: `regexp`, `field_at`, `strip_html`,
`without_combining`.

## 7. Importação/exportação

- `.apkg`: ZIP com `collection.anki2|anki21|anki21b`, arquivo `media` (JSON
  legado ou protobuf+zstd) e arquivos numerados. A importação faz *merge* por
  `guid` de nota e por id de tipo de nota (com detecção de esquema alterado).
- `.colpkg`: substitui a coleção inteira (após backup automático).
- CSV/TXT: detecção de separador, cabeçalhos `#separator`, `#html`, `#notetype`,
  `#deck`, `#tags column`, mapeamento de colunas → campos.
- Backups: `.colpkg` periódicos em `Application Support/Backups`, com poda.

## 8. Sincronização

`RecordaSync` define `SyncTransport` (protocolo) e `SyncEngine`, que trabalha com
`usn` (-1 = pendente local) e `mod`. O app fornece `CloudKitTransport` (banco
privado do usuário, zona própria, `CKSyncEngine`-like por *change tokens*).
Conflito por objeto: vence o `mod` mais recente; mudança de esquema (`scm`)
divergente força escolha de sincronização completa (enviar ou baixar).
Um futuro `AnkiSyncServerTransport` só precisa implementar o mesmo protocolo.

## 9. Targets e compartilhamento de dados

App, Share Extension e Widget compartilham um App Group
(`group.app.recorda`). A coleção fica no contêiner do grupo; a extensão grava
notas pendentes em uma caixa de entrada (`inbox/*.json`) que o app incorpora ao
abrir (evita abrir o banco em dois processos); o widget lê um instantâneo
`widget.json` gravado pelo app.

## 10. Ordem de implementação

1. Modelos + esquema + `Collection` (RecordaCore)
2. Importação `.apkg` (RecordaPackaging)
3. Templates/cloze/renderização (RecordaTemplates)
4. Revisão + SM-2 (RecordaScheduler + Features/Review)
5. FSRS + opções de baralho + otimizador + simulador
6. Adicionar/editar, mídia, cloze, image occlusion
7. Navegador + busca
8. Estatísticas
9. Exportação, backups, baralhos filtrados, estudo personalizado
10. Sync iCloud, Share Extension, Widget, notificações, acessibilidade
11. Polimento, FEATURES.md, autorrevisão
