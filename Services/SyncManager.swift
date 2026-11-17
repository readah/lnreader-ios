import Foundation
import Observation
import SwiftData

struct AuthenticatedUser: Codable, Equatable {
    let id: String
    let name: String?
    let email: String?
    let image: String?
    let username: String?
    let displayUsername: String?
}

private struct SyncEnvelope: Decodable {
    let user: AuthenticatedUser
    let data: RemoteSyncData?
}

private struct PushResult: Decodable {
    let ok: Bool
    let updatedAt: String
}

struct SyncProgress {
    let id = UUID()
    let title: String
    var detail: String
    var fraction: Double = 0
    var isFinished = false
    var failed = false
}

@Observable
@MainActor
final class SyncManager {
    var currentUser: AuthenticatedUser?
    private(set) var isWorking = false
    var lastMessage: String?
    var lastError: String?
    private(set) var progress: SyncProgress?
    private(set) var hasSynced = false
    private(set) var restoredContext: ModelContext?

    var backendURL: String = UserDefaults.standard.string(forKey: "sync.backendURL") ?? SyncManager.defaultBackendURL
    static let defaultBackendURL = "https://lnreader.traverses.dpdns.org"

    init() {
        if backendURL == "https://lnreader-sync-sky788.azurewebsites.net" || backendURL == "https://lnreader-sync.onrender.com" {
            updateBackendURL(Self.defaultBackendURL)
        }
    }

    private var baseURL: URL {
        URL(string: backendURL.trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: Self.defaultBackendURL)!
    }

    func updateBackendURL(_ value: String) {
        backendURL = value
        UserDefaults.standard.set(value, forKey: "sync.backendURL")
        currentUser = nil
        hasSynced = false
    }

    private var lastSyncedKey: String? {
        currentUser.map { "sync.lastSyncedAt.\(baseURL.absoluteString).\($0.id)" }
    }

    private var lastSyncedAt: Date? {
        get {
            guard let key = lastSyncedKey else { return nil }
            return UserDefaults.standard.object(forKey: key) as? Date
        }
        set {
            guard let key = lastSyncedKey else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            hasSynced = newValue != nil
        }
    }

    private func refreshSession() async throws {
        let envelope: SyncEnvelope = try await request(path: "/api/auth/get-session", method: "GET")
        currentUser = envelope.user
        hasSynced = lastSyncedAt != nil
    }

    func loadSession() async {
        guard !isWorking else { return }
        do {
            try await refreshSession()
        } catch {
            currentUser = nil
            hasSynced = false
        }
    }

    func signIn(identifier: String, password: String) async {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.contains("@") ? "/api/auth/sign-in/email" : "/api/auth/sign-in/username"
        let body: [String: Any] = trimmed.contains("@")
            ? ["email": trimmed, "password": password, "rememberMe": true]
            : ["username": trimmed, "password": password]
        await run("Signed in") {
            try await requestRaw(path: path, method: "POST", bodyData: try jsonData(body))
            try await refreshSession()
        }
    }

    func register(username: String, email: String, password: String) async {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "name": cleanUsername.isEmpty ? email : cleanUsername,
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
            "username": cleanUsername,
            "displayUsername": cleanUsername,
        ]
        await run("Account created") {
            try await requestRaw(path: "/api/auth/sign-up/email", method: "POST", bodyData: try jsonData(body))
            try await refreshSession()
        }
    }

    func signOut() async {
        await run("Signed out") {
            try await requestRaw(path: "/api/auth/sign-out", method: "POST", bodyData: try jsonData([String: String]()))
            currentUser = nil
            hasSynced = false
        }
    }

    func requestPasswordReset(email: String) async {
        await run("Password reset email requested") {
            try await requestRaw(path: "/api/auth/request-password-reset", method: "POST", bodyData: try jsonData([
                "email": email.trimmingCharacters(in: .whitespacesAndNewlines), "redirectTo": "lnreader://reset-password",
            ]))
        }
    }

    func resetPassword(token: String, newPassword: String) async {
        await run("Password reset") {
            try await requestRaw(path: "/api/auth/reset-password", method: "POST", bodyData: try jsonData([
                "token": token.trimmingCharacters(in: .whitespacesAndNewlines), "newPassword": newPassword,
            ]))
        }
    }

    func push(profile: UserProfile, sources: [any CatalogSource], context: ModelContext) async {
        await run("Uploaded library, books and bookmarks", title: "Syncing up") {
            try context.save()
            struct Meta: Decodable { let syncVersion: Int? }
            let meta: Meta = try await request(path: "/api/sync/meta", method: "GET")
            guard meta.syncVersion == 2 else { throw SyncError.requestFailed("Update the backend before syncing books and bookmarks.") }
            let container = context.container
            let profileInfo = SyncProfilePayload(username: currentUser?.username, email: currentUser?.email, name: profile.name, image: nil)
            let avatar = profile.avatarData
            let sourcePayloads = sources.map { SyncSourcePayload(source: $0) }
            setProgress("Preparing books and reading state", fraction: 0.02)
            let payload = try await Task.detached(priority: .userInitiated) {
                let background = ModelContext(container)
                var info = profileInfo
                info.image = avatar?.base64EncodedString()
                let entries = try background.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.inLibrary }))
                let library = entries.map { SyncNovelPayload(entry: $0) }
                var payload = SyncPayload(profile: info, library: library, sources: sourcePayloads, clientUpdatedAt: nil)
                payload.highlights = try background.fetch(FetchDescriptor<Highlight>()).map(SyncHighlightPayload.init)
                let includeLocalBooks = UserDefaults.standard.bool(forKey: "backup.includeLocalBooks")
                payload.localFiles = try SyncFiles.snapshot(library, includeLocalBooks: includeLocalBooks)
                return payload
            }.value

            let total = max(1, payload.localFiles.reduce(0) { $0 + $1.size })
            var completed = 0
            for file in payload.localFiles {
                for index in file.chunks.indices {
                    let bytes = try await Task.detached { try SyncFiles.chunk(file, index: index) }.value
                    let start = Double(completed) / Double(total)
                    let share = Double(bytes.count) / Double(total)
                    let detail = "Uploading books · \(ByteCountFormatter.string(fromByteCount: Int64(completed), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
                    setProgress(detail, fraction: 0.1 + 0.75 * start)
                    try await requestRaw(path: "/api/sync/blobs/\(file.chunks[index])", method: "PUT", bodyData: bytes,
                        contentType: "application/octet-stream", transfer: transferProgress(detail, start: 0.1 + 0.75 * start, span: 0.75 * share))
                    completed += bytes.count
                }
            }
            setProgress("Uploading reading state and bookmarks", fraction: 0.85)
            let body = try await Task.detached { try JSONEncoder().encode(payload) }.value
            let response = try await requestRaw(path: "/api/sync", method: "PUT", bodyData: body,
                transfer: transferProgress("Saving library to backend", start: 0.85, span: 0.13))
            let result = try JSONDecoder().decode(PushResult.self, from: response)
            guard result.ok, let date = SyncWire.date(from: result.updatedAt) else { throw SyncError.requestFailed("The backend did not confirm the upload.") }
            lastSyncedAt = date
        }
    }

    func restore(into context: ModelContext) async {
        await run("Downloaded library, books and bookmarks", title: "Syncing download") {
            try context.save()
            let response = try await requestRaw(path: "/api/sync", method: "GET", bodyData: nil,
                transfer: transferProgress("Downloading library", start: 0, span: 0.1))
            let envelope = try await Task.detached { try JSONDecoder().decode(SyncEnvelope.self, from: response) }.value
            guard let data = envelope.data else { throw SyncError.requestFailed("There is no cloud copy yet. Use Sync up on the device with your books first.") }
            let files = data.localFiles ?? []
            try await Task.detached {
                try SyncApplier.validate(data)
                try SyncFiles.validate(files, books: data.library, allowMissingLocalFiles: true)
            }.value
            currentUser = envelope.user
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("lnreader-sync-\(UUID().uuidString)")
            defer { Task.detached { try? FileManager.default.removeItem(at: staging) } }
            let total = max(1, files.reduce(0) { $0 + $1.size })
            var completed = 0
            for file in files {
                for index in file.chunks.indices {
                    let start = Double(completed) / Double(total)
                    let count = min(SyncFiles.chunkSize, file.size - index * SyncFiles.chunkSize)
                    let share = Double(count) / Double(total)
                    let detail = "Downloading books · \(ByteCountFormatter.string(fromByteCount: Int64(completed), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
                    setProgress(detail, fraction: 0.1 + 0.75 * start)
                    let bytes = try await requestRaw(path: "/api/sync/blobs/\(file.chunks[index])", method: "GET", bodyData: nil,
                        transfer: transferProgress(detail, start: 0.1 + 0.75 * start, span: 0.75 * share))
                    try await Task.detached { try SyncFiles.stage(bytes, file: file, index: index, root: staging) }.value
                    completed += count
                }
            }
            setProgress("Restoring books and reading state", fraction: 0.85)
            let container = context.container
            let report = transferProgress("Restoring reading state and bookmarks", start: 0.9, span: 0.09)
            try await Task.detached(priority: .userInitiated) {
                try SyncFiles.install(files, staging: staging)
                try SyncApplier.apply(data, context: ModelContext(container)) { done, total, _ in
                    report(Double(done) / Double(max(1, total)))
                }
            }.value
            await ChapterVisibility.reconcileAll(container: container)
            // SwiftData keeps registered models stale after another context saves.
            let refreshed = ModelContext(container)
            refreshed.autosaveEnabled = true
            restoredContext = refreshed
            NotificationCenter.default.post(name: ChapterVisibility.didChange, object: nil)
            lastSyncedAt = SyncWire.date(from: data.updatedAt)
        }
    }

    func dismissProgress() {
        guard progress?.isFinished == true else { return }
        progress = nil
    }

    private func setProgress(_ detail: String, fraction: Double) {
        guard var current = progress, !current.isFinished else { return }
        current.detail = detail
        current.fraction = max(current.fraction, min(0.99, fraction))
        progress = current
    }

    private func transferProgress(_ detail: String, start: Double, span: Double) -> @Sendable (Double) -> Void {
        let id = progress?.id
        return { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.isWorking, self.progress?.id == id else { return }
                self.setProgress(detail, fraction: start + span * fraction)
            }
        }
    }

    @discardableResult
    private func run(_ successMessage: String, title: String? = nil, operation: () async throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        lastError = nil
        lastMessage = nil
        progress = title.map { SyncProgress(title: $0, detail: "Connecting to backend") }
        defer { isWorking = false }
        do {
            try await operation()
            lastMessage = successMessage
            progress?.detail = successMessage
            progress?.fraction = 1
            progress?.isFinished = true
            if let id = progress?.id {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    if self?.progress?.id == id { self?.dismissProgress() }
                }
            }
            return true
        } catch {
            lastError = error.localizedDescription
            progress?.detail = error.localizedDescription
            progress?.failed = true
            progress?.isFinished = true
            return false
        }
    }

    private func request<T: Decodable>(path: String, method: String) async throws -> T {
        let data = try await requestRaw(path: path, method: method, bodyData: nil)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func requestRaw(path: String, method: String, bodyData: Data?, contentType: String = "application/json",
                            transfer: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let scheme = baseURL.scheme, let host = baseURL.host {
            var origin = "\(scheme)://\(host)"
            if let port = baseURL.port { origin += ":\(port)" }
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let data: Data
        let response: URLResponse
        let delegate = transfer.map { SyncTransferDelegate(report: $0) }
        if let bodyData {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            (data, response) = try await URLSession.shared.upload(for: request, from: bodyData, delegate: delegate)
        } else if let delegate {
            let result = try await URLSession.shared.download(for: request, delegate: delegate)
            response = result.1
            data = try await Task.detached {
                defer { try? FileManager.default.removeItem(at: result.0) }
                return try Data(contentsOf: result.0)
            }.value
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw SyncError.requestFailed("No response from the backend") }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 401 { throw SyncError.requestFailed("Your session expired. Sign in again, then retry sync.") }
            struct Failure: Decodable { let error: String?; let message: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw SyncError.requestFailed(failure?.error ?? failure?.message ?? "Backend request failed (HTTP \(http.statusCode)).")
        }
        return data
    }

    private func jsonData(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
}

private enum SyncError: LocalizedError {
    case requestFailed(String)
    var errorDescription: String? {
        switch self { case .requestFailed(let message): message }
    }
}

private final class SyncTransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { report(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

extension SyncSourcePayload {
    init(source: any CatalogSource) {
        id = SourceKey.identifier(from: source.key)
        name = source.name
        site = ""
        lang = source.lang
        version = "native"
        url = ""
        iconUrl = source.iconURL ?? ""
    }
}
