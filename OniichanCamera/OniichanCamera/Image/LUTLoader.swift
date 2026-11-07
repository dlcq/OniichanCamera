import CoreGraphics
import Foundation

/// Impulse LUT (.cube) ファイルのローダー。
/// 3D LUT のみ対応（LUT_3D_SIZE）。読み込んだ LUT は `ColorPipeline` の最終段で適用される。
struct CubeLUT: Equatable {
    let name: String
    let dimension: Int
    let data: Data

    static func == (lhs: CubeLUT, rhs: CubeLUT) -> Bool {
        lhs.name == rhs.name && lhs.dimension == rhs.dimension && lhs.data == rhs.data
    }
}

enum LUTLoader {

    static func load(from url: URL) throws -> CubeLUT {
        let raw = try Data(contentsOf: url)
        guard let text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .ascii) else {
            throw LUTError.invalidFile
        }
        return try parse(text: text, name: url.deletingPathExtension().lastPathComponent)
    }

    enum LUTError: LocalizedError {
        case invalidFile
        case unsupportedDimension
        case malformedData

        var errorDescription: String? {
            switch self {
            case .invalidFile: return "LUT ファイルを読み込めませんでした。"
            case .unsupportedDimension: return "対応していない LUT サイズです（2〜64 の 3D LUT）。"
            case .malformedData: return "LUT のデータ形式が正しくありません。"
            }
        }
    }

    static func parse(text: String, name: String) throws -> CubeLUT {
        var dimension = 0
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var entries: [SIMD3<Float>] = []

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = tokens.first else { continue }

            if first.uppercased() == "LUT_3D_SIZE" {
                guard tokens.count >= 2, let size = Int(tokens[1]) else { throw LUTError.malformedData }
                guard size >= 2, size <= 64 else { throw LUTError.unsupportedDimension }
                dimension = size
            } else if first.uppercased() == "LUT_1D_SIZE" {
                throw LUTError.unsupportedDimension
            } else if first.uppercased() == "DOMAIN_MIN" {
                guard tokens.count >= 4 else { throw LUTError.malformedData }
                domainMin = SIMD3<Float>(Float(tokens[1]) ?? 0, Float(tokens[2]) ?? 0, Float(tokens[3]) ?? 0)
            } else if first.uppercased() == "DOMAIN_MAX" {
                guard tokens.count >= 4 else { throw LUTError.malformedData }
                domainMax = SIMD3<Float>(Float(tokens[1]) ?? 1, Float(tokens[2]) ?? 1, Float(tokens[3]) ?? 1)
            } else if let r = Float(tokens[0]), tokens.count >= 3,
                      let g = Float(tokens[1]), let b = Float(tokens[2]) {
                entries.append(SIMD3<Float>(r, g, b))
            }
        }

        guard dimension > 0 else { throw LUTError.malformedData }
        let expected = dimension * dimension * dimension
        guard entries.count == expected else { throw LUTError.malformedData }

        // CIColorCubeWithColorSpace 用の RGBA float32 に変換（r が最も速く変化する順）
        var floats = [Float](repeating: 0, count: expected * 4)
        let span = max(domainMax.x - domainMin.x, 0.0001)
        let spanG = max(domainMax.y - domainMin.y, 0.0001)
        let spanB = max(domainMax.z - domainMin.z, 0.0001)
        for (index, entry) in entries.enumerated() {
            floats[index * 4] = (entry.x - domainMin.x) / span
            floats[index * 4 + 1] = (entry.y - domainMin.y) / spanG
            floats[index * 4 + 2] = (entry.z - domainMin.z) / spanB
            floats[index * 4 + 3] = 1
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(name: name, dimension: dimension, data: data)
    }
}
