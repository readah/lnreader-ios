// EpubExporter.swift - Export a novel's downloaded chapters as one EPUB book.
//
// A chapter qualifies when its download is completed and `OfflineChapters` can
// still validate the files on disk. Manga pages and imported local books are
// deliberately out of scope: neither stores a novel HTML fragment we can put in
// a reading spine. The package is built from plain values so the whole job -
// fetching the rows, reading every file, deflating the archive - can run off
// the main actor.
//
// The EPUB is written by hand: mimetype first and stored, then an EPUB 3
// package with both a nav document and an NCX so older readers still show a
// table of contents. No new dependency is needed; MiniZIP can read the result.

import Compression
import Foundation
import SwiftData
import zlib

enum EpubExporter {
    struct EpubChapter: Sendable {
        let title: String
        let html: String
    }

    struct Book: Sendable {
        let title: String
        let author: String?
        let chapters: [EpubChapter]
    }

    enum ExportError: LocalizedError {
        case noChapters
        case archiveTooLarge

        var errorDescription: String? {
            switch self {
            case .noChapters: "There are no downloaded chapters to export."
            case .archiveTooLarge: "The exported book would be too large for an EPUB archive."
            }
        }
    }

    // MARK: - Collection

    /// Reads the entry's downloaded chapters on whatever actor calls this.
    /// Callers pass a container, never a `ModelContext` from another actor.
    ///
    /// Hidden chapters are filtered in the predicate (`ChapterVisibility` is
    /// the only writer of `hidden`), downloads are fetched in one query, and
    /// the reading order comes from `ChapterOrder` - never from an inline sort.
    static func collect(
        container: ModelContainer,
        sourceKey: String,
        entryURL: String,
        title: String,
        author: String?
    ) throws -> Book {
        let context = ModelContext(container)
        let predicate = #Predicate<Chapter> { chapter in
            chapter.entry?.url == entryURL && chapter.entry?.sourceKey == sourceKey
        }
        var descriptor = FetchDescriptor<Chapter>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.sourceOrder)]
        )
        descriptor.relationshipKeyPathsForPrefetching = []
        let chapters = try context.fetch(descriptor)

        let completed = DownloadState.completed
        let downloads = try context.fetch(FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { item in
                item.state == completed
                    && item.chapter?.entry?.url == entryURL
                    && item.chapter?.entry?.sourceKey == sourceKey
            }
        ))
        let downloaded = Set(downloads.compactMap { $0.chapter?.url })

        let body = ChapterOrder.oldestFirst(chapters.filter {
            !$0.hidden && downloaded.contains($0.url)
        }).compactMap { chapter -> EpubChapter? in
            guard let html = OfflineChapters.novel(
                sourceKey: sourceKey,
                entryURL: entryURL,
                chapterURL: chapter.url
            ) else { return nil }
            return EpubChapter(title: chapter.name, html: html)
        }
        guard !body.isEmpty else { throw ExportError.noChapters }
        return Book(title: title, author: author, chapters: body)
    }

    // MARK: - Package

    /// Builds the complete .epub bytes. Pure: safe to call from a detached task
    /// or from a headless check with hand-made chapters.
    static func epubData(for book: Book) throws -> Data {
        guard !book.chapters.isEmpty else { throw ExportError.noChapters }

        let identifier = "urn:uuid:" + UUID().uuidString.lowercased()
        let modified = modifiedFormatter.string(from: Date())
        let language = "en" // Entries have no language field; EPUB requires one.

        var items = """
              <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
              <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
              <item id="css" href="styles.css" media-type="text/css"/>
        """
        var spine = ""
        var navPoints = ""
        var navItems = ""
        for (index, chapter) in book.chapters.enumerated() {
            let id = "chap-\(index)"
            let path = chapterPath(index)
            let label = escapedXMLText(chapter.title)
            items += "\n    <item id=\"\(id)\" href=\"\(path)\" media-type=\"application/xhtml+xml\"/>"
            spine += "\n    <itemref idref=\"\(id)\"/>"
            navPoints += """
                
                  <navPoint id="np-\(index)" playOrder="\(index + 1)">
                    <navLabel><text>\(label)</text></navLabel>
                    <content src="\(path)"/>
                  </navPoint>
            """
            navItems += "\n      <li><a href=\"\(path)\">\(label)</a></li>"
        }

        let title = escapedXMLText(book.title)
        let creator = escapedXMLText(book.author ?? "Unknown")
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="\(language)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/">
            <dc:identifier id="book-id">\(identifier)</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:creator>\(creator)</dc:creator>
            <dc:language>\(language)</dc:language>
            <dc:date>\(modified)</dc:date>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
        \(items)
          </manifest>
          <spine toc="ncx">
        \(spine)
          </spine>
        </package>
        """

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head><meta name="dtb:uid" content="\(identifier)"/></head>
          <docTitle><text>\(title)</text></docTitle>
          <navMap>
        \(navPoints)
          </navMap>
        </ncx>
        """

        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)" lang="\(language)">
          <head>
            <title>Contents</title>
            <link rel="stylesheet" type="text/css" href="styles.css"/>
          </head>
          <body>
            <nav epub:type="toc" id="toc">
              <h1>Contents</h1>
              <ol>
        \(navItems)
              </ol>
            </nav>
          </body>
        </html>
        """

        let css = """
        body { font-family: Georgia, serif; line-height: 1.6; margin: 1em; }
        h1 { font-size: 1.4em; line-height: 1.3; margin-bottom: 1em; }
        img { max-width: 100%; height: auto; }
        """

        var archive = ZipArchive()
        // The EPUB spec requires this entry first, uncompressed, with no extra field.
        try archive.add("mimetype", data: Data("application/epub+zip".utf8), store: true)
        try archive.add("META-INF/container.xml", data: Data(containerXML.utf8))
        try archive.add("OEBPS/content.opf", data: Data(opf.utf8))
        try archive.add("OEBPS/toc.ncx", data: Data(ncx.utf8))
        try archive.add("OEBPS/nav.xhtml", data: Data(nav.utf8))
        try archive.add("OEBPS/styles.css", data: Data(css.utf8))
        for (index, chapter) in book.chapters.enumerated() {
            let document = chapterDocument(chapter, at: index, language: language)
            try archive.add("OEBPS/\(chapterPath(index))", data: Data(document.utf8))
        }
        return archive.finish()
    }

    private static func chapterPath(_ index: Int) -> String {
        "text/chapter-\(String(format: "%04d", index + 1)).xhtml"
    }

    private static func chapterDocument(_ chapter: EpubChapter, at index: Int, language: String) -> String {
        let title = escapedXMLText(chapter.title)
        // Downloaded chapters are SwiftSoup fragments: tags are balanced but
        // void tags and HTML entities are not XML. The sanitizer below repairs
        // both, and closes anything left open, before the fragment goes in a
        // content document.
        let body = xhtmlFragment(chapter.html)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(language)" lang="\(language)">
          <head>
            <title>\(title)</title>
            <link rel="stylesheet" type="text/css" href="../styles.css"/>
          </head>
          <body>
            <h1>\(title)</h1>
            <div class="chapter">
        \(body)
            </div>
          </body>
        </html>
        """
    }

    private static let modifiedFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - HTML to XHTML

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    /// The entities SwiftSoup's default (base) escape mode can write, plus the
    /// handful of common ones sources use from full HTML. Named references are
    /// not defined in XML, so they become numeric character references.
    /// These five are predefined in XML, so they need no conversion.
    private static let xmlEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    private static let entityCodes: [String: String] = [
        "AElig": "198", "AMP": "38", "Aacute": "193", "Acirc": "194", "Agrave": "192",
        "Aring": "197", "Atilde": "195", "Auml": "196", "COPY": "169", "Ccedil": "199",
        "ETH": "208", "Eacute": "201", "Ecirc": "202", "Egrave": "200", "Euml": "203",
        "GT": "62", "Iacute": "205", "Icirc": "206", "Igrave": "204", "Iuml": "207",
        "LT": "60", "Ntilde": "209", "Oacute": "211", "Ocirc": "212", "Ograve": "210",
        "Oslash": "216", "Otilde": "213", "Ouml": "214", "QUOT": "34", "REG": "174",
        "THORN": "222", "Uacute": "218", "Ucirc": "219", "Ugrave": "217", "Uuml": "220",
        "Yacute": "221", "aacute": "225", "acirc": "226", "acute": "180", "aelig": "230",
        "agrave": "224", "amp": "38", "apos": "39", "aring": "229", "atilde": "227",
        "auml": "228", "brvbar": "166", "bull": "8226", "ccedil": "231", "cedil": "184",
        "cent": "162", "copy": "169", "curren": "164", "deg": "176", "divide": "247",
        "eacute": "233", "ecirc": "234", "egrave": "232", "eth": "240", "euml": "235",
        "euro": "8364", "frac12": "189", "frac14": "188", "frac34": "190", "gt": "62",
        "hellip": "8230", "iacute": "237", "icirc": "238", "iexcl": "161", "igrave": "236",
        "iquest": "191", "iuml": "239", "laquo": "171", "ldquo": "8220", "larr": "8592",
        "lsquo": "8216", "lt": "60", "macr": "175", "mdash": "8212", "micro": "181",
        "middot": "183", "nbsp": "160", "ndash": "8211", "not": "172", "ntilde": "241",
        "oacute": "243", "ocirc": "244", "ograve": "242", "ordf": "170", "ordm": "186",
        "oslash": "248", "otilde": "245", "ouml": "246", "para": "182", "plusmn": "177",
        "pound": "163", "quot": "34", "raquo": "187", "rarr": "8594", "rdquo": "8221",
        "reg": "174", "rsquo": "8217", "sect": "167", "shy": "173", "sup1": "185",
        "sup2": "178", "sup3": "179", "szlig": "223", "thorn": "254", "times": "215",
        "trade": "8482", "uacute": "250", "ucirc": "251", "ugrave": "249", "uml": "168",
        "uuml": "252", "yacute": "253", "yen": "165", "yuml": "255"
    ]

    private static func escapedXMLText(_ text: String) -> String {
        escapedAmpersands(text)
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Converts HTML named entities to numeric references, escapes stray `&`
    /// and drops control characters XML forbids. Leaves markup characters
    /// alone so it can be applied to a tag's raw text as well as to prose.
    private static func escapedAmpersands(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&" {
                var cursor = text.index(after: index)
                var name = ""
                while cursor < text.endIndex, name.count < 32, text[cursor].isLetter || text[cursor].isNumber {
                    name.append(text[cursor])
                    cursor = text.index(after: cursor)
                }
                if !name.isEmpty, cursor < text.endIndex, text[cursor] == ";" {
                    if xmlEntities.contains(name) {
                        output += "&" + name + ";"
                    } else if let codes = entityCodes[name] {
                        output += codes.split(separator: ",").compactMap {
                            UInt32($0).flatMap { Unicode.Scalar($0) }
                        }.map { "&#\($0.value);" }.joined()
                    } else {
                        // Unknown named reference: show the name, keep the XML valid.
                        output += "&amp;" + name + ";"
                    }
                    index = text.index(after: cursor)
                    continue
                }
                output += "&amp;"
            } else if let scalar = character.unicodeScalars.first, scalar.value < 0x20,
                      scalar != "\n" && scalar != "\r" && scalar != "\t" {
                // Not representable in XML 1.0.
            } else {
                output.append(character)
            }
            index = text.index(after: index)
        }
        return output
    }

    /// Repairs an HTML fragment into XML: self-closes void tags, closes whatever
    /// is left open, and removes scripts and styles that have no place in a book.
    private static func xhtmlFragment(_ html: String) -> String {
        let stripped = html.replacingOccurrences(
            of: #"<(script|style)\b[^>]*>[\s\S]*?</\1\s*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let characters = Array(stripped)
        var output = ""
        var open: [String] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "<" else {
                let start = index
                while index < characters.count && characters[index] != "<" { index += 1 }
                output += escapedXMLText(String(characters[start..<index]))
                continue
            }
            if matches("!--", at: index + 1, in: characters),
               let start = find("-->", from: index + 4, in: characters) {
                output += String(characters[index..<(start + 3)])
                index = start + 3
                continue
            }
            guard index + 1 < characters.count else { break }
            let first = characters[index + 1]
            guard first.isLetter || first == "/" || first == "!" || first == "?" else {
                output += "&lt;"
                index += 1
                continue
            }
            guard let end = tagEnd(from: index, in: characters) else { break }
            let raw = escapedAmpersands(String(characters[index...end]))
            let name = tagName(from: index + 1, upTo: end, in: characters).lowercased()
            index = end + 1
            guard !name.isEmpty, !name.hasPrefix("!"), !name.hasPrefix("?") else { continue }

            if raw.hasPrefix("</") {
                if let position = open.lastIndex(of: name) {
                    while open.count > position { output += "</\(open.removeLast())>" }
                }
            } else if voidElements.contains(name) {
                output += raw.hasSuffix("/>") ? raw : String(raw.dropLast()) + " />"
            } else if raw.hasSuffix("/>") {
                output += raw
            } else {
                output += raw
                open.append(name)
            }
        }
        while let name = open.popLast() { output += "</\(name)>" }
        return output
    }

    private static func tagEnd(from start: Int, in characters: [Character]) -> Int? {
        var quote: Character?
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func tagName(from start: Int, upTo end: Int, in characters: [Character]) -> String {
        var name = ""
        for index in start..<min(end, characters.count) {
            let character = characters[index]
            if character.isLetter || character.isNumber || character == "-" || character == "_" || character == ":" {
                name.append(character)
            } else if name.isEmpty && character == "/" {
                continue
            } else {
                break
            }
        }
        return name
    }

    private static func matches(_ token: String, at index: Int, in characters: [Character]) -> Bool {
        let needle = Array(token)
        guard index >= 0, index + needle.count <= characters.count else { return false }
        return Array(characters[index..<(index + needle.count)]) == needle
    }

    private static func find(_ token: String, from start: Int, in characters: [Character]) -> Int? {
        let needle = Array(token)
        guard start >= 0, start + needle.count <= characters.count else { return nil }
        for index in start...(characters.count - needle.count) {
            if Array(characters[index..<(index + needle.count)]) == needle { return index }
        }
        return nil
    }

    // MARK: - ZIP

    /// The smallest ZIP writer that satisfies EPUB: stored mimetype, deflated
    /// members, UTF-8 names, and one central directory. The reader in
    /// `MiniZIP` accepts the result.
    private struct ZipArchive {
        private struct Member {
            let name: Data
            let method: UInt16
            let checksum: UInt32
            let compressed: Data
            let size: UInt32
            let offset: UInt32
        }

        private var data = Data()
        private var members: [Member] = []

        mutating func add(_ path: String, data payload: Data, store: Bool = false) throws {
            guard let name = path.data(using: .utf8), payload.count <= Int(UInt32.max),
                  data.count <= Int(UInt32.max) else { throw ExportError.archiveTooLarge }
            let checksum = EpubExporter.checksum(payload)
            let method: UInt16
            let compressed: Data
            if store {
                method = 0
                compressed = payload
            } else if let deflated = EpubExporter.deflate(payload), deflated.count < payload.count {
                method = 8
                compressed = deflated
            } else {
                method = 0
                compressed = payload
            }

            let offset = UInt32(data.count)
            data += EpubExporter.bytes32(0x04034b50) // local file header
            data += EpubExporter.bytes16(20)         // version needed
            data += EpubExporter.bytes16(0x0800)     // UTF-8 names
            data += EpubExporter.bytes16(method)
            data += EpubExporter.bytes16(0)          // time
            data += EpubExporter.bytes16(0x0021)     // date: 1980-01-01
            data += EpubExporter.bytes32(checksum)
            data += EpubExporter.bytes32(UInt32(compressed.count))
            data += EpubExporter.bytes32(UInt32(payload.count))
            data += EpubExporter.bytes16(UInt16(name.count))
            data += EpubExporter.bytes16(0)          // extra length
            data += name
            data += compressed

            members.append(Member(name: name, method: method, checksum: checksum,
                                  compressed: compressed, size: UInt32(payload.count), offset: offset))
        }

        mutating func finish() -> Data {
            let directoryStart = UInt32(data.count)
            for member in members {
                data += EpubExporter.bytes32(0x02014b50) // central directory header
                data += EpubExporter.bytes16(20)         // made by
                data += EpubExporter.bytes16(20)         // needed
                data += EpubExporter.bytes16(0x0800)
                data += EpubExporter.bytes16(member.method)
                data += EpubExporter.bytes16(0)
                data += EpubExporter.bytes16(0x0021)
                data += EpubExporter.bytes32(member.checksum)
                data += EpubExporter.bytes32(UInt32(member.compressed.count))
                data += EpubExporter.bytes32(member.size)
                data += EpubExporter.bytes16(UInt16(member.name.count))
                data += EpubExporter.bytes16(0) // extra
                data += EpubExporter.bytes16(0) // comment
                data += EpubExporter.bytes16(0) // disk start
                data += EpubExporter.bytes16(0) // internal attributes
                data += EpubExporter.bytes32(0) // external attributes
                data += EpubExporter.bytes32(member.offset)
                data += member.name
            }
            let directorySize = UInt32(data.count) - directoryStart
            data += EpubExporter.bytes32(0x06054b50) // end of central directory
            data += EpubExporter.bytes16(0)
            data += EpubExporter.bytes16(0)
            data += EpubExporter.bytes16(UInt16(members.count))
            data += EpubExporter.bytes16(UInt16(members.count))
            data += EpubExporter.bytes32(directorySize)
            data += EpubExporter.bytes32(directoryStart)
            data += EpubExporter.bytes16(0)
            return data
        }
    }

    private static func checksum(_ payload: Data) -> UInt32 {
        payload.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(crc32(0, base, uInt(payload.count)))
        }
    }

    /// `COMPRESSION_ZLIB` is a raw DEFLATE stream, which is what ZIP method 8
    /// expects (the same call `Gzip.compress` uses behind its header).
    private static func deflate(_ payload: Data) -> Data? {
        let capacity = max(payload.count + payload.count / 10 + 1024, 1024)
        var buffer = [UInt8](repeating: 0, count: capacity)
        let size = payload.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&buffer, capacity, base, payload.count, nil, COMPRESSION_ZLIB)
        }
        guard size > 0 else { return nil }
        return Data(buffer[0..<size])
    }

    private static func bytes16(_ value: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
    }

    private static func bytes32(_ value: UInt32) -> Data {
        Data([0, 8, 16, 24].map { UInt8(truncatingIfNeeded: value >> UInt32($0)) })
    }
}
