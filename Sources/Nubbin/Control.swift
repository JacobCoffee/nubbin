import Foundation

/// JSON encoding for control replies. Shared by the app (answering `Nubbin ctl` and other socket
/// clients) and nothing else; `Nubbin ctl` only prints whatever bytes come back.
enum Control {
    /// `{"ok":true,"rows":[...]}`, one row per `Store.rows` entry, in display order.
    static func listReply(_ rows: [Row]) -> Data {
        let payload: [String: Any] = ["ok": true, "rows": rows.map(encode(_:))]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? errorReply("encoding failed")
    }

    static func okReply() -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": true])) ?? Data(#"{"ok":true}"#.utf8)
    }

    static func errorReply(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message]))
            ?? Data(#"{"ok":false,"error":"internal error"}"#.utf8)
    }


    private static func encode(_ row: Row) -> [String: Any] {
        var zellij: Any = NSNull()
        if let session = row.zellijSession {
            zellij = [
                "session": session,
                "tab_id": row.zellijTabID.map { $0 as Any } ?? NSNull(),
                "pane_id": row.zellijPaneID.map { $0 as Any } ?? NSNull(),
            ] as [String: Any]
        }
        return [
            "id": row.id,
            "source": row.source == .agent ? "agent" : "bell",
            "agent": row.agent ?? NSNull(),
            "title": row.title,
            "model": row.model ?? NSNull(),
            "cwd": row.cwd ?? NSNull(),
            "location": row.location ?? NSNull(),
            "detail": row.detail ?? NSNull(),
            "activity": row.activity.wireName,
            "since": row.since.formatted(.iso8601),
            "zellij": zellij,
            "terminal_bundle_id": row.terminalBundleID ?? NSNull(),
        ]
    }
}

extension Activity {
    /// Wire name sent over the control API; matches the Swift case name exactly.
    var wireName: String {
        switch self {
        case .needsYou: return "needsYou"
        case .error: return "error"
        case .done: return "done"
        case .working: return "working"
        case .idle: return "idle"
        }
    }
}
