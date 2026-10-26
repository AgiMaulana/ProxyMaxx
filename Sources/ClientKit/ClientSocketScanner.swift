import Darwin
import Foundation

protocol SocketOwnershipProbing: Sendable {
    func pid(clientAddress: String, clientPort: Int, proxyAddress: String, proxyPort: Int) -> Int32?
}

/// Matches the client side of an established TCP connection against its full endpoint pair.
final class ClientSocketScanner: SocketOwnershipProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var pids = [Int32](repeating: 0, count: 1024)
    private var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)

    func pid(clientAddress: String, clientPort: Int, proxyAddress: String, proxyPort: Int) -> Int32? {
        guard let client = IPAddress(clientAddress), let proxy = IPAddress(proxyAddress),
              (1...65535).contains(clientPort), (1...65535).contains(proxyPort)
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var owner: Int32?

        let count = listPIDs()
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            if owns(pid: pid, client: client, clientPort: clientPort, proxy: proxy, proxyPort: proxyPort) {
                guard owner == nil || owner == pid else { return nil }
                owner = pid
            }
        }
        return owner
    }

    private func listPIDs() -> Int {
        while true {
            let written = pids.withUnsafeMutableBytes {
                Int(proc_listallpids($0.baseAddress, Int32($0.count)))
            }
            guard written > 0 else { return 0 }
            if written < pids.count { return written }
            pids.append(contentsOf: repeatElement(0, count: pids.count))
        }
    }

    private func listDescriptors(pid: Int32) -> Int {
        while true {
            let written = descriptors.withUnsafeMutableBytes {
                Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)))
            }
            guard written > 0 else { return 0 }
            let count = written / MemoryLayout<proc_fdinfo>.stride
            if count < descriptors.count { return count }
            descriptors.append(contentsOf: repeatElement(proc_fdinfo(), count: descriptors.count))
        }
    }

    private func owns(pid: Int32, client: IPAddress, clientPort: Int, proxy: IPAddress, proxyPort: Int) -> Bool {
        let count = listDescriptors(pid: pid)
        for index in 0..<count {
            let descriptor = descriptors[index]
            guard descriptor.proc_fdtype == PROX_FDTYPE_SOCKET else { continue }
            var info = socket_fdinfo()
            let written = Int(proc_pidfdinfo(
                pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO,
                &info, Int32(MemoryLayout<socket_fdinfo>.size)
            ))
            guard written == MemoryLayout<socket_fdinfo>.size,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_ESTABLISHED
            else { continue }
            let socket = info.psi.soi_proto.pri_tcp.tcpsi_ini
            guard Self.port(socket.insi_lport) == clientPort,
                  Self.port(socket.insi_fport) == proxyPort
            else { continue }

            if socket.insi_vflag & UInt8(INI_IPV4) != 0 {
                if client == .ipv4(UInt32(bigEndian: socket.insi_laddr.ina_46.i46a_addr4.s_addr)),
                   proxy == .ipv4(UInt32(bigEndian: socket.insi_faddr.ina_46.i46a_addr4.s_addr)) {
                    return true
                }
            } else if socket.insi_vflag & UInt8(INI_IPV6) != 0 {
                if client == IPAddress(socket.insi_laddr.ina_6),
                   proxy == IPAddress(socket.insi_faddr.ina_6) {
                    return true
                }
            }
        }
        return false
    }

    private static func port(_ raw: Int32) -> Int {
        Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)))
    }
}

private enum IPAddress: Equatable {
    case ipv4(UInt32)
    case ipv6(UInt32, UInt32, UInt32, UInt32, scope: UInt32)

    init?(_ text: String) {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, text, &ipv4) == 1 {
            self = .ipv4(UInt32(bigEndian: ipv4.s_addr))
            return
        }
        let address: String
        var scope: UInt32 = 0
        if let separator = text.firstIndex(of: "%") {
            address = String(text[..<separator])
            let zone = String(text[text.index(after: separator)...])
            scope = UInt32(zone) ?? if_nametoindex(zone)
            guard scope != 0 else { return nil }
        } else {
            address = text
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return nil }
        self.init(ipv6, scope: scope)
    }

    init(_ address: in6_addr, scope: UInt32 = 0) {
        self = withUnsafeBytes(of: address) { bytes in
            var first = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            let second = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let third = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            let fourth = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            if first == 0, second == 0, third == 0xffff { return .ipv4(fourth) }
            var resolvedScope = scope
            if first & 0xffc00000 == 0xfe800000 {
                // Darwin embeds the link-local interface index in the kernel address.
                if resolvedScope == 0 { resolvedScope = first & 0xffff }
                first &= 0xffff0000
            }
            return .ipv6(first, second, third, fourth, scope: resolvedScope)
        }
    }
}
