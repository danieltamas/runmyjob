import Foundation

/// `rmj --version`: the version of the app bundle the CLI is installed in (`RMJ.app/Contents/Resources/rmj`).
public enum VersionCommand {
    public static let flags: Set<String> = ["--version", "-V", "version"]

    public static func text(executable: String) -> String {
        let plist = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Info.plist")
        let info = NSDictionary(contentsOf: plist)
        return "rmj \((info?["CFBundleShortVersionString"] as? String) ?? "unknown")"
    }
}
