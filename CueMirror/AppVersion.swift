import Foundation

enum AppVersion {
    static var displayName: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Development"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "v\(version)" : "v\(version) (\(build))"
    }
}
