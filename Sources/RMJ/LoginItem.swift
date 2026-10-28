import Foundation
import ServiceManagement

enum LoginItem {
    private static let registeredKey = "loginItemRegistered"

    /// Registers RMJ to open at login, once: a person who turns it off in System Settings keeps
    /// it off. Only the installed app does this, never `swift run` or a build folder copy.
    static func registerOnce() {
        guard isInstalled(Bundle.main.bundleURL),
              !UserDefaults.standard.bool(forKey: registeredKey) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: registeredKey)
        } catch {
            // Retried at the next launch; the app works without it.
        }
    }

    /// Exactly /Applications/RMJ.app, or ~/Applications/RMJ.app where a user without admin
    /// rights installs (install.sh): not a copy or a backup folder beneath them.
    private static func isInstalled(_ bundle: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/RMJ.app", home + "/Applications/RMJ.app"].contains(bundle.path)
    }
}
