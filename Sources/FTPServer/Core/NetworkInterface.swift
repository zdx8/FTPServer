import Foundation
import Darwin

/// 本机网络接口地址枚举。用于两条路径：
/// 1. 被动模式（PASV）向客户端通告可回连的服务器地址；
/// 2. 界面展示可用的连接地址。
enum NetworkInterface {
    static func ipv4Addresses() -> [(name: String, address: String)] {
        var results: [(name: String, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            if let address = interface.ifa_addr,
               address.pointee.sa_family == sa_family_t(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(address,
                                         socklen_t(address.pointee.sa_len),
                                         &host,
                                         socklen_t(host.count),
                                         nil, 0,
                                         NI_NUMERICHOST)
                if status == 0 {
                    results.append((name: String(cString: interface.ifa_name),
                                    address: String(cString: host)))
                }
            }
            cursor = interface.ifa_next
        }
        return results
    }

    /// 优先 en0，其次任意 en*，最后任意非回环 IPv4。
    static func primaryIPv4() -> String? {
        let candidates = ipv4Addresses()
            .filter { $0.address != "127.0.0.1" && $0.address != "0.0.0.0" }
        if let preferred = candidates.first(where: { $0.name == "en0" }) { return preferred.address }
        if let wired = candidates.first(where: { $0.name.hasPrefix("en") }) { return wired.address }
        return candidates.first?.address
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
            return true
        }
    }
}
