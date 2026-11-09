import SwiftUI
import Speech
import AVFoundation
import UIKit

final class VoiceController: NSObject, ObservableObject {
    @Published var heard = "Нажми «Говорить» и произнеси команду"
    @Published var status = "Готов"
    @Published var recording = false
    @Published var draftMessage: String? = nil
    @Published var draftRecipient = ""
    @Published var draftMessenger = "Telegram"

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
        guard !text.isEmpty else { speak("Я ничего не услышал. Попробуй ещё раз."); return }

        if let draft = parseMessage(original) {
            draftMessenger = draft.messenger
            draftRecipient = draft.recipient
            draftMessage = draft.message
            status = "Сообщение готово. Проверь текст и выбери отправку."
        } else if text.contains("телеграм") || text.contains("telegram") {
            openScheme("tg://", name: "Telegram")
        } else if text.contains("ватсап") || text.contains("ватсапп") || text.contains("whatsapp") || text.contains("вотсап") {
            openScheme("whatsapp://", name: "WhatsApp")
        } else if text.contains("сигнал") || text.contains("signal") {
            openScheme("sgnl://", name: "Signal")
        } else if text.contains("вайбер") || text.contains("viber") {
            openScheme("viber://", name: "Viber")
        } else if text.contains("сообщени") || text.contains("напиши") || text.contains("отправь") {
            speak("Скажи: напиши Андрею в Телеграм: буду через десять минут")
        } else if text.contains("навигатор") || text.contains("маршрут") || text.contains("заправк") ||
                    text.contains("газпром") || text.contains("адрес") || text.contains("карты") ||
                    text.contains("найди") || text.contains("покажи") {
            let destination = extractDestination(text)
            openNavigation(destination)
        } else if text.contains("музык") {
            speak("Музыку удобнее запускать через сценарий «Начать поездку» в приложении «Команды»")
        } else if text.contains("hudspeed") || text.contains("хадспид") || text.contains("хедспид") {
            speak("HUDspeed можно открыть голосом через Siri: «Открой HUDspeed»")
        } else if text.contains("начать поездку") {
            speak("Скажи Siri «Начать поездку», чтобы запустить свой сценарий")
        } else {
            speak("Не понял команду. Я услышал: \(original)")
        }
    }

    private func parseMessage(_ original: String) -> (recipient: String, messenger: String, message: String)? {
        let lower = original.lowercased()
        guard lower.contains("напиши") || lower.contains("отправь") || lower.contains("сообщение") else { return nil }
        let services: [(String, [String])] = [
            ("Telegram", ["телеграм", "telegram"]),
            ("WhatsApp", ["ватсап", "вотсап", "whatsapp"]),
            ("Signal", ["сигнал", "signal"]),
            ("Viber", ["вайбер", "viber"])
        ]
        let messenger = services.first(where: { service in service.1.contains(where: { lower.contains($0) }) })?.0
            ?? (UserDefaults.standard.string(forKey: "vasyaMessenger") ?? "Telegram")
        // A colon (or the phrase «что») separates the recipient from the message.
        let parts = original.split(separator: ":", maxSplits: 1).map(String.init)
        let prefix: String
        let message: String
        if parts.count == 2 {
            prefix = parts[0]
            message = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let range = lower.range(of: " что ") {
            let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
            let end = lower.distance(from: lower.startIndex, to: range.upperBound)
            prefix = String(original.prefix(start))
            message = String(original.dropFirst(end)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else { return nil }
        guard !message.isEmpty else { return nil }
        var recipient = prefix.lowercased()
        for word in ["вася", "напиши", "отправь", "сообщение", "сообщениe", "пожалуйста", "в телеграм", "в telegram", "в ватсап", "в вотсап", "в whatsapp", "в сигнал", "в signal", "в вайбер", "в viber"] {
            recipient = recipient.replacingOccurrences(of: word, with: "")
        }
        recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (recipient, messenger, message)
    }

    private func extractDestination(_ text: String) -> String {
        if text.contains("газпром") { return "Газпромнефть" }
        if text.contains("заправк") { return "заправка" }
        var value = text
        for word in ["вася", "построй маршрут", "проложи маршрут", "найди", "открой", "покажи", "навигаторе", "навигатор", "маршрут", "по адресу", "адрес", "до ", "в картах", "карты", "найди адрес", "найди место", "найди"] {
            value = value.replacingOccurrences(of: word, with: "")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func openNavigation(_ destination: String) {
        let name = UserDefaults.standard.string(forKey: "vasyaNavigator") ?? "Яндекс Навигатор"
        let query = destination.isEmpty ? "заправка" : destination
        var components = URLComponents()
        switch name {
        case "Google Карты":
            components.scheme = "https"; components.host = "www.google.com"; components.path = "/maps/search/"
            components.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: query)]
        case "Apple Карты":
            components.scheme = "https"; components.host = "maps.apple.com"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case "2ГИС":
            components.scheme = "https"; components.host = "2gis.ru"; components.path = "/search/" + (query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query)
        default:
            components.scheme = "yandexnavi"; components.host = "search"
            components.queryItems = [URLQueryItem(name: "text", value: query)]
        }
        guard let url = components.url else { speak("Не удалось подготовить адрес"); return }
        UIApplication.shared.open(url) { [weak self] ok in
            DispatchQueue.main.async {
                self?.speak(ok ? "Открываю поиск: \(query)" : "Не удалось открыть \(name). Проверь установленное приложение")
            }
        }
    }

    private func openScheme(_ scheme: String, name: String, note: String? = nil) {
        guard let url = URL(string: scheme) else { speak("Некорректная ссылка"); return }
        UIApplication.shared.open(url) { [weak self] ok in
            DispatchQueue.main.async {
                self?.speak(ok ? (note ?? "Открываю \(name)") : "Не удалось открыть \(name). Проверь, установлено ли приложение")
            }
        }
    }

}

struct ContentView: View {
    @StateObject private var voice = VoiceController()
    @AppStorage("vasyaNavigator") private var navigator = "Яндекс Навигатор"
    @AppStorage("vasyaMessenger") private var messenger = "Telegram"
    @AppStorage("vasyaAutoListen") private var autoListen = false
    @State private var didAutoStart = false
    @State private var showingShare = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Вася 2.0").font(.largeTitle.bold())
                Text("Голосовые команды для поездок").foregroundStyle(.secondary)
                Text(voice.heard).multilineTextAlignment(.center).padding()
                Text(voice.status).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(voice.recording ? "Выполнить команду" : "Говорить") {
                    if voice.recording { voice.finishAndExecute() } else { voice.start() }
                }
                .disabled(voice.status == "Обрабатываю команду…")
                .buttonStyle(.borderedProminent).controlSize(.large)

                if let draft = voice.draftMessage {
                    GroupBox("Сообщение для отправки") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Мессенджер: \(voice.draftMessenger)")
                            Text("Кому: \(voice.draftRecipient.isEmpty ? "выбрать в приложении" : voice.draftRecipient)")
                            Text(draft).font(.body)
                            Button("Поделиться сообщением") { showingShare = true }
                                .buttonStyle(.borderedProminent)
                            Button("Отменить") { voice.draftMessage = nil }
                                .buttonStyle(.bordered)
                            Text("Выбери нужный мессенджер и получателя в окне отправки, затем подтверди отправку. iOS не разрешает Васе самостоятельно отправлять сообщения через эти приложения.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                GroupBox("Мои приложения") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Навигатор", selection: $navigator) {
                            ForEach(["Яндекс Навигатор", "2ГИС", "Google Карты", "Apple Карты"], id: \.self) { Text($0) }
                        }
                        Picker("Мессенджер", selection: $messenger) {
                            ForEach(["Telegram", "WhatsApp", "Signal", "Viber"], id: \.self) { Text($0) }
                        }
                        Toggle("Слушать при открытии", isOn: $autoListen)
                        Text("Автопрослушивание работает только при активном приложении. Через Cardo потребуется отдельная проверка.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Примеры: «Открой Signal», «Найди заправку», «Построй маршрут до Тверской, 7». Поиск адреса не означает автоматический запуск маршрута.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("Вася распознаёт текст сообщения голосом и открывает окно отправки. Выбор получателя и подтверждение отправки выполняются в мессенджере. Управление чужими приложениями в фоне недоступно.")
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .padding()
        }
        .sheet(isPresented: $showingShare) {
            if let message = voice.draftMessage {
                ShareSheet(items: [message])
            }
        }
        .onAppear {
            if autoListen && !didAutoStart {
                didAutoStart = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { voice.start() }
            }
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
