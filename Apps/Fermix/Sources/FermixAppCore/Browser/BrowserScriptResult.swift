import Foundation

/// Decodes a page script's one answer, the JSON text every call in
/// `WebKitPageScript.text` produces: the one place a script result is
/// interpreted, so nothing downstream reads it a second way.
public enum BrowserScriptResult {
    public static func decode<Answer: Decodable>(_ json: String, as type: Answer.Type = Answer.self) throws -> Answer {
        guard let data = json.data(using: .utf8) else {
            throw BrowserPageDriveError.script("the page script's answer was not UTF-8 text")
        }

        do {
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            throw BrowserPageDriveError.script("unreadable answer: \(error)")
        }
    }
}
