import Foundation
import SwiftData
import PDFKit

/// Manages importing local e-books, unzipping their contents, parsing EPUB metadata/chapters, and inserting records into SwiftData.
///
/// Not main-actor isolated on purpose: PDF text extraction and EPUB unzipping take
/// seconds on a large book. Callers pass a background `ModelContext`.
final class LocalBookManager {
    /// PDF outlines define chapters; PDFs without outlines use eight-page sections.
    static func importPDF(at fileURL: URL, context: ModelContext) throws {
        guard let document = PDFDocument(url: fileURL), document.pageCount > 0 else { throw TTSError.request("This PDF could not be opened.") }
        var pages: [[String]] = []
        for index in 0..<document.pageCount {
            pages.append((document.page(at: index)?.string ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        }
        guard pages.joined().contains(where: { !$0.isEmpty }) else { throw TTSError.request("This PDF has no selectable text. Import an EPUB or a PDF with a text layer.") }
        // Only repeated margin lines qualify as running headers/footers.
        var margins: [String: Int] = [:]
        for lines in pages {
            for line in Set(Array(lines.filter { !$0.isEmpty }.prefix(2)) + Array(lines.filter { !$0.isEmpty }.suffix(2))) where !line.isEmpty { margins[line, default: 0] += 1 }
        }
        let recurring = Set(margins.filter { $0.value >= max(3, document.pageCount / 3) }.map(\.key))
        var starts: [(Int, String)] = []
        func collect(_ outline: PDFOutline) {
            if let page = outline.destination?.page {
                let index = document.index(for: page)
                if index != NSNotFound { starts.append((index, outline.label ?? "Section \(index + 1)")) }
            }
            for index in 0..<outline.numberOfChildren { if let child = outline.child(at: index) { collect(child) } }
        }
        if let outline = document.outlineRoot { collect(outline) }
        starts.sort { $0.0 < $1.0 }
        var seen: Set<Int> = []
        starts = starts.filter { seen.insert($0.0).inserted }
        if starts.isEmpty { starts = stride(from: 0, to: document.pageCount, by: 8).map { ($0, "Pages \($0 + 1)–\(min($0 + 8, document.pageCount))") } }
        else if starts[0].0 > 0 { starts.insert((0, "Front matter"), at: 0) }
        let id = UUID().uuidString
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalNovels").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? fileURL.deletingPathExtension().lastPathComponent
        let novel = Entry(kind: .novel, sourceKey: SourceKey.local, url: "local://\(id)", title: title)
        novel.author = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        novel.inLibrary = true
        var chapters: [Chapter] = []
        do {
            for (position, section) in starts.enumerated() {
                let end = position + 1 < starts.count ? starts[position + 1].0 : document.pageCount
                var paragraphs: [String] = []
                for pageIndex in section.0..<end {
                    let lines = pages[pageIndex]
                    var paragraph = ""
                    func flush() { if !paragraph.isEmpty { paragraphs.append(paragraph); paragraph = "" } }
                    for (lineIndex, line) in lines.enumerated() {
                        let margin = lineIndex < 2 || lineIndex >= lines.count - 2
                        if margin && (recurring.contains(line) || line.range(of: #"^(?:Page\s+)?\d+(?:\s+of\s+\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil) { continue }
                        if line.isEmpty { flush(); continue }
                        let clean = line.replacingOccurrences(of: #"[⁰¹²³⁴⁵⁶⁷⁸⁹]+"#, with: "", options: .regularExpression)
                        if paragraph.hasSuffix("-") { paragraph.removeLast(); paragraph += clean }
                        else { paragraph += (paragraph.isEmpty ? "" : " ") + clean }
                    }
                    flush()
                }
                guard !paragraphs.isEmpty else { continue }
                let path = "chapter-\(position).html"
                try TTSBookIdentity.html(blocks: paragraphs).write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
                let chapter = Chapter(
                    url: path,
                    name: section.1,
                    chapterNumber: Double(chapters.count + 1),
                    sourceOrder: chapters.count
                )
                chapter.entry = novel
                chapters.append(chapter)
            }
            novel.chapters = chapters
            context.insert(novel)
            try context.save()
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    
    /// Imports an EPUB file, extracts all its assets, parses its structural metadata, and inserts it into SwiftData.
    static func importEPUB(at fileURL: URL, context: ModelContext) throws {
        print("📥 [LocalBookManager] Starting import for file: \(fileURL.path)")
        
        guard let data = try? Data(contentsOf: fileURL) else {
            print("❌ [LocalBookManager] Failed to read data from file URL: \(fileURL)")
            throw NSError(
                domain: "LocalBookManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to read EPUB file from: \(fileURL.lastPathComponent)"]
            )
        }
        print("📥 [LocalBookManager] File size: \(data.count) bytes")
        
        guard let zip = MiniZIP(data: data) else {
            print("❌ [LocalBookManager] MiniZIP failed to parse data as a valid ZIP archive")
            throw NSError(
                domain: "LocalBookManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid EPUB file format (not a valid ZIP archive)"]
            )
        }
        print("📥 [LocalBookManager] MiniZIP initialized successfully. Found \(zip.entries.count) zip entries.")
        
        // Generate a unique identifier and path for the local novel
        let novelId = UUID().uuidString
        let novelPath = "local://\(novelId)"
        print("📥 [LocalBookManager] Assigned Novel ID: \(novelId), Path: \(novelPath)")
        
        let fileManager = FileManager.default
        let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let bookDir = docDir.appendingPathComponent("LocalNovels").appendingPathComponent(novelId)
        print("📥 [LocalBookManager] Target extraction directory: \(bookDir.path)")
        
        try fileManager.createDirectory(at: bookDir, withIntermediateDirectories: true)
        
        // Extract all entries in the ZIP to disk
        var extractedCount = 0
        for (path, _) in zip.entries {
            if path.hasSuffix("/") { continue } // Skip directories
            
            if let fileData = zip.fileData(for: path) {
                let targetURL = bookDir.appendingPathComponent(path)
                let parentDir = targetURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                try fileData.write(to: targetURL)
                extractedCount += 1
            } else {
                print("⚠️ [LocalBookManager] Failed to extract data for entry: \"\(path)\"")
            }
        }
        print("📥 [LocalBookManager] Extracted \(extractedCount) files to disk.")
        
        // Parse META-INF/container.xml to find the primary package OPF file
        let containerURL = bookDir.appendingPathComponent("META-INF/container.xml")
        print("📥 [LocalBookManager] Checking for container.xml at: \(containerURL.path)")
        guard fileManager.fileExists(atPath: containerURL.path) else {
            print("❌ [LocalBookManager] container.xml does not exist at expected path")
            throw NSError(
                domain: "LocalBookManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "META-INF/container.xml is missing from the EPUB."]
            )
        }
        
        guard let containerData = try? Data(contentsOf: containerURL) else {
            print("❌ [LocalBookManager] Failed to read container.xml data")
            throw NSError(
                domain: "LocalBookManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to read META-INF/container.xml."]
            )
        }
        
        guard let containerXML = parseXML(data: containerData) else {
            print("❌ [LocalBookManager] TinyXMLParser failed to parse container.xml")
            throw NSError(
                domain: "LocalBookManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "META-INF/container.xml is not valid XML."]
            )
        }
        
        guard let rootfile = containerXML.child(named: "rootfiles")?.child(named: "rootfile"),
              let opfRelativePath = rootfile.attributes["full-path"] else {
            print("❌ [LocalBookManager] Could not find rootfile tag or full-path attribute in container.xml")
            throw NSError(
                domain: "LocalBookManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "META-INF/container.xml structure is invalid."]
            )
        }
        print("📥 [LocalBookManager] Located OPF relative path in container.xml: \"\(opfRelativePath)\"")
        
        // Parse the OPF manifest/metadata file
        let opfURL = bookDir.appendingPathComponent(opfRelativePath)
        print("📥 [LocalBookManager] Checking for OPF file at: \(opfURL.path)")
        guard fileManager.fileExists(atPath: opfURL.path) else {
            print("❌ [LocalBookManager] OPF package file does not exist on disk")
            throw NSError(
                domain: "LocalBookManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "OPF package file is missing at: \(opfRelativePath)"]
            )
        }
        
        guard let opfData = try? Data(contentsOf: opfURL) else {
            print("❌ [LocalBookManager] Failed to read OPF file data")
            throw NSError(
                domain: "LocalBookManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to read OPF package file."]
            )
        }
        
        guard let opfXML = parseXML(data: opfData) else {
            print("❌ [LocalBookManager] TinyXMLParser failed to parse OPF XML")
            throw NSError(
                domain: "LocalBookManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "OPF file is not valid XML."]
            )
        }
        print("📥 [LocalBookManager] OPF XML parsed successfully.")
        
        // Extract metadata: title, author, summary, and subjects (genres)
        let metadataNode = opfXML.child(named: "metadata")
        let title = metadataNode?.child(named: "dc:title")?.value ?? fileURL.deletingPathExtension().lastPathComponent
        let author = metadataNode?.child(named: "dc:creator")?.value ?? "Unknown Author"
        let summary = metadataNode?.child(named: "dc:description")?.value
        
        let subjects = metadataNode?.children(named: "dc:subject").map { $0.value } ?? []
        let genres = subjects.isEmpty ? nil : subjects.joined(separator: ", ")
        print("📥 [LocalBookManager] Book Metadata -> Title: \"\(title)\", Author: \"\(author)\", Summary: \"\(summary ?? "None")\", Genres: \"\(genres ?? "None")\"")
        
        let opfDir = (opfRelativePath as NSString).deletingLastPathComponent
        
        // Parse Manifest items
        var manifest: [String: (href: String, mediaType: String, properties: String?)] = [:]
        if let manifestNode = opfXML.child(named: "manifest") {
            for item in manifestNode.children(named: "item") {
                if let id = item.attributes["id"],
                   let href = item.attributes["href"],
                   let mediaType = item.attributes["media-type"] {
                    manifest[id] = (href, mediaType, item.attributes["properties"])
                }
            }
        }
        print("📥 [LocalBookManager] Manifest contains \(manifest.count) item declarations.")
        
        // Parse Spine reading order
        var spineIds: [String] = []
        if let spineNode = opfXML.child(named: "spine") {
            for itemref in spineNode.children(named: "itemref") {
                if let idref = itemref.attributes["idref"] {
                    spineIds.append(idref)
                }
            }
        }
        print("📥 [LocalBookManager] Spine contains \(spineIds.count) reading order items.")
        
        // Try to identify the cover image
        var coverRelativePath: String?
        // Method A: Check for properties="cover-image" (EPUB 3)
        for (id, item) in manifest {
            if let props = item.properties, props.contains("cover-image") {
                coverRelativePath = item.href
                print("📥 [LocalBookManager] Found cover-image property in manifest item \"\(id)\": \"\(item.href)\"")
                break
            }
        }
        // Method B: Check meta tags for cover ID (EPUB 2)
        if coverRelativePath == nil {
            if let metaTags = metadataNode?.children(named: "meta") {
                for meta in metaTags {
                    if meta.attributes["name"] == "cover",
                       let coverId = meta.attributes["content"],
                       let item = manifest[coverId] {
                        coverRelativePath = item.href
                        print("📥 [LocalBookManager] Found cover metadata pointing to manifest item \"\(coverId)\": \"\(item.href)\"")
                        break
                    }
                }
            }
        }
        // Method C: Check manifest items named "cover"
        if coverRelativePath == nil {
            for (id, item) in manifest {
                let lowerId = id.lowercased()
                if lowerId == "cover" || lowerId == "cover-image" || lowerId == "cover-img" {
                    coverRelativePath = item.href
                    print("📥 [LocalBookManager] Found cover fallback by ID name \"\(id)\": \"\(item.href)\"")
                    break
                }
            }
        }
        
        var coverFileURLString: String?
        if let coverRel = coverRelativePath {
            let coverRelResolved = opfDir.isEmpty ? coverRel : (opfDir as NSString).appendingPathComponent(coverRel)
            let coverResolved = (coverRelResolved as NSString).standardizingPath
            let extractedCoverURL = bookDir.appendingPathComponent(coverResolved)
            print("📥 [LocalBookManager] Cover image resolved file path: \(extractedCoverURL.path)")
            
            if fileManager.fileExists(atPath: extractedCoverURL.path) {
                let coversDir = docDir.appendingPathComponent("Covers")
                try fileManager.createDirectory(at: coversDir, withIntermediateDirectories: true)
                let destCoverURL = coversDir.appendingPathComponent("\(novelId).jpg")
                if fileManager.fileExists(atPath: destCoverURL.path) {
                    try? fileManager.removeItem(at: destCoverURL)
                }
                try fileManager.copyItem(at: extractedCoverURL, to: destCoverURL)
                coverFileURLString = "local://Covers/\(novelId).jpg"
                print("📥 [LocalBookManager] Copied cover to library storage: \(destCoverURL.path)")
            } else {
                print("⚠️ [LocalBookManager] Cover file does not exist at resolved path: \(extractedCoverURL.path)")
            }
        } else {
            print("📥 [LocalBookManager] No cover image identified for this book.")
        }
        
        // Parse Chapter list (Table of Contents)
        var parsedChapters: [(title: String, href: String)] = []
        
        // 1. Check for NCX file (EPUB 2 / EPUB 3 fallback)
        var ncxPath: String?
        if let spineNode = opfXML.child(named: "spine"),
           let tocId = spineNode.attributes["toc"],
           let item = manifest[tocId] {
            ncxPath = item.href
        } else {
            for (_, item) in manifest {
                if item.mediaType == "application/x-dtbncx+xml" {
                    ncxPath = item.href
                    break
                }
            }
        }
        
        if let ncxRel = ncxPath {
            let ncxRelResolved = opfDir.isEmpty ? ncxRel : (opfDir as NSString).appendingPathComponent(ncxRel)
            let ncxResolved = (ncxRelResolved as NSString).standardizingPath
            let ncxURL = bookDir.appendingPathComponent(ncxResolved)
            print("📥 [LocalBookManager] Attempting to parse TOC from NCX file: \(ncxURL.path)")
            
            if fileManager.fileExists(atPath: ncxURL.path),
               let ncxData = try? Data(contentsOf: ncxURL),
               let ncxXML = parseXML(data: ncxData) {
                let navPoints = findNavPoints(in: ncxXML)
                print("📥 [LocalBookManager] NCX parsing returned \(navPoints.count) navPoints.")
                for navPoint in navPoints {
                    let label = navPoint.child(named: "navlabel")?.child(named: "text")?.value ?? "Unknown Chapter"
                    if let src = navPoint.child(named: "content")?.attributes["src"] {
                        let ncxDir = (ncxResolved as NSString).deletingLastPathComponent
                        let srcResolved = ncxDir.isEmpty ? src : (ncxDir as NSString).appendingPathComponent(src)
                        let srcStandardized = (srcResolved as NSString).standardizingPath
                        parsedChapters.append((label, srcStandardized))
                    }
                }
            } else {
                print("⚠️ [LocalBookManager] NCX file does not exist or failed to parse.")
            }
        }
        
        // 2. Check for EPUB 3 NAV document (if NCX was missing or empty)
        if parsedChapters.isEmpty {
            var navPath: String?
            for (_, item) in manifest {
                if let props = item.properties, props.contains("nav") {
                    navPath = item.href
                    break
                }
            }
            
            if let navRel = navPath {
                let navRelResolved = opfDir.isEmpty ? navRel : (opfDir as NSString).appendingPathComponent(navRel)
                let navResolved = (navRelResolved as NSString).standardizingPath
                let navURL = bookDir.appendingPathComponent(navResolved)
                print("📥 [LocalBookManager] Attempting to parse TOC from EPUB3 NAV file: \(navURL.path)")
                
                if fileManager.fileExists(atPath: navURL.path),
                   let navData = try? Data(contentsOf: navURL),
                   let navXML = parseXML(data: navData) {
                    
                    func findNavNode(in node: XMLNode) -> XMLNode? {
                        if node.name.lowercased() == "nav" { return node }
                        for child in node.children {
                            if let found = findNavNode(in: child) { return found }
                        }
                        return nil
                    }
                    
                    func findLinks(in node: XMLNode) -> [XMLNode] {
                        var links: [XMLNode] = []
                        if node.name.lowercased() == "a" { links.append(node) }
                        for child in node.children {
                            links.append(contentsOf: findLinks(in: child))
                        }
                        return links
                    }
                    
                    if let navNode = findNavNode(in: navXML) {
                        let links = findLinks(in: navNode)
                        print("📥 [LocalBookManager] EPUB3 NAV parsing found \(links.count) links.")
                        for link in links {
                            if let src = link.attributes["href"] {
                                let navDir = (navResolved as NSString).deletingLastPathComponent
                                let srcResolved = navDir.isEmpty ? src : (navDir as NSString).appendingPathComponent(src)
                                let srcStandardized = (srcResolved as NSString).standardizingPath
                                parsedChapters.append((link.value, srcStandardized))
                            }
                        }
                    } else {
                        print("⚠️ [LocalBookManager] Could not find <nav> tag inside NAV document.")
                    }
                } else {
                    print("⚠️ [LocalBookManager] EPUB3 NAV file does not exist or failed to parse.")
                }
            }
        }
        
        // 3. Fallback: Parse directly in Spine order if no navigation files exist
        if parsedChapters.isEmpty {
            print("📥 [LocalBookManager] TOC parsing returned no entries. Falling back to OPF Spine order.")
            for idref in spineIds {
                if let item = manifest[idref] {
                    if item.mediaType == "application/xhtml+xml" || item.mediaType == "text/html" {
                        let srcResolved = opfDir.isEmpty ? item.href : (opfDir as NSString).appendingPathComponent(item.href)
                        let srcStandardized = (srcResolved as NSString).standardizingPath
                        
                        var titleText = "Chapter \(parsedChapters.count + 1)"
                        let itemURL = bookDir.appendingPathComponent(srcStandardized)
                        
                        if fileManager.fileExists(atPath: itemURL.path),
                           let itemData = try? Data(contentsOf: itemURL),
                           let itemXML = parseXML(data: itemData) {
                            
                            func findTitleNode(in node: XMLNode) -> String? {
                                if node.name.lowercased() == "title" && !node.value.isEmpty {
                                    return node.value
                                }
                                if node.name.lowercased() == "h1" && !node.value.isEmpty {
                                    return node.value
                                }
                                for child in node.children {
                                    if let found = findTitleNode(in: child) { return found }
                                }
                                return nil
                            }
                            
                            if let titleFound = findTitleNode(in: itemXML) {
                                titleText = titleFound
                            }
                        }
                        
                        parsedChapters.append((titleText, srcStandardized))
                    }
                }
            }
        }
        
        // Clean paths: strip inner anchors (#section) and deduplicate chapters mapping to the same xhtml document.
        var cleanChapters: [(title: String, path: String)] = []
        for ch in parsedChapters {
            let cleanPath = ch.href.components(separatedBy: "#")[0]
            if !cleanChapters.contains(where: { $0.path == cleanPath }) {
                cleanChapters.append((ch.title, cleanPath))
            }
        }
        print("📥 [LocalBookManager] Finished parsing. Total chapters compiled: \(cleanChapters.count)")
        
        if cleanChapters.isEmpty {
            print("⚠️ [LocalBookManager] Warning: No chapters resolved for this EPUB book.")
        }
        
        // Save the entry and chapter metadata in SwiftData
        let novel = Entry(kind: .novel, sourceKey: SourceKey.local, url: novelPath, title: title)
        novel.thumbnailURL = coverFileURLString
        novel.summary = summary
        novel.author = author
        novel.status = .completed
        novel.genres = subjects
        novel.inLibrary = true

        context.insert(novel)

        for (index, ch) in cleanChapters.enumerated() {
            let chapter = Chapter(
                url: ch.path,
                name: ch.title,
                chapterNumber: Double(index + 1),
                sourceOrder: index
            )
            chapter.entry = novel
            context.insert(chapter)
            print("📥 [LocalBookManager]   Linked chapter [\(index + 1)]: \"\(ch.title)\" -> path: \"\(ch.path)\"")
        }
        
        try context.save()
        print("🎉 [LocalBookManager] EPUB import completed successfully for \"\(title)\"!")
    }
    
    private static func findNavPoints(in node: XMLNode) -> [XMLNode] {
        var results: [XMLNode] = []
        if node.name.lowercased() == "navpoint" {
            results.append(node)
        }
        for child in node.children {
            results.append(contentsOf: findNavPoints(in: child))
        }
        return results
    }
}
