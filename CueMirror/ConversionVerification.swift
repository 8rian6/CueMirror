import Foundation

struct TrackConversionVerification {
    let anlzWriteSucceeded: Bool
    let databaseWriteSucceeded: Bool
    let anlzReadbackMatches: Bool
    let databaseReadbackMatches: Bool

    var isSuccessful: Bool {
        anlzWriteSucceeded &&
        databaseWriteSucceeded &&
        anlzReadbackMatches &&
        databaseReadbackMatches
    }
}

enum MemoryCueNormalizer {
    static func normalized(_ cues: [Pco2CueReport]) -> [Pco2CueReport] {
        cues.sorted(by: MemoryCueReplacementPlanner.memoryCueWriteOrder)
    }

    static func contentsMatch(
        expected: [Pco2CueReport],
        actual: [Pco2CueReport]
    ) -> Bool {
        let lhs = normalized(expected)
        let rhs = normalized(actual)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0.hasSameContent(as: $1) }
    }
}
