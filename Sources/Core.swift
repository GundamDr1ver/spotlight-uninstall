import AppKit
import Carbon

func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
    event?.eventID == AEEventID(kAEOpenApplication)
        && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
}

func nameKey(_ name: String) -> String {
    let value = name.precomposedStringWithCanonicalMapping.lowercased()
    return value.hasSuffix(".app") ? String(value.dropLast(4)) : value
}

func allowedApp(_ url: URL, roots: [URL], ownURL: URL? = nil) -> Bool {
    let path = url.standardizedFileURL
    guard path.pathExtension.lowercased() == "app",
          path == path.resolvingSymlinksInPath(), path != ownURL?.standardizedFileURL else { return false }
    return roots.contains { root in
        let prefix = root.standardizedFileURL.path + "/"
        guard path.path.hasPrefix(prefix) else { return false }
        let relative = String(path.path.dropFirst(prefix.count))
        return !relative.split(separator: "/").dropLast().contains { $0.lowercased().hasSuffix(".app") }
    }
}

struct AppCatalog {
    var names: [String: Set<URL>] = [:]
    init(roots: [URL]) {
        let fm = FileManager.default
        for root in roots {
            guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files where url.pathExtension.lowercased() == "app" {
                files.skipDescendants()
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let bundle = Bundle(url: url)
                let labels = [url.lastPathComponent, fm.displayName(atPath: url.path),
                              bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
                              bundle?.localizedInfoDictionary?["CFBundleName"] as? String,
                              bundle?.infoDictionary?["CFBundleDisplayName"] as? String,
                              bundle?.infoDictionary?["CFBundleName"] as? String].compactMap { $0 }
                for label in labels { names[nameKey(label), default: []].insert(url.standardizedFileURL) }
            }
        }
    }
    func resolve(_ name: String) -> URL? {
        guard let matches = names[nameKey(name)], matches.count == 1 else { return nil }
        return matches.first
    }
}

func buttonFrame(row: CGRect, labelEnd: CGFloat, hintStart: CGFloat?, window: CGRect) -> CGRect {
    let width: CGFloat = 62, height: CGFloat = 26
    let right = min(hintStart ?? row.maxX - 12, row.maxX - 12) - 10
    if right - width > labelEnd + 16 && row.height >= height {
        return CGRect(x: right - width, y: row.midY - height / 2, width: width, height: height)
    }
    return CGRect(x: window.maxX - 148, y: window.maxY + 8, width: 148, height: 30)
}
