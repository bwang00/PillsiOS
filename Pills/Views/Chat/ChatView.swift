import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var authManager: AuthManager

    @State private var viewModel: ChatViewModel?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Messages list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if let vm = viewModel {
                                ForEach(vm.messages) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                }

                                if vm.isSending {
                                    HStack {
                                        TypingIndicator()
                                        Spacer()
                                    }
                                    .id("typing")
                                }
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel?.messages.count) {
                        if let lastId = viewModel?.messages.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                        if viewModel?.isSending == true {
                            withAnimation {
                                proxy.scrollTo("typing", anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                // Input bar
                inputBar
            }
            .navigationTitle("AI 教练")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await viewModel?.createNewConversation() }
                        } label: {
                            Label("新对话", systemImage: "plus")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task {
                if viewModel == nil {
                    let vm = ChatViewModel(
                        modelContext: modelContext,
                        username: authManager.currentUser?.username
                    )
                    viewModel = vm
                    await vm.loadOrCreateConversation()
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("输入消息...", text: Binding(
                get: { viewModel?.inputText ?? "" },
                set: { viewModel?.inputText = $0 }
            ), axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)

            Button {
                Task { await viewModel?.sendMessage() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        (viewModel?.inputText.trimmingCharacters(in: .whitespaces).isEmpty == false
                         && viewModel?.isSending == false)
                        ? Color.green : Color.gray.opacity(0.4)
                    )
            }
            .disabled(
                viewModel?.inputText.trimmingCharacters(in: .whitespaces).isEmpty == true
                || viewModel?.isSending == true
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Typing indicator

struct TypingIndicator: View {
    @State private var dotOpacity: [Double] = [0.3, 0.3, 0.3]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.gray)
                    .frame(width: 8, height: 8)
                    .opacity(dotOpacity[i])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.gray.opacity(0.1), in: Capsule())
        .task {
            while !Task.isCancelled {
                for i in 0..<3 {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        dotOpacity[i] = 1.0
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        dotOpacity[i] = 0.3
                    }
                }
            }
        }
    }
}
