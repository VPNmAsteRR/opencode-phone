import SwiftUI

@main
struct OpenCodePhoneApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var ready = false

    var body: some View {
        Group {
            if !ready {
                LaunchScreen()
                    .task {
                        if model.settings.isValid {
                            _ = await model.connect()
                        }
                        ready = true
                    }
            } else if model.connectionOK {
                SessionListView()
            } else {
                SetupView()
            }
        }
    }
}

struct LaunchScreen: View {
    var body: some View {
        ZStack {
            Color(hex: 0x11131A).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().tint(.white.opacity(0.7))
                Text("Подключение к OpenCode…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - Настройка подключения

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var checking = false
    @FocusState private var focus: Field?
    enum Field { case url, user, pass }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: 0x11131A).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("OpenCode")
                                .font(.largeTitle.bold())
                                .foregroundStyle(.white)
                            Text("Твои сессии с ноутбука — на телефоне.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.top, 8)

                        field("Адрес сервера", text: $model.settings.baseURL,
                              hint: "https://…", field: .url, keyboard: .URL)
                        field("Логин", text: $model.settings.username,
                              hint: "opencode", field: .user, keyboard: .default)
                        secureField("Пароль", text: $model.settings.password, field: .pass)

                        if let err = model.errorText {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        }

                        Button {
                            Task { await submit() }
                        } label: {
                            HStack {
                                if checking { ProgressView().tint(.black) }
                                Text(checking ? "Проверяю…" : "Подключиться")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.black)
                        }
                        .disabled(checking || !model.settings.isValid)
                        .opacity(model.settings.isValid ? 1 : 0.4)
                    }
                    .padding(20)
                }
            }
            .navigationBarHidden(true)
        }
    }

    private func submit() async {
        checking = true
        model.settings.save()
        _ = await model.connect()
        checking = false
    }

    private func field(_ label: String, text: Binding<String>, hint: String,
                       field: Field, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.45))
            TextField(hint, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .focused($focus, equals: field)
                .padding(12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
        }
    }

    private func secureField(_ label: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.45))
            SecureField("", text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: field)
                .padding(12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Список сессий

struct SessionListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var showNew = false
    @State private var search = ""

    var filtered: [OCSession] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return model.sessions }
        return model.sessions.filter {
            $0.displayTitle.lowercased().contains(q) || $0.directory.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: 0x11131A).ignoresSafeArea()
                if model.loadingSessions && model.sessions.isEmpty {
                    ProgressView().tint(.white.opacity(0.6))
                } else if model.sessions.isEmpty {
                    EmptyState(title: "Нет сессий",
                               subtitle: "Создай новую — она появится и на ноутбуке.")
                } else {
                    List {
                        ForEach(filtered) { session in
                            NavigationLink {
                                ChatView(session: session)
                            } label: {
                                SessionRow(session: session)
                            }
                            .listRowBackground(Color(hex: 0x181B23))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .searchable(text: $search, prompt: "Поиск сессий")
                }
            }
            .navigationTitle("Сессии")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            if let s = await model.createSession(title: nil, directory: nil) {
                                await model.openSession(s)
                            }
                            showNew = true
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .refreshable { await model.loadSessions() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .navigationDestination(isPresented: $showNew) {
                NewSessionChatView()
            }
        }
    }
}

struct SessionRow: View {
    let session: OCSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.displayTitle)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(shortDir(session.directory))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                Spacer()
                Text(relative(session.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.vertical, 6)
    }

    private func shortDir(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

struct EmptyState: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.25))
            Text(title).font(.headline).foregroundStyle(.white.opacity(0.75))
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

// MARK: - Настройки

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Сервер") {
                    TextField("Адрес", text: $model.settings.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Логин", text: $model.settings.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Пароль", text: $model.settings.password)
                }
                Section {
                    Button {
                        Task {
                            testing = true
                            model.settings.save()
                            let ok = await model.connect()
                            testResult = ok ? "Связь есть, версия \(model.serverVersion)" : (model.errorText ?? "Не удалось")
                            testing = false
                        }
                    } label: {
                        HStack {
                            if testing { ProgressView() }
                            Text(testing ? "Проверяю…" : "Проверить связь")
                        }
                    }
                } footer: {
                    if let testResult { Text(testResult) }
                }
                Section {
                    Text("Ноутбук должен быть включён: OpenCode работает на нём, а телефон подключается через туннель.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        model.settings.save()
                        Task { _ = await model.connect() }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Цвета

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
