import Foundation

struct DataviewQuery {
    enum Presentation {
        case list
        case table([Column])
    }

    struct Column {
        var key: String
        var label: String
    }

    var presentation: Presentation
    var sourcePath: String?
    var sourceTag: String?
    var filters: [(key: String, value: String)] = []
    var sortKey = "file.name"
    var sortDescending = false
    var limit: Int?

    init?(_ source: String) {
        let lines = source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }

        if first.uppercased().hasPrefix("LIST") {
            presentation = .list
        } else if first.uppercased().hasPrefix("TABLE") {
            let rawColumns = first.dropFirst("TABLE".count)
            let columns = rawColumns.split(separator: ",").map { raw -> Column in
                let expression = raw.trimmingCharacters(in: .whitespaces)
                if let range = expression.range(
                    of: #"\s+AS\s+"#,
                    options: [.regularExpression, .caseInsensitive]
                ) {
                    let key = expression[..<range.lowerBound]
                        .trimmingCharacters(in: .whitespaces)
                    let label = expression[range.upperBound...]
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                    return Column(key: key, label: label)
                }
                return Column(key: expression, label: expression)
            }
            presentation = .table(columns)
        } else {
            return nil
        }

        for line in lines.dropFirst() {
            if line.uppercased().hasPrefix("FROM ") {
                let source = line.dropFirst("FROM ".count)
                    .trimmingCharacters(in: .whitespaces)
                if source.hasPrefix("#") {
                    sourceTag = String(source.dropFirst())
                } else {
                    sourcePath = source.trimmingCharacters(
                        in: CharacterSet(charactersIn: "\"")
                    )
                }
            } else if line.uppercased().hasPrefix("WHERE ") {
                let expression = line.dropFirst("WHERE ".count)
                filters = String(expression).components(separatedBy: " OR ").compactMap { condition in
                    guard let equals = condition.firstIndex(of: "=") else { return nil }
                    let key = condition[..<equals].trimmingCharacters(in: .whitespaces)
                    let value = condition[condition.index(after: equals)...]
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                    return (key, value)
                }
            } else if line.uppercased().hasPrefix("SORT ") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count >= 2 { sortKey = String(parts[1]) }
                if parts.count >= 3 {
                    sortDescending = parts[2].caseInsensitiveCompare("DESC") == .orderedSame
                }
            } else if line.uppercased().hasPrefix("LIMIT ") {
                limit = Int(line.dropFirst("LIMIT ".count).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    func matches(_ document: IndexedDocument) -> Bool {
        if let sourcePath {
            let normalized = sourcePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard document.relativeFolder == normalized
                || document.relativeFolder.hasPrefix(normalized + "/") else {
                return false
            }
        }
        if let sourceTag,
           !document.analysis.tags.contains(where: {
               $0.caseInsensitiveCompare(sourceTag) == .orderedSame
           }) {
            return false
        }
        if !filters.isEmpty {
            return filters.contains { filter in
                value(for: filter.key, document: document)
                    .caseInsensitiveCompare(filter.value) == .orderedSame
            }
        }
        return true
    }

    func value(for key: String, document: IndexedDocument) -> String {
        switch key.lowercased() {
        case "file.name": return document.title
        case "file.path": return document.relativePath
        case "file.mtime":
            return document.modifiedAt.formatted(
                .dateTime.year().month().day().hour().minute()
            )
        default:
            return document.analysis.properties.first {
                $0.name.caseInsensitiveCompare(key) == .orderedSame
            }?.displayValue ?? ""
        }
    }

    func sortValue(for document: IndexedDocument) -> String {
        if sortKey.caseInsensitiveCompare("file.mtime") == .orderedSame {
            return String(document.modifiedAt.timeIntervalSinceReferenceDate)
                .leftPadding(toLength: 24, withPad: "0")
        }
        return value(for: sortKey, document: document)
    }
}

private extension String {
    func leftPadding(toLength length: Int, withPad pad: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(pad), count: length - count) + self
    }
}
