// appshot-helper: listens for both Command keys held together anywhere on the
// Mac, then captures the frontmost window (screenshot + accessibility text)
// into <root>/captures/<id>/ and prints one JSON line per event on stdout.
//
// One helper per machine: it holds an flock on <root>/helper.lock and exits
// with code 3 when another helper already holds it.
//
// Windows of a --skip-bundle app (Claude itself) are never captured: pressed
// over one, the hotkey takes the window right behind it instead.
//
// Text comes from accessibility alone, as Codex's Appshots take it: an app
// that exposes little (Telegram, games, canvas apps) sends its title and the
// screenshot, and nothing is read from the pixels.
//
// --paste <png> --expect-bundle <id> [--find-text <token>] pastes the
// screenshot into that app once it is frontmost: the text box holding the
// token (or labelled "Prompt") is given the focus first, then ⌘V, then the
// clipboard is put back as it was.
//
// Usage: appshot-helper --root ~/.claude/appshots [--skip-bundle <id>]... [--capture-now [--after-pid <pid>]]
//        appshot-helper --paste <png> --expect-bundle <id>

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Output

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
}

// MARK: - Arguments

var root = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/appshots")
var captureNow = false
var pastePath: String?
var pasteToken: String?
// Debug: --text <pid> times the accessibility walk; --status prints the
// permissions this binary holds.
var debugTextPid: pid_t?
var debugStatus = false
var expectBundle: String?
// The last regular app activated that is not Claude's own: where ⌘⌘ pressed
// inside Claude points. --after-pid seeds it, for testing.
var lastOtherPid: pid_t?
var skipBundles = Set<String>()
do {
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--root": if let value = args.next() { root = (value as NSString).expandingTildeInPath }
        case "--capture-now": captureNow = true
        case "--paste": pastePath = args.next()
        case "--find-text": pasteToken = args.next()
        case "--text": debugTextPid = args.next().flatMap { pid_t($0) }
        case "--status": debugStatus = true
        case "--expect-bundle": expectBundle = args.next()
        case "--skip-bundle": if let value = args.next() { skipBundles.insert(value) }
        case "--after-pid": if let value = args.next().flatMap({ pid_t($0) }) { lastOtherPid = value }
        default: break
        }
    }
}
let capturesDir = (root as NSString).appendingPathComponent("captures")
try? FileManager.default.createDirectory(atPath: capturesDir, withIntermediateDirectories: true)

// MARK: - Single instance

let isDebug = debugTextPid != nil || debugStatus
if !captureNow && pastePath == nil && !isDebug {
    let lockPath = (root as NSString).appendingPathComponent("helper.lock")
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    if fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0 {
        emit(["event": "busy"])
        exit(3)
    }
    // fd stays open for the life of the process; the lock goes with it.
}

// MARK: - Accessibility text

// The window's accessibility tree as Codex's Appshots print it: one line per
// element, indented by depth, "role title, Description: …, Value: …, ID: …".
// Safari hands the whole page over as its web area's Value, formatted, so the
// page is never walked node by node; an element whose Value holds its content
// (a web area, a text field) stands for its children.

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func stringAttr(_ element: AXUIElement, _ name: String) -> String? {
    guard let s = attr(element, name) as? String else { return nil }
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

// A value as text: strings, numbers, booleans, URLs and attributed strings;
// nothing for geometry and the other opaque kinds.
func appshotText(of value: AnyObject?) -> String? {
    guard let value else { return nil }
    if CFGetTypeID(value) == CFBooleanGetTypeID() { return (value as! Bool) ? "true" : "false" }
    let text: String?
    switch value {
    case let s as String: text = s
    case let n as NSNumber: text = n.stringValue
    case let u as URL: text = u.absoluteString
    case let a as NSAttributedString: text = a.string
    default: text = nil
    }
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
}

struct Described {
    let line: String
    let role: String
    let hasValue: Bool
    let url: String?
}

func describe(_ element: AXUIElement) -> Described {
    let role = stringAttr(element, "AXRole") ?? ""
    var line = stringAttr(element, "AXRoleDescription")
        ?? role.replacingOccurrences(of: "AX", with: "").lowercased()
    var isSettable: DarwinBoolean = false
    if AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &isSettable) == .success, isSettable.boolValue {
        line += " (settable)"
    }
    let title = stringAttr(element, "AXTitle")
    if let title { line += " \(title)" }

    var extras: [String] = []
    if let d = stringAttr(element, "AXDescription") { extras.append("Description: \(d)") }
    if let h = stringAttr(element, "AXHelp") { extras.append("Help: \(h)") }
    let url = appshotText(of: attr(element, "AXURL"))
    if let url { extras.append("URL: \(url)") }
    let value = appshotText(of: attr(element, "AXValue"))
    if let value { extras.append("Value: \(value)") }
    if let id = stringAttr(element, "AXIdentifier") { extras.append("ID: \(id)") }
    if !extras.isEmpty { line += (title == nil ? " " : ", ") + extras.joined(separator: ", ") }
    return Described(line: line, role: role, hasValue: value != nil, url: url)
}

// Elements whose Value is their whole content: their children add nothing.
let valueHoldsContent: Set<String> = ["AXWebArea", "AXTextArea", "AXTextField", "AXStaticText", "AXComboBox", "AXSearchField"]

func frame(of element: AXUIElement) -> CGRect? {
    var rect = CGRect.zero
    if let value = attr(element, "AXFrame"), CFGetTypeID(value) == AXValueGetTypeID(),
       AXValueGetValue(value as! AXValue, .cgRect, &rect) { return rect }
    // Web elements answer position and size separately.
    var origin = CGPoint.zero, size = CGSize.zero
    guard let p = attr(element, "AXPosition"), CFGetTypeID(p) == AXValueGetTypeID(), AXValueGetValue(p as! AXValue, .cgPoint, &origin),
          let z = attr(element, "AXSize"), CFGetTypeID(z) == AXValueGetTypeID(), AXValueGetValue(z as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
}

func shortURL(_ url: String?) -> String {
    guard let url else { return "" }
    return url.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
}

// Controls rendered inline as "[role: label]".
let inlineControls: Set<String> = [
    "AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXToggle",
    "AXComboBox", "AXTextField", "AXTextArea", "AXSearchField", "AXSlider", "AXTab", "AXMenuItem",
    "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXProgressIndicator",
]

// A web page as flowing text, the way Codex's Appshots show it: static text
// inline, links as [text](url), controls as [role: label], headings bold,
// table cells tab-separated, and a line break wherever the next element sits
// below the previous one on screen (the page's own layout, not the DOM).
struct WebRender {
    var out = ""
    var nodes = 0
    var lastFrame: CGRect?
    var isInline = false
    var hitLimit = false
    let deadline: Date
    let maxChars: Int

    init(deadline: Date, maxChars: Int) {
        self.deadline = deadline
        self.maxChars = maxChars
    }

    mutating func breakLine() {
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
    }

    mutating func put(_ text: String, at element: AXUIElement?) {
        if let element, let rect = frame(of: element) {
            // Laid out with no size: hidden (GitHub's permalink anchors, skip links).
            if rect.width < 1 || rect.height < 1 { return }
            if !isInline {
                if let last = lastFrame, rect.minY >= last.maxY - 2 || rect.maxY <= last.minY + 2 { breakLine() }
                lastFrame = rect
            }
        }
        out += text
        if out.count > maxChars { hitLimit = true }
    }

    mutating func renderChildren(of element: AXUIElement) {
        guard let children = attr(element, "AXChildren") as? [AXUIElement] else { return }
        for child in children where !hitLimit { render(child) }
    }

    mutating func render(_ element: AXUIElement) {
        nodes += 1
        if hitLimit || nodes > 60_000 { hitLimit = true; return }
        if Date() > deadline { hitLimit = true; return }
        AXUIElementSetMessagingTimeout(element, 0.2)
        let role = stringAttr(element, "AXRole") ?? ""
        let roleDescription = stringAttr(element, "AXRoleDescription") ?? role.replacingOccurrences(of: "AX", with: "").lowercased()
        let label = { stringAttr(element, "AXTitle") ?? stringAttr(element, "AXDescription") }

        switch role {
        case "AXStaticText":
            // Untrimmed: the spaces around a link are this text's own.
            if let value = attr(element, "AXValue") as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                put(value.replacingOccurrences(of: "\u{A0}", with: " "), at: element)
            }
        case "AXImage":
            if let name = stringAttr(element, "AXDescription") ?? stringAttr(element, "AXTitle") { put("[image: \(name)]", at: element) }
        case "AXLink":
            var inner = WebRender(deadline: deadline, maxChars: 4000)
            inner.isInline = true
            inner.renderChildren(of: element)
            let text = inner.out.trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing of its own to show: a decorative anchor (a heading's permalink icon).
            if text.isEmpty { return }
            put("[\(text)](\(shortURL(self.text(ofURL: element))))", at: element)
        case "AXHeading":
            breakLine()
            put("**", at: element)
            let wasInline = isInline
            isInline = true
            renderChildren(of: element)
            isInline = wasInline
            out += "**"
            breakLine()
        case "AXRow":
            breakLine()
            let wasInline = isInline
            isInline = true
            if let cells = attr(element, "AXChildren") as? [AXUIElement] {
                for (index, cell) in cells.enumerated() where !hitLimit {
                    if index > 0 { out += "\t" }
                    render(cell)
                }
            }
            isInline = wasInline
            lastFrame = frame(of: element)
            breakLine()
        case "AXTable":
            // Rows only: WebKit also lists each column and the header group,
            // which would print every cell three times.
            if let children = attr(element, "AXChildren") as? [AXUIElement] {
                for child in children where !hitLimit {
                    let childRole = stringAttr(child, "AXRole") ?? ""
                    if childRole != "AXColumn" && childRole != "AXGroup" { render(child) }
                }
            }
            breakLine()
        case _ where inlineControls.contains(role):
            let name = label() ?? text(of: attr(element, "AXValue")) ?? ""
            put("[\(roleDescription): \(name)]", at: element)
        default:
            let before = out.count
            renderChildren(of: element)
            if out.count == before, let name = label() { put("[\(roleDescription): \(name)]", at: element) }
        }
    }

    func text(ofURL element: AXUIElement) -> String? {
        appshotText(of: attr(element, "AXURL"))
    }
    func text(of value: AnyObject?) -> String? {
        appshotText(of: value)
    }
}

struct TextWalk {
    var lines: [String] = []
    var nodes = 0
    var hitDeadline = false
    let deadline: Date
    let maxNodes = 40_000
    let maxChars = 2_000_000
    var chars = 0
    var url: String?

    init(seconds: Double) { deadline = Date().addingTimeInterval(seconds) }

    mutating func walk(_ element: AXUIElement, depth: Int) {
        nodes += 1
        if Date() > deadline { hitDeadline = true }
        if nodes > maxNodes || depth > 80 || chars >= maxChars || hitDeadline { return }
        // An app that does not answer (Telegram, some games) costs at most
        // this per query instead of the system's several seconds.
        AXUIElementSetMessagingTimeout(element, 0.2)

        let described = describe(element)
        var line = String(repeating: "\t", count: depth) + described.line
        if url == nil, described.role == "AXWebArea", let found = described.url { url = found }
        if described.role == "AXWebArea" && !described.hasValue {
            // The page as text, in place of its thousands of nodes.
            var page = WebRender(deadline: deadline, maxChars: max(1000, maxChars - chars))
            page.renderChildren(of: element)
            nodes += page.nodes
            let value = page.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { line += ", Value: " + value }
            lines.append(line)
            chars += line.count + 1
            return
        }
        lines.append(line)
        chars += line.count + 1
        if described.hasValue && valueHoldsContent.contains(described.role) { return }

        guard let children = attr(element, "AXChildren") as? [AXUIElement] else { return }
        for child in children { walk(child, depth: depth + 1) }
    }
}

typealias WindowText = (text: String, title: String?, url: String?, document: String?, focused: String?)

var lapStart = Date()
func lap(_ what: String) {
    guard debugTextPid != nil else { return }
    FileHandle.standardError.write(String(format: "%6.3fs %@\n", Date().timeIntervalSince(lapStart), what).data(using: .utf8)!)
    lapStart = Date()
}

func windowText(pid: pid_t, windowTitle: String?) -> WindowText {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)

    // Chromium and Electron build their web accessibility tree only on request:
    // they alone list AXManualAccessibility (every AppKit app lists
    // AXEnhancedUserInterface, so that one tells nothing). Only they are
    // switched on and given time to fill in.
    var names: CFArray?
    AXUIElementCopyAttributeNames(app, &names)
    let known = Set((names as? [String]) ?? [])
    lap("attribute names")
    let isWebApp = known.contains("AXManualAccessibility")
    var enhancedBefore: Bool?
    if isWebApp {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        enhancedBefore = attr(app, "AXEnhancedUserInterface") as? Bool
        if enhancedBefore == false {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
    defer {
        if enhancedBefore == false {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
    }

    // The window's title is known from the window list; asking accessibility
    // for one is slow in some apps (Telegram: over a second), so it is asked
    // only to find the window when the app reports no focused one.
    var window = attr(app, "AXFocusedWindow").map { $0 as! AXUIElement }
    lap("focused window")
    if window == nil, let windowTitle, let windows = attr(app, "AXWindows") as? [AXUIElement] {
        window = windows.first { stringAttr($0, "AXTitle") == windowTitle }
        lap("windows by title")
    }
    guard let window else { return ("", nil, nil, nil, nil) }

    // What has the keyboard, as Codex reports it: "text field Search".
    var focused: String?
    if let element = attr(app, "AXFocusedUIElement") {
        let el = element as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.2)
        focused = describe(el).line
    }
    lap("focused element")

    AXUIElementSetMessagingTimeout(window, 0.5)
    var walk = TextWalk(seconds: 2)
    walk.walk(window, depth: 0)
    lap("walk")
    // A web tree that was just switched on fills in over a second: walk it
    // again while it is still nearly empty. Any other app's empty tree is empty.
    if isWebApp {
        for _ in 0..<3 where walk.nodes < 20 && !walk.hitDeadline {
            Thread.sleep(forTimeInterval: 0.4)
            var retry = TextWalk(seconds: 1.5)
            retry.walk(window, depth: 0)
            if retry.chars > walk.chars { walk = retry }
        }
    }
    if debugTextPid != nil { FileHandle.standardError.write("nodes \(walk.nodes), hitDeadline \(walk.hitDeadline)\n".data(using: .utf8)!) }
    let title = windowTitle ?? stringAttr(window, "AXTitle")
    lap("title")
    let document = stringAttr(window, "AXDocument")
    lap("document")
    return (walk.lines.joined(separator: "\n"), title, walk.url, document, focused)
}

// windowText with a hard cap: an app whose accessibility hangs on a single
// call must not hold the capture. Past the cap the walk is abandoned and the
// capture goes on with the screenshot alone.
final class TextBox: @unchecked Sendable {
    var value: WindowText?
}

func boundedWindowText(pid: pid_t, windowTitle: String?) -> WindowText {
    let box = TextBox()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        box.value = windowText(pid: pid, windowTitle: windowTitle)
        done.signal()
    }
    if done.wait(timeout: .now() + 4) == .success, let value = box.value { lap("bounded return"); return value }
    emit(["event": "error", "reason": "text-timeout"])
    return ("", windowTitle, nil, nil, nil)
}

// MARK: - Capture

func isSkipped(_ pid: pid_t) -> Bool {
    guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
    return skipBundles.contains(bundle)
}

func frontmostWindow() -> (id: CGWindowID, pid: pid_t, owner: String, title: String?)? {
    var focusedPid: pid_t?
    let system = AXUIElementCreateSystemWide()
    if let app = attr(system, "AXFocusedApplication") {
        var pid: pid_t = 0
        if AXUIElementGetPid(app as! AXUIElement, &pid) == .success { focusedPid = pid }
    }
    if focusedPid == nil { focusedPid = NSWorkspace.shared.frontmostApplication?.processIdentifier }
    // Pressed over Claude itself: the app used before it.
    let wantedPid = focusedPid.map(isSkipped) == true ? lastOtherPid : focusedPid

    func windows(_ options: CGWindowListOption) -> [[String: Any]] {
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        // Front to back: normal-layer, window-sized windows of regular apps, none of Claude's own.
        return list.filter { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
                  !isSkipped(pid),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width >= 120, height >= 120 else { return false }
            return true
        }
    }
    let onScreen = windows([.optionOnScreenOnly, .excludeDesktopElements])
    // Only on-screen windows: one Stage Manager holds off screen captures blank.
    let pick = onScreen.first { (window: [String: Any]) in (window[kCGWindowOwnerPID as String] as? pid_t) == wantedPid }
    guard let pick, let id = pick[kCGWindowNumber as String] as? CGWindowID,
          let pid = pick[kCGWindowOwnerPID as String] as? pid_t else { return nil }
    let owner = pick[kCGWindowOwnerName as String] as? String ?? "App"
    let title = (pick[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return (id, pid, owner, title)
}

func slug(_ s: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let mapped = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
    return String(String(mapped).prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

func readTarget() -> String? {
    let path = (root as NSString).appendingPathComponent("active.json")
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj["sessionId"] as? String
}

let captureQueue = DispatchQueue(label: "appshot.capture")
var isCapturing = false

func capture() {
    guard let front = frontmostWindow() else {
        emit(["event": "error", "reason": "no-window"])
        return
    }
    let app = NSRunningApplication(processIdentifier: front.pid)
    let appName = app?.localizedName ?? front.owner

    let stamp: String = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }()
    let id = "\(stamp)-\(slug(appName))"
    let dir = (capturesDir as NSString).appendingPathComponent(id)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let png = (dir as NSString).appendingPathComponent("window.png")
    let txt = (dir as NSString).appendingPathComponent("window.txt")

    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-o", "-l\(front.id)", "-t", "png", png]
    try? shot.run()

    let text = boundedWindowText(pid: front.pid, windowTitle: front.title)
    shot.waitUntilExit()

    let hasImage = FileManager.default.fileExists(atPath: png)
    let title = text.title ?? front.title ?? ""
    var body = "Window: \"\(title)\", App: \(appName).\n"
    if let doc = text.document { body += "Document: \(doc)\n" }
    body += text.text.isEmpty ? "(the app exposes nothing to accessibility; the screenshot is all there is)\n" : text.text + "\n"
    body += "\nThe focused UI element is \(text.focused ?? "unknown")\n"
    try? body.write(toFile: txt, atomically: true, encoding: .utf8)

    var meta: [String: Any] = [
        "id": id, "app": appName, "title": title, "pid": Int(front.pid),
        "txt": txt, "chars": body.count,
        "createdAt": Int(Date().timeIntervalSince1970 * 1000),
    ]
    if hasImage { meta["png"] = png }
    if let bundle = app?.bundleIdentifier { meta["bundleId"] = bundle }
    if let url = text.url { meta["url"] = url }
    if let target = readTarget() { meta["target"] = target }

    if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
        // meta.json last: its presence means the capture is complete.
        try? data.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("meta.json")))
    }
    NSSound(named: "Tink")?.play()
    var event = meta
    event["event"] = "capture"
    emit(event)
}

func triggerCapture() {
    captureQueue.async {
        guard !isCapturing else { return }
        isCapturing = true
        capture()
        isCapturing = false
    }
}

// MARK: - Debug flags

if debugStatus {
    emit([
        "accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(),
        "path": CommandLine.arguments[0],
        "axFrontmost": frontmostBundle() ?? "-",
        "workspaceFrontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-",
    ])
    exit(0)
}
if let debugTextPid {
    let started = Date()
    // As the live path passes it: the front window's title from the window list.
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let knownTitle = list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == debugTextPid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        .flatMap { $0[kCGWindowName as String] as? String }.flatMap { $0.isEmpty ? nil : $0 }
    let got = boundedWindowText(pid: debugTextPid, windowTitle: knownTitle)
    print("\(got.text.count) chars in \(Date().timeIntervalSince(started))s, title \(got.title ?? "-"), focused \(got.focused ?? "-"), trusted \(AXIsProcessTrusted())")
    print(got.text)
    exit(0)
}

// MARK: - Permissions

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
let isTrusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
var canRecord = CGPreflightScreenCaptureAccess()
if !canRecord { canRecord = CGRequestScreenCaptureAccess() }

if captureNow {
    capture()
    exit(0)
}

// MARK: - Paste

func frontmostBundle() -> String? {
    // AXFocusedApplication answers nothing from a process without a run loop;
    // the workspace's answer is current enough for a paste.
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
}

// Focuses the app's composer: the text box whose value holds `token`, or the
// one labelled "Prompt". A paste lands only where the keyboard focus is, and
// after a click elsewhere in the window it is not in the composer.
func focusComposer(of app: NSRunningApplication, holding token: String?) -> Bool {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 0.5)
    // Electron builds its tree on request.
    AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var windows = (attr(ax, "AXWindows") as? [AXUIElement]) ?? []
    if let focused = attr(ax, "AXFocusedWindow") { windows.insert(focused as! AXUIElement, at: 0) }

    var found: AXUIElement?
    var nodes = 0
    let deadline = Date().addingTimeInterval(1.5)
    func search(_ element: AXUIElement, depth: Int) {
        guard found == nil, nodes < 20_000, depth < 60, Date() < deadline else { return }
        nodes += 1
        AXUIElementSetMessagingTimeout(element, 0.2)
        let role = stringAttr(element, "AXRole") ?? ""
        if role == "AXTextArea" || role == "AXTextField" {
            let value = (attr(element, "AXValue") as? String) ?? ""
            let label = stringAttr(element, "AXTitle") ?? stringAttr(element, "AXDescription") ?? ""
            if (token.map { value.contains($0) } ?? false) || label == "Prompt" {
                found = element
                return
            }
        }
        for child in (attr(element, "AXChildren") as? [AXUIElement]) ?? [] { search(child, depth: depth + 1) }
    }
    for window in windows where found == nil { search(window, depth: 0) }
    guard let found else { return false }
    return AXUIElementSetAttributeValue(found, "AXFocused" as CFString, kCFBooleanTrue) == .success
}

var didFocusComposer = false

func paste(png: String, into bundle: String) -> String? {
    guard let image = FileManager.default.contents(atPath: png) else { return "no-image" }
    guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return "not-running" }
    // The keystroke goes to that process alone (never to whatever else has the
    // keyboard, another device under Universal Control included), once it has
    // come forward and its window has had a moment to take the focus.
    target.activate()
    let deadline = Date().addingTimeInterval(2.5)
    while frontmostBundle() != bundle && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    Thread.sleep(forTimeInterval: 0.3)
    didFocusComposer = focusComposer(of: target, holding: pasteToken)
    Thread.sleep(forTimeInterval: 0.3)

    let board = NSPasteboard.general
    let saved: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    board.clearContents()
    let item = NSPasteboardItem()
    item.setData(image, forType: .png)
    if let tiff = NSImage(data: image)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
    board.writeObjects([item])
    let ours = board.changeCount

    let source = CGEventSource(stateID: .combinedSessionState)
    let vKey: CGKeyCode = 9 // kVK_ANSI_V
    for isDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: isDown)
        event?.flags = .maskCommand
        event?.postToPid(target.processIdentifier)
    }

    // Give the app time to read the image, then put the clipboard back unless
    // something else was copied meanwhile.
    Thread.sleep(forTimeInterval: 1.0)
    if board.changeCount == ours {
        board.clearContents()
        let restored = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
    return nil
}

if let pastePath, let expectBundle {
    if let reason = paste(png: pastePath, into: expectBundle) {
        emit(["event": "paste-skipped", "reason": reason])
        exit(1)
    }
    emit(["event": "pasted", "focused": didFocusComposer])
    exit(0)
}

// MARK: - Hotkey: both Command keys

let leftCommand: UInt64 = 0x08   // NX_DEVICELCMDKEYMASK
let rightCommand: UInt64 = 0x10  // NX_DEVICERCMDKEYMASK
var wasBoth = false
var lastFire = Date.distantPast
var tap: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let raw = event.flags.rawValue
    let isBoth = raw & leftCommand != 0 && raw & rightCommand != 0
    if isBoth && !wasBoth && Date().timeIntervalSince(lastFire) > 1.5 {
        lastFire = Date()
        triggerCapture()
    }
    wasBoth = isBoth
    return Unmanaged.passUnretained(event)
}

func installTap() -> Bool {
    let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                       options: .listenOnly, eventsOfInterest: mask,
                                       callback: callback, userInfo: nil) else { return false }
    tap = port
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    return true
}

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
) { note in
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          app.activationPolicy == .regular, !isSkipped(app.processIdentifier) else { return }
    lastOtherPid = app.processIdentifier
}

var hasTap = installTap()
emit(["event": "ready", "accessibility": isTrusted, "screenRecording": canRecord, "hotkey": hasTap])

// Retry the tap until permission is granted; exit if the session that started us is gone.
let parent = getppid()
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    if getppid() != parent { exit(0) }
    if !hasTap {
        hasTap = installTap()
        if hasTap { emit(["event": "ready", "accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(), "hotkey": true]) }
    }
}

NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
