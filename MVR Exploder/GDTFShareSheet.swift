import SwiftUI

/// Swapping one fixture type's GDTF for one from GDTF Share.
///
/// Sign in once — the account is kept in the Keychain — then search, with
/// the type's own manufacturer and name already filled in. Picking a result
/// shows where each mode in use would go on the new GDTF: the same name
/// where there is one, else the same footprint, and any change in channels
/// called out before anything is replaced. Replacing is one undo step.
struct GDTFShareSheet: View {
    @ObservedObject var document: MVRDocument
    let spec: String
    let typeName: String
    /// Modes in use, with how many fixtures and the old footprint.
    let modesInUse: [(mode: String, count: Int, channels: Int?)]
    /// The message to show, or nil when cancelled.
    let onDone: (String?) -> Void

    @State private var signedInUser: String?
    @State private var user = ""
    @State private var password = ""
    @State private var remember = true
    @State private var entries: [GDTFShareEntry] = []
    @State private var query = ""
    @State private var selection: GDTFShareEntry.ID?
    @State private var modeMap: [String: String] = [:]
    @State private var isWorking = false
    @State private var working = ""
    @State private var problem: String?

    private var client: GDTFShareClient { .shared }

    private var results: [GDTFShareEntry] {
        GDTFShareClient.search(entries, for: query)
    }

    private var chosen: GDTFShareEntry? {
        results.first { $0.id == selection } ?? entries.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Replace the GDTF for \(typeName)")
                    .font(.title3.weight(.semibold))
                Text("Now: \(spec)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if signedInUser == nil {
                signIn
            } else {
                browser
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let signedInUser {
                    Text("Signed in to GDTF Share as \(signedInUser)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Sign Out") { Task { await signOut() } }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text(working)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                if signedInUser != nil {
                    Button("Replace GDTF") { Task { await replace() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(chosen == nil || isWorking)
                }
            }
        }
        .padding(20)
        .frame(width: 820, height: signedInUser == nil ? 340 : 640)
        .task { await start() }
    }

    // MARK: - Signing in

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GDTF Share holds fixtures' full GDTFs — every mode, the real channels and models — where the file may only carry a stand-in. It needs a free account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Username:", text: $user)
                    .textContentType(.username)
                SecureField("Password:", text: $password)
                    .textContentType(.password)
                    .onSubmit { Task { await signInTapped() } }
                Toggle("Remember in my Keychain", isOn: $remember)
            }
            .formStyle(.columns)
            .frame(maxWidth: 420)
            HStack {
                Button("Sign In") { Task { await signInTapped() } }
                    .disabled(user.isEmpty || password.isEmpty || isWorking)
                Link("Create a free GDTF Share account", destination: URL(string: "https://gdtf-share.com/")!)
                    .font(.callout)
            }
        }
    }

    // MARK: - Choosing

    private var browser: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search", text: $query, prompt: Text("Search GDTF Share by manufacturer and fixture"))
                .textFieldStyle(.roundedBorder)

            Table(results, selection: $selection) {
                TableColumn("Fixture") { entry in
                    Text(entry.fixture).fontWeight(.medium).lineLimit(1)
                }
                .width(min: 160, ideal: 230)
                TableColumn("Manufacturer") { entry in
                    Text(entry.manufacturer).lineLimit(1)
                }
                .width(min: 90, ideal: 120)
                TableColumn("Revision") { entry in
                    Text(entry.revision).lineLimit(1).foregroundStyle(.secondary).help(entry.revision)
                }
                .width(min: 80, ideal: 150)
                TableColumn("Updated") { entry in
                    Text(entry.lastModified, format: .dateTime.day().month(.abbreviated).year())
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 95)
                TableColumn("By") { entry in
                    if entry.isFromManufacturer {
                        Label("Manufacturer", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("User").foregroundStyle(.secondary)
                    }
                }
                .width(min: 70, ideal: 110)
                TableColumn("Modes") { entry in
                    Text("\(entry.modes.count)").monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 40, ideal: 50)
            }
            .frame(minHeight: 200)
            .overlay {
                if entries.isEmpty && isWorking {
                    ProgressView("Fetching the GDTF Share list…")
                } else if results.isEmpty && !entries.isEmpty {
                    Text(query.isEmpty ? "Type a fixture name to search." : "Nothing on GDTF Share matches that.")
                        .foregroundStyle(.secondary)
                }
            }

            if let chosen {
                modeMapping(chosen)
            } else {
                Text("Pick a fixture to see where each mode in use would go.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 90, alignment: .topLeading)
            }
        }
        .onChange(of: selection) { _, _ in fillModeMap() }
    }

    private func modeMapping(_ entry: GDTFShareEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Modes")
                .font(.headline)
            if entry.modes.isEmpty {
                Text("This GDTF lists no modes.")
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(modesInUse, id: \.mode) { old in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(old.mode == "-" || old.mode.isEmpty ? "No mode" : old.mode)
                                .fontWeight(.medium)
                            Text("\(old.count) fixture\(old.count == 1 ? "" : "s")" + (old.channels.map { " · \($0) ch" } ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Picker("New mode", selection: Binding(
                            get: { modeMap[old.mode] ?? "" },
                            set: { modeMap[old.mode] = $0 })
                        ) {
                            ForEach(entry.modes, id: \.name) { mode in
                                Text("\(mode.name) — \(mode.footprint) ch").tag(mode.name)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                        footprintChange(from: old.channels, to: entry.modes.first { $0.name == modeMap[old.mode] }?.footprint)
                    }
                }
            }
        }
        .frame(minHeight: 90, alignment: .topLeading)
    }

    @ViewBuilder
    private func footprintChange(from old: Int?, to new: Int?) -> some View {
        if let old, let new, old != new {
            Label("\(new > old ? "+" : "−")\(abs(new - old)) ch each — check the patch after", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if old != nil, new != nil {
            Label("Same footprint", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    // MARK: - Work

    private func start() async {
        query = GDTFShareClient.suggestedQuery(for: spec)
        if let user = await client.signedInUser {
            signedInUser = user
            await loadEntries()
        } else if let saved = GDTFShareKeychain.load() {
            user = saved.user
            password = saved.password
            await signInTapped()
        }
    }

    private func signInTapped() async {
        isWorking = true
        working = "Signing in…"
        problem = nil
        defer { isWorking = false }
        do {
            try await client.signIn(user: user, password: password)
            if remember {
                GDTFShareKeychain.save(user: user, password: password)
            }
            signedInUser = user
            password = ""
            await loadEntries()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func signOut() async {
        await client.signOut()
        GDTFShareKeychain.delete()
        signedInUser = nil
        entries = []
        selection = nil
    }

    private func loadEntries() async {
        isWorking = true
        working = "Fetching the GDTF Share list…"
        defer { isWorking = false }
        do {
            entries = try await client.entries()
            selection = results.first?.id
            fillModeMap()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func fillModeMap() {
        guard let chosen else { return }
        var map: [String: String] = [:]
        for old in modesInUse {
            map[old.mode] = GDTFShareClient.defaultMode(for: old.mode, footprint: old.channels, in: chosen.modes)
        }
        modeMap = map
    }

    private func replace() async {
        guard let chosen else { return }
        isWorking = true
        working = "Downloading \(chosen.fixture)…"
        problem = nil
        defer { isWorking = false }
        do {
            let data = try await client.download(chosen)
            document.replaceGDTF(
                spec, withFile: chosen.fileName, data: data, modes: modeMap,
                source: MVRUserData.GDTFSource(
                    rid: chosen.rid, manufacturer: chosen.manufacturer, fixture: chosen.fixture,
                    revision: chosen.revision, uploader: chosen.uploader, modified: chosen.lastModified))
            onDone("Replaced \(typeName)'s GDTF with \(chosen.manufacturer) \(chosen.fixture) (\(chosen.revision)) from GDTF Share. ⌘Z undoes it.")
        } catch {
            problem = error.localizedDescription
        }
    }
}
