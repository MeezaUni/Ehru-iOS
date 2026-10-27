import Foundation
import NaturalLanguage

/// VYBE's embedder on iOS: Apple's built-in sentence embedding (NaturalLanguage), which ships with
/// the OS and runs entirely on the device. Android runs EmbeddingGemma through MediaPipe, which has
/// no matching iOS runtime; the rest of VYBE (descriptions, routing, boosts, index) is the same, so
/// only the vectors (and hence the index file) differ. Query and document need no prompt prefixes.
final class SentenceEmbedder: TextEmbedder {
    enum Failure: LocalizedError {
        case unavailable
        case noVector

        var errorDescription: String? {
            switch self {
            case .unavailable: "This device has no on-device sentence model for English"
            case .noVector: "The model returned no embedding"
            }
        }
    }

    private let embedding: NLEmbedding
    let modelId: String
    let dimension: Int
    /// Calibrated for EmbeddingGemma on Android; Apple's model may spread scores differently.
    let weakBest: Float = 0.30

    init(language: NLLanguage = .english) throws {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { throw Failure.unavailable }
        self.embedding = embedding
        dimension = embedding.dimension
        modelId = "apple-nl-sentence-\(language.rawValue)-r\(embedding.revision)|doc\(VybeText.documentVersion)"
    }

    func embed(_ text: String, role: EmbeddingRole) throws -> [Float] {
        guard let vector = embedding.vector(for: text), !vector.isEmpty else { throw Failure.noVector }
        return vector.map { Float($0) }
    }
}
