import AppKit

/// Checks GitHub for a newer release and downloads it.
///
/// Releases are published on GitHub with the DMG attached, so the latest
/// release *is* the update feed — nothing else to host or keep in step.
/// Checked once at launch, quietly, and from the app menu on request.
///
/// The update is downloaded and its disk image opened, not installed: the
/// app is sandboxed and not signed with a Developer ID, so it can't replace
/// itself in /Applications. The new copy is dragged across as on first
/// install, and macOS asks once more before opening it, as it did then.
@MainActor
final class Updater {
    static let shared = Updater()

    private static let latestRelease = URL(string: "https://api.github.com/repos/oliverh57/MVR-Exploder/releases/latest")!
    private static let skippedVersionKey = "updaterSkippedVersion"

    private var isBusy = false

    struct Release: Decodable {
        let tag_name: String
        let name: String?
        let html_url: URL
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Whether `candidate` is a later version than `current`. A leading "v"
    /// is ignored and missing parts count as zero, so tag "v1.3.0" is the
    /// same version as the app's "1.3".
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// `userInitiated` is false for the launch check: that one says nothing
    /// unless there is an update, and leaves out a version already skipped.
    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let release: Release
        do {
            var request = URLRequest(url: Self.latestRelease)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            if userInitiated { showError("Couldn't check for updates.", error) }
            return
        }

        let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.isNewer(version, than: currentVersion) else {
            if userInitiated {
                let alert = NSAlert()
                alert.messageText = "MVR Exploder is up to date."
                alert.informativeText = "Version \(currentVersion) is the latest."
                alert.runModal()
            }
            return
        }
        if !userInitiated, UserDefaults.standard.string(forKey: Self.skippedVersionKey) == version {
            return
        }

        let alert = NSAlert()
        alert.messageText = "MVR Exploder \(version) is available."
        var info = "You have \(currentVersion)."
        if let name = release.name, !name.isEmpty { info += "\n\n\(name)" }
        alert.informativeText = info
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if !userInitiated { alert.addButton(withTitle: "Skip This Version") }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await download(release)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(version, forKey: Self.skippedVersionKey)
        default:
            break
        }
    }

    /// Saves the release's DMG to Downloads and opens it. A release with no
    /// DMG attached opens its GitHub page instead.
    private func download(_ release: Release) async {
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            NSWorkspace.shared.open(release.html_url)
            return
        }

        do {
            let (temporary, response) = try await URLSession.shared.download(from: asset.browser_download_url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            let destination = downloads.appendingPathComponent(asset.name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            NSWorkspace.shared.open(destination)
        } catch {
            showError("Couldn't download the update.", error)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Install the update"
        alert.informativeText = """
            The new version has been saved to Downloads and opened. \
            Quit MVR Exploder, then drag the new copy onto Applications \
            and choose Replace.
            """
        alert.addButton(withTitle: "Quit Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    private func showError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
