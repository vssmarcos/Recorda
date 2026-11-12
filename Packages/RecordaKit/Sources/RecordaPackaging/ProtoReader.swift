import Foundation

/// Leitor mínimo do wire-format do Protocol Buffers.
/// Suficiente para ler os blobs de configuração das coleções no formato novo, sem depender de bibliotecas.
struct ProtoMessage {

    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    private(set) var fields: [Int: [Value]] = [:]

    init(_ data: Data) {
        let bytes = [UInt8](data)
        var index = 0

        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        while index < bytes.count {
            guard let key = readVarint() else { break }
            let number = Int(key >> 3)
            let wireType = Int(key & 0x7)
            var value: Value?
            switch wireType {
            case 0:
                if let v = readVarint() { value = .varint(v) }
            case 1:
                guard index + 8 <= bytes.count else { index = bytes.count; break }
                var v: UInt64 = 0
                for offset in 0..<8 { v |= UInt64(bytes[index + offset]) << UInt64(8 * offset) }
                index += 8
                value = .fixed64(v)
            case 2:
                guard let length = readVarint(), index + Int(length) <= bytes.count else { index = bytes.count; break }
                value = .bytes(Data(bytes[index..<(index + Int(length))]))
                index += Int(length)
            case 5:
                guard index + 4 <= bytes.count else { index = bytes.count; break }
                var v: UInt32 = 0
                for offset in 0..<4 { v |= UInt32(bytes[index + offset]) << UInt32(8 * offset) }
                index += 4
                value = .fixed32(v)
            default:
                // Tipos de grupo (obsoletos) não são usados; interrompe a leitura.
                index = bytes.count
            }
            if let value { fields[number, default: []].append(value) }
        }
    }

    // MARK: Acesso

    func uint(_ number: Int) -> UInt64? {
        guard let value = fields[number]?.last else { return nil }
        switch value {
        case .varint(let v): return v
        case .fixed64(let v): return v
        case .fixed32(let v): return UInt64(v)
        case .bytes: return nil
        }
    }

    func int(_ number: Int) -> Int? {
        uint(number).map { Int(Int64(bitPattern: $0)) }
    }

    func bool(_ number: Int) -> Bool? {
        uint(number).map { $0 != 0 }
    }

    func float(_ number: Int) -> Double? {
        guard let value = fields[number]?.last else { return nil }
        switch value {
        case .fixed32(let v): return Double(Float(bitPattern: v))
        case .fixed64(let v): return Double(bitPattern: v)
        case .varint(let v): return Double(v)
        case .bytes: return nil
        }
    }

    func string(_ number: Int) -> String? {
        guard case .bytes(let data)? = fields[number]?.last else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func data(_ number: Int) -> Data? {
        guard case .bytes(let data)? = fields[number]?.last else { return nil }
        return data
    }

    func message(_ number: Int) -> ProtoMessage? {
        data(number).map(ProtoMessage.init)
    }

    func messages(_ number: Int) -> [ProtoMessage] {
        (fields[number] ?? []).compactMap { value in
            if case .bytes(let data) = value { return ProtoMessage(data) }
            return nil
        }
    }

    /// `repeated float`, empacotado ou não.
    func floats(_ number: Int) -> [Double] {
        var result: [Double] = []
        for value in fields[number] ?? [] {
            switch value {
            case .fixed32(let v):
                result.append(Double(Float(bitPattern: v)))
            case .bytes(let data):
                let bytes = [UInt8](data)
                var index = 0
                while index + 4 <= bytes.count {
                    var v: UInt32 = 0
                    for offset in 0..<4 { v |= UInt32(bytes[index + offset]) << UInt32(8 * offset) }
                    result.append(Double(Float(bitPattern: v)))
                    index += 4
                }
            default:
                break
            }
        }
        return result
    }
}
