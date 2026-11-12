import Foundation
import GRDB

public struct MediaCheckReport: Sendable, Equatable {
    /// Arquivos referenciados por notas, mas ausentes da pasta de mídia.
    public var missing: [String]
    /// Arquivos na pasta de mídia que nenhuma nota usa.
    public var unused: [String]
    /// Notas que referenciam arquivos ausentes.
    public var notesWithMissing: [NoteID]
    public var totalFiles: Int
    public var totalBytes: Int64
}

extension Collection {

    // MARK: Nomes

    /// Remove caracteres inválidos e limita o tamanho do nome de arquivo.
    public static func sanitizedMediaName(_ raw: String) -> String {
        var name = (raw as NSString).lastPathComponent.nfc
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|[]\u{0}\n\r\t")
        name = String(name.unicodeScalars.filter { !forbidden.contains($0) })
        name = name.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix(".") { name = "arquivo" + name }
        if name.isEmpty { name = "arquivo" }
        if name.utf8.count > 120 {
            let ext = (name as NSString).pathExtension
            var stem = (name as NSString).deletingPathExtension
            while stem.utf8.count > 100 { stem.removeLast() }
            name = ext.isEmpty ? stem : stem + "." + ext
        }
        return name
    }

    public func mediaURL(for name: String) -> URL {
        mediaFolder.appendingPathComponent(name, isDirectory: false)
    }

    public func mediaExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: mediaURL(for: name).path)
    }

    // MARK: Adicionar

    /// Copia os dados para a pasta de mídia e devolve o nome final.
    /// Se já existir um arquivo com o mesmo nome e conteúdo diferente, acrescenta um sufixo com o hash.
    @discardableResult
    public func addMedia(data: Data, preferredName: String) throws -> String {
        let clean = Collection.sanitizedMediaName(preferredName)
        var name = clean
        let target = mediaURL(for: name)
        if FileManager.default.fileExists(atPath: target.path) {
            if let existing = try? Data(contentsOf: target), existing == data { return name }
            let hash = Hashing.sha1Hex(data)
            let ext = (clean as NSString).pathExtension
            let stem = (clean as NSString).deletingPathExtension
            name = ext.isEmpty ? "\(stem)-\(hash)" : "\(stem)-\(hash).\(ext)"
            if FileManager.default.fileExists(atPath: mediaURL(for: name).path) { return name }
        }
        try data.write(to: mediaURL(for: name), options: .atomic)
        try markMediaDirty(name)
        return name
    }

    @discardableResult
    public func addMedia(fileAt url: URL, preferredName: String? = nil) throws -> String {
        let data = try Data(contentsOf: url)
        return try addMedia(data: data, preferredName: preferredName ?? url.lastPathComponent)
    }

    /// Grava com o nome exato (usado pela importação e pelo sync, que já resolveram conflitos).
    public func writeMedia(data: Data, exactName: String) throws {
        try data.write(to: mediaURL(for: exactName), options: .atomic)
        try markMediaDirty(exactName)
    }

    func markMediaDirty(_ name: String) throws {
        let mtime = Int64(clock.now().timeIntervalSince1970)
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO media_meta (fname, csum, mtime, dirty) VALUES (?, '', ?, 1)
                ON CONFLICT(fname) DO UPDATE SET mtime = excluded.mtime, dirty = 1
                """, arguments: [name, mtime])
        }
    }

    // MARK: Listar / excluir

    public func allMediaFiles() throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: mediaFolder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        return contents.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }
            .map { $0.lastPathComponent.nfc }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func deleteMedia(_ names: [String]) throws {
        for name in names {
            let url = mediaURL(for: name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try writer.write { db in
            for name in names {
                try db.execute(sql: """
                    INSERT INTO media_meta (fname, csum, mtime, dirty) VALUES (?, '', 0, 1)
                    ON CONFLICT(fname) DO UPDATE SET csum = '', dirty = 1
                    """, arguments: [name])
            }
        }
    }

    public func mediaFolderSize() -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: mediaFolder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        return contents.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: Verificação

    /// Compara as referências nas notas (e nos modelos) com o conteúdo da pasta de mídia.
    public func checkMedia() throws -> MediaCheckReport {
        let files = try allMediaFiles()
        let onDisk = Set(files)
        var referenced = Set<String>()
        var notesWithMissing: [NoteID] = []
        var missing = Set<String>()

        try read { txn in
            let cursor = try Row.fetchCursor(txn.db, sql: "SELECT id, flds FROM notes")
            while let row = try cursor.next() {
                let flds: String = row["flds"]
                guard flds.contains("[sound:") || flds.contains("<") else { continue }
                var noteMissing = false
                for name in HTMLText.mediaReferences(in: flds) {
                    let normalized = name.nfc
                    referenced.insert(normalized)
                    if !onDisk.contains(normalized) {
                        missing.insert(normalized)
                        noteMissing = true
                    }
                }
                if noteMissing { notesWithMissing.append(row["id"]) }
            }
            // Modelos e CSS podem referenciar arquivos (convenção: nomes iniciados por "_").
            for nt in try txn.allNotetypes() {
                var sources = [nt.css]
                for template in nt.templates { sources += [template.qfmt, template.afmt] }
                for source in sources {
                    for name in HTMLText.mediaReferences(in: source) { referenced.insert(name.nfc) }
                    for file in files where file.hasPrefix("_") && source.contains(file) { referenced.insert(file) }
                }
            }
        }

        let unused = files.filter { !referenced.contains($0) && !$0.hasPrefix("_") }
        return MediaCheckReport(missing: missing.sorted(), unused: unused, notesWithMissing: notesWithMissing,
                                totalFiles: files.count, totalBytes: mediaFolderSize())
    }
}
