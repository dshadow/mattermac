import MattermacCore
import SwiftUI

/// Shared by timeline, future thread and direct-message surfaces. Never fetches Markdown images.
struct MessageTextView: View {
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(MessageBlock.parse(message).enumerated()), id: \.offset) { _, block in
        if block.isCode {
          Text(verbatim: block.text).font(.system(.body, design: .monospaced))
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        } else {
          Text(inline(block.text))
        }
      }
    }
    .textSelection(.enabled)
    .environment(
      \.openURL,
      OpenURLAction { url in
        MessagePresentation.allowsLink(url) ? .systemAction : .discarded
      })
  }

  private func inline(_ text: String) -> AttributedString {
    var result =
      (try? AttributedString(
        markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
    for run in result.runs {
      if let link = run.link, !MessagePresentation.allowsLink(link) { result[run.range].link = nil }
      if run.inlinePresentationIntent?.contains(.code) == true {
        result[run.range].font = .system(.body, design: .monospaced)
        result[run.range].backgroundColor = .secondary.opacity(0.12)
      }
    }
    let plain = String(result.characters)
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
      for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
        if let url = match.url, MessagePresentation.allowsLink(url),
          let range = Range(match.range, in: plain), let attributedRange = Range(range, in: result),
          result[attributedRange].inlinePresentationIntent?.contains(.code) != true,
          result[attributedRange].link == nil
        {
          result[attributedRange].link = url
        }
      }
    }
    if let expression = try? NSRegularExpression(pattern: #"(?<![\w@])@[\w.-]+"#) {
      for match in expression.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
        if let range = Range(match.range, in: plain),
          let attributedRange = Range(range, in: result),
          result[attributedRange].inlinePresentationIntent?.contains(.code) != true
        {
          result[attributedRange].foregroundColor = .accentColor
          result[attributedRange].font = .body.bold()
        }
      }
    }
    return result
  }
}
