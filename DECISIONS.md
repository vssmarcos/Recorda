# Recorda — Registro de decisões

Decisões tomadas sem consulta, conforme o método de trabalho combinado.

## D1. Nome e identidade
O app chama-se **Recorda**. Não usa o nome, ícone nem assets do Anki. A
compatibilidade é apenas com o formato de arquivo e com o comportamento
documentado publicamente.

## D2. Ambiente de desenvolvimento sem toolchain Swift
O código foi escrito em uma máquina Windows sem Swift nem Xcode instalados.
Consequência: **build e testes não puderam ser executados aqui**. Para reduzir o
risco, a aritmética do agendador (FSRS e SM-2) foi conferida com um porte
independente em Python usado para gerar os vetores de referência dos testes.
O primeiro build no Xcode pode exigir pequenos ajustes de compilação.

## D3. Projeto Xcode via XcodeGen
O projeto é descrito em `project.yml` e gerado com `xcodegen generate`. Um
`.pbxproj` escrito à mão sem Xcode para validar seria frágil; o `project.yml` é
legível, versionável e gera App + Share Extension + Widget de forma determinística.

## D4. JSON no banco de trabalho em vez de protobuf
O Anki moderno guarda configurações de baralho/tipo de nota como protobuf. O
Recorda usa as mesmas tabelas e colunas, mas com JSON nos blobs. Evita depender
de SwiftProtobuf e de arquivos `.proto` do Anki (AGPL). A leitura de coleções
v18 usa um decodificador mínimo de wire-format escrito do zero, com os números
de campo observados no formato de arquivo.

## D5. Exportação no formato legado
`.apkg` e `.colpkg` são exportados com `collection.anki2` (esquema v11) e mapa de
mídia JSON, que todas as versões do Anki (desktop, AnkiMobile, AnkiDroid)
importam. A importação aceita legado e formato novo (zstd).

## D6. Licença
Nenhum código do Anki foi copiado. FSRS foi implementado a partir das fórmulas
públicas do algoritmo; SM-2 e o restante, a partir do manual e do comportamento
observável.
