import CaptionFeed
import Foundation
import SafariServices

/// Answers the extension's caption polls with what the Translate app is captioning right now.
/// The app writes the captions to the shared App Group container; this only reads them.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        var reply: [String: Any]
        switch message?["type"] as? String {
        case "captions":
            reply = CaptionFeedReply.make(from: CaptionFeedStore.shared()?.read())
            if let configuration = CaptionExtensionConfigurationStore.shared()?.read() {
                reply["configuration"] = configuration.reply
            }
        default:
            reply = ["error": "Unknown message"]
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
