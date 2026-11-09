import SwiftUI
import Speech
import AVFoundation

final class VoiceController: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published var heard = "Нажми «Говорить» и произнеси команду"
    @Published var status = "Готов"
    @Published var recording = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            guard auth == .authorized else {
                DispatchQueue.main.async { self?.status = "Разреши распознавание речи в настройках" }
                return
            }
            AVAudioApplication.requestRecordPermission { [weak self] allowed in
                DispatchQueue.main.async {
                    if allowed { self?.beginRecording() }
                    else { self?.status = "Разреши доступ к микрофону" }
                }
            }
        }
    }

    private func beginRecording() {
        stopAudio()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
            engine.prepare()
            try engine.start()
            recording = true
            status = "Слушаю…"
            task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                DispatchQueue.main.async {
                    if let result { self.heard = result.bestTranscription.formattedString }
                    if error != nil { self.stopAudio(); self.status = "Ошибка распознавания" }
                }
            }
        } catch { status = "Не удалось включить микрофон: \(error.localizedDescription)"; stopAudio() }
    }

    func finishAndExecute() {
        let command = heard
        stopAudio()
        execute(command)
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio(); task?.cancel(); request = nil; task = nil
        recording = false
    }

    private func speak(_ message: String) {
        status = message
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        synthesizer.speak(utterance)
    }

    private func execute(_ original: String) {
        let text = original.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { speak("Я ничего не услышал. Попробуй ещё раз."); return }
        if text.contains("навигатор") || text.contains("маршрут") || text.contains("заправк") {
            let query = text.contains("газпром") ? "Газпромнефть" : "заправка"
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            if let url = URL(string: "yandexnavi://search?text=\(encoded)") {
                UIApplication.shared.open(url) { [weak self] success in
                    DispatchQueue.main.async { self?.speak(success ? "Открываю поиск в Яндекс Навигаторе" : "Не удалось открыть Яндекс Навигатор") }
                }
            }
        } else if text.contains("открой") && text.contains("телеграм") {
            if let url = URL(string: "tg://") {
                UIApplication.shared.open(url) { [weak self] success in
                    DispatchQueue.main.async { self?.speak(success ? "Открываю Telegram" : "Telegram не открылся") }
                }
            }
        } else {
            speak("Команду понял, но это действие пока не подключено")
        }
    }
}

struct ContentView: View {
    @StateObject private var voice = VoiceController()
    var body: some View {
        VStack(spacing: 24) {
            Text("Вася").font(.largeTitle.bold())
            Text("Голосовой помощник — прототип").foregroundStyle(.secondary)
            Text(voice.heard).multilineTextAlignment(.center).padding()
            Text(voice.status).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(voice.recording ? "Выполнить команду" : "Говорить") {
                if voice.recording { voice.finishAndExecute() } else { voice.start() }
            }.buttonStyle(.borderedProminent).controlSize(.large)
            Text("Примеры: «Открой Телеграм», «Найди заправку в навигаторе»")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }.padding()
    }
}
