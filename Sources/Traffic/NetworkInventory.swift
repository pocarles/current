import Foundation
import SystemConfiguration
import Darwin
import CNetwork
import TrafficCore
import Security

enum NetworkInventory {
    static func read(includeTailscale: Bool) async -> ConnectionInventory {
        await Task.detached(priority: .utility) {
            var inventory = ConnectionInventory()
            if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
                for interface in interfaces {
                    guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                          let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
                    let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? ""
                    if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { inventory.physicalKinds[name] = .wifi }
                    else if display.hasPrefix("Thunderbolt") { inventory.physicalKinds[name] = .thunderbolt }
                    else if type == (kSCNetworkInterfaceTypeEthernet as String) { inventory.physicalKinds[name] = display.hasPrefix("iPhone") ? .hotspot : .ethernet }
                    else if type == (kSCNetworkInterfaceTypeBluetooth as String) { inventory.physicalKinds[name] = .bluetoothPAN }
                }
            }
            let addresses = localAddresses()
            inventory.addresses = addresses
            let app = URL(fileURLWithPath: "/Applications/Tailscale.app", isDirectory: true)
            let supported = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]
            inventory.tailscaleInstalled = Bundle(url: app)?.bundleIdentifier.map(supported.contains) == true
            guard includeTailscale, inventory.tailscaleInstalled,
                  let own = tailscaleAddresses(executable: app.appendingPathComponent("Contents/MacOS/Tailscale")) else { return inventory }
            inventory.tailscaleAvailable = true
            inventory.tailscaleInterface = ConnectionInventory.matchTailscale(selfAddresses: own, interfaceAddresses: addresses)
            if let name = inventory.tailscaleInterface { inventory.tailscaleIndex = name.withCString { if_nametoindex($0) } }
            // No match means current identity cannot establish a local tunnel.
            if !own.isEmpty && (inventory.tailscaleInterface == nil || inventory.tailscaleIndex == 0) { inventory.tailscaleAvailable = false }
            return inventory
        }.value
    }

    private static func localAddresses() -> [String: Set<String>] {
        var raw = [TrafficAddress](repeating: TrafficAddress(), count: 256)
        let count = traffic_addresses(&raw, Int32(raw.count))
        guard count >= 0 else { return [:] }
        var output: [String: Set<String>] = [:]
        for item in raw.prefix(Int(count)) {
            var name = item.name, address = item.address
            let n = withUnsafePointer(to: &name) { $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) } }
            let a = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
            output[n, default: []].insert(a)
        }
        return output
    }

    // An existing local client is optional, never installed or configured here.
    // Only its own status is requested. Output is bounded and never persisted.
    static func trustedTailscale(executable: URL) -> Bool {
        var code: SecStaticCode?, requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[subject.OU] = \"W5364U7YZB\" and (identifier \"io.tailscale.ipn.macsys\" or identifier \"io.tailscale.ipn.macos\")"
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code, SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }
    private static func tailscaleAddresses(executable: URL) -> Set<String>? {
        guard trustedTailscale(executable: executable) else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["status", "--json", "--self", "--peers=false"]
        guard let data = BoundedProcess.output(process),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard status["BackendState"] as? String == "Running" else { return [] }
        guard let own = status["Self"] as? [String: Any], let addresses = own["TailscaleIPs"] as? [String], addresses.count <= 16 else { return nil }
        return Set(addresses)
    }
}
