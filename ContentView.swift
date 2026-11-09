import SwiftUI
import Speech
import AVFoundation
import UIKit

final class VoiceController: NSObject, ObservableObject {
    @Published var heard = "Нажми «Говорить» и произнеси команду"
    @Published var status = "Готов"
    @Published var recording = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalizing = false
    private var didExecute = false
    private var fallback: DispatchWorkItem?

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            DispatchQueue.main.async {
                guard let self else { return }
                guard auth == .authorized else {
                    self.status = "Разреши распознавание речи в настройках"
                    return
                }
                AVAudioApplication.requestRecordPermission { [weak self] allowed in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if allowed { self.beginRecording() }
                        else { self.status = "Разреши доступ к микрофону" }
                    }
                }
            }
        }
    }

    private func beginRecording() {
        stopAudio()
        heard = ""
        finalizing = false
        didExecute = false
        guard let recognizer, recognizer.isAvailable else {
            status = "Распознавание речи сейчас недоступно"
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try AVAudioSession.sharedInstance().setActive(true)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
            try engine.start()
            recording = true
            status = "Слушаю…"
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let result {
                        self.heard = result.bestTranscription.formattedString
                        if self.finalizing && result.isFinal {
                            self.completeRecognition()
                            return
                        }
                    }
                    if let error {
                        if self.finalizing {
                            self.completeRecognition()
                        } else {
                            self.stopAudio()
                            self.status = "Ошибка распознавания: \(error.localizedDescription)"
                        }
                    }
                }
            }
        } catch {
            status = "Не удалось включить микрофон: \(error.localizedDescription)"
            stopAudio()
        }
    }

    func finishAndExecute() {
        guard recording, !finalizing else { return }
        finalizing = true
        recording = false
        status = "Обрабатываю команду…"
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        // A bounded wait prevents the interface from hanging if no final result arrives.
        let work = DispatchWorkItem { [weak self] in self?.completeRecognition() }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func completeRecognition() {
        guard finalizing, !didExecute else { return }
        didExecute = true
        let command = heard
        stopAudio()
        execute(command)
    }

    private func stopAudio() {
        fallback?.cancel()
        fallback = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        recording = false
        finalizing = false
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
        guard !text.isEmpty else {
            speak("Я ничего не услышал. Попробуй ещё раз.")
            return
        }
        if text.contains("телеграм") || text.contains("telegram") {
            openApp("tg://", success: "Открываю Telegram", failure: "Не удалось открыть Telegram. Проверь, установлен ли он.")
        } else if text.contains("навигатор") || text.contains("маршрут") ||
                    text.contains("заправк") || text.contains("газпром") {
            let query: String
            if text.contains("газпром") {
                query = "Газпромнефть"
            } else if text.contains("заправк") {
                query = "заправка"
            } else {
                // For arbitrary destinations, pass the requested phrase to search.
                // This is a search, not automatic route construction.
                query = text
                    .replacingOccurrences(of: "открой", with: "")
                    .replacingOccurrences(of: "навигатор", with: "")
                    .replacingOccurrences(of: "найди", with: "")
                    .replacingOccurrences(of: "построй маршрут", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let search = query.isEmpty ? "заправка" : query
            var components = URLComponents()
            components.scheme = "yandexnavi"
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "text", value: search)]
            guard let url = components.url else {
                speak("Не удалось сформировать поиск")
                return
            }
            UIApplication.shared.open(url) { [weak self] success in
                DispatchQueue.main.async {
                    self?.speak(success ? "Открываю поиск в Яндекс Навигаторе" :
                        "Не удалось открыть Яндекс Навигатор. Проверь, установлен ли он.")
                }
            }
        } else {
            speak("Не понял команду. Я услышал: \(original)")
        }
    }

    private func openApp(_ link: String, success: String, failure: String) {
        guard let url = URL(string: link) else {
            speak(failure)
            return
        }
        UIApplication.shared.open(url) { [weak self] opened in
            DispatchQueue.main.async { self?.speak(opened ? success : failure) }
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
                if voice.recording { voice.finishAndExecute() }
                else { voice.start() }
            }
            .disabled(voice.status == "Обрабатываю команду…")
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("Примеры: «Открой Телеграм», «Найди заправку в навигаторе»")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
