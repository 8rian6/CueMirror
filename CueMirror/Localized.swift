import Foundation

@inline(__always)
func L(_ source: String) -> String {
    NSLocalizedString(source, value: source, comment: "")
}

@inline(__always)
func LF(_ source: String, _ arguments: CVarArg...) -> String {
    String(format: L(source), locale: Locale.current, arguments: arguments)
}
