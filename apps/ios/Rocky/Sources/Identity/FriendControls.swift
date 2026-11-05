import SwiftUI
import UniformTypeIdentifiers

struct FriendBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct FriendControls: View {
    @ObservedObject var store: FriendStore
    let reference: FaceFeaturePrintDescriptor?
    @State private var name = ""
    @State private var message: String?
    @State private var password = ""
    @State private var working = false
    @State private var exporting = false
    @State private var importing = false
    @State private var document: FriendBackupDocument?
    @State private var pendingRestore: FriendVault?
    @State private var forgetID: UUID?
    @State private var confirmClear = false

    var body: some View {
        Section("Remember a friend") {
            Text("Capture a reference above, then save their name once. During conversation Rocky will recognize saved friends automatically. Only save someone who agrees.")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("Name", text: $name).textContentType(.givenName)
            Button("Remember this face") {
                do {
                    try store.remember(name: name, descriptor: reference!)
                    message = "Saved. Resume conversation from the orb when ready."
                    name = ""
                } catch { message = error.localizedDescription }
            }
            .disabled(reference == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message { Text(message).font(.footnote) }
            if let error = store.error { Text(error).foregroundStyle(.red).font(.footnote) }
            ForEach(store.vault.friends) { friend in
                HStack {
                    Text(friend.name)
                    Spacer()
                    Text(friend.templates.allSatisfy { $0.preprocessing == FaceProbeCapture.preprocessing }
                         ? "\(friend.templates.count)/5 samples" : "Refresh reference")
                        .foregroundStyle(.secondary)
                    Button("Forget", role: .destructive) { forgetID = friend.id }
                        .buttonStyle(.borderless)
                }
            }
            Text("For better angle coverage, capture another reference and save the same name. Up to five samples per friend. Names can reach the conversation service; face vectors stay on this phone.")
                .font(.footnote).foregroundStyle(.secondary)
            if store.vault.friends.contains(where: { $0.templates.contains(where: { $0.preprocessing == nil }) }) {
                Text("Camera normalization was corrected. Capture a new reference and save the same name to refresh that friend's old samples. Names and other friends are preserved.")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        Section("Backup & restore") {
            Text("Before reinstalling, export a backup and keep its password. App deletion removes the local friend list. There is no automatic cloud sync.")
                .font(.footnote).foregroundStyle(.secondary)
            SecureField("Backup password (10+ characters)", text: $password)
            Button("Export encrypted friends") { exportBackup() }
                .disabled(password.count < 10 || store.vault.friends.isEmpty || working)
            Button("Restore encrypted friends…") { importing = true }
                .disabled(password.isEmpty || working)
            if working { ProgressView("Processing backup…") }
            Button("Clear saved friends", role: .destructive) { confirmClear = true }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .data,
                      defaultFilename: "Rocky-friends.rockyfriends") { result in
            if case .failure = result { message = "Backup was not saved." }
            document = nil
            password = ""
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): restoreBackup(url)
            case .failure: message = "No backup selected."
            }
        }
        .alert("Replace saved friends?", isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingRestore = nil }
            Button("Replace", role: .destructive) {
                do {
                    if let pendingRestore { try store.restore(pendingRestore) }
                    message = "Friends restored."
                } catch { message = error.localizedDescription }
                pendingRestore = nil
            }
        } message: { Text("This replaces the local list with the validated encrypted backup.") }
        .confirmationDialog("Forget this friend?", isPresented: Binding(
            get: { forgetID != nil }, set: { if !$0 { forgetID = nil } }
        ), titleVisibility: .visible) {
            Button("Forget friend", role: .destructive) {
                do { if let forgetID { try store.forget(forgetID) } }
                catch { message = error.localizedDescription }
                forgetID = nil
            }
        }
        .confirmationDialog("Clear all saved friends?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear saved friends", role: .destructive) {
                do { try store.clear() } catch { message = error.localizedDescription }
            }
        }
    }

    private func exportBackup() {
        working = true
        let vault = store.vault
        let password = password
        Task {
            defer { working = false }
            do {
                let data = try await Task.detached { try FriendBackup.seal(vault, password: password) }.value
                document = FriendBackupDocument(data: data)
                exporting = true
            } catch { message = error.localizedDescription }
        }
    }

    private func restoreBackup(_ url: URL) {
        working = true
        let password = password
        Task {
            defer { working = false; self.password = "" }
            do {
                let vault = try await Task.detached {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 2_000_000 else { throw FriendStoreError.backup }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 2_000_001) ?? Data()
                    return try FriendBackup.open(data, password: password)
                }.value
                pendingRestore = vault
            } catch { message = error.localizedDescription }
        }
    }
}
