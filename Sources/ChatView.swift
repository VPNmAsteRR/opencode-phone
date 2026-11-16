import SwiftUI

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    let session: OCSession

    @State private var draft = ""
    @State private var showReasoning = false
    @FocusState private var inputFocused: Bool
    @State private var didLoad = false

    var body: some View {
        ZStack {
            Color(hex: 0x11131A).ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.messages) { msg in
                                MessageBubble(message: msg, showReasoning: $showReasoning)
                                    .id(msg.id)
                            }
                            if model.messages.isEmpty && model.loadingMessages {
                                ProgressView().tint(.white.opacity(0.5))
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            }
                            if model.messages.isEmpty && !model.loadingMessages {
                                EmptyState(title: "Пусто",
                                           subtitle: "Напиши первое сообщение — оно придёт в эту же сессию на ноутбуке.")
                                    .padding(.top, 60)
                            }
                            Color.clear.frame(height: 8).id("BOTTOM")
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.messages.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("BOTTOM", anchor: .bottom)
                        }
                    }
                    .onChange(of: model.messages.last?.id) { _, _ in
                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                    }
                    .task {
                        guard !didLoad else { return }
                        didLoad = true
                        await model.openSession(session)
                    }
                }

                Divider().overlay(Color.white.opacity(0.06))

                Composer(text: $draft, sending: model.sending, focused: $inputFocused) {
                    let text = draft
                    draft = ""
                    Task { _ = await model.send(text) }
                }
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showReasoning.toggle()
                    } label: {
                        Label(showReasoning ? "Скрыть рассуждения" : "Показать рассуждения",
                              systemImage: showReasoning ? "eye.slash" : "eye")
                    }
                    Button {
                        Task { await model.loadMessages() }
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .overlay(alignment: .top) {
            if let err = model.errorText {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.85), in: Capsule())
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Пузырь сообщения

struct MessageBubble: View {
    let message: OCMessage
    @Binding var showReasoning: Bool

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 8) {
            if !message.isUser {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: 0x3DDC97)).frame(width: 6, height: 6)
                    Text(message.agent ?? "agent")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                }
            }

            // Рассуждения
            if showReasoning, !message.reasoningText.isEmpty {
                Text(message.reasoningText)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }

            // Инструменты
            ForEach(message.tools, id: \.uid) { tool in
                ToolCard(tool: tool)
            }

            // Основной текст
            if !message.displayText.isEmpty {
                MarkdownText(text: message.displayText, isUser: message.isUser)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}

struct MarkdownText: View {
    let text: String
    let isUser: Bool

    var body: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(isUser ? Color.black : Color.white.opacity(0.92))
        .textSelection(.enabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            isUser ? Color.white : Color(hex: 0x1C2029),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }
}

struct ToolCard: View {
    let tool: OCPart
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)
                Text(tool.name ?? "tool")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                Text(tool.statusText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
            }
            if expanded, !(tool.state?.resultText.isEmpty ?? true) {
                Text(tool.state?.resultText ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(80)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private var summary: String {
        tool.state?.input?.summary ?? ""
    }

    private var icon: String {
        switch tool.name {
        case "shell", "bash": return "terminal"
        case "edit", "write": return "pencil"
        case "read": return "doc.text"
        case "grep", "search": return "magnifyingglass"
        case "websearch", "webfetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    private var statusColor: Color {
        switch tool.state?.status {
        case "running": return .yellow
        case "error": return .red
        default: return Color(hex: 0x3DDC97)
        }
    }
}

// MARK: - Поле ввода

struct Composer: View {
    @Binding var text: String
    let sending: Bool
    let focused: FocusState<Bool>.Binding
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Сообщение…", text: $text, axis: .vertical)
                .focused(focused)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.sentences)

            Button {
                onSend()
            } label: {
                ZStack {
                    Circle()
                        .fill(canSend ? Color.white : Color.white.opacity(0.15))
                        .frame(width: 36, height: 36)
                    if sending {
                        ProgressView().tint(.black).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(canSend ? .black : .white.opacity(0.4))
                    }
                }
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: 0x11131A))
    }

    private var canSend: Bool {
        !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Переход в только что созданную сессию

struct NewSessionChatView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let sid = model.currentSessionID,
           let session = model.sessions.first(where: { $0.id == sid }) {
            ChatView(session: session)
        } else {
            ZStack {
                Color(hex: 0x11131A).ignoresSafeArea()
                ProgressView().tint(.white.opacity(0.6))
            }
        }
    }
}
