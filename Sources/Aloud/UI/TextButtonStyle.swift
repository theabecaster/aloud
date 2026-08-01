import SwiftUI

// The app's text button. A settings row already says what it is; the action
// only has to say what it does, so it does it in words — accent-coloured so
// it still reads as the one thing to click, with no bezel to draw the eye
// away from the row's own label. A bordered button in that position competes
// with every other row for attention and turns a list into a control panel.
//
// Reserve the bordered styles for the places that genuinely need weight: a
// sheet's Cancel/Save pair, the commit button of an inline editor, and the
// hotkey capture well.
struct TextButtonStyle: ButtonStyle {
    // Overridable for the one case that isn't an invitation to click: a copy
    // control that has just copied says so in Aloud's own blue.
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .opacity(configuration.isPressed ? 0.5 : 1)
            // The words are a small target — take the whole label's frame
            // rather than only the glyphs the text happens to cover.
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == TextButtonStyle {
    static var text: TextButtonStyle { TextButtonStyle() }
    static func text(_ tint: Color) -> TextButtonStyle { TextButtonStyle(tint: tint) }
}
