import Foundation

public enum DisplayMapper {
    /// Exact UUID first, then internal display, then closest aspect/size, without reusing a screen until needed.
    public static func map(saved: [DisplayRecord], current: [DisplayRecord]) -> [String: DisplayRecord] {
        guard let fallback = current.first else { return [:] }
        var result: [String: DisplayRecord] = [:], used = Set<String>()
        for d in saved {
            if let exact = current.first(where: { $0.id == d.id }) { result[d.id] = exact; used.insert(exact.id) }
        }
        for d in saved where result[d.id] == nil {
            let candidates = current.filter { !used.contains($0.id) }
            let target = candidates.min { score(d, $0) < score(d, $1) } ?? fallback
            result[d.id] = target; used.insert(target.id)
        }
        return result
    }
    private static func score(_ a: DisplayRecord, _ b: DisplayRecord) -> Double {
        abs(log((a.frame.width / a.frame.height) / (b.frame.width / b.frame.height))) * 4 +
        abs(log(a.frame.width / b.frame.width)) + (a.isBuiltin == b.isBuiltin ? 0 : 3)
    }
    public static func frame(for window: WindowRecord, saved: DisplayRecord, target: DisplayRecord) -> Rect {
        if window.fullscreen { return target.visibleFrame }
        if saved.id == target.id && saved.frame.width == target.frame.width && saved.frame.height == target.frame.height {
            return Rect(x: target.frame.x + window.frame.x - saved.frame.x,
                        y: target.frame.y + window.frame.y - saved.frame.y,
                        width: window.frame.width, height: window.frame.height).clamped(to: target.visibleFrame)
        }
        return window.frame.relative(to: saved.visibleFrame).inBounds(target.visibleFrame).clamped(to: target.visibleFrame)
    }
}
public enum WindowMatcher {
    /// One-to-one assignment. Runtime IDs are trusted only within the same app launch.
    public static func match(saved: [WindowRecord], live: [WindowRecord]) -> [UUID: UUID] {
        var result: [UUID: UUID] = [:], used = Set<UUID>()
        for pass in 0..<4 {
            for s in saved where result[s.id] == nil {
                let candidates = live.filter { l in
                    guard l.appID == s.appID && !used.contains(l.id) else { return false }
                    switch pass {
                    case 0: return s.windowID != 0 && s.windowID == l.windowID && s.processID == l.processID &&
                        s.launchDate != nil && l.launchDate != nil && abs(s.launchDate!.timeIntervalSince(l.launchDate!)) < 0.001
                    case 1: return s.identifier?.isEmpty == false && s.identifier == l.identifier
                    case 2: return !s.title.isEmpty && s.title == l.title
                    default: return s.ordinal == l.ordinal
                    }
                }
                if let l = candidates.min(by: { distance(s.frame, $0.frame) < distance(s.frame, $1.frame) }) {
                    result[s.id] = l.id; used.insert(l.id)
                }
            }
        }
        return result
    }
    private static func distance(_ a: Rect, _ b: Rect) -> Double {
        abs(a.x-b.x) + abs(a.y-b.y) + abs(a.width-b.width) + abs(a.height-b.height)
    }
}
public enum LayoutEditor {
    public static func updateDesktop(in layout: Layout, snapshot: Layout, displayID: String, spaceIndex: Int, preservingAppIDs: Set<String> = []) -> Layout {
        var result = layout
        result.windows.removeAll { $0.displayID == displayID && $0.spaceIndex == spaceIndex && !preservingAppIDs.contains($0.appID) }
        result.windows += snapshot.windows.filter { $0.displayID == displayID && $0.spaceIndex == spaceIndex }
        let appsWithoutWindows = Set(layout.apps.map(\.id)).subtracting(layout.windows.map(\.appID))
        let ids = Set(result.windows.map(\.appID)).union(appsWithoutWindows)
        var apps = Dictionary(uniqueKeysWithValues: layout.apps.map { ($0.id, $0) })
        for app in snapshot.apps { apps[app.id] = app }
        result.apps = apps.values.filter { ids.contains($0.id) }.sorted { $0.name < $1.name }
        if let display = snapshot.displays.first(where: { $0.id == displayID }) {
            if let index = result.displays.firstIndex(where: { $0.id == displayID }) { result.displays[index] = display }
            else { result.displays.append(display) }
        }
        result.updatedAt = Date()
        return result
    }
}
