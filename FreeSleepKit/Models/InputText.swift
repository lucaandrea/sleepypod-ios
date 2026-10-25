import Foundation

enum InputText {
    // Match the API's UTF-16 limit without splitting an emoji or composed character.
    static func limit(_ text: String, to maximum: Int) -> String {
        var size = 0
        return String(text.prefix { character in
            size += String(character).utf16.count; return size <= maximum
        })
    }
}
