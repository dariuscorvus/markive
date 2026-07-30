import Foundation

struct WorkspaceSettings: Equatable, Sendable {
    var defaultFolder = ""
    var dailyFolder = ""
    var dailyFormat = "YYYY-MM-DD"
    var dailyTemplate = ""
    var templatesFolder = ""
    var homeNote = ""
    var useWikilinks = true
    var alwaysUpdateLinks = true

    static func load(root: URL, defaults: UserDefaults) -> WorkspaceSettings {
        let prefix = defaultsPrefix(root)
        var settings = compatibleObsidianSettings(root: root)

        if defaults.object(forKey: prefix + ".defaultFolder") != nil {
            settings.defaultFolder = defaults.string(forKey: prefix + ".defaultFolder") ?? ""
        } else if FileManager.default.fileExists(
            atPath: root.appendingPathComponent("10--inbox", isDirectory: true).path
        ) {
            settings.defaultFolder = "10--inbox"
        }
        if defaults.object(forKey: prefix + ".dailyFolder") != nil {
            settings.dailyFolder = defaults.string(forKey: prefix + ".dailyFolder") ?? ""
        }
        if defaults.object(forKey: prefix + ".dailyFormat") != nil {
            settings.dailyFormat = defaults.string(forKey: prefix + ".dailyFormat") ?? "YYYY-MM-DD"
        }
        if defaults.object(forKey: prefix + ".dailyTemplate") != nil {
            settings.dailyTemplate = defaults.string(forKey: prefix + ".dailyTemplate") ?? ""
        }
        if defaults.object(forKey: prefix + ".templatesFolder") != nil {
            settings.templatesFolder = defaults.string(forKey: prefix + ".templatesFolder") ?? ""
        }
        if defaults.object(forKey: prefix + ".homeNote") != nil {
            settings.homeNote = defaults.string(forKey: prefix + ".homeNote") ?? ""
        } else {
            for candidate in ["00--home.md", "Home.md", "home.md"] where
                FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
                settings.homeNote = candidate
                break
            }
        }
        if defaults.object(forKey: prefix + ".useWikilinks") != nil {
            settings.useWikilinks = defaults.bool(forKey: prefix + ".useWikilinks")
        }
        if defaults.object(forKey: prefix + ".alwaysUpdateLinks") != nil {
            settings.alwaysUpdateLinks = defaults.bool(forKey: prefix + ".alwaysUpdateLinks")
        }
        return settings
    }

    func save(root: URL, defaults: UserDefaults) {
        let prefix = Self.defaultsPrefix(root)
        defaults.set(defaultFolder, forKey: prefix + ".defaultFolder")
        defaults.set(dailyFolder, forKey: prefix + ".dailyFolder")
        defaults.set(dailyFormat, forKey: prefix + ".dailyFormat")
        defaults.set(dailyTemplate, forKey: prefix + ".dailyTemplate")
        defaults.set(templatesFolder, forKey: prefix + ".templatesFolder")
        defaults.set(homeNote, forKey: prefix + ".homeNote")
        defaults.set(useWikilinks, forKey: prefix + ".useWikilinks")
        defaults.set(alwaysUpdateLinks, forKey: prefix + ".alwaysUpdateLinks")
    }

    func dailyRelativePath(on date: Date, calendar: Calendar = .current) -> String {
        let filename = Self.expandDateFormat(dailyFormat, date: date, calendar: calendar)
        return [dailyFolder, filename + ".md"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    static func expandTemplate(
        _ template: String,
        title: String,
        date: Date,
        calendar: Calendar = .current
    ) -> String {
        var output = template.replacingOccurrences(of: "{{title}}", with: title)
        output = replaceVariables(named: "date", in: output) { format in
            expandDateFormat(format ?? "YYYY-MM-DD", date: date, calendar: calendar)
        }
        output = replaceVariables(named: "time", in: output) { format in
            expandDateFormat(format ?? "HH:mm", date: date, calendar: calendar)
        }
        return output
    }

    private static func compatibleObsidianSettings(root: URL) -> WorkspaceSettings {
        var settings = WorkspaceSettings()
        let obsidian = root.appendingPathComponent(".obsidian", isDirectory: true)

        if let daily: [String: Any] = json(at: obsidian.appendingPathComponent("daily-notes.json")) {
            settings.dailyFolder = daily["folder"] as? String ?? ""
            settings.dailyFormat = daily["format"] as? String ?? "YYYY-MM-DD"
            settings.dailyTemplate = daily["template"] as? String ?? ""
        }
        if let templates: [String: Any] = json(at: obsidian.appendingPathComponent("templates.json")) {
            settings.templatesFolder = templates["folder"] as? String ?? ""
        }
        if let app: [String: Any] = json(at: obsidian.appendingPathComponent("app.json")) {
            settings.alwaysUpdateLinks = app["alwaysUpdateLinks"] as? Bool ?? true
            settings.useWikilinks = !(app["useMarkdownLinks"] as? Bool ?? false)
        }
        return settings
    }

    private static func json<T>(at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? T
    }

    private static func defaultsPrefix(_ root: URL) -> String {
        "workspaceSettings:\(root.canonicalPath)"
    }

    private static func expandDateFormat(
        _ format: String,
        date: Date,
        calendar: Calendar
    ) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.locale = .current
        monthFormatter.dateFormat = "MMMM"

        let replacements: [(String, String)] = [
            ("YYYY", String(format: "%04d", components.year ?? 0)),
            ("MMMM", monthFormatter.string(from: date)),
            ("MM", String(format: "%02d", components.month ?? 0)),
            ("DD", String(format: "%02d", components.day ?? 0)),
            ("HH", String(format: "%02d", components.hour ?? 0)),
            ("mm", String(format: "%02d", components.minute ?? 0)),
            ("ss", String(format: "%02d", components.second ?? 0)),
        ]
        return replacements.reduce(format) { result, replacement in
            result.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
    }

    private static func replaceVariables(
        named name: String,
        in input: String,
        replacement: (String?) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\{\{"# + name + #"(?::([^}]+))?\}\}"#
        ) else { return input }
        var output = input
        for match in regex.matches(
            in: input,
            range: NSRange(location: 0, length: (input as NSString).length)
        ).reversed() {
            let format = match.range(at: 1).location == NSNotFound
                ? nil
                : (input as NSString).substring(with: match.range(at: 1))
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: replacement(format))
        }
        return output
    }
}
