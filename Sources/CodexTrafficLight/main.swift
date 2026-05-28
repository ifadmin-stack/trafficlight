import AppKit
import Foundation
import SQLite3

enum CodexState: String, Codable {
    case working
    case approval
    case complete
    case error
    case idle
    case unknown

    var title: String {
        switch self {
        case .working:
            return "Codex 正在工作"
        case .approval:
            return "需要你确认权限"
        case .complete:
            return "任务已完成"
        case .error:
            return "任务出错"
        case .idle:
            return "等待 Codex 任务"
        case .unknown:
            return "状态未知"
        }
    }

    var shortTitle: String {
        switch self {
        case .working:
            return "工作中"
        case .approval:
            return "待确认"
        case .complete:
            return "已完成"
        case .error:
            return "出错"
        case .idle:
            return "等待中"
        case .unknown:
            return "未知"
        }
    }
}

struct CodexStatus: Codable, Equatable {
    var state: CodexState
    var event: String?
    var source: String?
    var message: String?
    var threadId: String?
    var workspace: String?
    var updatedAt: String?

    static let initial = CodexStatus(
        state: .idle,
        event: nil,
        source: "codex",
        message: "还没有收到 Codex 状态事件",
        threadId: nil,
        workspace: nil,
        updatedAt: nil
    )
}

enum StatusPaths {
    static var appSupportDirectory: URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codex-trafficlight-\(getuid())", isDirectory: true)
    }

    static var statusFile: URL {
        appSupportDirectory.appendingPathComponent("status.json", isDirectory: false)
    }

    static var legacyStatusFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodexTrafficLight", isDirectory: true)
            .appendingPathComponent("status.json", isDirectory: false)
    }
}

enum CodexLogMonitor {
    private struct LogRow {
        let ts: Int64
        let body: String
        let threadId: String?

        var date: Date {
            Date(timeIntervalSince1970: TimeInterval(ts))
        }
    }

    private enum ResponseEvent {
        case inProgress
        case completed
        case failed
    }

    private static let recentActivityWindowSeconds: TimeInterval = 15

    private static var logsDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("logs_2.sqlite", isDirectory: false)
    }

    static func latestStatus(after fileStatus: CodexStatus) -> CodexStatus? {
        let query = """
        select ts, feedback_log_body, thread_id
        from logs
        order by ts desc, ts_nanos desc, id desc
        limit 220;
        """

        let rows = queryRecentRows(query)
        guard let firstInteresting = rows.first(where: { isInteresting($0.body) }) else {
            return nil
        }

        let logDate = firstInteresting.date
        if let fileDate = parseDate(fileStatus.updatedAt), fileDate > logDate {
            return nil
        }

        guard let status = inferStatus(from: rows) else {
            return nil
        }

        if fileStatus.source != "codex-log",
           (fileStatus.state == .working || fileStatus.state == .approval),
           status.state == .complete {
            return nil
        }

        return status
    }

    private static func inferStatus(from rows: [LogRow]) -> CodexStatus? {
        var latestActivity: LogRow?
        var latestMainResponse: (row: LogRow, event: ResponseEvent)?

        for row in rows {
            let body = row.body
            guard isInteresting(body) else {
                continue
            }

            if latestActivity == nil && isActivity(body) {
                latestActivity = row
            }

            guard !isAutoReview(body), let event = responseEvent(body) else {
                continue
            }

            latestMainResponse = (row, event)
            break
        }

        if let latestMainResponse {
            return status(for: latestMainResponse.event, row: latestMainResponse.row)
        }

        if let latestActivity, Date().timeIntervalSince(latestActivity.date) < recentActivityWindowSeconds {
            return CodexStatus(
                state: .working,
                event: "activity",
                source: "codex-log",
                message: "Codex 正在处理子任务",
                threadId: latestActivity.threadId,
                workspace: nil,
                updatedAt: isoString(from: latestActivity.date)
            )
        }

        return nil
    }

    private static func status(for event: ResponseEvent, row: LogRow) -> CodexStatus? {
        switch event {
        case .inProgress:
            return CodexStatus(
                state: .working,
                event: "response.in_progress",
                source: "codex-log",
                message: "Codex 正在响应",
                threadId: row.threadId,
                workspace: nil,
                updatedAt: isoString(from: row.date)
            )
        case .failed:
            return CodexStatus(
                state: .error,
                event: "response.failed",
                source: "codex-log",
                message: "Codex 响应出错",
                threadId: row.threadId,
                workspace: nil,
                updatedAt: isoString(from: row.date)
            )
        case .completed:
            return nil
        }
    }

    private static func isInteresting(_ body: String) -> Bool {
        responseEvent(body) != nil || isActivity(body)
    }

    private static func isActivity(_ body: String) -> Bool {
        body.contains("response.in_progress")
            || body.contains("dispatch_tool_call")
            || body.contains("tool_name=")
            || body.contains("function_call")
            || body.contains("codex-auto-review")
            || body.contains("hook/started")
            || body.contains("hook/completed")
    }

    private static func responseEvent(_ body: String) -> ResponseEvent? {
        if body.contains("response.failed") {
            return .failed
        }
        if body.contains("response.in_progress") {
            return .inProgress
        }
        if body.contains("response.completed") {
            return .completed
        }
        return nil
    }

    private static func isAutoReview(_ body: String) -> Bool {
        body.contains("codex-auto-review")
    }

    private static func queryRecentRows(_ query: String) -> [LogRow] {
        var rows: [LogRow] = []
        var database: OpaquePointer?
        guard sqlite3_open_v2(logsDatabase.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let ts = sqlite3_column_int64(statement, 0)
            let body = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let threadId = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            rows.append(LogRow(ts: ts, body: body, threadId: threadId))
        }

        return rows
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }
}

final class SignalPalette {
    static let red = NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.20, alpha: 1.0)
    static let yellow = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.10, alpha: 1.0)
    static let green = NSColor(calibratedRed: 0.19, green: 0.78, blue: 0.36, alpha: 1.0)
    static let dim = NSColor(calibratedWhite: 0.33, alpha: 1.0)
    static let body = NSColor(calibratedWhite: 0.08, alpha: 1.0)
    static let bodyStroke = NSColor(calibratedWhite: 0.24, alpha: 1.0)
}

final class MenuBarIconRenderer {
    static func image(for state: CodexState, phase: Bool) -> NSImage {
        let size = NSSize(width: 34, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let bodyRect = NSRect(x: 2, y: 2, width: 30, height: 14)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 7, yRadius: 7)
        SignalPalette.body.withAlphaComponent(0.92).setFill()
        bodyPath.fill()

        let leftYellow = NSRect(x: 9, y: 5, width: 8, height: 8)
        let rightYellow = NSRect(x: 18, y: 5, width: 8, height: 8)
        let single = NSRect(x: 13, y: 5, width: 8, height: 8)

        switch state {
        case .working:
            drawLamp(single, color: SignalPalette.yellow, intensity: phase ? 1.0 : 0.25)
        case .approval:
            drawLamp(leftYellow, color: SignalPalette.yellow, intensity: phase ? 1.0 : 0.18)
            drawLamp(rightYellow, color: SignalPalette.yellow, intensity: phase ? 0.18 : 1.0)
        case .complete:
            drawLamp(single, color: SignalPalette.green, intensity: 1.0)
        case .error:
            drawLamp(single, color: SignalPalette.red, intensity: 1.0)
        case .idle:
            drawLamp(single, color: SignalPalette.dim, intensity: 0.72)
        case .unknown:
            drawLamp(single, color: SignalPalette.dim, intensity: 0.65)
        }

        return image
    }

    private static func drawLamp(_ rect: NSRect, color: NSColor, intensity: CGFloat) {
        let glowRect = rect.insetBy(dx: -3, dy: -3)
        color.withAlphaComponent(0.22 * intensity).setFill()
        NSBezierPath(ovalIn: glowRect).fill()

        color.withAlphaComponent(0.28 + 0.72 * intensity).setFill()
        NSBezierPath(ovalIn: rect).fill()

        NSColor.white.withAlphaComponent(0.35 * intensity).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 2, y: rect.maxY - 3.5, width: 2.4, height: 2.4)).fill()
    }
}

final class TrafficSignalView: NSView {
    var state: CodexState = .idle {
        didSet { needsDisplay = true }
    }

    var phase: Bool = false {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 112, height: 164)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bodyRect = NSRect(
            x: (bounds.width - 92) / 2,
            y: (bounds.height - 148) / 2,
            width: 92,
            height: 148
        )

        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 12, yRadius: 12)
        SignalPalette.body.setFill()
        bodyPath.fill()
        SignalPalette.bodyStroke.setStroke()
        bodyPath.lineWidth = 1
        bodyPath.stroke()

        let redRect = NSRect(x: bodyRect.midX - 18, y: bodyRect.maxY - 42, width: 36, height: 36)
        let yellowLeftRect = NSRect(x: bodyRect.midX - 39, y: bodyRect.midY - 18, width: 36, height: 36)
        let yellowRightRect = NSRect(x: bodyRect.midX + 3, y: bodyRect.midY - 18, width: 36, height: 36)
        let greenRect = NSRect(x: bodyRect.midX - 18, y: bodyRect.minY + 6, width: 36, height: 36)

        let redIntensity: CGFloat = state == .error ? 1.0 : 0.12
        let greenIntensity: CGFloat = state == .complete ? 1.0 : 0.12
        let idleIntensity: CGFloat = state == .idle ? 0.72 : 0
        let yellowLeftIntensity: CGFloat
        let yellowRightIntensity: CGFloat

        switch state {
        case .working:
            yellowLeftIntensity = phase ? 1.0 : 0.18
            yellowRightIntensity = phase ? 1.0 : 0.18
        case .approval:
            yellowLeftIntensity = phase ? 1.0 : 0.15
            yellowRightIntensity = phase ? 0.15 : 1.0
        default:
            yellowLeftIntensity = 0.12
            yellowRightIntensity = 0.12
        }

        drawLamp(redRect, color: SignalPalette.red, intensity: redIntensity)
        drawLamp(yellowLeftRect, color: SignalPalette.yellow, intensity: yellowLeftIntensity)
        drawLamp(yellowRightRect, color: SignalPalette.yellow, intensity: yellowRightIntensity)
        drawLamp(greenRect, color: SignalPalette.green, intensity: greenIntensity)

        if idleIntensity > 0 {
            drawLamp(greenRect, color: SignalPalette.dim, intensity: idleIntensity)
        }
    }

    private func drawLamp(_ rect: NSRect, color: NSColor, intensity: CGFloat) {
        color.withAlphaComponent(0.20 * intensity).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -6, dy: -6)).fill()

        let base = intensity < 0.2 ? SignalPalette.dim : color
        base.withAlphaComponent(0.22 + 0.78 * intensity).setFill()
        NSBezierPath(ovalIn: rect).fill()

        NSColor.white.withAlphaComponent(0.34 * intensity).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 9, y: rect.maxY - 12, width: 8, height: 8)).fill()
    }
}

final class DashboardView: NSView {
    private let signalView = TrafficSignalView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .center

        let stack = NSStackView(views: [signalView, titleLabel, detailLabel, timeLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            signalView.widthAnchor.constraint(equalToConstant: 112),
            signalView.heightAnchor.constraint(equalToConstant: 164),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            timeLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func update(status: CodexStatus, phase: Bool) {
        signalView.state = status.state
        signalView.phase = phase
        titleLabel.stringValue = status.state.title

        let fallback = status.event.map { "事件: \($0)" } ?? status.state.shortTitle
        detailLabel.stringValue = status.message?.isEmpty == false ? status.message! : fallback
        timeLabel.stringValue = status.updatedAt.map { "更新: \(Self.formatUpdatedAt($0))" } ?? "等待状态文件"
    }

    private static func formatUpdatedAt(_ value: String) -> String {
        guard let date = parseDate(value) else {
            return value
        }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "今天 HH:mm:ss"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "昨天 HH:mm:ss"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "MM-dd HH:mm:ss"
        } else {
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        }

        return formatter.string(from: date)
    }

    private static func parseDate(_ value: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: value) {
            return date
        }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = .current
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return fallback.date(from: value)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let dashboardView = DashboardView(frame: NSRect(x: 0, y: 0, width: 300, height: 258))
    private var currentStatus = CodexStatus.initial
    private var phase = false
    private var timer: Timer?
    private var lastModificationDate: Date?
    private var lastRenderedStatus: CodexStatus?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        reloadStatus(force: true)
        reloadCodexLogStatus()
        render()

        timer = Timer.scheduledTimer(
            timeInterval: 0.55,
            target: self,
            selector: #selector(tickTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Codex Traffic Light"
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let dashboardItem = NSMenuItem()
        dashboardItem.view = dashboardView
        menu.addItem(dashboardItem)
        menu.addItem(.separator())

        menu.addItem(menuItem("显示状态文件", action: #selector(revealStatusFile)))
        menu.addItem(menuItem("复制状态文件路径", action: #selector(copyStatusPath)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出", action: #selector(quit)))

        return menu
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func tickTimerFired(_ timer: Timer) {
        tick()
    }

    private func tick() {
        phase.toggle()
        reloadStatus(force: false)
        reloadCodexLogStatus()
        render()
    }

    private func reloadStatus(force: Bool) {
        let fileURL = activeStatusFile()
        let modificationDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        guard force || modificationDate != lastModificationDate else {
            return
        }

        lastModificationDate = modificationDate

        guard let data = try? Data(contentsOf: fileURL) else {
            currentStatus = CodexStatus.initial
            render()
            return
        }

        do {
            currentStatus = try JSONDecoder().decode(CodexStatus.self, from: data)
        } catch {
            currentStatus = CodexStatus(
                state: .unknown,
                event: "decode-error",
                source: "CodexTrafficLight",
                message: "状态文件无法解析",
                threadId: nil,
                workspace: nil,
                updatedAt: nil
            )
        }

        render()
    }

    private func activeStatusFile() -> URL {
        if FileManager.default.fileExists(atPath: StatusPaths.statusFile.path) {
            return StatusPaths.statusFile
        }
        return StatusPaths.legacyStatusFile
    }

    private func reloadCodexLogStatus() {
        guard let status = CodexLogMonitor.latestStatus(after: currentStatus) else {
            return
        }
        currentStatus = status
    }

    private func render() {
        guard currentStatus != lastRenderedStatus || currentStatus.state == .working || currentStatus.state == .approval else {
            return
        }
        lastRenderedStatus = currentStatus
        statusItem?.button?.image = MenuBarIconRenderer.image(for: currentStatus.state, phase: phase)
        statusItem?.button?.toolTip = "Codex Traffic Light - \(currentStatus.state.title)"
        dashboardView.update(status: currentStatus, phase: phase)
    }

    @objc private func revealStatusFile() {
        let fileURL = StatusPaths.statusFile
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.open(StatusPaths.appSupportDirectory)
        }
    }

    @objc private func copyStatusPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(StatusPaths.statusFile.path, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
