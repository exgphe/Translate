import Foundation
import SwiftData
import TranslationCore

/// Local text-only history. Images are never stored here.
@Model
final class HistoryEntry {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var sourceText: String
    var translatedText: String
    var sourceLanguage: String?
    var targetLanguage: String
    var engineID: String
    var modelName: String
    var processingLocation: String
    var context: String?
    var promptVersion: String

    init(request: TranslationRequest, result: TranslationResult) {
        id = request.id
        createdAt = result.finishedAt
        sourceText = request.sourceText
        translatedText = result.text
        sourceLanguage = request.effectiveSourceLanguage?.identifier
        targetLanguage = request.targetLanguage.identifier
        engineID = result.providerID
        modelName = result.modelName
        processingLocation = result.processingLocation.rawValue
        context = request.context
        promptVersion = request.promptVersion
    }

    var targetLanguageCode: LanguageCode { LanguageCode(targetLanguage) }
    var sourceLanguageCode: LanguageCode? { sourceLanguage.map(LanguageCode.init) }
    var location: ProcessingLocation { ProcessingLocation(rawValue: processingLocation) ?? .cloud }
}
