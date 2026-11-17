import Foundation

// MARK: - Модели
//
// Все поля, кроме идентификаторов, опциональны: сервер OpenCode V2 добавляет
// новые поля между версиями, и клиент не должен из-за этого падать.

struct ServerInfo: Decodable {
    let version: String?
}

struct SessionModelRef: Decodable, Hashable {
    let id: String?
    let providerID: String?
    let variant: String?
}

struct SessionTime: Decodable, Hashable {
    let created: Double?
    let updated: Double?
    let idle: Double?
}

struct OCProject: Decodable, Identifiable, Hashable {
    let id: String
    let canonical: String?

    var directory: String { canonical ?? "" }
}

struct OCSession: Decodable, Identifiable, Hashable {
    let id: String
    let projectID: String?
    let title: String?
    let agent: String?
    let model: SessionModelRef?
    let time: SessionTime?
    let outcome: String?
    let location: OCLocation?

    var displayTitle: String {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "Без названия" : t
    }
    var directory: String { location?.directory ?? "" }
    var updatedAt: Date {
        Date(timeIntervalSince1970: ((time?.updated ?? time?.created ?? 0)) / 1000)
    }
    var isWorking: Bool {
        if let o = outcome, o == "interrupted" { return false }
        guard let idle = time?.idle, let updated = time?.updated else { return false }
        return updated > idle && (updated - idle) < 300_000
    }
}

struct OCLocation: Decodable, Hashable {
    let directory: String?
}

// MARK: - Сообщения

struct OCMessage: Decodable, Identifiable {
    let id: String
    let type: String            // "user" | "assistant" | "system"
    let time: SessionTime?
    let text: String?
    let content: [OCPart]?
    let agent: String?
    let error: OCErrorPayload?
    let finish: String?
    let status: String?

    var isUser: Bool { type == "user" }
    var isSystem: Bool { type != "user" && type != "assistant" }

    /// Полный текст для отображения (user — text, assistant — склейка text-частей)
    var displayText: String {
        if let t = text, !t.isEmpty { return t }
        let parts = content ?? []
        let joined = parts.filter { $0.type == "text" }
            .compactMap { $0.text }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return joined
    }

    /// Только рассуждения модели
    var reasoningText: String {
        (content ?? []).filter { $0.type == "reasoning" }
            .compactMap { $0.text }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Инструменты (shell, edit, read и т.п.)
    var tools: [OCPart] {
        (content ?? []).filter { $0.type == "tool" }
    }
}

struct OCErrorPayload: Decodable {
    let message: String?
    let type: String?
    let name: String?
}

struct OCPart: Decodable {
    let type: String
    let text: String?
    let name: String?
    let id: String?
    let state: OCToolState?
    let time: SessionTime?

    var uid: String {
        if let i = id, !i.isEmpty { return i }
        return "\(type)-\(time?.created ?? 0)-\(name ?? "")-\(text?.prefix(20) ?? "")"
    }

    var statusText: String {
        guard let s = state else { return "" }
        switch s.status {
        case "running": return "выполняется"
        case "completed", "success": return "готово"
        case "error", "failed": return "ошибка"
        default: return s.status ?? ""
        }
    }
}

struct OCToolState: Decodable {
    let status: String?
    let input: OCToolInput?
    let output: String?
    let content: [OCToolContent]?
    let error: OCErrorPayload?

    /// Текст результата инструмента — сервер отдаёт его в content[].text
    var resultText: String {
        if let c = content, !c.isEmpty {
            let joined = c.compactMap { $0.text }.filter { !$0.isEmpty }.joined(separator: "\n")
            if !joined.isEmpty { return joined }
        }
        if let o = output, !o.isEmpty { return o }
        if let e = error { return e.message ?? e.name ?? "ошибка" }
        return ""
    }
}

struct OCToolContent: Decodable {
    let type: String?
    let text: String?
}

/// Вход инструмента. Набор полей у каждого инструмента свой —
/// декодируем самые частые, остальное игнорируем.
struct OCToolInput: Decodable {
    let command: String?
    let filePath: String?
    let path: String?
    let description: String?
    let query: String?
    let url: String?
    let pattern: String?
    let oldString: String?
    let newString: String?
    let code: String?
    let content: String?
    let format: String?
    let workdir: String?
    let title: String?

    /// Короткая человекочитаемая строка для карточки инструмента
    var summary: String {
        let candidates = [command, description, filePath, path, query, url, pattern, title]
        for c in candidates {
            if let c, !c.isEmpty { return c }
        }
        if let oldString, let newString, oldString != newString {
            return "изменить: \(oldString.prefix(60)) → \(newString.prefix(60))"
        }
        return ""
    }
}

// MARK: - Ответы-обёртки

struct DataEnvelope<T: Decodable>: Decodable {
    let data: T
}

// MARK: - Ошибки

enum OCError: LocalizedError {
    case badURL
    case unauthorized
    case http(Int, String)
    case transport(String)
    case decoding(String)
    case emptySessions(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Неверный адрес сервера"
        case .unauthorized: return "Сервер отклонил логин или пароль"
        case let .http(code, body):
            if code == 404 { return "Не найдено (404). Похоже, это не сервер OpenCode V2" }
            return "Ошибка сервера \(code): \(body.prefix(140))"
        case let .transport(msg): return "Нет связи с сервером: \(msg)"
        case let .decoding(msg): return "Непонятный ответ сервера: \(msg.prefix(140))"
        case let .emptySessions(sample): return "Сервер отдал неожиданный формат: \(sample.prefix(140))"
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Клиент

actor OpenCodeAPI {
    private let base: URL
    private let authHeader: String
    private let session: URLSession

    init(baseURL: URL, username: String, password: String) {
        var normalized = baseURL.absoluteString
        if !normalized.hasSuffix("/") { normalized += "/" }
        self.base = URL(string: normalized) ?? baseURL
        let raw = "\(username):\(password)".data(using: .utf8) ?? Data()
        self.authHeader = "Basic " + raw.base64EncodedString()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    private func request(_ path: String,
                         method: String = "GET",
                         query: [URLQueryItem] = [],
                         body: Data? = nil) -> URLRequest {
        let full = URL(string: path, relativeTo: base)?.absoluteURL ?? base
        var comps = URLComponents(url: full, resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query }
        var r = URLRequest(url: comps?.url ?? full)
        r.httpMethod = method
        r.setValue(authHeader, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// Отправляет запрос и возвращает сырые байты, проверяя только HTTP-статус.
    /// Разбор JSON — отдельный шаг, чтобы ошибки были понятными.
    @discardableResult
    private func raw(_ req: URLRequest) async throws -> Data {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw OCError.transport("пустой ответ") }
            if http.statusCode == 401 { throw OCError.unauthorized }
            guard (200..<300).contains(http.statusCode) else {
                throw OCError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            return data
        } catch let e as OCError {
            throw e
        } catch {
            throw OCError.transport(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OCError.decoding(String(data: data, encoding: .utf8) ?? "\(error)")
        }
    }

    /// Терпимый разбор списков: элементы, которые не удалось разобрать,
    /// пропускаются; если не разобрался ни один — отдаём внятную ошибку.
    private func decodeList<T: Decodable>(_ data: Data) throws -> [T] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw OCError.decoding(String(data: data, encoding: .utf8) ?? "не JSON")
        }
        let array: [Any]
        if let dict = root as? [String: Any], let arr = dict["data"] as? [Any] {
            array = arr
        } else if let arr = root as? [Any] {
            array = arr
        } else {
            throw OCError.decoding(String(data: data, encoding: .utf8) ?? "ожидался список")
        }

        var out: [T] = []
        var firstFailure = ""
        for element in array {
            guard JSONSerialization.isValidJSONObject(element),
                  let elementData = try? JSONSerialization.data(withJSONObject: element) else { continue }
            if let value = try? JSONDecoder().decode(T.self, from: elementData) {
                out.append(value)
            } else if firstFailure.isEmpty {
                firstFailure = String(data: elementData, encoding: .utf8) ?? ""
            }
        }
        if out.isEmpty && !array.isEmpty {
            throw OCError.emptySessions(firstFailure)
        }
        return out
    }

    func info() async throws -> ServerInfo {
        let data = try await raw(request("/api/info"))
        return (try? JSONDecoder().decode(ServerInfo.self, from: data)) ?? ServerInfo(version: nil)
    }

    func sessions() async throws -> [OCSession] {
        let data = try await raw(request("/api/session", query: [URLQueryItem(name: "limit", value: "200")]))
        let list: [OCSession] = try decodeList(data)
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    func projects() async throws -> [OCProject] {
        let data = try await raw(request("/api/project"))
        if let list: [OCProject] = try? decodeList(data) { return list }
        if let env: DataEnvelope<[OCProject]> = try? decode(data) { return env.data }
        return []
    }

    func messages(sessionID: String, limit: Int = 200) async throws -> [OCMessage] {
        let data = try await raw(request("/api/session/\(sessionID)/message",
                                         query: [URLQueryItem(name: "limit", value: "\(limit)"),
                                                 URLQueryItem(name: "order", value: "asc")]))
        return try decodeList(data)
    }

    func sendPrompt(sessionID: String, text: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["text": text])
        try await raw(request("/api/session/\(sessionID)/prompt", method: "POST", body: body))
    }

    func createSession(title: String?, directory: String?) async throws -> OCSession {
        var payload: [String: Any] = [:]
        if let title, !title.isEmpty { payload["title"] = title }
        if let directory, !directory.isEmpty { payload["location"] = ["directory": directory] }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await raw(request("/api/session", method: "POST", body: body))
        if let env: DataEnvelope<OCSession> = try? decode(data) { return env.data }
        if let direct: OCSession = try? decode(data) { return direct }
        throw OCError.decoding(String(data: data, encoding: .utf8) ?? "")
    }
}
