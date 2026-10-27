import Foundation
import NaturalLanguage

/// VYBE's embedder on iOS: Apple's on-device NaturalLanguage embeddings, which ship with the OS
/// and run entirely on the device. Android runs EmbeddingGemma through MediaPipe, which has no
/// matching iOS runtime; the rest of VYBE (descriptions, routing, boosts, index) is the same, so
/// only the vectors (and hence the index file) differ. Query and document need no prompt prefixes.
///
/// Prefers the sentence embedding; where the OS doesn't have it, falls back to the mean of the
/// word vectors of the text's words (built into every iOS version this app supports).
final class SentenceEmbedder: TextEmbedder {
    enum Failure: LocalizedError {
        case unavailable
        case noVector

        var errorDescription: String? {
            switch self {
            case .unavailable: "This device has no on-device English language model"
            case .noVector: "The model returned no embedding"
            }
        }
    }

    private enum Mode {
        case sentence(NLEmbedding)
        case words(NLEmbedding)
    }

    private let mode: Mode
    let modelId: String
    let dimension: Int
    /// Best similarity below this: nothing is described like the query. The sentence model keeps
    /// Android's EmbeddingGemma value until it is measured on a device; averaged word vectors score
    /// everything higher (CI, 2026-10-27: genre and mood queries topped at 0.70-0.76, "sad but
    /// beautiful" at 0.56, a song with no tags at 0.55), so their bar is 0.6.
    var weakBest: Float { usesSentenceModel ? 0.30 : 0.60 }

    init(language: NLLanguage = .english, allowSentence: Bool = true) throws {
        if allowSentence, let sentence = NLEmbedding.sentenceEmbedding(for: language) {
            mode = .sentence(sentence)
            dimension = sentence.dimension
            modelId = "apple-nl-sentence-\(language.rawValue)-r\(sentence.revision)|doc\(VybeText.documentVersion)"
        } else if let words = NLEmbedding.wordEmbedding(for: language) {
            mode = .words(words)
            dimension = words.dimension
            modelId = "apple-nl-words-\(language.rawValue)-r\(words.revision)|doc\(VybeText.documentVersion)"
        } else {
            throw Failure.unavailable
        }
    }

    var usesSentenceModel: Bool {
        if case .sentence = mode { return true }
        return false
    }

    func embed(_ text: String, role: EmbeddingRole) throws -> [Float] {
        switch mode {
        case .sentence(let embedding):
            guard let vector = embedding.vector(for: text), !vector.isEmpty else { throw Failure.noVector }
            return vector.map { Float($0) }
        case .words(let embedding):
            return try Self.meanOfWords(text, embedding: embedding, dimension: dimension)
        }
    }

    /// The average vector of the words the model knows; a text with none of them has no vector.
    private static func meanOfWords(_ text: String, embedding: NLEmbedding, dimension: Int) throws -> [Float] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if let vector = embedding.vector(for: text[range].lowercased()), vector.count == dimension {
                for i in 0..<dimension { sum[i] += vector[i] }
                count += 1
            }
            return true
        }
        guard count > 0 else { throw Failure.noVector }
        return sum.map { Float($0 / Double(count)) }
    }
}
