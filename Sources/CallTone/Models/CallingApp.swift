import Foundation
import AppKit

enum CallState: String, Codable, Equatable {
    case idle = "Idle"
    case ringing = "Ringing"
    case connected = "In Call"
    case ended = "Ended"
}

enum AppInstallStatus: String, Codable, Equatable {
    case installed = "Installed"
    case systemBuiltIn = "System Built-in"
    case webBased = "Browser / PWA"
    case notInstalled = "Not Installed"
}

struct CallingApp: Identifiable, Codable, Equatable, Hashable {
    let id: String // Canonical identifier (usually primary bundle ID)
    var name: String
    var bundleIdentifiers: [String]
    var audioProcessNames: [String]
    var incomingWindowKeywords: [String]
    var sfSymbol: String
    var isEnabled: Bool
    var customRingtoneID: UUID? // nil = Use Global Ringtone
    var isCustomAdded: Bool
    var isContinuityPhone: Bool

    init(
        id: String,
        name: String,
        bundleIdentifiers: [String],
        audioProcessNames: [String],
        incomingWindowKeywords: [String],
        sfSymbol: String,
        isEnabled: Bool = true,
        customRingtoneID: UUID? = nil,
        isCustomAdded: Bool = false,
        isContinuityPhone: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.audioProcessNames = audioProcessNames
        self.incomingWindowKeywords = incomingWindowKeywords
        self.sfSymbol = sfSymbol
        self.isEnabled = isEnabled
        self.customRingtoneID = customRingtoneID
        self.isCustomAdded = isCustomAdded
        self.isContinuityPhone = isContinuityPhone
    }

    static let defaultCatalog: [CallingApp] = [
        CallingApp(
            id: "com.apple.ContinuityPhone",
            name: "Apple Phone (iPhone Continuity)",
            bundleIdentifiers: [
                "com.apple.FaceTime",
                "com.apple.mobilephone",
                "com.apple.InCallService",
                "com.apple.notificationcenterui",
                "com.apple.telephonyutilities.callservicesd",
                "com.apple.TelephonyUtilities",
                "com.apple.avconferenced"
            ],
            audioProcessNames: [
                "callservicesd",
                "avconferenced",
                "Phone",
                "FaceTime",
                "NotificationCenter",
                "InCallService",
                "MacInCallService",
                "TelephonyUtilities"
            ],
            incomingWindowKeywords: ["iPhone", "Incoming Call", "Call from", "Accept", "Decline"],
            sfSymbol: "phone.fill",
            isContinuityPhone: true
        ),
        CallingApp(
            id: "com.apple.FaceTime",
            name: "FaceTime",
            bundleIdentifiers: [
                "com.apple.FaceTime",
                "com.apple.notificationcenterui",
                "com.apple.InCallService",
                "com.apple.TelephonyUtilities",
                "com.apple.avconferenced",
                "com.apple.FaceTimeNotificationService",
                "com.apple.FaceTimeNotificationViewBridgeService"
            ],
            audioProcessNames: [
                "FaceTime",
                "avconferenced",
                "callservicesd",
                "NotificationCenter",
                "MacInCallService",
                "InCallService",
                "TelephonyUtilities"
            ],
            incomingWindowKeywords: ["Incoming", "Accept", "Decline", "is calling", "Call from"],
            sfSymbol: "video.fill"
        ),
        CallingApp(
            id: "net.whatsapp.WhatsApp",
            name: "WhatsApp",
            bundleIdentifiers: ["net.whatsapp.WhatsApp", "WhatsApp", "net.whatsapp.WhatsApp.ServiceExtension"],
            audioProcessNames: ["WhatsApp", "WhatsApp Helper"],
            incomingWindowKeywords: ["Incoming voice call", "Incoming video call", "WhatsApp Call", "Accept", "Decline"],
            sfSymbol: "message.fill"
        ),
        CallingApp(
            id: "ru.keepcoder.Telegram",
            name: "Telegram",
            bundleIdentifiers: ["ru.keepcoder.Telegram", "org.telegram.desktop"],
            audioProcessNames: ["Telegram"],
            incomingWindowKeywords: ["Incoming call", "Telegram Call", "Ringing", "Accept"],
            sfSymbol: "paperplane.fill"
        ),
        CallingApp(
            id: "org.whispersystems.signal-desktop",
            name: "Signal",
            bundleIdentifiers: ["org.whispersystems.signal-desktop"],
            audioProcessNames: ["Signal", "Signal Helper"],
            incomingWindowKeywords: ["Incoming Call", "Signal Call", "Answer", "Decline"],
            sfSymbol: "lock.shield.fill"
        ),
        CallingApp(
            id: "us.zoom.xos",
            name: "Zoom",
            bundleIdentifiers: ["us.zoom.xos"],
            audioProcessNames: ["zoom.us", "CptHost"],
            incomingWindowKeywords: ["is calling you", "Incoming", "Zoom Meeting", "Accept", "Decline"],
            sfSymbol: "video.bubble.fill"
        ),
        CallingApp(
            id: "com.microsoft.teams2",
            name: "Microsoft Teams",
            bundleIdentifiers: ["com.microsoft.teams2", "com.microsoft.teams"],
            audioProcessNames: ["MSTeams", "Microsoft Teams", "Microsoft Teams WebView"],
            incomingWindowKeywords: ["Incoming call", "is calling", "Teams Call", "Accept"],
            sfSymbol: "person.3.fill"
        ),
        CallingApp(
            id: "com.google.Meet",
            name: "Google Meet",
            bundleIdentifiers: [
                "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", // Meet PWA
                "com.google.Chrome",
                "com.apple.Safari",
                "company.thebrowser.Browser", // Arc
                "com.microsoft.edgemac"
            ],
            audioProcessNames: ["Google Chrome Helper", "Safari", "Arc Helper", "Microsoft Edge Helper"],
            incomingWindowKeywords: ["Meet -", "Google Meet", "Incoming call", "is calling"],
            sfSymbol: "globe"
        ),
        CallingApp(
            id: "com.hnc.Discord",
            name: "Discord",
            bundleIdentifiers: ["com.hnc.Discord"],
            audioProcessNames: ["Discord", "Discord Helper"],
            incomingWindowKeywords: ["Incoming Call", "Calling", "Discord"],
            sfSymbol: "headphones"
        )
    ]
}
