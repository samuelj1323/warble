import AVFAudio

/// Speaks text via AVSpeechSynthesizer, fully offline. Replaces the lack of
/// any TTS in the old Electron app — used for Mac-control confirmations and
/// code-change summaries in later tickets.
final class TTSService {
    private let speakUtterance: (AVSpeechUtterance) -> Void

    init(speakUtterance: ((AVSpeechUtterance) -> Void)? = nil) {
        if let speakUtterance {
            self.speakUtterance = speakUtterance
        } else {
            let synthesizer = AVSpeechSynthesizer()
            self.speakUtterance = { synthesizer.speak($0) }
        }
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        speakUtterance(AVSpeechUtterance(string: text))
    }
}
