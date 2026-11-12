import Foundation
import libzstd

public enum PackagingError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case invalidPackage(String)
    case decompressionFailed(String)
    case unsupportedVersion(Int)
    case io(String)

    public var description: String {
        switch self {
        case .invalidPackage(let why): return "Arquivo inválido: \(why)"
        case .decompressionFailed(let why): return "Falha ao descompactar: \(why)"
        case .unsupportedVersion(let version): return "Versão de pacote não suportada (\(version)). Atualize o app."
        case .io(let why): return "Erro de leitura/gravação: \(why)"
        }
    }

    public var errorDescription: String? { description }
}

/// Descompressão Zstandard (usada pelo formato novo de pacotes).
enum Zstd {
    static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    static func isCompressed(_ data: Data) -> Bool {
        data.count >= 4 && Array(data.prefix(4)) == magic
    }

    /// Descomprime um bloco em memória.
    static func decompress(_ data: Data) throws -> Data {
        guard let stream = ZSTD_createDStream() else { throw PackagingError.decompressionFailed("sem memória") }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)

        let outCapacity = ZSTD_DStreamOutSize()
        var outBuffer = [UInt8](repeating: 0, count: outCapacity)
        var result = Data()
        var failure: String?

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var input = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
            while input.pos < input.size {
                let code: Int = outBuffer.withUnsafeMutableBytes { outRaw -> Int in
                    var output = ZSTD_outBuffer(dst: outRaw.baseAddress, size: outRaw.count, pos: 0)
                    let status = ZSTD_decompressStream(stream, &output, &input)
                    if ZSTD_isError(status) != 0 {
                        failure = String(cString: ZSTD_getErrorName(status))
                        return -1
                    }
                    if output.pos > 0, let base = outRaw.baseAddress {
                        result.append(base.assumingMemoryBound(to: UInt8.self), count: output.pos)
                    }
                    return 0
                }
                if code < 0 { break }
            }
        }
        if let failure { throw PackagingError.decompressionFailed(failure) }
        return result
    }

    /// Descomprime um arquivo para outro, em fluxo (para coleções grandes).
    static func decompressFile(at source: URL, to destination: URL) throws {
        guard let input = InputStream(url: source) else { throw PackagingError.io("não foi possível abrir \(source.lastPathComponent)") }
        guard let output = OutputStream(url: destination, append: false) else {
            throw PackagingError.io("não foi possível criar \(destination.lastPathComponent)")
        }
        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }
        guard let stream = ZSTD_createDStream() else { throw PackagingError.decompressionFailed("sem memória") }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)

        let inCapacity = ZSTD_DStreamInSize()
        let outCapacity = ZSTD_DStreamOutSize()
        var inBuffer = [UInt8](repeating: 0, count: inCapacity)
        var outBuffer = [UInt8](repeating: 0, count: outCapacity)

        while true {
            let read = input.read(&inBuffer, maxLength: inCapacity)
            if read < 0 { throw PackagingError.io(input.streamError?.localizedDescription ?? "leitura") }
            if read == 0 { break }
            var failure: String?
            inBuffer.withUnsafeBytes { inRaw in
                var inState = ZSTD_inBuffer(src: inRaw.baseAddress, size: read, pos: 0)
                while inState.pos < inState.size {
                    var produced = 0
                    outBuffer.withUnsafeMutableBytes { outRaw in
                        var outState = ZSTD_outBuffer(dst: outRaw.baseAddress, size: outRaw.count, pos: 0)
                        let status = ZSTD_decompressStream(stream, &outState, &inState)
                        if ZSTD_isError(status) != 0 {
                            failure = String(cString: ZSTD_getErrorName(status))
                        }
                        produced = outState.pos
                    }
                    if failure != nil { return }
                    var written = 0
                    while written < produced {
                        let count = outBuffer.withUnsafeBufferPointer { pointer -> Int in
                            guard let base = pointer.baseAddress else { return -1 }
                            return output.write(base + written, maxLength: produced - written)
                        }
                        if count <= 0 {
                            failure = output.streamError?.localizedDescription ?? "gravação"
                            return
                        }
                        written += count
                    }
                }
            }
            if let failure { throw PackagingError.decompressionFailed(failure) }
        }
    }
}
