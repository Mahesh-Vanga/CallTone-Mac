import AppKit
import ApplicationServices
import OSLog

enum AppleCallUI {
    private static let diagnosticLock = NSLock()
    nonisolated(unsafe) private static var lastDiagnostic = ""
    private static let logger = Logger(subsystem: "com.calltone.macos", category: "CallDetection")

    nonisolated private static func report(_ state: Bool?, _ reason: String) -> Bool? {
        diagnosticLock.lock()
        let changed = reason != lastDiagnostic
        lastDiagnostic = reason
        diagnosticLock.unlock()
        if changed { logger.notice("Apple UI detection: \(reason, privacy: .private)") }
        return state
    }

    static let bundleIDs = ["com.apple.InCallService", "com.apple.notificationcenterui"]

    nonisolated static func incomingState() -> Bool? {
        // The attribute query enforces access and provides the actual permission error.
        let apps = bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        if apps.isEmpty { return report(nil, "Call UI service not running") }
        var labels: [String] = []
        var sawWindow = false
        let deadline = ProcessInfo.processInfo.systemUptime + 0.04
        for app in apps {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.02)
            var rawWindows: CFTypeRef?
            let windowResult = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &rawWindows)
            guard windowResult == .success, let windows = rawWindows as? [AXUIElement] else {
                continue
            }
            sawWindow = sawWindow || !windows.isEmpty
            var pending = windows
            var visited = 0
            while let node = pending.popLast() {
                guard visited < 256, ProcessInfo.processInfo.systemUptime < deadline else { return report(nil, "Call UI scan exceeded its budget") }
                visited += 1
                AXUIElementSetMessagingTimeout(node, 0.01)
                var role: CFTypeRef?
                let roleResult = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
                guard roleResult == .success else { continue }
                if role as? String == kAXButtonRole {
                    for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXHelpAttribute] {
                        var value: CFTypeRef?
                        let result = AXUIElementCopyAttributeValue(node, attribute as CFString, &value)
                        if result == .cannotComplete || result == .invalidUIElement { continue }
                        if let text = value as? String { labels.append(text) }
                    }
                    if incomingState(buttonLabels: labels) == true {
                        return report(true, "Incoming Answer/Decline controls found")
                    }
                }
                var children: CFTypeRef?
                let childResult = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children)
                if childResult == .cannotComplete || childResult == .invalidUIElement { continue }
                if let items = children as? [AXUIElement] { pending.append(contentsOf: items) }
            }
        }
        if !sawWindow { return report(nil, "Call UI has no windows") }
        let state = incomingState(buttonLabels: labels)
        return report(state, state == false ? "Active-call controls found" : (state == true ? "Incoming Answer/Decline controls found" : "Unrecognized call UI controls: \(labels.count)"))
    }

    private static let answerKeywords = [
        "accept", "answer", "answercallbutton", "acceptcallbutton", "incomingcallanswerbutton",
        "aceptar", "responder",
        "accepter", "répondre", "repondre",
        "annehmen", "antworten",
        "rispondi", "accetta",
        "atender", "aceitar",
        "ответить", "принять",
        "応答", "受ける",
        "接听", "接聽", "接受",
        "응답", "수락",
        "beantwoorden", "aannemen",
        "उत्तर दें", "स्वीकार"
    ]

    private static let declineKeywords = [
        "decline", "reject", "rejectcallbutton", "declinecallbutton", "incomingcalldeclinebutton",
        "rechazar", "denegar",
        "refuser", "rejeter",
        "ablehnen", "abweisen",
        "rifiuta", "declina",
        "recusar", "rejeitar",
        "отклонить", "сбросить",
        "拒否", "辞退",
        "拒绝", "拒絕",
        "거절",
        "weigeren", "afwijzen",
        "अस्वीकार", "काटें"
    ]

    private static let endCallKeywords = [
        "end call", "endcall", "hang up", "hangup", "endcallbutton", "disconnectcallbutton", "leave call", "leavecall",
        "finalizar llamada", "colgar", "terminar llamada",
        "raccrocher", "fin d'appel", "mettre fin",
        "auflegen", "anruf beenden",
        "termina chiamata", "riaggancia",
        "desligar", "encerrar chamada",
        "завершить", "положить трубку",
        "通話を終了", "切断",
        "挂断", "結束通話", "挂断电话",
        "통화 종료",
        "ophangen", "oproep beëindigen",
        "कॉल समाप्त करें"
    ]

    nonisolated static func incomingState(buttonLabels: [String]) -> Bool? {
        let labels = buttonLabels.map { $0.lowercased() }
        let answer = labels.contains { label in
            answerKeywords.contains { label.contains($0) }
        }
        let decline = labels.contains { label in
            declineKeywords.contains { label.contains($0) }
        }
        if answer && decline { return true }
        if labels.contains(where: { label in
            endCallKeywords.contains { label.contains($0) }
        }) { return false }
        // unrecognized/localized controls retain audio fallback
        return nil
    }
}
