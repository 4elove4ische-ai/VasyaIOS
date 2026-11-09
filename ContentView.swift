import SwiftUI
import Speech
import AVFoundation
import UIKit

// Вася 2.1: голосовой диалог работает только пока Вася находится на экране.
final class VoiceController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var heard = ""
    @Published var status = "Запускаюсь…"
    @Published var recording = false
    @Published var draftMessage: String?
    @Published var draftRecipient = ""
    @Published var draftMessenger = "Telegram"
    @Published var presentShare = false

    private enum Stage { case command, message, confirmation }
    private var stage: Stage = .command
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceWork: DispatchWorkItem?
    private var finalWork: DispatchWorkItem?
    private var finalizing = false
    private var lastTranscript = ""
    private var active = false
    private var shouldResumeAfterSpeech = false
    private var permissionGranted = false
    private var starting = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func activate() {
        active = true
        guard !recording && !finalizing && !starting && !synthesizer.isSpeaking else { return }
        starting = true
        if permissionGranted { starting = false; beginRecording(); return }
        SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                guard authorization == .authorized else {
                    self.starting = false
                    self.status = "Разреши распознавание речи в настройках iPhone"
                    return
                }
                AVAudioApplication.requestRecordPermission { [weak self] allowed in
                    DispatchQueue.main.async {
                        guard let self, self.active else { return }
                        self.starting = false
                        guard allowed else { self.status = "Разреши доступ к микрофону"; return }
                        self.permissionGranted = true
                        self.beginRecording()
                    }
                }
            }
        }
    }

    func deactivate() {
        active = false
        starting = false
        shouldResumeAfterSpeech = false
        stopRecording()
        synthesizer.stopSpeaking(at: .immediate)
    }

    func retry() { activate() }

    private func beginRecording() {
        guard active else { return }
        guard !recording && !finalizing else { return }
        stopRecording()
        synthesizer.stopSpeaking(at: .immediate)
        heard = ""
        lastTranscript = ""
        finalizing = false
        guard let recognizer, recognizer.isAvailable else {
            status = "Распознавание речи временно недоступно"
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let newRequest = SFSpeechAudioBufferRecognitionRequest()
            newRequest.shouldReportPartialResults = true
            request = newRequest
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0 && format.sampleRate > 0 else {
                status = "Микрофон ещё не готов. Попробуй снова."
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                newRequest.append(buffer)
            }
            engine.prepare()
            try engine.start()
            recording = true
            status = "Слушаю…"
            task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    if let result {
                        let value = result.bestTranscription.formattedString
                        if !value.isEmpty && value != self.lastTranscript {
                            self.heard = value
                            self.lastTranscript = value
                            self.scheduleSilence()
                        }
                        if result.isFinal && !self.finalizing { self.finish() }
                    }
                    if error != nil && !self.finalizing {
                        if self.heard.isEmpty {
                            self.stopRecording()
                            self.say("Не расслышал. Повтори, пожалуйста.", resume: true)
                        } else { self.finish() }
                    }
                }
            }
        } catch {
            stopRecording()
            status = "Ошибка микрофона: \(error.localizedDescription)"
        }
    }

    private func scheduleSilence() {
        silenceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    func finish() {
        guard recording && !finalizing else { return }
        finalizing = true
        recording = false
        status = "Обрабатываю…"
        silenceWork?.cancel()
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        let work = DispatchWorkItem { [weak self] in self?.complete() }
        finalWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
    }

    private func complete() {
        guard finalizing else { return }
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        stopRecording()
        guard !text.isEmpty else { say("Повтори, пожалуйста.", resume: true); return }
        switch stage {
        case .command: handleCommand(text)
        case .message:
            draftMessage = text
            stage = .confirmation
            say("Сообщение для \(draftRecipient): \(text). Отправить?", resume: true)
        case .confirmation:
            let answer = text.lowercased()
            if ["да", "отправ", "подтверж", "конечно"].contains(where: { answer.contains($0) }) {
                stage = .command
                // iOS share sheet: user must select the actual recipient and confirm sending.
                say("Открываю отправку. Выбери получателя и подтверди сообщение в мессенджере.", resume: false)
                presentShare = true
            } else if ["нет", "отмена", "отмени"].contains(where: { answer.contains($0) }) {
                draftMessage = nil
                stage = .command
                say("Отменил. Слушаю следующую команду.", resume: true)
            } else if answer.contains("измени") || answer.contains("заново") {
                stage = .message
                say("Продиктуй сообщение заново.", resume: true)
            } else {
                say("Скажи «отправляй», «отмена» или «заново».", resume: true)
            }
        }
    }

    private func stopRecording() {
        silenceWork?.cancel(); silenceWork = nil
        finalWork?.cancel(); finalWork = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recording = false
        finalizing = false
    }

    private func say(_ text: String, resume: Bool) {
        stopRecording()
        shouldResumeAfterSpeech = resume
        status = text
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.shouldResumeAfterSpeech else { return }
            self.shouldResumeAfterSpeech = false
            self.beginRecording()
        }
    }

    private func handleCommand(_ original: String) {
        let lower = original.lowercased()
        if lower.contains("навигатор") && (lower.contains("верни") || lower.contains("открой")) {
            openNavigatorHome(); return
        }
        if lower.contains("напиши") || lower.contains("сообщение") || lower.contains("отправь") {
            let messenger: String
            if lower.contains("ватсап") || lower.contains("whatsapp") { messenger = "WhatsApp" }
            else if lower.contains("сигнал") || lower.contains("signal") { messenger = "Signal" }
            else if lower.contains("вайбер") || lower.contains("viber") { messenger = "Viber" }
            else { messenger = "Telegram" }
            draftMessenger = messenger
            var recipient = lower
            for phrase in ["вася", "напиши", "отправь", "сообщение", "пожалуйста", "в телеграме", "в телеграм", "в telegram", "в ватсапе", "в ватсап", "в whatsapp", "в сигнале", "в сигнал", "в signal", "в вайбере", "в вайбер", "в viber"] {
                recipient = recipient.replacingOccurrences(of: phrase, with: "")
            }
            recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !recipient.isEmpty else {
                say("Назови получателя. Например: напиши Андрею в Телеграм.", resume: true)
                return
            }
            draftRecipient = recipient
            draftMessage = nil
            stage = .message
            say("Что написать \(recipient)?", resume: true)
            return
        }
        if lower.contains("телеграм") || lower.contains("telegram") {
            open(URL(string: "tg://"), title: "Telegram"); return
        }
        if lower.contains("маршрут") || lower.contains("поехали") || lower.contains("найди") || lower.contains("адрес") || lower.contains("заправк") {
            var destination = lower
            for phrase in ["вася", "построй маршрут", "проложи маршрут", "маршрут до", "поехали на", "поехали в", "найди", "адрес", "навигаторе", "навигатор", "до "] {
                destination = destination.replacingOccurrences(of: phrase, with: "")
            }
            destination = destination.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if lower.contains("заправк") { destination = "заправка" }
            openSearch(destination.isEmpty ? "заправка" : destination)
            return
        }
        say("Не понял. Повтори команду.", resume: true)
    }

    private func open(_ url: URL?, title: String) {
        guard let url else { say("Не удалось создать ссылку.", resume: true); return }
        shouldResumeAfterSpeech = false
        UIApplication.shared.open(url) { [weak self] success in
            DispatchQueue.main.async {
                if !success { self?.say("Не удалось открыть \(title).", resume: true) }
            }
        }
    }

    private func openNavigatorHome() {
        let navigator = UserDefaults.standard.string(forKey: "vasyaNavigator") ?? "Яндекс Навигатор"
        switch navigator {
        case "Google Карты": open(URL(string: "comgooglemaps://"), title: navigator)
        case "Apple Карты": open(URL(string: "maps://"), title: navigator)
        case "2ГИС": open(URL(string: "dgis://"), title: navigator)
        default: open(URL(string: "yandexnavi://"), title: navigator)
        }
    }

    private func openSearch(_ query: String) {
        let navigator = UserDefaults.standard.string(forKey: "vasyaNavigator") ?? "Яндекс Навигатор"
        var components = URLComponents()
        switch navigator {
        case "Google Карты":
            components.scheme = "https"; components.host = "www.google.com"; components.path = "/maps/search/"
            components.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: query)]
        case "Apple Карты":
            components.scheme = "https"; components.host = "maps.apple.com"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case "2ГИС":
            components.scheme = "https"; components.host = "2gis.ru"
            components.path = "/search/" + (query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query)
        default:
            components.scheme = "yandexnavi"; components.host = "search"
            components.queryItems = [URLQueryItem(name: "text", value: query)]
        }
        open(components.url, title: navigator)
    }
}

struct ContentView: View {
    @StateObject private var voice = VoiceController()
    @AppStorage("vasyaNavigator") private var navigator = "Яндекс Навигатор"
    @AppStorage("vasyaAutoListen") private var autoListen = true
    @State private var showingShare = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Вася 2.1").font(.largeTitle.bold())
                Text("Голосовой помощник мотоциклиста").foregroundStyle(.secondary)
                Text(voice.status).multilineTextAlignment(.center).padding()
                if !voice.heard.isEmpty { Text("Услышал: \(voice.heard)").foregroundStyle(.secondary) }
                Button(voice.recording ? "Завершить фразу (резерв)" : "Включить микрофон (резерв)") {
                    if voice.recording { voice.finish() } else { voice.retry() }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                if let message = voice.draftMessage {
                    GroupBox("Сообщение") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(voice.draftMessenger) · \(voice.draftRecipient)")
                            Text(message)
                            Button("Поделиться сообщением") { showingShare = true }
                                .buttonStyle(.borderedProminent)
                            Text("Telegram не позволяет Васе самостоятельно найти чат по отображаемому имени или отправить сообщение. В окне отправки выбери Telegram и получателя, затем нажми отправку.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                GroupBox("Настройки") {
                    Picker("Навигатор", selection: $navigator) {
                        ForEach(["Яндекс Навигатор", "2ГИС", "Google Карты", "Apple Карты"], id: \.self) { Text($0) }
                    }
                    Toggle("Слушать при открытии", isOn: $autoListen)
                }
                Text("Скажи: «Напиши Андрею в Telegram» или «Найди заправку». После вопроса Васи говори без нажатия кнопки.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("Вася слушает только когда находится на экране. Поиск адреса пока открывает варианты в навигаторе; отправку сообщений нужно подтвердить в Telegram. Автоматический возврат из Telegram в навигатор iOS не гарантирует.")
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }.padding()
        }
        .sheet(isPresented: $showingShare) {
            if let message = voice.draftMessage { ShareSheet(items: [message]) }
        }
        .onAppear { if autoListen { voice.activate() } }
        .onChange(of: voice.presentShare) { ready in
            if ready { showingShare = true; voice.presentShare = false }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { if autoListen { voice.activate() } }
            else { voice.deactivate() }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
