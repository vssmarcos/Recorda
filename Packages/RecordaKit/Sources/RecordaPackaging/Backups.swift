import Foundation
import RecordaCore

public struct BackupInfo: Sendable, Equatable, Identifiable {
    public var url: URL
    public var date: Date
    public var bytes: Int64
    public var id: URL { url }
}

/// Backups automáticos da coleção, gravados como `.colpkg` (sem mídia) em uma pasta do app.
public struct BackupManager: Sendable {
    public let folder: URL
    /// Intervalo mínimo entre backups automáticos.
    public var minimumInterval: TimeInterval
    /// Quantos backups manter.
    public var maximumCount: Int

    public init(folder: URL, minimumInterval: TimeInterval = 30 * 60, maximumCount: Int = 30) {
        self.folder = folder
        self.minimumInterval = minimumInterval
        self.maximumCount = maximumCount
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        return formatter
    }

    public func list() -> [BackupInfo] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        let formatter = BackupManager.formatter()
        return contents.filter { $0.pathExtension == "colpkg" }.compactMap { url -> BackupInfo? in
            let stem = url.deletingPathExtension().lastPathComponent
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let stamp = stem.replacingOccurrences(of: "backup-", with: "")
            guard let date = formatter.date(from: stamp) ?? values?.contentModificationDate else { return nil }
            return BackupInfo(url: url, date: date, bytes: Int64(values?.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }

    /// Cria um backup agora.
    @discardableResult
    public func create(from collection: Collection, now: Date = Date()) throws -> BackupInfo {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "backup-\(BackupManager.formatter().string(from: now)).colpkg"
        let url = folder.appendingPathComponent(name)
        try PackageExporter.exportCollectionPackage(from: collection, to: url, includeMedia: false)
        prune()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return BackupInfo(url: url, date: now, bytes: Int64(size))
    }

    /// Cria um backup se o último for mais antigo que `minimumInterval` e a coleção tiver mudado desde então.
    @discardableResult
    public func createIfNeeded(from collection: Collection, now: Date = Date()) throws -> BackupInfo? {
        let existing = list()
        if let latest = existing.first {
            if now.timeIntervalSince(latest.date) < minimumInterval { return nil }
            let modified = try collection.read { txn in try txn.meta().mod }
            if Double(modified) / 1000.0 <= latest.date.timeIntervalSince1970 { return nil }
        }
        return try create(from: collection, now: now)
    }

    /// Mantém todos os backups dos últimos dois dias, um por dia nos anteriores, até `maximumCount`.
    public func prune(now: Date = Date()) {
        let backups = list()
        var keep: [BackupInfo] = []
        var seenDays = Set<String>()
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        for backup in backups {
            let recent = now.timeIntervalSince(backup.date) < 2 * 86_400
            let day = dayFormatter.string(from: backup.date)
            if recent || seenDays.insert(day).inserted {
                seenDays.insert(day)
                keep.append(backup)
            }
        }
        let kept = Set(keep.prefix(max(1, maximumCount)).map(\.url))
        for backup in backups where !kept.contains(backup.url) {
            try? FileManager.default.removeItem(at: backup.url)
        }
    }

    public func delete(_ backup: BackupInfo) throws {
        try FileManager.default.removeItem(at: backup.url)
    }

    /// Restaura um backup, substituindo a coleção atual. Antes, guarda um backup do estado atual.
    public func restore(_ backup: BackupInfo, into collection: Collection) throws {
        _ = try? create(from: collection)
        var options = PackageImportOptions()
        options.includeMedia = false
        _ = try PackageImporter.importPackage(at: backup.url, into: collection, options: options)
    }
}
