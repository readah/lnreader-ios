import Foundation

@main struct EpubExportChecks {
    static func main() throws {
        let book = EpubExporter.Book(
            title: "A & B <Test>",
            author: "Someone",
            chapters: [
                .init(title: "Chapter 1", html: "<p>Hello&nbsp;world &amp; more</p><p>Line<br>break</p>"),
                .init(title: "Chapter 2", html: "<div class=\"x\"><p>Unclosed & raw</p>")
            ]
        )
        let data = try EpubExporter.epubData(for: book)
        precondition(Array(data.prefix(4)) == [0x50, 0x4b, 0x03, 0x04], "not a ZIP")
        // The mimetype entry must be first and stored, with no extra field.
        precondition(data[8] == 0 && data[9] == 0, "mimetype must be stored")
        precondition(String(data: data[30..<38], encoding: .utf8) == "mimetype", "mimetype must be first")

        guard let zip = MiniZIP(data: data) else { fatalError("MiniZIP cannot read the exported EPUB") }
        let paths = [
            "mimetype", "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/toc.ncx",
            "OEBPS/nav.xhtml", "OEBPS/styles.css",
            "OEBPS/text/chapter-0001.xhtml", "OEBPS/text/chapter-0002.xhtml"
        ]
        for path in paths {
            guard let file = zip.fileData(for: path) else { fatalError("missing \(path)") }
            if path.hasSuffix(".xml") || path.hasSuffix(".opf") || path.hasSuffix(".ncx") || path.hasSuffix(".xhtml") {
                let parser = XMLParser(data: file)
                precondition(parser.parse(), "\(path) is not well-formed XML")
            }
        }
        precondition(String(data: zip.fileData(for: "mimetype")!, encoding: .utf8) == "application/epub+zip")

        let opf = String(data: zip.fileData(for: "OEBPS/content.opf")!, encoding: .utf8)!
        precondition(opf.contains("A &amp; B &lt;Test&gt;"), "title was not escaped")
        precondition(opf.contains("Someone"), "author missing")
        precondition(opf.contains("properties=\"nav\""), "nav property missing")
        precondition(opf.contains("<spine toc=\"ncx\">"), "NCX fallback missing")
        precondition(opf.range(of: "chapter-0001.xhtml")!.lowerBound
                     < opf.range(of: "chapter-0002.xhtml")!.lowerBound, "chapters out of order")

        let ncx = String(data: zip.fileData(for: "OEBPS/toc.ncx")!, encoding: .utf8)!
        precondition(ncx.contains("Chapter 1") && ncx.contains("Chapter 2"), "NCX is missing chapters")
        let nav = String(data: zip.fileData(for: "OEBPS/nav.xhtml")!, encoding: .utf8)!
        precondition(nav.contains("epub:type=\"toc\""), "nav is not a TOC")

        let first = String(data: zip.fileData(for: "OEBPS/text/chapter-0001.xhtml")!, encoding: .utf8)!
        precondition(first.contains("Hello&#160;world &amp; more"), "HTML entities were not repaired")
        precondition(first.contains("<br />"), "void tag was not closed")
        let second = String(data: zip.fileData(for: "OEBPS/text/chapter-0002.xhtml")!, encoding: .utf8)!
        precondition(second.contains("Unclosed &amp; raw</p></div>"), "open tags were not closed")

        do {
            _ = try EpubExporter.epubData(for: .init(title: "Empty", author: nil, chapters: []))
            fatalError("an empty export should fail")
        } catch {}

        print("epub-export checks passed")
    }
}
