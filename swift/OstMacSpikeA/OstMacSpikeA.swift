import SwiftUI
import CRustA

private func rustCallback(
    reqID: Int64, json: UnsafePointer<CChar>?, ctx: UnsafeMutableRawPointer?
) {
    guard let json, let ctx else { return }
    let str = String(cString: json)
    let bridge = Unmanaged<Bridge>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async { bridge.handle(reqID: reqID, json: str) }
}

final class Bridge: ObservableObject {
    @Published var coreVersion = "?"
    @Published var status = "starting…"
    @Published var signin = "not started"
    @Published var chats = "not started"
    @Published var events: [String] = []
    private var nextID: Int64 = 1

    init() {
        let v = String(cString: ostmac_version())
        coreVersion = v
        status = ostmac_init() == 1 ? "Rust core initialised" : "init FAILED"
    }

    private func ctx() -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    func handle(reqID: Int64, json: String) {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            events.append("req \(reqID): <non-json>")
            return
        }
        let ok = (obj["ok"] as? Bool) ?? false
        if reqID == 9001 {  // trouter stream
            if ok, let d = obj["data"] as? [String: Any], let ev = d["event"] as? String {
                events.append(String(ev.prefix(160)))
            } else {
                events.append("trouter: \(json.prefix(200))")
            }
            return
        }
        let pretty: String = {
            if let d = obj["data"], ok,
                let dd = try? JSONSerialization.data(
                    withJSONObject: d, options: [.prettyPrinted, .sortedKeys]),
                let s = String(data: dd, encoding: .utf8)
            { return s }
            return (obj["error"] as? String) ?? json
        }()
        switch reqID {
        case 1: signin = pretty
        case 2: chats = pretty
        default: events.append("req \(reqID): \(pretty.prefix(160))")
        }
    }

    func startSignin() {
        signin = "requesting device code…"
        ostmac_auth_start(1, rustCallback, ctx())
    }

    func listChats() {
        chats = "loading…"
        ostmac_chats(2, 10, rustCallback, ctx())
        _ = nextID
    }

    func startTrouter() {
        events.append("connecting…")
        ostmac_trouter_start(9001, rustCallback, ctx())
    }
}

struct ContentView: View {
    @StateObject private var bridge = Bridge()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OstMac spike (A)").font(.title2).bold()
            Text("core \(bridge.coreVersion) · \(bridge.status)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Start sign-in", action: bridge.startSignin)
                Button("List chats", action: bridge.listChats)
                Button("Trouter", action: bridge.startTrouter)
            }
            Group {
                Text("sign-in").bold()
                Text(bridge.signin).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                Text("chats").bold()
                Text(bridge.chats).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                Text("trouter events").bold()
                Text(
                    bridge.events.isEmpty
                        ? "none yet" : bridge.events.suffix(6).joined(separator: "\n")
                ).font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding()
        .frame(width: 640, height: 520)
    }
}

@main
struct OstMacSpikeAApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
