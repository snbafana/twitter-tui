import Darwin
import Foundation

struct LocalhostCallbackServer {
    func waitForCallback(redirectURI: String, timeoutSeconds: Int = 180) async throws -> OAuthCallbackPayload {
        guard let redirect = URL(string: redirectURI),
              let host = redirect.host(),
              let port = redirect.port,
              host == "127.0.0.1" || host == "localhost"
        else {
            throw AuthError.invalidCallbackURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let payload = try receiveCallback(host: host, port: port, timeoutSeconds: timeoutSeconds)
                    continuation.resume(returning: payload)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct OAuthCallbackPayload: Equatable {
    var code: String?
    var state: String?
    var error: String?
    var errorDescription: String?
}

private func receiveCallback(host: String, port: Int, timeoutSeconds: Int) throws -> OAuthCallbackPayload {
    let server = socket(AF_INET, SOCK_STREAM, 0)
    guard server >= 0 else {
        throw LocalhostCallbackError.socketFailed
    }
    defer {
        close(server)
    }

    var reuse = 1
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr(host == "localhost" ? "127.0.0.1" : host))

    let bindStatus = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(server, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindStatus == 0 else {
        throw LocalhostCallbackError.bindFailed(port)
    }

    guard listen(server, 1) == 0 else {
        throw LocalhostCallbackError.listenFailed
    }

    var readSet = fd_set()
    fdZero(&readSet)
    fdSet(server, set: &readSet)
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    let ready = select(server + 1, &readSet, nil, nil, &timeout)
    guard ready > 0 else {
        throw LocalhostCallbackError.timedOut
    }

    let client = accept(server, nil, nil)
    guard client >= 0 else {
        throw LocalhostCallbackError.acceptFailed
    }
    defer {
        close(client)
    }

    var buffer = [UInt8](repeating: 0, count: 8192)
    let bytesRead = read(client, &buffer, buffer.count)
    guard bytesRead > 0 else {
        throw LocalhostCallbackError.readFailed
    }

    let request = String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
    let payload = try LocalhostCallbackParser.parse(request)
    try writeCallbackResponse(payload, to: client)
    if let error = payload.error {
        throw LocalhostCallbackError.authorizationDenied(error, payload.errorDescription ?? "")
    }
    return payload
}

struct LocalhostCallbackParser {
    static func parse(_ request: String) throws -> OAuthCallbackPayload {
        guard let requestLine = request.split(separator: "\r\n", maxSplits: 1).first else {
            throw LocalhostCallbackError.malformedRequest
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/") else {
            throw LocalhostCallbackError.malformedRequest
        }

        guard let url = URL(string: "http://localhost\(parts[1])"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw LocalhostCallbackError.malformedRequest
        }

        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        return OAuthCallbackPayload(
            code: values["code"],
            state: values["state"],
            error: values["error"],
            errorDescription: values["error_description"]
        )
    }
}

private func writeCallbackResponse(_ payload: OAuthCallbackPayload, to client: Int32) throws {
    let body: String
    let statusLine: String
    if let error = payload.error {
        statusLine = "HTTP/1.1 400 Bad Request\r\n"
        body = "X authorization failed: \(error) \(payload.errorDescription ?? "")"
    } else {
        statusLine = "HTTP/1.1 200 OK\r\n"
        body = "Authorization complete. You can return to XUI."
    }

    let response = """
    \(statusLine)Content-Type: text/plain; charset=utf-8\r
    Content-Length: \(body.utf8.count)\r
    Connection: close\r
    \r
    \(body)
    """
    _ = response.withCString { pointer in
        write(client, pointer, strlen(pointer))
    }
}

private enum LocalhostCallbackError: Error, LocalizedError {
    case socketFailed
    case bindFailed(Int)
    case listenFailed
    case acceptFailed
    case readFailed
    case malformedRequest
    case timedOut
    case authorizationDenied(String, String)

    var errorDescription: String? {
        switch self {
        case .socketFailed:
            "Could not create localhost callback socket."
        case let .bindFailed(port):
            "Could not bind localhost callback on port \(port)."
        case .listenFailed:
            "Could not listen for localhost callback."
        case .acceptFailed:
            "Could not accept localhost callback."
        case .readFailed:
            "Could not read localhost callback."
        case .malformedRequest:
            "Received malformed OAuth callback."
        case .timedOut:
            "Timed out waiting for OAuth callback."
        case let .authorizationDenied(error, description):
            "Authorization denied: \(error) \(description)"
        }
    }
}

private func fdZero(_ set: inout fd_set) {
    set = fd_set()
}

private func fdSet(_ fd: Int32, set: inout fd_set) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    let mask = Int32(1 << bitOffset)

    switch intOffset {
    case 0: set.fds_bits.0 |= mask
    case 1: set.fds_bits.1 |= mask
    case 2: set.fds_bits.2 |= mask
    case 3: set.fds_bits.3 |= mask
    case 4: set.fds_bits.4 |= mask
    case 5: set.fds_bits.5 |= mask
    case 6: set.fds_bits.6 |= mask
    case 7: set.fds_bits.7 |= mask
    case 8: set.fds_bits.8 |= mask
    case 9: set.fds_bits.9 |= mask
    case 10: set.fds_bits.10 |= mask
    case 11: set.fds_bits.11 |= mask
    case 12: set.fds_bits.12 |= mask
    case 13: set.fds_bits.13 |= mask
    case 14: set.fds_bits.14 |= mask
    case 15: set.fds_bits.15 |= mask
    case 16: set.fds_bits.16 |= mask
    case 17: set.fds_bits.17 |= mask
    case 18: set.fds_bits.18 |= mask
    case 19: set.fds_bits.19 |= mask
    case 20: set.fds_bits.20 |= mask
    case 21: set.fds_bits.21 |= mask
    case 22: set.fds_bits.22 |= mask
    case 23: set.fds_bits.23 |= mask
    case 24: set.fds_bits.24 |= mask
    case 25: set.fds_bits.25 |= mask
    case 26: set.fds_bits.26 |= mask
    case 27: set.fds_bits.27 |= mask
    case 28: set.fds_bits.28 |= mask
    case 29: set.fds_bits.29 |= mask
    case 30: set.fds_bits.30 |= mask
    case 31: set.fds_bits.31 |= mask
    default: break
    }
}
