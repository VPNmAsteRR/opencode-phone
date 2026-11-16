import Foundation

// MARK: - Модели

struct ServerInfo: Decodable {
    let version: String
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
    let canonical: String
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
}

struct OCLocation: Decodable, Hashable {
    let directory: String
}

// MARK: - Сообщения

struct OCMessage: Decodable, Identifiable {
    let id: String
    let type: String            // "user" | "assistant"
    let time: SessionTime?
    let text: String?
    let content: [OCPart]?
    let agent: String?
    let metadata: OCMessageMetadata?

    var createdAt: Date {
        Date(timeIntervalSince1970: ((time?.created ?? 0)) / 1000)
    }
    var isUser: Bool { type == "user" }

    /// Полный текст для отображения (user — text, assistant — склейка text-частей)
    var displayText: String {
        if let t = text, !t.isEmpty { return t }
        let parts = content ?? []
        if let joined = parts.compactMap({ $0.type == "text" ? $0.text : nil })
            .filter({ !$0.isEmpty }).joined(separator: "\n").nilIfEmpty {
            return joined
        }
        return ""
    }

    /// Только рассуждения модели
    var reasoningText: String {
        let parts = content ?? []
        return parts.compactMap { $0.type == "reasoning" ? $0.text : nil }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Инструменты (shell, edit, read и т.п.)
    var tools: [OCPart] {
        (content ?? []).filter { $0.type == "tool" }
    }
}

struct OCMessageMetadata: Decodable {
    let displayText: String?
}

struct OCPart: Decodable {
    let type: String
    let text: String?
    let name: String?
    let id: String?
    let state: OCToolState?

    var uid: String { id ?? "\(type)-\(name ?? "" )-\(text?.prefix(24) ?? "")" }

    var statusText: String {
        guard let s = state else { return "" }
        switch s.status {
        case "running": return "выполняется"
        case "completed": return "готово"
        case "error": return "ошибка"
        default: return s.status ?? ""
        }
    }
}

struct OCToolState: Decodable {
    let status: String?
    let title: String?
    let input: OCToolInput?
    let output: String?
}

struct OCToolInput: Decodable {
    let command: String?
    let filePath: String?
    let description: String?
}

// MARK: - Ответы-обёртки

struct DataEnvelope<T: Decodable>: Decodable {
    let data: T
}

struct MessagePage: Decodable {
    let data: [OCMessage]
    let cursor: String?
}

// MARK: - Ошибки

enum OCError: LocalizedError {
    case badURL
    case unauthorized
    case http(Int, String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Неверный адрес сервера"
        case .unauthorized: return "Сервер отклонил логин или пароль"
        case let .http(code, body):
            if code == 404 { return "Не найдено (404)" }
            return "Ошибка сервера \(code): \(body.prefix(160))"
        case let .transport(msg): return "Нет связи с сервером: \(msg)"
        case let .decoding(msg): return "Непонятный ответ сервера: \(msg.prefix(160))"
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
        self.base = baseURL
        let raw = "\(username):\(password)".data(using: .utf8) ?? Data()
        self.authHeader = "Basic " + raw.base64EncodedString()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
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

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw OCError.transport("нет ответа") }
            if http.statusCode == 401 { throw OCError.unauthorized }
            guard (200..<300).contains(http.statusCode) else {
                throw OCError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw OCError.decoding(String(data: data, encoding: .utf8) ?? "\(error)")
            }
        } catch let e as OCError {
            throw e
        } catch {
            throw OCError.transport(error.localizedDescription)
        }
    }

    func info() async throws -> ServerInfo {
        try await send(request("/api/info"), as: DataEnvelope<ServerInfo>.self).data
    }

    func sessions() async throws -> [OCSession] {
        let env = try await send(
            request("/api/session", query: [URLQueryItem(name: "limit", value: "200")]),
            as: DataEnvelope<[OCSession]>.self
        )
        return env.data.sorted { $0.updatedAt > $1.updatedAt }
    }

    func projects() async throws -> [OCProject] {
        try await send(request("/api/project"), as: [OCProject].self)
    }

    func messages(sessionID: String, limit: Int = 200) async throws -> [OCMessage] {
        let page = try await send(
            request("/api/session/\(sessionID)/message",
                    query: [URLQueryItem(name: "limit", value: "\(limit)"),
                            URLQueryItem(name: "order", value: "asc")]),
            as: MessagePage.self
        )
        return page.data
    }

    func sendPrompt(sessionID: String, text: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["text": text])
        _ = try await send(
            request("/api/session/\(sessionID)/prompt", method: "POST", body: body),
            as: DataEnvelope<OCRawUserMessage>.self
        )
    }

    func createSession(title: String?, directory: String?) async throws -> OCSession {
        var payload: [String: Any] = [:]
        if let title { payload["title"] = title }
        if let directory { payload["location"] = ["directory": directory] }
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await send(
            request("/api/session", method: "POST", body: body),
            as: DataEnvelope<OCSession>.self
        ).data
    }
}

struct OCRawUserMessage: Decodable {
    let id: String
}
