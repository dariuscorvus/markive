import Foundation

struct DocumentAnalysis: Codable, Equatable, Sendable {
    var headings: [IndexedHeading]
    var links: [IndexedLink]
    var properties: [IndexedProperty]
    var aliases: [String]
    var tags: [String]
    var tasks: [IndexedTask]
    var frontmatterError: String?
}

struct IndexedHeading: Codable, Equatable, Sendable {
    var level: UInt8
    var text: String
    var slug: String
    var line: Int
}

struct IndexedLink: Codable, Equatable, Sendable {
    var kind: IndexedLinkKind
    var target: String
    var heading: String?
    var display: String
    var line: Int
    var column: Int
    var utf16Location: Int
    var utf16Length: Int
}

enum IndexedLinkKind: String, Codable, Sendable {
    case markdown
    case wikilink
    case embed
}

struct IndexedProperty: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var kind: IndexedPropertyKind
    var displayValue: String
    var values: [String]
}

enum IndexedPropertyKind: String, Codable, Sendable {
    case text
    case list
    case number
    case checkbox
    case date
    case object
    case empty
}

struct IndexedTask: Codable, Equatable, Sendable {
    var text: String
    var completed: Bool
    var line: Int
}

struct IndexedDocument: Identifiable, Equatable, Sendable {
    var id: FileID
    var diskID: FileID
    var relativePath: String
    var title: String
    var modifiedAt: Date
    var content: String
    var analysis: DocumentAnalysis

    var relativeFolder: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    var displayNames: [String] {
        [title] + analysis.aliases
    }
}

struct SearchResult: Identifiable, Equatable, Sendable {
    var id: String
    var documentID: FileID
    var relativePath: String
    var title: String
    var line: Int
    var lineText: String
    var contextBefore: String? = nil
    var contextAfter: String? = nil
    var utf16Location: Int
    var utf16Length: Int
}

struct Backlink: Identifiable, Equatable, Sendable {
    var id: String
    var sourceDocumentID: FileID
    var sourcePath: String
    var sourceTitle: String
    var line: Int
    var context: String
    var utf16Location: Int
    var utf16Length: Int
}

enum LinkResolution: Equatable, Sendable {
    case external
    case resolved(IndexedDocument)
    case ambiguous([IndexedDocument])
    case broken
}

/// Disposable, in-memory knowledge derived from Markdown files. Files remain
/// the source of truth; every value here can be rebuilt without writing into
/// the workspace or `.obsidian`.
struct KnowledgeIndex: Equatable, Sendable {
    var documentsByPath: [String: IndexedDocument] = [:]

    static let empty = KnowledgeIndex()

    var documents: [IndexedDocument] {
        Array(documentsByPath.values)
    }

    var allTags: [String] {
        Array(Set(documents.flatMap(\.analysis.tags)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func build(
        documents: [DocumentItem],
        reusing previous: KnowledgeIndex = .empty
    ) -> KnowledgeIndex {
        var entries = [String: IndexedDocument](minimumCapacity: documents.count)

        for item in documents {
            if let prior = previous.documentsByPath[item.relativePath],
               prior.diskID == item.diskID,
               prior.modifiedAt == item.modifiedAt {
                entries[item.relativePath] = prior
                continue
            }
            guard let content = try? String(contentsOf: item.url, encoding: .utf8),
                  let analysis = MarkiveCore.analyzeDocument(markdown: content) else {
                continue
            }
            entries[item.relativePath] = IndexedDocument(
                id: item.id,
                diskID: item.diskID,
                relativePath: item.relativePath,
                title: item.title,
                modifiedAt: item.modifiedAt,
                content: content,
                analysis: analysis
            )
        }

        return KnowledgeIndex(documentsByPath: entries)
    }

    func document(id: FileID) -> IndexedDocument? {
        documentsByPath.values.first { $0.id == id }
    }

    func completions(matching query: String, limit: Int = 50) -> [IndexedDocument] {
        let needle = normalized(query)
        return documents
            .map { document in
                (document, completionScore(document: document, needle: needle))
            }
            .filter { $0.1 < Int.max }
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    func linkCompletions(matching query: String, limit: Int = 50) -> [String] {
        let parts = query.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let documentQuery = String(parts.first ?? "")
        let headingQuery = parts.count > 1 ? String(parts[1]) : nil
        let matchedDocuments = completions(matching: documentQuery, limit: limit)
        let duplicateTitles = Dictionary(grouping: matchedDocuments, by: {
            $0.title.folding(options: .caseInsensitive, locale: .current)
        })

        if let headingQuery {
            return matchedDocuments.flatMap { document in
                let target = duplicateTitles[
                    document.title.folding(options: .caseInsensitive, locale: .current)
                ]?.count ?? 0 > 1
                    ? removeMarkdownExtension(document.relativePath)
                    : document.title
                return document.analysis.headings
                    .filter {
                        headingQuery.isEmpty
                            || $0.text.localizedCaseInsensitiveContains(headingQuery)
                    }
                    .map { "\(target)#\($0.text)]]" }
            }
            .prefix(limit)
            .map { $0 }
        }

        return matchedDocuments.map { document in
            let key = document.title.folding(options: .caseInsensitive, locale: .current)
            let target = duplicateTitles[key]?.count ?? 0 > 1
                ? removeMarkdownExtension(document.relativePath)
                : document.title
            return "\(target)]]"
        }
    }

    func resolve(_ link: IndexedLink, from sourcePath: String) -> LinkResolution {
        let rawTarget = link.target.removingPercentEncoding ?? link.target
        if rawTarget.isEmpty, link.heading != nil {
            guard let current = documentsByPath[sourcePath] else { return .broken }
            return headingExists(link.heading, in: current) ? .resolved(current) : .broken
        }
        if hasURLScheme(rawTarget) || rawTarget.hasPrefix("#") {
            return .external
        }

        let targetWithoutExtension = removeMarkdownExtension(rawTarget)
        let sourceFolder = sourcePath.split(separator: "/").dropLast().joined(separator: "/")
        var candidates = [IndexedDocument]()

        if rawTarget.contains("/") || rawTarget.hasPrefix(".") {
            let joined = normalizedRelativePath(
                sourceFolder.isEmpty ? rawTarget : "\(sourceFolder)/\(rawTarget)"
            )
            let rootRelative = normalizedRelativePath(rawTarget)
            candidates = documents.filter {
                removeMarkdownExtension($0.relativePath).caseInsensitiveEquals(
                    removeMarkdownExtension(joined)
                )
                    || removeMarkdownExtension($0.relativePath).caseInsensitiveEquals(
                        removeMarkdownExtension(rootRelative)
                    )
            }
        } else {
            candidates = documents.filter { document in
                removeMarkdownExtension(document.title).caseInsensitiveEquals(targetWithoutExtension)
                    || document.analysis.aliases.contains {
                        removeMarkdownExtension($0).caseInsensitiveEquals(targetWithoutExtension)
                    }
            }
        }

        if let heading = link.heading {
            candidates = candidates.filter { headingExists(heading, in: $0) }
        }
        switch candidates.count {
        case 0: return .broken
        case 1: return .resolved(candidates[0])
        default: return .ambiguous(candidates.sorted { $0.relativePath < $1.relativePath })
        }
    }

    func backlinks(to targetPath: String) -> [Backlink] {
        var output: [Backlink] = []
        for source in documents {
            for link in source.analysis.links {
                guard case .resolved(let target) = resolve(link, from: source.relativePath),
                      target.relativePath == targetPath else { continue }
                output.append(Backlink(
                    id: "\(source.relativePath):\(link.utf16Location)",
                    sourceDocumentID: source.id,
                    sourcePath: source.relativePath,
                    sourceTitle: source.title,
                    line: link.line,
                    context: lineText(in: source.content, line: link.line),
                    utf16Location: link.utf16Location,
                    utf16Length: link.utf16Length
                ))
            }
        }
        return output.sorted {
            if $0.sourceTitle != $1.sourceTitle {
                return $0.sourceTitle.localizedStandardCompare($1.sourceTitle) == .orderedAscending
            }
            return $0.line < $1.line
        }
    }

    func rewritingInboundLinks(from oldPath: String, to newPath: String) -> [String: String] {
        rewritingInboundLinks(moving: [oldPath: newPath])
    }

    /// Rewrites links for a file or folder move as one operation. A source may
    /// itself be moving, so Markdown links are made relative to its new folder.
    func rewritingInboundLinks(moving paths: [String: String]) -> [String: String] {
        var rewritten: [String: String] = [:]

        for source in documents {
            let sourceIsMoving = paths[source.relativePath] != nil
            let inbound = source.analysis.links.compactMap { link -> (IndexedLink, String)? in
                guard case .resolved(let target) = resolve(link, from: source.relativePath) else {
                    return nil
                }
                let targetIsMoving = paths[target.relativePath] != nil
                guard sourceIsMoving || targetIsMoving else { return nil }
                let newPath = paths[target.relativePath] ?? target.relativePath
                return (link, newPath)
            }
            guard !inbound.isEmpty else { continue }

            var content = source.content
            let sourcePath = paths[source.relativePath] ?? source.relativePath
            let sourceFolder = sourcePath.lastIndex(of: "/").map {
                String(sourcePath[..<$0])
            } ?? ""
            for (link, newPath) in inbound.sorted(by: {
                $0.0.utf16Location > $1.0.utf16Location
            }) {
                let range = NSRange(location: link.utf16Location, length: link.utf16Length)
                guard let swiftRange = Range(range, in: content) else { continue }
                let heading = link.heading.map { "#\($0)" } ?? ""
                let newTitle = URL(fileURLWithPath: newPath)
                    .deletingPathExtension().lastPathComponent
                let replacement: String
                switch link.kind {
                case .wikilink, .embed:
                    let target = link.target.contains("/")
                        ? removeMarkdownExtension(newPath)
                        : newTitle
                    let originalDefault = link.heading ?? link.target
                    let alias = link.display.caseInsensitiveEquals(originalDefault)
                        ? ""
                        : "|\(link.display)"
                    let prefix = link.kind == .embed ? "!" : ""
                    replacement = "\(prefix)[[\(target)\(heading)\(alias)]]"
                case .markdown:
                    let relative = relativeLinkPath(
                        from: sourceFolder,
                        to: newPath
                    )
                    replacement = "[\(escapedMarkdownLabel(link.display))](\(percentEncodedPath(relative))\(heading))"
                }
                content.replaceSubrange(swiftRange, with: replacement)
            }
            if content != source.content {
                rewritten[source.relativePath] = content
            }
        }
        return rewritten
    }

    func search(
        _ rawQuery: String,
        caseSensitive: Bool = false,
        excludedPaths: [String] = []
    ) -> [SearchResult] {
        let query = ParsedSearchQuery(rawQuery)
        let exclusions = excludedPaths.filter { !$0.isEmpty }
        var output: [SearchResult] = []

        for document in documents.sorted(by: { $0.relativePath < $1.relativePath }) {
            guard !exclusions.contains(where: {
                document.relativePath.localizedCaseInsensitiveContains($0)
            }),
            query.matchesMetadata(document) else { continue }

            if query.terms.isEmpty {
                output.append(result(for: document, line: 1, match: nil))
                continue
            }

            var lines: [String] = []
            document.content.enumerateLines { line, _ in lines.append(line) }
            let nsContent = document.content as NSString
            var utf16LineStart = 0
            var index = 0
            while utf16LineStart < nsContent.length {
                let fullRange = nsContent.lineRange(
                    for: NSRange(location: utf16LineStart, length: 0)
                )
                var contentLength = fullRange.length
                while contentLength > 0 {
                    let character = nsContent.character(
                        at: fullRange.location + contentLength - 1
                    )
                    if character == 10 || character == 13 {
                        contentLength -= 1
                    } else {
                        break
                    }
                }
                let line = nsContent.substring(
                    with: NSRange(location: fullRange.location, length: contentLength)
                )
                let haystack = caseSensitive ? line : line.lowercased()
                let terms = caseSensitive ? query.terms : query.terms.map { $0.lowercased() }
                guard terms.allSatisfy({ haystack.contains($0) }) else {
                    utf16LineStart = NSMaxRange(fullRange)
                    index += 1
                    continue
                }
                let firstTerm = terms.first ?? ""
                let matchRange = haystack.range(of: firstTerm)
                let locationInLine = matchRange.map {
                    haystack[..<$0.lowerBound].utf16.count
                } ?? 0
                output.append(result(
                    for: document,
                    line: index + 1,
                    match: (
                        lines: lines,
                        index: index,
                        location: fullRange.location + locationInLine,
                        length: firstTerm.utf16.count
                    )
                ))
                utf16LineStart = NSMaxRange(fullRange)
                index += 1
            }
        }
        return output
    }

    /// Rewrites only wikilinks for preview rendering. The editor keeps the
    /// source byte-for-byte. Resolved links become portable Markdown links;
    /// ambiguous and broken targets stay visibly marked.
    func renderableMarkdown(_ markdown: String, sourcePath: String) -> String {
        guard let source = documentsByPath[sourcePath] else { return markdown }
        var output = markdown
        for link in source.analysis.links
            .filter({ $0.kind == .wikilink })
            .sorted(by: { $0.utf16Location > $1.utf16Location }) {
            let range = NSRange(location: link.utf16Location, length: link.utf16Length)
            guard let swiftRange = Range(range, in: output) else { continue }
            let replacement: String
            switch resolve(link, from: sourcePath) {
            case .resolved(let target):
                let relative = relativeLinkPath(from: source.relativeFolder, to: target.relativePath)
                let anchor = link.heading.map { "#\(slugify($0))" } ?? ""
                replacement = "[\(escapedMarkdownLabel(link.display))](\(percentEncodedPath(relative))\(anchor))"
            case .ambiguous:
                replacement = "<span class=\"ambiguous-link\">\(escapeHTML(String(output[swiftRange])))</span>"
            case .broken:
                let target = link.target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? link.target
                replacement = "[\(escapedMarkdownLabel(link.display))](markive-create://note/\(target))"
            case .external:
                continue
            }
            output.replaceSubrange(swiftRange, with: replacement)
        }
        return expandDataview(
            in: strippingLeadingFrontmatter(from: output),
            sourcePath: sourcePath
        )
    }

    private func strippingLeadingFrontmatter(from markdown: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?s)\A---[ \t]*\r?\n.*?\r?\n---[ \t]*(?:\r?\n|$)"#
        ) else { return markdown }
        let range = NSRange(location: 0, length: (markdown as NSString).length)
        guard let match = regex.firstMatch(in: markdown, range: range),
              let swiftRange = Range(match.range, in: markdown) else {
            return markdown
        }
        var output = markdown
        output.removeSubrange(swiftRange)
        return output
    }

    private func expandDataview(in markdown: String, sourcePath: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?ms)^```dataview[ \t]*\n(.*?)^```[ \t]*$"#
        ) else { return markdown }
        var output = markdown
        let matches = regex.matches(
            in: markdown,
            range: NSRange(location: 0, length: (markdown as NSString).length)
        )
        for match in matches.reversed() {
            let queryText = (markdown as NSString).substring(with: match.range(at: 1))
            guard let query = DataviewQuery(queryText),
                  let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(
                range,
                with: render(query: query, sourcePath: sourcePath)
            )
        }
        return output
    }

    private func render(query: DataviewQuery, sourcePath: String) -> String {
        var matches = documents.filter { query.matches($0) }
        matches.sort { lhs, rhs in
            let left = query.sortValue(for: lhs)
            let right = query.sortValue(for: rhs)
            let comparison = left.localizedStandardCompare(right)
            return query.sortDescending
                ? comparison == .orderedDescending
                : comparison == .orderedAscending
        }
        if let limit = query.limit {
            matches = Array(matches.prefix(limit))
        }

        switch query.presentation {
        case .list:
            return matches.map { document in
                let path = relativeLinkPath(
                    from: documentsByPath[sourcePath]?.relativeFolder ?? "",
                    to: document.relativePath
                )
                return "- [\(escapedMarkdownLabel(document.title))](\(percentEncodedPath(path)))"
            }.joined(separator: "\n")
        case .table(let columns):
            let headers = ["Note"] + columns.map(\.label)
            var rows = [
                "| " + headers.joined(separator: " | ") + " |",
                "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |",
            ]
            for document in matches {
                let path = relativeLinkPath(
                    from: documentsByPath[sourcePath]?.relativeFolder ?? "",
                    to: document.relativePath
                )
                let values = columns.map { column in
                    query.value(for: column.key, document: document)
                        .replacingOccurrences(of: "|", with: #"\\|"#)
                        .replacingOccurrences(of: "\n", with: " ")
                }
                rows.append(
                    "| [\(escapedMarkdownLabel(document.title))](\(percentEncodedPath(path))) | "
                        + values.joined(separator: " | ") + " |"
                )
            }
            return rows.joined(separator: "\n")
        }
    }

    private func completionScore(document: IndexedDocument, needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var best = Int.max
        for candidate in document.displayNames + [document.relativePath] {
            let value = normalized(candidate)
            if value == needle { best = min(best, 0) }
            else if value.hasPrefix(needle) { best = min(best, 10 + value.count - needle.count) }
            else if value.contains(needle) { best = min(best, 100 + value.count - needle.count) }
            else if isSubsequence(needle, of: value) { best = min(best, 1_000 + value.count) }
        }
        return best
    }

    private func headingExists(_ heading: String?, in document: IndexedDocument) -> Bool {
        guard let heading else { return true }
        let slug = slugify(heading)
        return document.analysis.headings.contains {
            $0.slug.caseInsensitiveEquals(slug) || $0.text.caseInsensitiveEquals(heading)
        }
    }

    private func result(
        for document: IndexedDocument,
        line: Int,
        match: (lines: [String], index: Int, location: Int, length: Int)?
    ) -> SearchResult {
        let lineText = match?.lines[match!.index] ?? document.title
        return SearchResult(
            id: "\(document.relativePath):\(line):\(match?.location ?? 0)",
            documentID: document.id,
            relativePath: document.relativePath,
            title: document.title,
            line: line,
            lineText: lineText.trimmingCharacters(in: .whitespaces),
            contextBefore: match.flatMap { $0.index > 0 ? $0.lines[$0.index - 1] : nil },
            contextAfter: match.flatMap { $0.index + 1 < $0.lines.count ? $0.lines[$0.index + 1] : nil },
            utf16Location: match?.location ?? 0,
            utf16Length: match?.length ?? 0
        )
    }
}

private struct ParsedSearchQuery {
    var terms: [String] = []
    var tag: String?
    var property: (name: String, value: String)?
    var path: String?

    init(_ raw: String) {
        var remaining = raw

        if let match = remaining.firstMatch(of: /(?:^|\s)tag:#?([^\s]+)/) {
            tag = String(match.1)
            remaining.replaceSubrange(match.range, with: " ")
        }
        if let match = remaining.firstMatch(of: /\[([^:\]]+):([^\]]+)\]/) {
            property = (String(match.1), String(match.2))
            remaining.replaceSubrange(match.range, with: " ")
        }
        if let match = remaining.firstMatch(of: /(?:^|\s)path:"([^"]+)"/) {
            path = String(match.1)
            remaining.replaceSubrange(match.range, with: " ")
        } else if let match = remaining.firstMatch(of: /(?:^|\s)path:([^\s]+)/) {
            path = String(match.1)
            remaining.replaceSubrange(match.range, with: " ")
        }

        let phraseRegex = try? NSRegularExpression(pattern: #""([^"]+)""#)
        let nsRemaining = remaining as NSString
        var consumed = IndexSet()
        phraseRegex?.enumerateMatches(
            in: remaining,
            range: NSRange(location: 0, length: nsRemaining.length)
        ) { match, _, _ in
            guard let match else { return }
            terms.append(nsRemaining.substring(with: match.range(at: 1)))
            consumed.insert(integersIn: match.range.location..<(match.range.location + match.range.length))
        }
        let rest = (0..<nsRemaining.length)
            .filter { !consumed.contains($0) }
            .map { nsRemaining.substring(with: NSRange(location: $0, length: 1)) }
            .joined()
        terms += rest.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    func matchesMetadata(_ document: IndexedDocument) -> Bool {
        if let tag, !document.analysis.tags.contains(where: { $0.caseInsensitiveEquals(tag) }) {
            return false
        }
        if let property {
            guard let found = document.analysis.properties.first(where: {
                $0.name.caseInsensitiveEquals(property.name)
            }),
            found.values.contains(where: {
                $0.localizedCaseInsensitiveContains(property.value)
            }) else { return false }
        }
        if let path, !document.relativePath.localizedCaseInsensitiveContains(path) {
            return false
        }
        return true
    }
}

private func normalized(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .replacingOccurrences(of: " ", with: "")
}

private func removeMarkdownExtension(_ value: String) -> String {
    let lower = value.lowercased()
    for ext in [".markdown", ".mdown", ".mkd", ".md"] where lower.hasSuffix(ext) {
        return String(value.dropLast(ext.count))
    }
    return value
}

private func normalizedRelativePath(_ path: String) -> String {
    var components: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
        switch component {
        case ".": continue
        case "..": if !components.isEmpty { components.removeLast() }
        default: components.append(component)
        }
    }
    return components.joined(separator: "/")
}

private func relativeLinkPath(from sourceFolder: String, to targetPath: String) -> String {
    let source = sourceFolder.split(separator: "/")
    let target = targetPath.split(separator: "/")
    var shared = 0
    while shared < source.count, shared < target.count, source[shared] == target[shared] {
        shared += 1
    }
    let parents = Array(repeating: "..", count: source.count - shared)
    let remainder = Array(target[shared...]).map(String.init)
    return (parents + remainder).joined(separator: "/")
}

private func percentEncodedPath(_ path: String) -> String {
    path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
}

private func hasURLScheme(_ value: String) -> Bool {
    guard let colon = value.firstIndex(of: ":") else { return false }
    let scheme = value[..<colon]
    guard let first = scheme.first, first.isLetter else { return false }
    return scheme.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
}

private func slugify(_ value: String) -> String {
    value.lowercased().compactMap { character in
        if character.isLetter || character.isNumber { return String(character) }
        if character == " " || character == "-" { return "-" }
        return nil
    }.joined()
}

private func lineText(in content: String, line: Int) -> String {
    let lines = content.components(separatedBy: .newlines)
    guard lines.indices.contains(line - 1) else { return "" }
    return lines[line - 1].trimmingCharacters(in: .whitespaces)
}

private func escapedMarkdownLabel(_ value: String) -> String {
    value.replacingOccurrences(of: "]", with: #"\\]"#)
}

private func escapeHTML(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func isSubsequence(_ needle: String, of haystack: String) -> Bool {
    var iterator = haystack.makeIterator()
    for character in needle {
        var found = false
        while let candidate = iterator.next() {
            if candidate == character {
                found = true
                break
            }
        }
        if !found { return false }
    }
    return true
}

private extension String {
    func caseInsensitiveEquals(_ other: String) -> Bool {
        compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
