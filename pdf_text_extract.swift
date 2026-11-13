import Foundation
import PDFKit

guard CommandLine.arguments.count == 3 else {
    fputs("usage: pdf_text_extract input.pdf output.txt\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let document = PDFDocument(url: inputURL) else {
    fputs("could not open PDF\n", stderr)
    exit(1)
}

var pages: [String] = []
pages.reserveCapacity(document.pageCount)

for index in 0..<document.pageCount {
    let text = document.page(at: index)?.string ?? ""
    pages.append(text)
    print(index + 1)
}

let result = pages.joined(separator: "\u{000C}")
try result.write(to: outputURL, atomically: true, encoding: .utf8)
