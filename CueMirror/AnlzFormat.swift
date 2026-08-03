import Foundation

enum AnlzFormatError: LocalizedError, Equatable {
    case truncated(offset: Int, needed: Int)
    case invalidMagic(expected: String, actual: String)
    case invalidLength(offset: Int, header: Int, total: Int)

    var errorDescription: String? {
        switch self {
        case let .truncated(offset, needed):
            return LF("ANLZ 在偏移 %lld 缺少 %lld 字节。", offset, needed)
        case let .invalidMagic(expected, actual):
            return LF("ANLZ 标记错误：期望 %@，实际 %@。", expected, actual)
        case let .invalidLength(offset, header, total):
            return LF("ANLZ 长度错误：offset=%lld, header=%lld, total=%lld。", offset, header, total)
        }
    }
}

struct AnlzSectionHeader: Equatable {
    var magic: String
    var headerLength: UInt32
    var totalLength: UInt32

    static func parse(_ data: Data, at offset: Int) throws -> Self {
        let magic = try data.anlzASCII(at: offset, count: 4)
        let header = try data.anlzUInt32BE(at: offset + 4)
        let total = try data.anlzUInt32BE(at: offset + 8)
        guard header >= 12, total >= header else {
            throw AnlzFormatError.invalidLength(
                offset: offset,
                header: Int(header),
                total: Int(total)
            )
        }
        return Self(magic: magic, headerLength: header, totalLength: total)
    }

    func encoded() -> Data {
        var data = Data(magic.utf8.prefix(4))
        data.anlzAppendUInt32BE(headerLength)
        data.anlzAppendUInt32BE(totalLength)
        return data
    }
}

/// rekordcrate `LenPrefixedWideString` 的 Swift 对应结构。
/// `payload` 包含长度字段之后的原始字节，以便无损往返。
struct AnlzLenPrefixedWideString: Equatable {
    var value: String
    var payload: Data

    var byteLength: UInt32 { UInt32(payload.count) }

    static func parse(_ data: Data, at offset: Int, limit: Int) throws -> (Self, Int) {
        let length = Int(try data.anlzUInt32BE(at: offset))
        guard offset + 4 + length <= limit else {
            throw AnlzFormatError.truncated(offset: offset + 4, needed: length)
        }
        let payload = data.subdata(in: offset + 4..<offset + 4 + length)
        guard !payload.isEmpty else {
            return (Self(value: "", payload: payload), offset + 4)
        }
        var units: [UInt16] = []
        var cursor = 0
        while cursor + 1 < payload.count {
            units.append(UInt16(payload[cursor]) << 8 | UInt16(payload[cursor + 1]))
            cursor += 2
        }
        while units.last == 0 { units.removeLast() }
        return (
            Self(value: String(decoding: units, as: UTF16.self), payload: payload),
            offset + 4 + length
        )
    }

    init(value: String) {
        self.value = value
        guard !value.isEmpty else {
            payload = Data()
            return
        }
        var bytes = Data()
        for unit in value.utf16 { bytes.anlzAppendUInt16BE(unit) }
        bytes.anlzAppendUInt16BE(0)
        payload = bytes
    }

    init(value: String, payload: Data) {
        self.value = value
        self.payload = payload
    }

    func encoded() -> Data {
        var data = Data()
        data.anlzAppendUInt32BE(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

/// PCOB 内的 56 字节 PCPT。未知字段保留为原始整数/字节。
struct AnlzCue: Equatable {
    var header: AnlzSectionHeader
    var hotCueNumber: UInt32
    var status: UInt32
    var unknown1: UInt32
    var orderFirst: UInt16
    var orderLast: UInt16
    var cueType: UInt8
    var unknown2: UInt8
    var unknown3: UInt16
    var timeMs: UInt32
    var loopTimeMs: UInt32
    var unknownTrailing: Data

    static func parse(_ data: Data, at offset: Int, limit: Int) throws -> (Self, Int) {
        let header = try AnlzSectionHeader.parse(data, at: offset)
        guard header.magic == "PCPT" else {
            throw AnlzFormatError.invalidMagic(expected: "PCPT", actual: header.magic)
        }
        let end = offset + Int(header.totalLength)
        guard end <= limit, end >= offset + 40 else {
            throw AnlzFormatError.truncated(offset: offset, needed: Int(header.totalLength))
        }
        let cue = Self(
            header: header,
            hotCueNumber: try data.anlzUInt32BE(at: offset + 12),
            status: try data.anlzUInt32BE(at: offset + 16),
            unknown1: try data.anlzUInt32BE(at: offset + 20),
            orderFirst: try data.anlzUInt16BE(at: offset + 24),
            orderLast: try data.anlzUInt16BE(at: offset + 26),
            cueType: try data.anlzUInt8(at: offset + 28),
            unknown2: try data.anlzUInt8(at: offset + 29),
            unknown3: try data.anlzUInt16BE(at: offset + 30),
            timeMs: try data.anlzUInt32BE(at: offset + 32),
            loopTimeMs: try data.anlzUInt32BE(at: offset + 36),
            unknownTrailing: data.subdata(in: offset + 40..<end)
        )
        return (cue, end)
    }

    func encoded() -> Data {
        var body = Data()
        body.anlzAppendUInt32BE(hotCueNumber)
        body.anlzAppendUInt32BE(status)
        body.anlzAppendUInt32BE(unknown1)
        body.anlzAppendUInt16BE(orderFirst)
        body.anlzAppendUInt16BE(orderLast)
        body.append(cueType)
        body.append(unknown2)
        body.anlzAppendUInt16BE(unknown3)
        body.anlzAppendUInt32BE(timeMs)
        body.anlzAppendUInt32BE(loopTimeMs)
        body.append(unknownTrailing)
        var output = header.encoded()
        output.append(body)
        return output
    }
}

struct AnlzCueList: Equatable {
    var header: AnlzSectionHeader
    var listType: UInt32
    var unknown: UInt16
    var memoryCount: UInt32
    var headerExtra: Data
    var cues: [AnlzCue]
    var trailing: Data

    static func parse(_ raw: Data) throws -> Self {
        let header = try AnlzSectionHeader.parse(raw, at: 0)
        guard header.magic == "PCOB" else {
            throw AnlzFormatError.invalidMagic(expected: "PCOB", actual: header.magic)
        }
        let end = Int(header.totalLength)
        guard end <= raw.count, header.headerLength >= 24 else {
            throw AnlzFormatError.truncated(offset: 0, needed: end)
        }
        let count = Int(try raw.anlzUInt16BE(at: 18))
        var cursor = Int(header.headerLength)
        var cues: [AnlzCue] = []
        for _ in 0..<count {
            let (cue, next) = try AnlzCue.parse(raw, at: cursor, limit: end)
            cues.append(cue)
            cursor = next
        }
        return Self(
            header: header,
            listType: try raw.anlzUInt32BE(at: 12),
            unknown: try raw.anlzUInt16BE(at: 16),
            memoryCount: try raw.anlzUInt32BE(at: 20),
            headerExtra: raw.subdata(in: 24..<Int(header.headerLength)),
            cues: cues,
            trailing: raw.subdata(in: cursor..<end)
        )
    }

    func encoded() -> Data {
        var body = Data()
        body.anlzAppendUInt32BE(listType)
        body.anlzAppendUInt16BE(unknown)
        body.anlzAppendUInt16BE(UInt16(cues.count))
        body.anlzAppendUInt32BE(memoryCount)
        body.append(headerExtra)
        for cue in cues { body.append(cue.encoded()) }
        body.append(trailing)
        var output = header.encoded()
        output.append(body)
        return output
    }
}

/// PCO2 内的 PCP2。兼容截短条目；只有存在的字段才会被结构化。
struct AnlzExtendedCue: Equatable {
    var header: AnlzSectionHeader
    var hotCueNumber: UInt32
    var cueType: UInt8
    var unknown1: UInt8
    var unknown2: UInt16
    var timeMs: UInt32
    var loopTimeMs: UInt32
    var colorID: UInt8?
    var unknownBeforeLoop: Data
    var loopNumerator: UInt16?
    var loopDenominator: UInt16?
    var comment: AnlzLenPrefixedWideString?
    var hotCueColorIndex: UInt8?
    var colorRed: UInt8?
    var colorGreen: UInt8?
    var colorBlue: UInt8?
    var unknownWordsAfterColor: [UInt32]
    var trailing: Data

    static func parse(_ data: Data, at offset: Int, limit: Int) throws -> (Self, Int) {
        let header = try AnlzSectionHeader.parse(data, at: offset)
        guard header.magic == "PCP2" else {
            throw AnlzFormatError.invalidMagic(expected: "PCP2", actual: header.magic)
        }
        let end = offset + Int(header.totalLength)
        guard end <= limit, end >= offset + 28 else {
            throw AnlzFormatError.truncated(offset: offset, needed: Int(header.totalLength))
        }
        var cursor = offset + 28
        let colorID = cursor < end ? try data.anlzUInt8(at: cursor) : nil
        if colorID != nil { cursor += 1 }
        let beforeLoopEnd = min(end, cursor + 7)
        let unknownBeforeLoop = data.subdata(in: cursor..<beforeLoopEnd)
        cursor = beforeLoopEnd
        let loopNumerator = cursor + 2 <= end ? try data.anlzUInt16BE(at: cursor) : nil
        if loopNumerator != nil { cursor += 2 }
        let loopDenominator = cursor + 2 <= end ? try data.anlzUInt16BE(at: cursor) : nil
        if loopDenominator != nil { cursor += 2 }

        var comment: AnlzLenPrefixedWideString?
        if cursor + 4 <= end {
            let parsed = try AnlzLenPrefixedWideString.parse(data, at: cursor, limit: end)
            comment = parsed.0
            cursor = parsed.1
        }
        let colorBytesAvailable = end - cursor >= 4
        let colorIndex = colorBytesAvailable ? try data.anlzUInt8(at: cursor) : nil
        let red = colorBytesAvailable ? try data.anlzUInt8(at: cursor + 1) : nil
        let green = colorBytesAvailable ? try data.anlzUInt8(at: cursor + 2) : nil
        let blue = colorBytesAvailable ? try data.anlzUInt8(at: cursor + 3) : nil
        if colorBytesAvailable { cursor += 4 }

        var unknownWords: [UInt32] = []
        while unknownWords.count < 5, cursor + 4 <= end {
            unknownWords.append(try data.anlzUInt32BE(at: cursor))
            cursor += 4
        }
        let cue = Self(
            header: header,
            hotCueNumber: try data.anlzUInt32BE(at: offset + 12),
            cueType: try data.anlzUInt8(at: offset + 16),
            unknown1: try data.anlzUInt8(at: offset + 17),
            unknown2: try data.anlzUInt16BE(at: offset + 18),
            timeMs: try data.anlzUInt32BE(at: offset + 20),
            loopTimeMs: try data.anlzUInt32BE(at: offset + 24),
            colorID: colorID,
            unknownBeforeLoop: unknownBeforeLoop,
            loopNumerator: loopNumerator,
            loopDenominator: loopDenominator,
            comment: comment,
            hotCueColorIndex: colorIndex,
            colorRed: red,
            colorGreen: green,
            colorBlue: blue,
            unknownWordsAfterColor: unknownWords,
            trailing: data.subdata(in: cursor..<end)
        )
        return (cue, end)
    }

    func encoded() -> Data {
        var body = Data()
        body.anlzAppendUInt32BE(hotCueNumber)
        body.append(cueType)
        body.append(unknown1)
        body.anlzAppendUInt16BE(unknown2)
        body.anlzAppendUInt32BE(timeMs)
        body.anlzAppendUInt32BE(loopTimeMs)
        if let colorID { body.append(colorID) }
        body.append(unknownBeforeLoop)
        if let loopNumerator { body.anlzAppendUInt16BE(loopNumerator) }
        if let loopDenominator { body.anlzAppendUInt16BE(loopDenominator) }
        if let comment { body.append(comment.encoded()) }
        if let hotCueColorIndex, let colorRed, let colorGreen, let colorBlue {
            body.append(contentsOf: [hotCueColorIndex, colorRed, colorGreen, colorBlue])
        }
        for word in unknownWordsAfterColor { body.anlzAppendUInt32BE(word) }
        body.append(trailing)
        var output = header.encoded()
        output.append(body)
        return output
    }
}

struct AnlzExtendedCueList: Equatable {
    var header: AnlzSectionHeader
    var listType: UInt32
    var unknown: UInt16
    var headerExtra: Data
    var cues: [AnlzExtendedCue]
    var trailing: Data

    static func parse(_ raw: Data) throws -> Self {
        let header = try AnlzSectionHeader.parse(raw, at: 0)
        guard header.magic == "PCO2" else {
            throw AnlzFormatError.invalidMagic(expected: "PCO2", actual: header.magic)
        }
        let end = Int(header.totalLength)
        guard end <= raw.count, header.headerLength >= 20 else {
            throw AnlzFormatError.truncated(offset: 0, needed: end)
        }
        let count = Int(try raw.anlzUInt16BE(at: 16))
        var cursor = Int(header.headerLength)
        var cues: [AnlzExtendedCue] = []
        for _ in 0..<count {
            let (cue, next) = try AnlzExtendedCue.parse(raw, at: cursor, limit: end)
            cues.append(cue)
            cursor = next
        }
        return Self(
            header: header,
            listType: try raw.anlzUInt32BE(at: 12),
            unknown: try raw.anlzUInt16BE(at: 18),
            headerExtra: raw.subdata(in: 20..<Int(header.headerLength)),
            cues: cues,
            trailing: raw.subdata(in: cursor..<end)
        )
    }

    func encoded() -> Data {
        var body = Data()
        body.anlzAppendUInt32BE(listType)
        body.anlzAppendUInt16BE(UInt16(cues.count))
        body.anlzAppendUInt16BE(unknown)
        body.append(headerExtra)
        for cue in cues { body.append(cue.encoded()) }
        body.append(trailing)
        var output = header.encoded()
        output.append(body)
        return output
    }
}

enum AnlzSectionContent: Equatable {
    case cueList(AnlzCueList)
    case extendedCueList(AnlzExtendedCueList)
    case preserved(Data)

    func encoded() -> Data {
        switch self {
        case .cueList(let value): value.encoded()
        case .extendedCueList(let value): value.encoded()
        case .preserved(let data): data
        }
    }
}

struct AnlzSection: Equatable {
    var content: AnlzSectionContent
    func encoded() -> Data { content.encoded() }
}

struct AnlzDocument: Equatable {
    var header: AnlzSectionHeader
    var headerData: Data
    var sections: [AnlzSection]
    var trailing: Data

    static func parse(_ data: Data) throws -> Self {
        let header = try AnlzSectionHeader.parse(data, at: 0)
        guard header.magic == "PMAI" else {
            throw AnlzFormatError.invalidMagic(expected: "PMAI", actual: header.magic)
        }
        let fileEnd = Int(header.totalLength)
        let headerEnd = Int(header.headerLength)
        guard fileEnd <= data.count, headerEnd <= fileEnd else {
            throw AnlzFormatError.truncated(offset: 0, needed: fileEnd)
        }
        var cursor = headerEnd
        var sections: [AnlzSection] = []
        while cursor < fileEnd {
            let sectionHeader = try AnlzSectionHeader.parse(data, at: cursor)
            let end = cursor + Int(sectionHeader.totalLength)
            guard end <= fileEnd else {
                throw AnlzFormatError.truncated(offset: cursor, needed: Int(sectionHeader.totalLength))
            }
            let raw = data.subdata(in: cursor..<end)
            let content: AnlzSectionContent
            switch sectionHeader.magic {
            case "PCOB": content = .cueList(try AnlzCueList.parse(raw))
            case "PCO2": content = .extendedCueList(try AnlzExtendedCueList.parse(raw))
            default: content = .preserved(raw)
            }
            sections.append(AnlzSection(content: content))
            cursor = end
        }
        return Self(
            header: header,
            headerData: data.subdata(in: 12..<headerEnd),
            sections: sections,
            trailing: data.subdata(in: fileEnd..<data.count)
        )
    }

    func encoded() -> Data {
        var output = header.encoded()
        output.append(headerData)
        for section in sections { output.append(section.encoded()) }
        output.append(trailing)
        return output
    }
}

private extension Data {
    func anlzUInt8(at offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < count else {
            throw AnlzFormatError.truncated(offset: offset, needed: 1)
        }
        return self[startIndex + offset]
    }

    func anlzUInt16BE(at offset: Int) throws -> UInt16 {
        UInt16(try anlzUInt8(at: offset)) << 8 | UInt16(try anlzUInt8(at: offset + 1))
    }

    func anlzUInt32BE(at offset: Int) throws -> UInt32 {
        UInt32(try anlzUInt8(at: offset)) << 24 |
        UInt32(try anlzUInt8(at: offset + 1)) << 16 |
        UInt32(try anlzUInt8(at: offset + 2)) << 8 |
        UInt32(try anlzUInt8(at: offset + 3))
    }

    func anlzASCII(at offset: Int, count length: Int) throws -> String {
        guard offset >= 0, offset + length <= count else {
            throw AnlzFormatError.truncated(offset: offset, needed: length)
        }
        return String(decoding: self[offset..<offset + length], as: UTF8.self)
    }

    mutating func anlzAppendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff)); append(UInt8(value & 0xff))
    }

    mutating func anlzAppendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff)); append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff)); append(UInt8(value & 0xff))
    }
}
