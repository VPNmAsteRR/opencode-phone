import Foundation
import SwiftUI

// MARK: - Хранилище настроек подключения

struct ConnectionSettings: Codable, Equatable {
    var baseURL: String = "https://oc.13.143.161.69.sslip.io:8443"
    var username: String = "opencode"
    var password: String = ""

    var url: URL? { URL(string: baseURL) }
    var isValid: Bool { url != nil && !username.isEmpty && !password.isEmpty }

    static let defaultsKey = "oc.connection.v1"

    static func load() -> ConnectionSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let v = try? JSONDecoder().decode(ConnectionSettings.self, from: data) else {
            return ConnectionSettings()
        }
        return v
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Живой поток событий

@MainActor
final class EventStream {
    private var task: Task<Void, Never>?
    var onEvent: ((String) -> Void)?

    func start(baseURL: URL, username: String, password: String) {
        stop()
        task = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                do {
                    try await self?.consume(baseURL: baseURL, username: username, password: password) {
                        attempt = 0
                        self?.onEvent?("tick")
                    }
                } catch {
                    attempt = min(attempt + 1, 6)
                    let delay = UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
    }

    private func consume(baseURL: URL, username: String, password: String,
                         onEvent: @escaping () -> Void) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/event"))
        let raw = "\(username):\(password)".data(using: .utf8) ?? Data()
        req.setValue("Basic " + raw.base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 3600

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 { throw OCError.unauthorized }
        for try await line in bytes.lines {
            if Task.isCancelled { return }
            if line.hasPrefix("data:") { onEvent() }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Главное состояние

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = ConnectionSettings.load()
    @Published var sessions: [OCSession] = []
    @Published var messages: [OCMessage] = []
    @Published var loadingSessions = false
    @Published var loadingMessages = false
    @Published var sending = false
    @Published var errorText: String?
    @Published var connectionOK = false
    @Published var serverVersion = ""

    let events = EventStream()
    private var api: OpenCodeAPI?

    var currentSessionID: String?

    func rebuildClient() {
        guard let url = settings.url, settings.isValid else {
            api = nil
            connectionOK = false
            return
        }
        api = OpenCodeAPI(baseURL: url, username: settings.username, password: settings.password)
    }

    /// Полная проверка: сервер отвечает и авторизация проходит
    func connect() async -> Bool {
        rebuildClient()
        guard let api else { connectionOK = false; return false }
        do {
            let info = try await api.info()
            serverVersion = info.version
            connectionOK = true
            errorText = nil
            events.onEvent = { [weak self] _ in
                Task { @MainActor in await self?.refreshQuietly() }
            }
            if let url = settings.url {
                events.start(baseURL: url, username: settings.username, password: settings.password)
            }
            await loadSessions()
            return true
        } catch {
            connectionOK = false
            errorText = error.localizedDescription
            return false
        }
    }

    func loadSessions() async {
        guard let api else { return }
        loadingSessions = true
        defer { loadingSessions = false }
        do {
            sessions = try await api.sessions()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func openSession(_ session: OCSession) async {
        currentSessionID = session.id
        await loadMessages()
    }

    func loadMessages() async {
        guard let api, let sid = currentSessionID else { return }
        loadingMessages = true
        defer { loadingMessages = false }
        do {
            messages = try await api.messages(sessionID: sid)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Тихая догрузка по событию SSE
    private func refreshQuietly() async {
        guard let api else { return }
        if let sid = currentSessionID {
            if let fresh = try? await api.messages(sessionID: sid),
               fresh.count != messages.count || fresh.last?.id != messages.last?.id {
                messages = fresh
            }
        }
        if let list = try? await api.sessions(), list != sessions {
            sessions = list
        }
    }

    func send(_ text: String) async -> Bool {
        guard let api, let sid = currentSessionID else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        sending = true
        defer { sending = false }
        do {
            try await api.sendPrompt(sessionID: sid, text: trimmed)
            errorText = nil
            // показываем отправленное сразу, затем подтянем ответ
            await loadMessages()
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                await loadMessages()
                if let last = messages.last, !last.isUser, !last.displayText.isEmpty { break }
            }
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    func createSession(title: String?, directory: String?) async -> OCSession? {
        guard let api else { return nil }
        do {
            let s = try await api.createSession(title: title, directory: directory)
            await loadSessions()
            return s
        } catch {
            errorText = error.localizedDescription
            return nil
        }
    }

    func projects() async -> [OCProject] {
        guard let api else { return [] }
        return (try? await api.projects()) ?? []
    }
}
