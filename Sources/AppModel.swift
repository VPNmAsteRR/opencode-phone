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
//
// SSE лишь подаёт сигнал «что-то изменилось». Сами данные тянет AppModel,
// причём с троттлингом — иначе поток событий устраивает шторм запросов.

final class EventStream {
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var signal: (() -> Void)?

    func onSignal(_ handler: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        signal = handler
    }

    func start(baseURL: URL, username: String, password: String) {
        stop()
        task = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                do {
                    try await self?.consume(baseURL: baseURL, username: username, password: password)
                    attempt = 0
                } catch {
                    if Task.isCancelled { return }
                    attempt = min(attempt + 1, 5)
                    let delay = UInt64(pow(1.8, Double(attempt)) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
    }

    private func consume(baseURL: URL, username: String, password: String) async throws {
        var normalized = baseURL.absoluteString
        if !normalized.hasSuffix("/") { normalized += "/" }
        guard let url = URL(string: "api/event", relativeTo: URL(string: normalized))?.absoluteURL else {
            throw OCError.badURL
        }
        var req = URLRequest(url: url)
        let raw = "\(username):\(password)".data(using: .utf8) ?? Data()
        req.setValue("Basic " + raw.base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.timeoutInterval = 3600

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 3600
        cfg.timeoutIntervalForResource = .infinity
        cfg.waitsForConnectivity = true
        let s = URLSession(configuration: cfg)

        let (bytes, resp) = try await s.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 { throw OCError.unauthorized }

        var lastSignal = Date.distantPast
        for try await line in bytes.lines {
            if Task.isCancelled { return }
            guard line.hasPrefix("data:") else { continue }
            let now = Date()
            // не чаще 8 раз в секунду
            if now.timeIntervalSince(lastSignal) < 0.12 { continue }
            lastSignal = now
            lock.lock()
            let handler = signal
            lock.unlock()
            handler?()
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
    @Published var agentWorking = false

    /// Подпись содержимого переписки — по ней SwiftUI понимает, что текст изменился
    @Published private(set) var messagesSignature: String = ""

    let events = EventStream()
    private var api: OpenCodeAPI?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh = false
    private var refreshing = false
    private var lastSessionsFetch = Date.distantPast

    var currentSessionID: String? {
        didSet { if oldValue != currentSessionID { resetStream() } }
    }

    private func resetStream() {
        refreshTask?.cancel()
        refreshTask = nil
        guard let sid = currentSessionID else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if Task.isCancelled { return }
                await self?.refreshSession(sid, quiet: true)
            }
        }
    }

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
            serverVersion = info.version ?? ""
            connectionOK = true
            errorText = nil
            events.onSignal { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
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

    // MARK: Список сессий

    func loadSessions(quiet: Bool = false) async {
        guard let api else { return }
        if !quiet { loadingSessions = true }
        defer { if !quiet { loadingSessions = false } }
        do {
            sessions = try await api.sessions()
            lastSessionsFetch = Date()
            if errorText != nil { errorText = nil }
        } catch {
            if !quiet { errorText = error.localizedDescription }
        }
    }

    // MARK: Сессия и сообщения

    func openSession(_ session: OCSession) async {
        if currentSessionID != session.id {
            messages = []
            messagesSignature = ""
            currentSessionID = session.id
        }
        loadingMessages = messages.isEmpty
        await refreshSession(session.id, quiet: false)
        loadingMessages = false
    }

    /// Дебаунс обновлений от SSE
    private var debounceTask: Task<Void, Never>?

    private func scheduleRefresh() {
        if refreshing { pendingRefresh = true; return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if let sid = self.currentSessionID {
                await self.refreshSession(sid, quiet: true)
            }
            if Date().timeIntervalSince(self.lastSessionsFetch) > 3 {
                await self.loadSessions(quiet: true)
            }
        }
    }

    /// Тянет сообщения сессии. Не запускается параллельно самой себя.
    func refreshSession(_ sid: String, quiet: Bool) async {
        guard let api else { return }
        if refreshing { pendingRefresh = true; return }
        refreshing = true
        defer {
            refreshing = false
            if pendingRefresh {
                pendingRefresh = false
                scheduleRefresh()
            }
        }
        do {
            let fresh = try await api.messages(sessionID: sid)
            guard sid == currentSessionID else { return }
            apply(fresh)
            if !quiet, errorText != nil { errorText = nil }
        } catch {
            if !quiet { errorText = error.localizedDescription }
        }
    }

    private func apply(_ fresh: [OCMessage]) {
        let sig = AppModel.signature(of: fresh)
        if sig == messagesSignature { return }
        messages = fresh
        messagesSignature = sig

        if let last = fresh.last {
            if last.isUser {
                agentWorking = true
            } else if last.type == "assistant" {
                let fin = last.finish ?? last.status
                agentWorking = (fin == nil || fin?.isEmpty == true)
            } else {
                agentWorking = false
            }
        } else {
            agentWorking = false
        }
    }

    /// Отпечаток переписки: id + объём текста каждой части.
    /// Ловит и новые сообщения, и рост текста внутри уже существующих.
    nonisolated static func signature(of msgs: [OCMessage]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(msgs.count * 2)
        for m in msgs {
            var n = m.id.count + (m.text?.count ?? 0)
            for c in m.content ?? [] {
                n += c.type.count + (c.text?.count ?? 0) + (c.name?.count ?? 0)
                if let s = c.state {
                    n += (s.status?.count ?? 0) + s.resultText.count
                }
            }
            parts.append("\(m.id)#\(n)")
        }
        return parts.joined(separator: "|")
    }

    func reloadMessages() async {
        if let sid = currentSessionID {
            await refreshSession(sid, quiet: false)
        }
    }

    // MARK: Отправка

    /// Возвращает управление сразу после того, как сервер принял сообщение.
    /// Ответ агента подтягивается опросом/SSE — интерфейс не блокируется.
    func send(_ text: String) async -> Bool {
        guard let api, let sid = currentSessionID else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        sending = true
        defer { sending = false }
        do {
            try await api.sendPrompt(sessionID: sid, text: trimmed)
            errorText = nil
            agentWorking = true
            await refreshSession(sid, quiet: true)
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
            await loadSessions(quiet: true)
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

    func stopEvents() {
        events.stop()
        refreshTask?.cancel()
        refreshTask = nil
    }
}
