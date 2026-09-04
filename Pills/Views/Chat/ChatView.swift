import SwiftUI
import SwiftData
import Speech
import AVFoundation
import UIKit

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var authManager: AuthManager

    @State private var viewModel: ChatViewModel?
    @State private var isRecording = false
    @State private var speechRecognizer: SpeechRecognizer?
    @State private var voiceError: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let vm = viewModel {
                            if vm.messages.isEmpty && !vm.isSending {
                                ChatWelcomeView()
                                    .id("welcome")
                            }

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
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        inputBar
                    }
                    .background(.bar)
                }
                .onChange(of: viewModel?.messages.count) { oldCount, newCount in
                    if let newCount, let oldCount, newCount > oldCount {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            scrollToBottom(proxy: proxy)
                        }
                    } else {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel?.isSending) {
                    scrollToBottom(proxy: proxy)
                }
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

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let vm = viewModel else { return }
        if vm.isSending {
            withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
        } else if let lastId = vm.messages.last?.id {
            withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Voice error banner
            if let voiceError {
                Text(voiceError)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.orange)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 8) {
                // Mic button
                Button {
                    toggleVoiceInput()
                } label: {
                    ZStack {
                        if isRecording {
                            Circle()
                                .fill(.red.opacity(0.15))
                                .frame(width: 36, height: 36)
                        }
                        Image(systemName: isRecording ? "mic.fill" : "mic")
                            .font(.title3)
                            .foregroundStyle(isRecording ? .red : .secondary)
                    }
                    .frame(width: 36, height: 36)
                }

                // Text field (UIKit-backed for reliable return key)
                ChatTextField(
                    text: Binding(
                        get: { viewModel?.inputText ?? "" },
                        set: { viewModel?.inputText = $0 }
                    ),
                    placeholder: "输入消息...",
                    onReturn: { text in
                        viewModel?.inputText = text
                        sendMessageIfValid()
                    }
                )
                .frame(height: 36)

                // Send button
                Button {
                    sendMessageIfValid()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            canSend ? Color.green : Color.gray.opacity(0.4)
                        )
                }
                .disabled(!canSend)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var canSend: Bool {
        let text = viewModel?.inputText.trimmingCharacters(in: .whitespaces) ?? ""
        let result = !text.isEmpty && viewModel?.isSending == false
        return result
    }

    private func sendMessageIfValid() {
        guard canSend else { return }
        inputFocused = false
        Task { await viewModel?.sendMessage() }
    }

    // MARK: - Voice input

    private func toggleVoiceInput() {
        voiceError = nil
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        if speechRecognizer == nil {
            speechRecognizer = SpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        }

        speechRecognizer?.onTranscript = { text in
            viewModel?.inputText = text
        }

        speechRecognizer?.onError = { [self] error in
            voiceError = error
            isRecording = false
            // Auto-dismiss error after 3 seconds
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run { voiceError = nil }
            }
        }

        speechRecognizer?.startRecording { error in
            if let error = error {
                voiceError = error.localizedDescription
                isRecording = false
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run { voiceError = nil }
                }
            } else {
                isRecording = true
            }
        }
    }

    private func stopRecording() {
        speechRecognizer?.stopRecording()
        isRecording = false
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

// MARK: - Chat welcome screen

struct ChatWelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "leaf.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green.opacity(0.8))

            VStack(spacing: 8) {
                Text("你好，我是你的 AI 教练")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("可以问我关于呼吸练习、正念冥想、\n放松技巧等任何问题")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Suggested prompts
            VStack(spacing: 8) {
                SuggestionChip(text: "今天适合做什么练习？", icon: "sun.max.fill")
                SuggestionChip(text: "帮我缓解焦虑", icon: "heart.fill")
                SuggestionChip(text: "推荐睡前放松方法", icon: "moon.fill")
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}

struct SuggestionChip: View {
    let text: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.green)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Speech Recognizer

final class SpeechRecognizer: NSObject {
    var transcript = ""
    var onTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let speechRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    init(locale: Locale = .current) {
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
        super.init()
    }

    func startRecording(completion: @escaping (Error?) -> Void) {
        // Cancel any ongoing task
        recognitionTask?.cancel()
        recognitionTask = nil

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            let err = NSError(domain: "SpeechRecognizer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "语音识别不可用，请检查设备是否支持中文语音识别"
            ])
            completion(err)
            return
        }

        // Request authorization
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                let msg: String
                switch status {
                case .denied: msg = "语音识别权限被拒绝，请在设置中开启"
                case .restricted: msg = "语音识别受限"
                case .notDetermined: msg = "语音识别权限未确定"
                default: msg = "语音识别未授权"
                }
                completion(NSError(domain: "SpeechRecognizer", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: msg
                ]))
                return
            }

            Task { @MainActor in
                guard let self else { return }
                do {
                    try self.startAudioSession()
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }
    }

    @MainActor
    private func startAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        // Prefer on-device when available
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }

        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Guard against zero-sample-rate format (simulator edge case)
        guard recordingFormat.sampleRate > 0 else {
            throw NSError(domain: "SpeechRecognizer", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "无法获取麦克风音频格式，模拟器可能不支持语音输入"
            ])
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.transcript = text
                    self.onTranscript?(text)
                }
            }

            if let error {
                Task { @MainActor in
                    self.onError?(error.localizedDescription)
                }
                self.cleanupAudioEngine()
            } else if result?.isFinal == true {
                self.cleanupAudioEngine()
            }
        }
    }

    func stopRecording() {
        audioEngine.stop()
        cleanupAudioEngine()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func cleanupAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest = nil
    }
}

// MARK: - UIKit TextField wrapper for reliable return key

struct ChatTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onReturn: (String) -> Void

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator
        tf.placeholder = placeholder
        tf.returnKeyType = .send
        tf.borderStyle = .roundedRect
        tf.font = .preferredFont(forTextStyle: .body)
        tf.setContentHuggingPriority(.defaultLow, for: .vertical)
        tf.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        if tf.text != text {
            tf.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onReturn: onReturn)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        let onReturn: (String) -> Void

        init(text: Binding<String>, onReturn: @escaping (String) -> Void) {
            _text = text
            self.onReturn = onReturn
        }

        @objc func textChanged(_ textField: UITextField) {
            text = textField.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            let currentText = textField.text ?? ""
            text = currentText
            onReturn(currentText)
            return false
        }
    }
}
