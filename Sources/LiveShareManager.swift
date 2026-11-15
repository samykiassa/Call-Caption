import Foundation
import Network
import AppKit
import Security
import Darwin
import os

public struct LiveCaptionEvent: Codable, Sendable, Equatable {
    public let id: String
    public let timestamp: String
    public let speaker: String
    public let originalText: String
    public let translatedText: String
    public let sourceLangCode: String
    public let targetLangCode: String
    public let isFinal: Bool
    public let isUntranslated: Bool

    public init(
        id: String = UUID().uuidString,
        timestamp: String,
        speaker: String,
        originalText: String,
        translatedText: String,
        sourceLangCode: String,
        targetLangCode: String,
        isFinal: Bool,
        isUntranslated: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.speaker = speaker
        self.originalText = originalText
        self.translatedText = translatedText
        self.sourceLangCode = sourceLangCode
        self.targetLangCode = targetLangCode
        self.isFinal = isFinal
        self.isUntranslated = isUntranslated
    }
}

public struct ParsedHTTPRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let host: String?
    public let hasProxyHeaders: Bool

    public init(method: String, path: String, host: String?, hasProxyHeaders: Bool = false) {
        self.method = method
        self.path = path
        self.host = host
        self.hasProxyHeaders = hasProxyHeaders
    }
}

public enum HTTPRouteAction: Sendable, Equatable {
    case serveHTML
    case serveAPIState
    case serveSSE
    case forbidden
    case notFound
    case methodNotAllowed
}

public final class LiveShareManager: @unchecked Sendable {
    public static let shared = LiveShareManager()

    public static let stateDidChangeNotification = Notification.Name("LiveShareManagerStateDidChangeNotification")
    public static let urlDidUpdateNotification = Notification.Name("LiveShareManagerURLDidUpdateNotification")

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()
    private static let formatterLock = OSAllocatedUnfairLock()

    public static let sshTunnelRegex = try! NSRegularExpression(
        pattern: #"https://(?!admin\.|www\.|docs\.|api\.)(?:[a-zA-Z0-9-]+\.)+(?:lhr\.life|lhr\.rocks|localhost\.run)(?!(?:\.[a-zA-Z0-9-]+)|[a-zA-Z0-9-])"#
    )

    public static func extractTunnelURL(
        from text: String,
        regex: NSRegularExpression = sshTunnelRegex
    ) -> URL? {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, options: [], range: nsRange).last,
              let range = Range(match.range, in: text) else {
            return nil
        }
        return URL(string: String(text[range]))
    }

    private struct State: Sendable {
        var isSharing: Bool = false
        var sessionEpoch: UInt64 = 0
        var clearGeneration: UInt64 = 0
        var sessionToken: String = ""
        var sessionKeyFragment: String = ""
        var sessionCrypto: LiveShareCrypto? = nil
        var port: UInt16 = 0
        var localIP: String = "127.0.0.1"
        var localURL: URL? = nil
        var publicURL: URL? = nil
        var tunnelHost: String? = nil
        var isTunnelStarting: Bool = false
        var tunnelError: String? = nil
        var activeClientCount: Int = 0
        var isPaused: Bool = false
        var history: [LiveCaptionEvent] = []
        var callerPartial: LiveCaptionEvent? = nil
        var micPartial: LiveCaptionEvent? = nil
    }

    private final class SSEClient: @unchecked Sendable {
        let id: ObjectIdentifier
        let connection: NWConnection
        let encryptPayloads: Bool
        var pendingSends: Int = 0

        init(connection: NWConnection, encryptPayloads: Bool) {
            self.id = ObjectIdentifier(connection)
            self.connection = connection
            self.encryptPayloads = encryptPayloads
        }
    }

    private final class HeaderTimeoutToken: @unchecked Sendable {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) {
            self.item = item
        }
        func cancel() {
            item.cancel()
        }
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let maxSSEClients = 20
    private let maxPendingSendsPerClient = 8
    private let maxActiveHTTPConnections = 64

    private let jsonEncoder = JSONEncoder()
    private var listener: NWListener?
    private var activeHTTPConnections: [ObjectIdentifier: NWConnection] = [:]
    private var sseClients: [ObjectIdentifier: SSEClient] = [:]
    private var pendingSSEHandshakes: [ObjectIdentifier: NWConnection] = [:]
    private var sseStreamSequence: UInt64 = 0
    private var stateSequence: UInt64 = 0
    private var tunnelProcess: Process?
    private var tunnelPipe: Pipe?
    private var tunnelGeneration: UInt64 = 0
    private var tunnelOutputBuffer: String = ""
    private var tunnelPartialUTF8Data = Data()
    private var tunnelConnectedUptime: TimeInterval = 0
    private var tunnelTimeoutWorkItem: DispatchWorkItem?
    private var tunnelRestartWorkItem: DispatchWorkItem?
    private var tunnelStabilityWorkItem: DispatchWorkItem?
    private var tunnelRestartAttempts: Int = 0
    private var pingTimer: DispatchSourceTimer?
    private let serverQueue = DispatchQueue(label: "com.callcaption.liveshare.server", qos: .userInitiated)
    private let serverQueueKey = DispatchSpecificKey<Void>()

    public var isSharing: Bool {
        lock.withLock { $0.isSharing }
    }

    public var publicShareURL: URL? {
        lock.withLock { $0.publicURL }
    }

    public var localShareURL: URL? {
        lock.withLock { $0.localURL }
    }

    public var displayLANURL: URL? {
        localShareURL
    }

    public var effectiveShareURL: URL? {
        lock.withLock { $0.publicURL ?? $0.localURL }
    }

    public var isTunnelStarting: Bool {
        lock.withLock { $0.isTunnelStarting }
    }

    public var tunnelError: String? {
        lock.withLock { $0.tunnelError }
    }

    public var activeClientCount: Int {
        lock.withLock { $0.activeClientCount }
    }

    private init() {
        serverQueue.setSpecific(key: serverQueueKey, value: ())
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stopSharingSynchronously()
        }
    }


    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1"
    }

    public static func buildLocalShareURL(
        host: String,
        port: UInt16,
        sessionToken: String,
        sessionKeyFragment: String
    ) -> URL? {
        let isLoopback = isLoopbackHost(host)
        let fragment = (isLoopback && !sessionKeyFragment.isEmpty) ? "#\(sessionKeyFragment)" : ""
        let formattedHost: String
        if host.contains(":") && !host.hasPrefix("[") {
            formattedHost = "[\(host)]"
        } else {
            formattedHost = host
        }
        return URL(string: "http://\(formattedHost):\(port)/s/\(sessionToken)\(fragment)")
    }


    public static func generateSessionToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public static func parseHTTPRequest(_ raw: String) -> ParsedHTTPRequest? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.utf8.contains(0x0D) else { return nil }
        guard let firstLineEnd = normalized.range(of: "\n") else { return nil }
        let firstLine = String(normalized[..<firstLineEnd.lowerBound])
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let fullPath = String(parts[1])
        let cleanPath = fullPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? fullPath

        var hostHeader: String? = nil
        var hasProxyHeaders = false
        let lines = normalized.components(separatedBy: "\n")
        for rawLine in lines.dropFirst() {
            if rawLine.isEmpty { break }
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty { return nil }
            let lowerLine = line.lowercased()
            if lowerLine.hasPrefix("host:") {
                if hostHeader != nil { return nil }
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("["), let closing = value.firstIndex(of: "]") {
                    hostHeader = String(value[...closing]).lowercased()
                } else {
                    hostHeader = value.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased()
                }
            } else if lowerLine.hasPrefix("x-forwarded-for:")
                || lowerLine.hasPrefix("x-forwarded-host:")
                || lowerLine.hasPrefix("forwarded:") {
                hasProxyHeaders = true
            }
        }
        return ParsedHTTPRequest(method: method, path: cleanPath, host: hostHeader, hasProxyHeaders: hasProxyHeaders)
    }

    public static func isAllowedHost(
        _ host: String?,
        localIP: String,
        allowLAN: Bool,
        tunnelHost: String?
    ) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        if h == "127.0.0.1" || h == "localhost" || h == "[::1]" {
            return true
        }
        if allowLAN && h == localIP.lowercased() {
            return true
        }
        if let th = tunnelHost?.lowercased(), h == th {
            return true
        }
        return false
    }

    public static func evaluateRoute(
        request: ParsedHTTPRequest,
        sessionToken: String,
        localIP: String,
        allowLAN: Bool,
        tunnelHost: String?
    ) -> HTTPRouteAction {
        guard !sessionToken.isEmpty else { return .notFound }
        guard isAllowedHost(request.host, localIP: localIP, allowLAN: allowLAN, tunnelHost: tunnelHost) else {
            return .forbidden
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            return .methodNotAllowed
        }

        let basePrefix = "/s/\(sessionToken)"
        if request.path == basePrefix || request.path == "\(basePrefix)/" {
            return .serveHTML
        } else if request.path == "\(basePrefix)/events" {
            return request.method == "HEAD" ? .methodNotAllowed : .serveSSE
        } else if request.path == "\(basePrefix)/api/state" {
            return .serveAPIState
        } else {
            return .notFound
        }
    }


    public func startSharing() {
        let token = Self.generateSessionToken()
        let crypto = LiveShareCrypto()
        let keyFragment = crypto.keyFragment
        let capturedEpoch: UInt64? = lock.withLock { state -> UInt64? in
            guard !state.isSharing else { return nil }
            state.isSharing = true
            state.sessionEpoch &+= 1
            state.clearGeneration = 0
            state.sessionToken = token
            state.sessionKeyFragment = keyFragment
            state.sessionCrypto = crypto
            state.port = 0
            state.isTunnelStarting = AppSettings.shared.liveShareUseExternalTunnel
            state.tunnelError = nil
            state.isPaused = false
            state.publicURL = nil
            state.tunnelHost = nil
            state.localURL = nil
            state.history.removeAll()
            state.callerPartial = nil
            state.micPartial = nil
            return state.sessionEpoch
        }
        guard let epoch = capturedEpoch else { return }

        notifyStateChange()

        serverQueue.async { [weak self] in
            self?.startLocalServerOnQueue(epoch: epoch)
        }
    }

    @discardableResult
    private func resetSharingState() -> Bool {
        lock.withLock { state -> Bool in
            guard state.isSharing else { return false }
            state.isSharing = false
            state.sessionEpoch &+= 1
            state.clearGeneration = 0
            state.sessionToken = ""
            state.sessionKeyFragment = ""
            state.sessionCrypto = nil
            state.port = 0
            state.isTunnelStarting = false
            state.tunnelError = nil
            state.publicURL = nil
            state.tunnelHost = nil
            state.localURL = nil
            state.activeClientCount = 0
            state.isPaused = false
            state.history.removeAll()
            state.callerPartial = nil
            state.micPartial = nil
            return true
        }
    }

    public func stopSharing() {
        guard resetSharingState() else { return }

        serverQueue.async { [weak self] in
            self?.tearDownServerAndTunnelOnQueue()
        }

        notifyStateChange()
    }

    public func stopSharingSynchronously() {
        let wasSharing = resetSharingState()
        let work = { [weak self] in
            self?.tearDownServerAndTunnelOnQueue(forceKillSynchronously: true)
        }
        if DispatchQueue.getSpecific(key: serverQueueKey) != nil {
            work()
        } else {
            serverQueue.sync(execute: work)
        }
        if wasSharing {
            notifyStateChange()
        }
    }

    private func tearDownServerAndTunnelOnQueue(forceKillSynchronously: Bool = false) {
        stopHeartbeatOnQueue()

        terminateTunnelProcessOnQueue(forceKillSynchronously: forceKillSynchronously)
        tunnelRestartAttempts = 0

        for (_, client) in sseClients {
            client.connection.stateUpdateHandler = nil
            client.connection.cancel()
        }
        sseClients.removeAll()
        for (_, conn) in pendingSSEHandshakes {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        pendingSSEHandshakes.removeAll()
        for (_, conn) in activeHTTPConnections {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        activeHTTPConnections.removeAll()
        sseStreamSequence = 0
        stateSequence = 0

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }


    private func startLocalServerOnQueue(epoch: UInt64) {
        tearDownServerAndTunnelOnQueue()
        tunnelRestartAttempts = 0

        let isStillValid = lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
        guard isStillValid else { return }

        let allowLAN = AppSettings.shared.allowLANShare
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false

        if !allowLAN {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        }

        guard let validListener = try? NWListener(using: parameters) else {
            AppLog.liveShare.error("Failed to create NWListener")
            stopSharing()
            return
        }

        self.listener = validListener

        validListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            let stillActive = self.lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
            guard stillActive else {
                validListener.cancel()
                return
            }

            switch state {
            case .ready:
                guard let boundPort = validListener.port?.rawValue, boundPort > 0 else {
                    self.stopSharing()
                    return
                }
                AppLog.liveShare.info("Live Share server listening on port \(boundPort, privacy: .public) (LAN: \(allowLAN, privacy: .public))")
                self.setupLocalAndTunnelURLsOnQueue(port: boundPort, allowLAN: allowLAN, epoch: epoch)
            case .failed(let error):
                AppLog.liveShare.error("NWListener failed: \(error.localizedDescription, privacy: .public)")
                self.stopSharing()
            default:
                break
            }
        }

        validListener.newConnectionHandler = { [weak self] connection in
            self?.handleIncomingConnectionOnQueue(connection, epoch: epoch)
        }

        validListener.start(queue: serverQueue)
    }

    private func setupLocalAndTunnelURLsOnQueue(port: UInt16, allowLAN: Bool, epoch: UInt64) {
        let detectedIP = allowLAN ? (Self.getLocalIPAddress() ?? "127.0.0.1") : "127.0.0.1"
        let updated = lock.withLock { state -> Bool in
            guard state.isSharing && state.sessionEpoch == epoch else { return false }
            state.port = port
            state.localIP = detectedIP
            state.localURL = Self.buildLocalShareURL(
                host: detectedIP,
                port: port,
                sessionToken: state.sessionToken,
                sessionKeyFragment: state.sessionKeyFragment
            )
            return true
        }
        guard updated else { return }

        notifyStateChange()
        startTunnelProcessOnQueue(port: port, epoch: epoch)
    }

    private static func isLoopbackEndpoint(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let addr):
            return addr.rawValue.first == 127
        case .ipv6(let addr):
            if addr == .loopback { return true }
            let bytes = addr.rawValue
            return bytes.count == 16 && bytes.starts(with: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127])
        case .name(let name, _):
            return isLoopbackHost(name)
        @unknown default:
            return false
        }
    }

    private func untrackHTTPConnectionOnQueue(_ connection: NWConnection) {
        activeHTTPConnections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func handleIncomingConnectionOnQueue(_ connection: NWConnection, epoch: UInt64) {
        let isStillValid = lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
        guard isStillValid, activeHTTPConnections.count < maxActiveHTTPConnections else {
            connection.cancel()
            return
        }

        activeHTTPConnections[ObjectIdentifier(connection)] = connection
        connection.start(queue: serverQueue)

        let timeoutItem = DispatchWorkItem { [weak self, weak connection] in
            guard let connection = connection else { return }
            self?.untrackHTTPConnectionOnQueue(connection)
            connection.cancel()
        }
        serverQueue.asyncAfter(deadline: .now() + 10.0, execute: timeoutItem)

        receiveHTTPHeaderOnQueue(connection: connection, accumulated: Data(), timeoutItem: HeaderTimeoutToken(timeoutItem), epoch: epoch)
    }

    private func receiveHTTPHeaderOnQueue(
        connection: NWConnection,
        accumulated: Data,
        timeoutItem: HeaderTimeoutToken,
        epoch: UInt64
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - accumulated.count) { [weak self] content, _, isComplete, error in
            guard let self = self else {
                timeoutItem.cancel()
                connection.cancel()
                return
            }
            if error != nil {
                timeoutItem.cancel()
                self.untrackHTTPConnectionOnQueue(connection)
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data = content {
                buffer.append(data)
            }

            let requestString = String(decoding: buffer, as: UTF8.self)
            if requestString.contains("\r\n\r\n") || requestString.contains("\n\n") {
                timeoutItem.cancel()
                self.untrackHTTPConnectionOnQueue(connection)
                self.routeHTTPRequestOnQueue(request: requestString, connection: connection, epoch: epoch)
            } else if isComplete || buffer.count >= 8192 {
                timeoutItem.cancel()
                self.untrackHTTPConnectionOnQueue(connection)
                connection.cancel()
            } else {
                self.receiveHTTPHeaderOnQueue(connection: connection, accumulated: buffer, timeoutItem: timeoutItem, epoch: epoch)
            }
        }
    }

    private func routeHTTPRequestOnQueue(request: String, connection: NWConnection, epoch: UInt64) {
        guard let parsed = Self.parseHTTPRequest(request) else {
            sendSimpleResponse(connection: connection, status: "400 Bad Request", body: "Bad Request")
            return
        }

        let (isSharingNow, token, localIP, tunnelHost) = lock.withLock { state -> (Bool, String, String, String?) in
            guard state.isSharing && state.sessionEpoch == epoch else {
                return (false, "", "127.0.0.1", nil)
            }
            return (true, state.sessionToken, state.localIP, state.tunnelHost)
        }
        guard isSharingNow else {
            connection.cancel()
            return
        }

        let action = Self.evaluateRoute(
            request: parsed,
            sessionToken: token,
            localIP: localIP,
            allowLAN: AppSettings.shared.allowLANShare,
            tunnelHost: tunnelHost
        )

        let host = parsed.host?.lowercased()
        let isLoopbackHeader = host.map { Self.isLoopbackHost($0) } ?? false
        let isTunnelHeader = tunnelHost.map { host == $0.lowercased() } ?? false
        let arrivedOnLoopbackSocket = Self.isLoopbackEndpoint(connection.currentPath?.localEndpoint)
            || Self.isLoopbackEndpoint(connection.currentPath?.remoteEndpoint)
        let includeBody = parsed.method != "HEAD"

        // Prevent tunnel intermediaries or local loopback clients from downgrading payload
        // encryption by spoofing the LAN Host header.
        if !isLoopbackHeader && !isTunnelHeader && (arrivedOnLoopbackSocket || parsed.hasProxyHeaders) {
            sendSimpleResponse(connection: connection, status: "403 Forbidden", body: "Forbidden", includeBody: includeBody)
            return
        }
        let encryptPayloads = isLoopbackHeader || isTunnelHeader || arrivedOnLoopbackSocket

        switch action {
        case .serveHTML:
            handleServeHTMLOnQueue(connection, token: token, encryptPayloads: encryptPayloads, includeBody: includeBody)
        case .serveAPIState:
            handleAPIStateOnQueue(connection, encryptPayloads: encryptPayloads, includeBody: includeBody, epoch: epoch)
        case .serveSSE:
            handleSSEConnectionOnQueue(connection, encryptPayloads: encryptPayloads, epoch: epoch)
        case .forbidden:
            sendSimpleResponse(connection: connection, status: "403 Forbidden", body: "Forbidden", includeBody: includeBody)
        case .notFound:
            sendSimpleResponse(connection: connection, status: "404 Not Found", body: "Not Found", includeBody: includeBody)
        case .methodNotAllowed:
            sendSimpleResponse(connection: connection, status: "405 Method Not Allowed", body: "Method Not Allowed", includeBody: includeBody)
        }
    }

    private func sendSimpleResponse(connection: NWConnection, status: String, body: String, includeBody: Bool = true) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var fullData = Data(header.utf8)
        if includeBody {
            fullData.append(bodyData)
        }
        connection.send(content: fullData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func handleServeHTMLOnQueue(_ connection: NWConnection, token: String, encryptPayloads: Bool, includeBody: Bool = true) {
        let html = ReceiverWebAppHTML.html(forToken: token, encryptPayloads: encryptPayloads)
        let data = Data(html.utf8)
        let csp = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: \(csp)\r\nCross-Origin-Resource-Policy: same-origin\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nCache-Control: no-cache, no-store, must-revalidate\r\n\r\n"

        var fullData = Data(header.utf8)
        if includeBody {
            fullData.append(data)
        }

        connection.send(content: fullData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private struct APIStateResponse: Codable, Sendable {
        let foreignLanguage: String
        let mainLanguage: String
        let callerPartial: LiveCaptionEvent?
        let micPartial: LiveCaptionEvent?
        let history: [LiveCaptionEvent]
        let isPaused: Bool
        let viewerCount: Int
        let clearEpoch: UInt64
    }

    private func handleAPIStateOnQueue(_ connection: NWConnection, encryptPayloads: Bool, includeBody: Bool = true, epoch: UInt64) {
        let (responseModel, crypto) = lock.withLock { state -> (APIStateResponse?, LiveShareCrypto?) in
            guard state.isSharing && state.sessionEpoch == epoch else { return (nil, nil) }
            let model = APIStateResponse(
                foreignLanguage: AppSettings.shared.foreignLanguageCode,
                mainLanguage: AppSettings.shared.mainLanguageCode,
                callerPartial: state.callerPartial,
                micPartial: state.micPartial,
                history: Array(state.history.suffix(60)),
                isPaused: state.isPaused,
                viewerCount: state.activeClientCount,
                clearEpoch: state.clearGeneration
            )
            return (model, state.sessionCrypto)
        }

        guard let responseModel else {
            connection.cancel()
            return
        }

        guard let jsonData = try? jsonEncoder.encode(responseModel) else {
            connection.cancel()
            return
        }
        let responseData: Data?
        if encryptPayloads {
            stateSequence &+= 1
            responseData = encryptPayload(jsonData, type: "state", sequence: stateSequence, crypto: crypto)
        } else {
            responseData = jsonData
        }
        guard let responseData else {
            connection.cancel()
            return
        }

        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(responseData.count)\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nCross-Origin-Resource-Policy: same-origin\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var fullData = Data(header.utf8)
        if includeBody {
            fullData.append(responseData)
        }

        connection.send(content: fullData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func handleSSEConnectionOnQueue(_ connection: NWConnection, encryptPayloads: Bool, epoch: UInt64) {
        guard sseClients.count + pendingSSEHandshakes.count < maxSSEClients else {
            sendSimpleResponse(connection: connection, status: "503 Service Unavailable", body: "Server busy")
            return
        }

        let headerData = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache, no-transform\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nCross-Origin-Resource-Policy: same-origin\r\nConnection: keep-alive\r\n\r\n".utf8)

        let client = SSEClient(connection: connection, encryptPayloads: encryptPayloads)
        let id = client.id
        pendingSSEHandshakes[id] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.pendingSSEHandshakes.removeValue(forKey: id)
                self?.removeSSEClientOnQueue(id: id)
            default:
                break
            }
        }

        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            let wasPending = self.pendingSSEHandshakes.removeValue(forKey: id) != nil
            guard wasPending, error == nil else {
                connection.stateUpdateHandler = nil
                connection.cancel()
                return
            }

            let isStillValid = self.lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
            guard isStillValid, self.sseClients.count < self.maxSSEClients else {
                connection.stateUpdateHandler = nil
                connection.cancel()
                return
            }

            self.sseClients[id] = client
            self.updateActiveClientCountOnQueue(excluding: id)
            self.startHeartbeatIfNeededOnQueue()
            self.receiveSSEDrainOnQueue(connection: connection, clientID: id)

            let (historySnapshot, callerPart, micPart, paused, viewerCount, clearGen, crypto) = self.lock.withLock {
                (
                    Array($0.history.suffix(50)),
                    $0.callerPartial,
                    $0.micPartial,
                    $0.isPaused,
                    $0.activeClientCount,
                    $0.clearGeneration,
                    $0.sessionCrypto
                )
            }
            var initialBurst = Data()
            // Send `status` before `history` so `clearEpoch` changes clear stale viewer cards first.
            if let statusData = try? self.jsonEncoder.encode(StatusEvent(paused: paused, viewerCount: viewerCount, clearEpoch: clearGen)),
               let statusPayload = self.payloadDataOnQueue(statusData, encrypt: client.encryptPayloads, type: "status", crypto: crypto) {
                initialBurst.append(Self.makeSSEFrame(event: "status", payload: statusPayload))
            }
            if let histData = try? self.jsonEncoder.encode(historySnapshot),
               let histPayload = self.payloadDataOnQueue(histData, encrypt: client.encryptPayloads, type: "history", crypto: crypto) {
                initialBurst.append(Self.makeSSEFrame(event: "history", payload: histPayload))
            }
            if let cp = callerPart, let d = try? self.jsonEncoder.encode(cp),
               let payload = self.payloadDataOnQueue(d, encrypt: client.encryptPayloads, type: "caption", crypto: crypto) {
                initialBurst.append(Self.makeSSEFrame(event: "caption", payload: payload))
            }
            if let mp = micPart, let d = try? self.jsonEncoder.encode(mp),
               let payload = self.payloadDataOnQueue(d, encrypt: client.encryptPayloads, type: "caption", crypto: crypto) {
                initialBurst.append(Self.makeSSEFrame(event: "caption", payload: payload))
            }
            if !initialBurst.isEmpty {
                self.sendSSEPayloadOnQueue(initialBurst, to: client)
            }
        })
    }

    private func receiveSSEDrainOnQueue(connection: NWConnection, clientID: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self, weak connection] content, _, isComplete, error in
            guard let self = self else { return }
            if error != nil || isComplete {
                self.removeSSEClientOnQueue(id: clientID)
                return
            }
            if let data = content, !data.isEmpty {
                self.removeSSEClientOnQueue(id: clientID)
                return
            }
            guard let connection = connection, self.sseClients[clientID] != nil else { return }
            self.receiveSSEDrainOnQueue(connection: connection, clientID: clientID)
        }
    }

    private func sendSSEPayloadOnQueue(_ data: Data, to client: SSEClient, isDroppable: Bool = false) {
        guard sseClients[client.id] != nil else { return }
        if isDroppable && client.pendingSends >= maxPendingSendsPerClient / 2 {
            return
        }
        if client.pendingSends >= maxPendingSendsPerClient {
            removeSSEClientOnQueue(id: client.id)
            return
        }
        client.pendingSends += 1
        let id = client.id
        client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if error != nil {
                self.removeSSEClientOnQueue(id: id)
            } else if let existing = self.sseClients[id] {
                existing.pendingSends = max(0, existing.pendingSends - 1)
            }
        })
    }

    private func removeSSEClientOnQueue(id: ObjectIdentifier) {
        if let client = sseClients.removeValue(forKey: id) {
            client.connection.stateUpdateHandler = nil
            client.connection.cancel()
            if sseClients.isEmpty {
                stopHeartbeatOnQueue()
            }
            updateActiveClientCountOnQueue()
        }
    }

    private func updateActiveClientCountOnQueue(excluding excludedClientID: ObjectIdentifier? = nil) {
        let count = sseClients.count
        let (changed, epoch) = lock.withLock { state -> (Bool, UInt64) in
            guard state.activeClientCount != count else { return (false, state.sessionEpoch) }
            state.activeClientCount = count
            return (state.isSharing, state.sessionEpoch)
        }
        if changed {
            sendStatusEventOnQueue(StatusEvent(viewerCount: count), epoch: epoch, excluding: excludedClientID)
            notifyStateChange()
        }
    }

    private func startHeartbeatIfNeededOnQueue() {
        guard pingTimer == nil, !sseClients.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: serverQueue)
        timer.schedule(deadline: .now() + 15.0, repeating: 15.0, leeway: .seconds(2))
        let pingData = Data(": ping\n\n".utf8)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.sseClients.isEmpty {
                self.stopHeartbeatOnQueue()
                return
            }
            for (_, client) in Array(self.sseClients) {
                self.sendSSEPayloadOnQueue(pingData, to: client)
            }
        }
        timer.resume()
        self.pingTimer = timer
    }

    private func stopHeartbeatOnQueue() {
        pingTimer?.cancel()
        pingTimer = nil
    }


    public func broadcastCaption(
        speaker: String,
        original: String,
        translated: String,
        sourceLangCode: String,
        targetLangCode: String,
        isFinal: Bool,
        isUntranslated: Bool = false,
        utteranceID: UUID = UUID()
    ) {
        guard isSharing else { return }

        if !AppSettings.shared.shareBothSpeakersOnLink && speaker.lowercased() == "caller" {
            return
        }

        let now = Date()
        let timeStr = Self.formatterLock.withLock {
            Self.timeFormatter.string(from: now)
        }

        let (event, epoch, clearGen, crypto): (LiveCaptionEvent?, UInt64, UInt64, LiveShareCrypto?) = lock.withLock { state -> (LiveCaptionEvent?, UInt64, UInt64, LiveShareCrypto?) in
            guard state.isSharing else { return (nil, 0, 0, nil) }
            if !AppSettings.shared.shareBothSpeakersOnLink && speaker.lowercased() == "caller" {
                return (nil, 0, 0, nil)
            }
            if isFinal {
                var eventToBroadcast = LiveCaptionEvent(
                    id: utteranceID.uuidString,
                    timestamp: timeStr,
                    speaker: speaker,
                    originalText: original,
                    translatedText: translated,
                    sourceLangCode: sourceLangCode,
                    targetLangCode: targetLangCode,
                    isFinal: true,
                    isUntranslated: isUntranslated
                )
                if let idx = state.history.firstIndex(where: { $0.id == eventToBroadcast.id }) {
                    let prev = state.history[idx]
                    eventToBroadcast = LiveCaptionEvent(
                        id: prev.id,
                        timestamp: prev.timestamp,
                        speaker: speaker,
                        originalText: original,
                        translatedText: translated,
                        sourceLangCode: sourceLangCode,
                        targetLangCode: targetLangCode,
                        isFinal: true,
                        isUntranslated: isUntranslated
                    )
                    state.history[idx] = eventToBroadcast
                } else {
                    state.history.append(eventToBroadcast)
                }

                if state.history.count > 100 {
                    state.history.removeFirst(state.history.count - 100)
                }
                if speaker.lowercased() == "caller" {
                    state.callerPartial = nil
                } else {
                    state.micPartial = nil
                }
                return (eventToBroadcast, state.sessionEpoch, state.clearGeneration, state.sessionCrypto)
            } else {
                if state.history.contains(where: { $0.id == utteranceID.uuidString }) {
                    return (nil, 0, 0, nil)
                }
                let partialEvent = LiveCaptionEvent(
                    id: utteranceID.uuidString,
                    timestamp: timeStr,
                    speaker: speaker,
                    originalText: original,
                    translatedText: translated,
                    sourceLangCode: sourceLangCode,
                    targetLangCode: targetLangCode,
                    isFinal: false,
                    isUntranslated: isUntranslated
                )
                if speaker.lowercased() == "caller" {
                    state.callerPartial = partialEvent
                } else {
                    state.micPartial = partialEvent
                }
                return (partialEvent, state.sessionEpoch, state.clearGeneration, state.sessionCrypto)
            }
        }

        guard let event else { return }

        serverQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.sseClients.isEmpty else { return }
            let stillValid = self.lock.withLock {
                $0.isSharing && $0.sessionEpoch == epoch && $0.clearGeneration == clearGen
            }
            guard stillValid else { return }
            guard let jsonData = try? self.jsonEncoder.encode(event) else { return }

            let clients = Array(self.sseClients.values)
            let needsPlain = clients.contains { !$0.encryptPayloads }
            let needsEncrypted = clients.contains { $0.encryptPayloads }

            let plainPayload: Data? = needsPlain
                ? Self.makeSSEFrame(event: "caption", payload: jsonData)
                : nil

            let encryptedPayload: Data?
            if needsEncrypted {
                self.sseStreamSequence &+= 1
                let seq = self.sseStreamSequence
                encryptedPayload = self.encryptPayload(jsonData, type: "caption", sequence: seq, crypto: crypto)
                    .map { Self.makeSSEFrame(event: "caption", payload: $0) }
            } else {
                encryptedPayload = nil
            }

            let isDroppable = !event.isFinal
            for client in clients {
                guard let payload = client.encryptPayloads ? encryptedPayload : plainPayload else { continue }
                self.sendSSEPayloadOnQueue(payload, to: client, isDroppable: isDroppable)
            }
        }
    }

    private static func makeSSEFrame(event: String, payload: Data) -> Data {
        var frame = Data(capacity: 15 + event.utf8.count + payload.count)
        frame.append(contentsOf: "event: ".utf8)
        frame.append(contentsOf: event.utf8)
        frame.append(contentsOf: "\ndata: ".utf8)
        frame.append(payload)
        frame.append(contentsOf: "\n\n".utf8)
        return frame
    }

    private func payloadDataOnQueue(_ data: Data, encrypt: Bool, type: String, crypto: LiveShareCrypto?) -> Data? {
        if encrypt {
            sseStreamSequence &+= 1
            return encryptPayload(data, type: type, sequence: sseStreamSequence, crypto: crypto)
        }
        return data
    }

    private func encryptPayload(_ data: Data, type: String, sequence: UInt64, crypto: LiveShareCrypto?) -> Data? {
        let resolvedCrypto = crypto ?? lock.withLock { $0.sessionCrypto }
        guard let resolvedCrypto else { return nil }
        return try? resolvedCrypto.seal(data, type: type, sequence: sequence)
    }

    private struct StatusEvent: Codable, Sendable {
        var paused: Bool? = nil
        var viewerCount: Int? = nil
        var clearCaller: Bool? = nil
        var clearAll: Bool? = nil
        var clearEpoch: UInt64? = nil
    }

    private func sendStatusEvent(_ status: StatusEvent, epoch: UInt64, excluding excludedClientID: ObjectIdentifier? = nil) {
        serverQueue.async { [weak self] in
            self?.sendStatusEventOnQueue(status, epoch: epoch, excluding: excludedClientID)
        }
    }

    private func sendStatusEventOnQueue(_ status: StatusEvent, epoch: UInt64, excluding excludedClientID: ObjectIdentifier? = nil) {
        guard !sseClients.isEmpty else { return }
        let crypto = lock.withLock { state -> LiveShareCrypto? in
            guard state.isSharing && state.sessionEpoch == epoch else { return nil }
            return state.sessionCrypto
        }
        guard lock.withLock({ $0.isSharing && $0.sessionEpoch == epoch }) else { return }
        guard let jsonData = try? jsonEncoder.encode(status) else { return }

        let clients = sseClients.values.filter { $0.id != excludedClientID }
        guard !clients.isEmpty else { return }
        let needsPlain = clients.contains { !$0.encryptPayloads }
        let needsEncrypted = clients.contains { $0.encryptPayloads }

        let plainPayload: Data? = needsPlain
            ? Self.makeSSEFrame(event: "status", payload: jsonData)
            : nil

        let encryptedPayload: Data?
        if needsEncrypted {
            sseStreamSequence &+= 1
            let seq = sseStreamSequence
            encryptedPayload = encryptPayload(jsonData, type: "status", sequence: seq, crypto: crypto)
                .map { Self.makeSSEFrame(event: "status", payload: $0) }
        } else {
            encryptedPayload = nil
        }

        for client in clients {
            guard let payload = client.encryptPayloads ? encryptedPayload : plainPayload else { continue }
            sendSSEPayloadOnQueue(payload, to: client)
        }
    }

    public func speakerSharingDidChange() {
        let shareCaller = AppSettings.shared.shareBothSpeakersOnLink
        guard !shareCaller else { return }
        let (changed, clearGen, shouldBroadcast, epoch) = lock.withLock { state -> (Bool, UInt64, Bool, UInt64) in
            let hadCallerData = state.history.contains { $0.speaker.lowercased() == "caller" }
                || state.callerPartial != nil
            state.history.removeAll { $0.speaker.lowercased() == "caller" }
            state.callerPartial = nil
            state.clearGeneration &+= 1
            return (hadCallerData, state.clearGeneration, state.isSharing, state.sessionEpoch)
        }
        if shouldBroadcast {
            sendStatusEvent(StatusEvent(clearCaller: true, clearEpoch: clearGen), epoch: epoch)
        }
        if changed {
            notifyStateChange()
        }
    }

    public func clearHistoryForPrivacy() {
        let (changed, clearGen, shouldBroadcast, epoch) = lock.withLock { state -> (Bool, UInt64, Bool, UInt64) in
            let hadData = !state.history.isEmpty || state.callerPartial != nil || state.micPartial != nil
            state.history.removeAll()
            state.callerPartial = nil
            state.micPartial = nil
            state.clearGeneration &+= 1
            return (hadData, state.clearGeneration, state.isSharing, state.sessionEpoch)
        }
        if shouldBroadcast {
            sendStatusEvent(StatusEvent(clearAll: true, clearEpoch: clearGen), epoch: epoch)
        }
        if changed {
            notifyStateChange()
        }
    }

    public func broadcastPauseState(_ paused: Bool) {
        let (changed, viewerCount, epoch) = lock.withLock { state -> (Bool, Int, UInt64) in
            guard state.isSharing, state.isPaused != paused else { return (false, 0, 0) }
            state.isPaused = paused
            return (true, state.activeClientCount, state.sessionEpoch)
        }
        guard changed else { return }
        sendStatusEvent(StatusEvent(paused: paused, viewerCount: viewerCount), epoch: epoch)
    }


    public static let pinnedSSHKnownHosts: String = """
    localhost.run,*.localhost.run,ssh.localhost.run,*.lhr.life ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILVqOuSMnyeGDVO1lG6EaG5In/dXABCchhmHKkuRU2s9
    localhost.run,*.localhost.run,ssh.localhost.run,*.lhr.life ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC3lJnhW1oCXuAYV9IBdcJA+Vx7AHL5S/ZQvV2fhceOAPgO2kNQZla6xvUwoE4iw8lYu3zoE1KtieCU9yInWOVI6W/wFaT/ETH1tn55T2FVsK/zaxPiHZVJGLPPdEEid0vS2p1JDfc9onZ0pNSHLl1QusIOeMUyZ2bUMMLLgw46KOT9S3s/LmxgoJ3PocVUn5rVXz/Dng7Y8jYNe4IFrZOAUsi7hNBa+OYja6ceefpDvNDEJ1BdhbYfGolBdNA7f+FNl0kfaWru4Cblr843wBe2ckO/sNqgeAMXO/qH+SSgQxUXF2AgAw+TGp3yCIyYoOPvOgvcPsQziJLmDbUuQpnH
    """ + "\n"

    public static func ensureSSHKnownHostsPopulated(at url: URL) throws {
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        let pinnedData = Data(pinnedSSHKnownHosts.utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            try AppPaths.writePrivateData(pinnedData, to: url)
        } else {
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if !existing.contains("AAAAC3NzaC1lZDI1NTE5AAAAILVqOuSMnyeGDVO1lG6EaG5In/dXABCchhmHKkuRU2s9") {
                let updated = pinnedSSHKnownHosts + (existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n" + existing)
                try AppPaths.writePrivateData(Data(updated.utf8), to: url)
            } else {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: url.path
                )
            }
        }
    }

    private static var sshKnownHostsFileURL: URL? {
        AppPaths.sshKnownHostsURL
    }

    private func startTunnelProcessOnQueue(port: UInt16, epoch: UInt64) {
        let isStillValid = lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
        guard isStillValid else { return }

        guard AppSettings.shared.liveShareUseExternalTunnel else {
            terminateTunnelProcessOnQueue()
            let updated = lock.withLock { state -> Bool in
                guard state.isSharing && state.sessionEpoch == epoch else { return false }
                state.isTunnelStarting = false
                state.tunnelError = nil
                state.publicURL = nil
                state.tunnelHost = nil
                return true
            }
            if updated { notifyStateChange() }
            return
        }

        guard let knownHostsURL = Self.sshKnownHostsFileURL else {
            markTunnelFailed(epoch: epoch, message: "Tunnel unavailable (no writable app-support directory)")
            return
        }
        do {
            try Self.ensureSSHKnownHostsPopulated(at: knownHostsURL)
        } catch {
            AppLog.liveShare.error("Failed to prepare SSH known-hosts path: \(error.localizedDescription, privacy: .public)")
            markTunnelFailed(epoch: epoch, message: "Tunnel unavailable")
            return
        }

        terminateTunnelProcessOnQueue()
        scheduleTunnelStartupTimeout(epoch: epoch, port: port)
        launchSSHTunnelOnQueue(port: port, epoch: epoch, knownHostsURL: knownHostsURL)
    }

    public static func buildSSHTunnelArguments(port: UInt16, knownHostsURL: URL) -> [String] {
        let quotedKnownHostsPath = "\"\(knownHostsURL.path.replacingOccurrences(of: "\"", with: ""))\""
        return [
            "-F", "/dev/null",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityFile=/dev/null",
            "-o", "IdentityAgent=none",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "PermitLocalCommand=no",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "CheckHostIP=no",
            "-o", "UserKnownHostsFile=\(quotedKnownHostsPath)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-R", "80:127.0.0.1:\(port)",
            "nokey@localhost.run"
        ]
    }

    private func launchSSHTunnelOnQueue(port: UInt16, epoch: UInt64, knownHostsURL: URL) {
        let isStillValid = lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
        guard isStillValid, AppSettings.shared.liveShareUseExternalTunnel else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.buildSSHTunnelArguments(port: port, knownHostsURL: knownHostsURL)
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        self.tunnelProcess = process
        self.tunnelPipe = pipe
        self.tunnelGeneration &+= 1
        let launchGen = self.tunnelGeneration
        self.tunnelOutputBuffer = ""
        self.tunnelPartialUTF8Data.removeAll(keepingCapacity: false)
        self.tunnelConnectedUptime = 0

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.serverQueue.async { [weak self] in
                guard let self = self,
                      self.tunnelGeneration == launchGen,
                      self.tunnelPipe != nil,
                      self.tunnelProcess != nil else { return }
                let chunk = Self.decodeUTF8Chunk(newData: data, remainder: &self.tunnelPartialUTF8Data)
                guard !chunk.isEmpty else { return }
                self.tunnelOutputBuffer.append(chunk)
                self.parseTunnelOutput(self.tunnelOutputBuffer, regex: Self.sshTunnelRegex, epoch: epoch)
                if self.tunnelOutputBuffer.count > 32768 {
                    self.tunnelOutputBuffer = String(self.tunnelOutputBuffer.suffix(8192))
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            let status = proc.terminationStatus
            self.serverQueue.async {
                guard self.tunnelGeneration == launchGen,
                      self.tunnelProcess != nil else { return }
                if let handle = self.tunnelPipe?.fileHandleForReading {
                    handle.readabilityHandler = nil
                    let fd = handle.fileDescriptor
                    let prevFlags = Darwin.fcntl(fd, F_GETFL)
                    if prevFlags != -1 {
                        _ = Darwin.fcntl(fd, F_SETFL, prevFlags | O_NONBLOCK)
                    }
                    var drained = Data()
                    var scratch = [UInt8](repeating: 0, count: 4096)
                    while drained.count < 32768 {
                        let n = Darwin.read(fd, &scratch, scratch.count)
                        if n <= 0 { break }
                        drained.append(contentsOf: scratch[..<n])
                    }
                    if prevFlags != -1 {
                        _ = Darwin.fcntl(fd, F_SETFL, prevFlags)
                    }
                    if !drained.isEmpty {
                        let chunk = Self.decodeUTF8Chunk(newData: drained, remainder: &self.tunnelPartialUTF8Data)
                        self.tunnelOutputBuffer.append(chunk)
                    }
                }
                let tailSnippet = String(self.tunnelOutputBuffer.suffix(300))
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                AppLog.liveShare.error("SSH tunnel process exited (status \(status, privacy: .public)): \(tailSnippet, privacy: .private)")
                self.tunnelGeneration &+= 1
                self.tunnelProcess = nil
                self.tunnelPipe = nil
                self.tunnelOutputBuffer = ""
                self.tunnelPartialUTF8Data.removeAll(keepingCapacity: false)
                self.handleTunnelTerminatedOnQueue(epoch: epoch)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            if self.tunnelGeneration == launchGen {
                self.tunnelGeneration &+= 1
                self.tunnelProcess = nil
                self.tunnelPipe = nil
            }
            AppLog.liveShare.error("Failed to launch SSH tunnel: \(error.localizedDescription, privacy: .public)")
            scheduleTunnelRestart(epoch: epoch, port: port)
        }
    }

    private func terminateTunnelProcessOnQueue(forceKillSynchronously: Bool = false) {
        tunnelTimeoutWorkItem?.cancel()
        tunnelTimeoutWorkItem = nil
        tunnelRestartWorkItem?.cancel()
        tunnelRestartWorkItem = nil
        tunnelStabilityWorkItem?.cancel()
        tunnelStabilityWorkItem = nil
        tunnelConnectedUptime = 0
        tunnelGeneration &+= 1

        tunnelPipe?.fileHandleForReading.readabilityHandler = nil
        tunnelPipe = nil
        tunnelOutputBuffer = ""
        tunnelPartialUTF8Data.removeAll(keepingCapacity: false)

        if let proc = tunnelProcess {
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
                if forceKillSynchronously {
                    for _ in 0..<3 where proc.isRunning {
                        usleep(20_000)
                    }
                }
                if proc.isRunning {
                    let pid = proc.processIdentifier
                    if forceKillSynchronously {
                        _ = Darwin.kill(pid, SIGKILL)
                    } else {
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
                            if proc.isRunning {
                                _ = Darwin.kill(pid, SIGKILL)
                            }
                        }
                    }
                }
            }
        }
        tunnelProcess = nil
    }

    private func scheduleTunnelStartupTimeout(epoch: UInt64, port: UInt16) {
        tunnelTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.tunnelTimeoutWorkItem = nil
            let state = self.lock.withLock { ($0.isSharing, $0.sessionEpoch, $0.publicURL, $0.port) }
            guard state.0, state.1 == epoch, state.2 == nil else { return }
            AppLog.liveShare.error("Public tunnel did not become ready in time; retrying.")
            self.terminateTunnelProcessOnQueue()
            self.scheduleTunnelRestart(epoch: epoch, port: state.3 > 0 ? state.3 : port, updateConnectingStatus: true)
        }
        tunnelTimeoutWorkItem = item
        serverQueue.asyncAfter(deadline: .now() + 20.0, execute: item)
    }

    private func handleTunnelTerminatedOnQueue(epoch: UInt64) {
        let nowUptime = ProcessInfo.processInfo.systemUptime
        if tunnelConnectedUptime > 0, (nowUptime - tunnelConnectedUptime) >= 20.0 {
            tunnelRestartAttempts = 0
        }
        tunnelConnectedUptime = 0
        tunnelStabilityWorkItem?.cancel()
        tunnelStabilityWorkItem = nil

        guard AppSettings.shared.liveShareUseExternalTunnel else {
            let updated = lock.withLock { state -> Bool in
                guard state.isSharing && state.sessionEpoch == epoch else { return false }
                state.isTunnelStarting = false
                state.tunnelError = nil
                state.publicURL = nil
                state.tunnelHost = nil
                return true
            }
            if updated { notifyStateChange() }
            return
        }
        let (stillSharing, hadPublicURL, port) = lock.withLock { state -> (Bool, Bool, UInt16) in
            guard state.isSharing && state.sessionEpoch == epoch else { return (false, false, 0) }
            return (true, state.publicURL != nil, state.port)
        }
        guard stillSharing, port > 0 else { return }

        guard tunnelRestartAttempts < 5 else {
            markTunnelFailed(epoch: epoch, message: "Public tunnel unavailable. Retry from the Live Link banner.")
            return
        }

        let updated = lock.withLock { state -> Bool in
            guard state.isSharing && state.sessionEpoch == epoch else { return false }
            state.publicURL = nil
            state.tunnelHost = nil
            state.isTunnelStarting = true
            state.tunnelError = hadPublicURL
                ? "Public tunnel disconnected; reconnecting…"
                : "Connecting to public tunnel (attempt \(min(5, tunnelRestartAttempts + 1))/5)…"
            return true
        }
        if updated { notifyStateChange() }
        scheduleTunnelRestart(epoch: epoch, port: port)
    }

    private func scheduleTunnelRestart(epoch: UInt64, port: UInt16, updateConnectingStatus: Bool = false) {
        guard AppSettings.shared.liveShareUseExternalTunnel else { return }
        let stillSharing = lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
        guard stillSharing else { return }

        terminateTunnelProcessOnQueue()

        guard tunnelRestartAttempts < 5 else {
            markTunnelFailed(epoch: epoch, message: "Public tunnel unavailable. Retry from the Live Link banner.")
            return
        }

        tunnelRestartAttempts += 1
        if updateConnectingStatus {
            let attempt = tunnelRestartAttempts
            let updated = lock.withLock { state -> Bool in
                guard state.isSharing && state.sessionEpoch == epoch else { return false }
                state.isTunnelStarting = true
                state.tunnelError = "Connecting to public tunnel (attempt \(min(5, attempt))/5)…"
                return true
            }
            if updated { notifyStateChange() }
        }
        let delay = min(30.0, pow(2.0, Double(tunnelRestartAttempts - 1)))
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.tunnelRestartWorkItem = nil
            self.startTunnelProcessOnQueue(port: port, epoch: epoch)
        }
        tunnelRestartWorkItem = item
        serverQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public func retryTunnel() {
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            let state = self.lock.withLock { ($0.isSharing, $0.sessionEpoch, $0.port) }
            guard state.0, state.2 > 0 else { return }
            self.tunnelRestartAttempts = 0
            self.lock.withLock {
                $0.tunnelError = nil
                $0.isTunnelStarting = true
            }
            self.notifyStateChange()
            self.startTunnelProcessOnQueue(port: state.2, epoch: state.1)
        }
    }

    private func markTunnelFailed(epoch: UInt64, message: String) {
        terminateTunnelProcessOnQueue()

        let updated = lock.withLock { state -> Bool in
            guard state.isSharing && state.sessionEpoch == epoch else { return false }
            state.isTunnelStarting = false
            state.tunnelError = message
            state.publicURL = nil
            state.tunnelHost = nil
            return true
        }
        if updated {
            notifyStateChange()
        }
    }

    private func parseTunnelOutput(_ text: String, regex: NSRegularExpression, epoch: UInt64) {
        guard let baseURL = Self.extractTunnelURL(from: text, regex: regex),
              let host = baseURL.host else { return }
        let baseURLString = baseURL.absoluteString

        let updatedURL: URL? = lock.withLock { state -> URL? in
            guard state.isSharing && state.sessionEpoch == epoch else { return nil }
            guard !state.sessionKeyFragment.isEmpty,
                  let tokenizedURL = URL(string: "\(baseURLString)/s/\(state.sessionToken)#\(state.sessionKeyFragment)") else { return nil }
            if state.publicURL == tokenizedURL { return nil }
            state.publicURL = tokenizedURL
            state.tunnelHost = host
            state.isTunnelStarting = false
            state.tunnelError = nil
            return tokenizedURL
        }
        if updatedURL != nil {
            tunnelTimeoutWorkItem?.cancel()
            tunnelTimeoutWorkItem = nil
            tunnelRestartWorkItem?.cancel()
            tunnelRestartWorkItem = nil

            let connectedAt = ProcessInfo.processInfo.systemUptime
            tunnelConnectedUptime = connectedAt
            tunnelStabilityWorkItem?.cancel()
            let stabilityItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.tunnelStabilityWorkItem = nil
                let isStillReady = self.lock.withLock {
                    $0.isSharing && $0.sessionEpoch == epoch && $0.publicURL != nil
                }
                if isStillReady && self.tunnelConnectedUptime == connectedAt {
                    self.tunnelRestartAttempts = 0
                }
            }
            tunnelStabilityWorkItem = stabilityItem
            serverQueue.asyncAfter(deadline: .now() + 20.0, execute: stabilityItem)
        }

        if let validURL = updatedURL {
            AppLog.liveShare.info("Public Live Share tunnel ready on host \(host, privacy: .private)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.urlDidUpdateNotification, object: self, userInfo: ["url": validURL])
                NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: self)
            }
        }
    }

    private static func decodeUTF8Chunk(newData: Data, remainder: inout Data) -> String {
        var combined: Data
        if remainder.isEmpty {
            combined = newData
        } else {
            combined = remainder
            combined.append(newData)
            remainder.removeAll(keepingCapacity: false)
        }
        guard !combined.isEmpty else { return "" }

        let count = combined.count
        let tailLimit = min(count, 3)
        var contCount = 0
        while contCount < tailLimit && (combined[count - 1 - contCount] & 0xC0) == 0x80 {
            contCount += 1
        }

        let leadIndex = count - 1 - contCount
        if leadIndex >= 0 {
            let lead = combined[leadIndex]
            let expectedLen: Int
            if (lead & 0xE0) == 0xC0 {
                expectedLen = 2
            } else if (lead & 0xF0) == 0xE0 {
                expectedLen = 3
            } else if (lead & 0xF8) == 0xF0 {
                expectedLen = 4
            } else {
                expectedLen = 1
            }
            let actualLen = count - leadIndex
            if expectedLen > 1 && actualLen < expectedLen {
                remainder = combined.subdata(in: leadIndex..<count)
                if leadIndex == 0 {
                    return ""
                }
                return String(decoding: combined.subdata(in: 0..<leadIndex), as: UTF8.self)
            }
        }
        return String(decoding: combined, as: UTF8.self)
    }

    private func notifyStateChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: self)
        }
    }

    public static func getLocalIPAddress() -> String? {
        var primaryAddress: String?
        var fallbackAddress: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = interface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("wlan") || name.hasPrefix("bridge") else {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let res = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                socklen_t(0),
                NI_NUMERICHOST
            )
            guard res == 0 else { continue }

            let ip: String? = hostname.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return nil }
                return String(cString: base)
            }
            guard let validIP = ip, !validIP.isEmpty, !validIP.hasPrefix("169.254.") else { continue }

            if name == "en0" || name == "en1" {
                primaryAddress = validIP
                break
            } else if fallbackAddress == nil {
                fallbackAddress = validIP
            }
        }
        return primaryAddress ?? fallbackAddress
    }
}


private struct ReceiverWebAppHTML {
    static func html(forToken token: String, encryptPayloads: Bool) -> String {
        content
            .replacingOccurrences(of: "__SESSION_BASE_PATH__", with: "/s/\(token)")
            .replacingOccurrences(of: "__PAYLOAD_ENCRYPTED__", with: encryptPayloads ? "true" : "false")
    }

    static let content = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Call Caption</title>
        <style>
            :root {
                --bg: #0b0d12;
                --card-bg: rgba(20, 24, 33, 0.82);
                --card-border: rgba(255, 255, 255, 0.08);
                --accent-blue: #38bdf8;
                --accent-green: #34d399;
                --accent-amber: #fbbf24;
                --text-main: #f8fafc;
                --text-sub: #94a3b8;
                --font-size: 18px;
            }
            * { box-sizing: border-box; margin: 0; padding: 0; }
            html, body {
                background: var(--bg);
                color: var(--text-main);
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", system-ui, sans-serif;
                -webkit-font-smoothing: antialiased;
                -moz-osx-font-smoothing: grayscale;
                text-rendering: optimizeLegibility;
                min-height: 100vh;
                overflow-x: hidden;
                overflow-y: auto;
            }
            body { display: flex; flex-direction: column; }
            header {
                position: sticky;
                top: 0;
                background: rgba(11, 13, 18, 0.88);
                backdrop-filter: blur(20px);
                -webkit-backdrop-filter: blur(20px);
                border-bottom: 1px solid var(--card-border);
                padding: 12px 20px;
                display: flex;
                align-items: center;
                justify-content: space-between;
                flex-wrap: wrap;
                gap: 10px;
                z-index: 20;
            }
            .brand { display: flex; align-items: center; gap: 10px; }
            .brand-logo {
                width: 26px;
                height: 26px;
                background: linear-gradient(135deg, #0284c7, #38bdf8);
                border-radius: 7px;
                display: flex;
                align-items: center;
                justify-content: center;
                font-weight: 700;
                font-size: 11.5px;
                letter-spacing: -0.02em;
                color: white;
            }
            .brand-title {
                font-weight: 600;
                font-size: 14.5px;
                letter-spacing: -0.015em;
            }
            .status-pill {
                display: inline-flex;
                align-items: center;
                gap: 6px;
                padding: 3px 9px;
                border-radius: 999px;
                font-size: 11px;
                font-weight: 500;
                background: rgba(52, 211, 153, 0.12);
                color: var(--accent-green);
                border: 1px solid rgba(52, 211, 153, 0.24);
            }
            .status-pill.offline {
                background: rgba(239, 68, 68, 0.12);
                color: #f87171;
                border-color: rgba(239, 68, 68, 0.24);
            }
            .status-pill.paused {
                background: rgba(251, 191, 36, 0.12);
                color: var(--accent-amber);
                border-color: rgba(251, 191, 36, 0.28);
            }
            .viewer-count {
                color: var(--text-sub);
                font-size: 11px;
                min-width: 0;
            }
            .pulse-dot {
                width: 6px;
                height: 6px;
                background: currentColor;
                border-radius: 50%;
            }
            .controls { display: flex; align-items: center; gap: 6px; }
            .btn {
                background: rgba(255, 255, 255, 0.05);
                border: 1px solid var(--card-border);
                color: var(--text-main);
                padding: 5px 10px;
                border-radius: 7px;
                font-size: 12px;
                font-weight: 500;
                cursor: pointer;
                transition: all 0.15s ease;
            }
            .btn:hover { background: rgba(255, 255, 255, 0.10); }
            .btn.active {
                background: rgba(56, 189, 248, 0.16);
                border-color: rgba(56, 189, 248, 0.34);
                color: var(--accent-blue);
            }
            main {
                flex: 1;
                width: 100%;
                padding: 20px 20px 90px 20px;
                display: flex;
                flex-direction: column;
                align-items: center;
            }
            .caption-stream {
                width: 100%;
                max-width: 720px;
                display: flex;
                flex-direction: column;
                gap: 12px;
            }
            .empty-state {
                margin: 18vh auto;
                text-align: center;
                padding: 32px 20px;
                color: var(--text-sub);
            }
            .empty-state h3 {
                font-size: 14px;
                font-weight: 500;
                letter-spacing: -0.01em;
                color: var(--text-sub);
            }
            .card {
                background: var(--card-bg);
                border: 1px solid var(--card-border);
                border-radius: 12px;
                padding: 14px 16px;
                backdrop-filter: blur(10px);
                -webkit-backdrop-filter: blur(10px);
            }
            .card.live {
                border-color: rgba(56, 189, 248, 0.32);
            }
            .card-meta {
                display: flex;
                align-items: center;
                justify-content: space-between;
                margin-bottom: 6px;
                font-size: 11px;
            }
            .speaker-badge {
                font-weight: 600;
                text-transform: uppercase;
                letter-spacing: 0.04em;
                font-size: 10.5px;
            }
            .speaker-host { color: var(--accent-blue); }
            .speaker-caller { color: var(--accent-green); }
            .untranslated-badge {
                color: var(--accent-amber);
                font-size: 10px;
                margin-left: 6px;
                font-weight: 500;
            }
            .time-label {
                color: var(--text-sub);
                font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                font-variant-numeric: tabular-nums;
            }
            .translated-text {
                font-size: var(--font-size);
                font-weight: 400;
                line-height: 1.36;
                letter-spacing: -0.012em;
                color: #f8fafc;
                word-break: break-word;
            }
            .card.live .translated-text { color: #bae6fd; }
            .original-text {
                margin-top: 4px;
                font-size: calc(var(--font-size) * 0.82);
                font-weight: 400;
                line-height: 1.32;
                color: rgba(148, 163, 184, 0.78);
                display: none;
            }
            body.show-orig .original-text { display: block; }
            .floating-bottom {
                position: fixed;
                bottom: 18px;
                left: 50%;
                transform: translateX(-50%);
                background: rgba(16, 19, 26, 0.92);
                border: 1px solid var(--card-border);
                backdrop-filter: blur(14px);
                -webkit-backdrop-filter: blur(14px);
                border-radius: 999px;
                padding: 6px 14px;
                display: flex;
                align-items: center;
                gap: 10px;
                z-index: 30;
                user-select: none;
            }
            .jump-latest-btn {
                background: rgba(56, 189, 248, 0.20);
                border: 1px solid rgba(56, 189, 248, 0.40);
                color: var(--accent-blue);
                border-radius: 999px;
                padding: 2px 9px;
                font-size: 11px;
                font-weight: 500;
                cursor: pointer;
                display: none;
            }
            .jump-latest-btn.visible {
                display: inline-flex;
                align-items: center;
                gap: 4px;
            }
        </style>
    </head>
    <body class="show-orig">
        <header>
            <div class="brand">
                <div class="brand-logo" aria-hidden="true">CC</div>
                <div class="brand-title">Call Caption</div>
                <div id="conn-pill" class="status-pill" role="status" aria-live="polite">
                    <span class="pulse-dot" aria-hidden="true"></span>
                    <span id="conn-label">Connecting</span>
                </div>
            </div>
            <div class="controls">
                <span id="viewer-count" class="viewer-count" aria-live="polite"></span>
                <button id="view-mode-btn" class="btn active" aria-pressed="true" aria-label="Filter speakers">All</button>
                <button id="orig-toggle-btn" class="btn active" aria-pressed="true" aria-label="Show original text">Original</button>
                <button id="font-dec-btn" class="btn" aria-label="Decrease font size">A-</button>
                <button id="font-inc-btn" class="btn" aria-label="Increase font size">A+</button>
            </div>
        </header>

        <main id="main-scroll">
            <div id="empty-state" class="empty-state">
                <h3>Listening…</h3>
            </div>
            <div id="caption-stream" class="caption-stream" aria-live="polite"></div>
        </main>

        <div class="floating-bottom" id="autoscroll-pill">
            <label for="autoscroll-toggle" style="font-size: 11.5px; color: var(--text-sub); cursor: pointer;">Auto-Scroll</label>
            <input type="checkbox" id="autoscroll-toggle" checked style="accent-color: var(--accent-blue); cursor: pointer;">
            <button id="jump-latest-btn" class="jump-latest-btn" type="button">↓ Latest</button>
        </div>

        <script>
            const BASE_PATH = "__SESSION_BASE_PATH__";
            const PAYLOAD_ENCRYPTED = __PAYLOAD_ENCRYPTED__;
            const SESSION_KEY = (() => {
                const match = location.hash.match(/[#&]k=([A-Za-z0-9_-]+)/);
                return match ? match[1] : null;
            })();
            let sessionCryptoKey = null;
            let decryptChain = Promise.resolve();
            let linkErrorShown = false;
            let hasDecryptedSuccessfully = false;
            let lastSseSeq = 0;
            let lastStateSeq = 0;
            let lastClearEpoch = null;
            let currentFontSize = 18;
            let showOriginal = true;
            let hostFocusMode = false;
            let autoScroll = true;
            let isProgrammaticScroll = false;
            let hostPaused = false;

            const streamContainer = document.getElementById('caption-stream');
            const emptyState = document.getElementById('empty-state');
            const emptyStateLabel = emptyState.querySelector('h3');
            const connPill = document.getElementById('conn-pill');
            const connLabel = document.getElementById('conn-label');
            const viewerCountEl = document.getElementById('viewer-count');
            const autoscrollToggle = document.getElementById('autoscroll-toggle');
            const jumpLatestBtn = document.getElementById('jump-latest-btn');
            const liveSlots = { 'You': null, 'Caller': null };

            function isNearBottom() {
                const docEl = document.scrollingElement || document.documentElement;
                return (docEl.scrollHeight - (window.scrollY + window.innerHeight)) <= 90;
            }

            function scrollToBottom(instant = false) {
                if (!autoScroll) return;
                isProgrammaticScroll = true;
                requestAnimationFrame(() => {
                    const docEl = document.scrollingElement || document.documentElement;
                    window.scrollTo({
                        top: Math.max(docEl.scrollHeight, document.body.scrollHeight),
                        behavior: instant ? 'auto' : 'smooth'
                    });
                    setTimeout(() => { isProgrammaticScroll = false; }, 220);
                });
            }

            window.addEventListener('scroll', () => {
                if (isProgrammaticScroll) return;
                if (isNearBottom()) {
                    if (!autoScroll) { autoScroll = true; autoscrollToggle.checked = true; }
                    jumpLatestBtn.classList.remove('visible');
                } else if (!autoScroll) {
                    jumpLatestBtn.classList.add('visible');
                }
            }, { passive: true });

            window.addEventListener('wheel', (e) => {
                if (e.deltaY < -4 && !isNearBottom()) {
                    autoScroll = false;
                    autoscrollToggle.checked = false;
                    jumpLatestBtn.classList.add('visible');
                }
            }, { passive: true });

            window.addEventListener('touchmove', () => {
                if (!isNearBottom()) {
                    autoScroll = false;
                    autoscrollToggle.checked = false;
                    jumpLatestBtn.classList.add('visible');
                }
            }, { passive: true });

            jumpLatestBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                autoScroll = true;
                autoscrollToggle.checked = true;
                jumpLatestBtn.classList.remove('visible');
                scrollToBottom(false);
            });

            function base64urlToBytes(value) {
                let base64 = value.replace(/-/g, '+').replace(/_/g, '/');
                while (base64.length % 4 !== 0) base64 += '=';
                const binary = atob(base64);
                const bytes = new Uint8Array(binary.length);
                for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                return bytes;
            }

            async function initSessionCrypto() {
                if (!PAYLOAD_ENCRYPTED) return true;
                if (!SESSION_KEY || !window.crypto || !window.crypto.subtle) return false;
                try {
                    const raw = base64urlToBytes(SESSION_KEY);
                    if (raw.length !== 32) return false;
                    sessionCryptoKey = await window.crypto.subtle.importKey(
                        'raw', raw, { name: 'AES-GCM' }, false, ['decrypt']
                    );
                    return true;
                } catch (err) {
                    return false;
                }
            }

            function makeReplayError(message) {
                const err = new Error(message);
                err.name = 'ReplayError';
                return err;
            }

            async function decryptEnvelope(payload, expectedType, isSSE = false) {
                const envelope = typeof payload === 'string' ? JSON.parse(payload) : payload;
                if (!envelope || envelope.v !== 1 || typeof envelope.d !== 'string') {
                    throw new Error('Unsupported envelope');
                }
                const hasMeta = envelope.t !== undefined || envelope.s !== undefined;
                let additionalData;
                if (hasMeta || expectedType) {
                    if (typeof envelope.t !== 'string' || typeof envelope.s !== 'number' || !Number.isSafeInteger(envelope.s) || envelope.s < 0) {
                        throw new Error('Invalid envelope metadata');
                    }
                    if (expectedType && envelope.t !== expectedType) {
                        throw new Error('Unexpected envelope type');
                    }
                    if (isSSE) {
                        if (envelope.s <= lastSseSeq) throw makeReplayError('Stale SSE sequence');
                    } else if (expectedType === 'state') {
                        if (envelope.s <= lastStateSeq) throw makeReplayError('Stale state sequence');
                    }
                    additionalData = new TextEncoder().encode(`v1:${envelope.t}:${envelope.s}`);
                }
                const combined = base64urlToBytes(envelope.d);
                if (combined.length < 28) throw new Error('Invalid envelope');
                const iv = combined.slice(0, 12);
                const ciphertext = combined.slice(12);
                const params = additionalData
                    ? { name: 'AES-GCM', iv, additionalData }
                    : { name: 'AES-GCM', iv };
                const plaintext = await window.crypto.subtle.decrypt(
                    params, sessionCryptoKey, ciphertext
                );
                if (hasMeta) {
                    if (isSSE) lastSseSeq = envelope.s;
                    else if (expectedType === 'state') lastStateSeq = envelope.s;
                }
                return new TextDecoder().decode(plaintext);
            }

            function showLinkError() {
                if (linkErrorShown) return;
                linkErrorShown = true;
                stopPollingFallback();
                if (eventSource) { eventSource.close(); eventSource = null; }
                emptyState.style.display = '';
                emptyStateLabel.textContent = 'This Live Link is incomplete or corrupted. Copy the full link including the #key fragment.';
                connPill.className = 'status-pill offline';
                connLabel.textContent = 'Link error';
            }

            function enqueueDecrypted(payload, handler, expectedType) {
                if (!PAYLOAD_ENCRYPTED) {
                    try { handler(JSON.parse(payload)); } catch (err) {}
                    return;
                }
                decryptChain = decryptChain
                    .then(async () => {
                        const text = await decryptEnvelope(payload, expectedType, true);
                        hasDecryptedSuccessfully = true;
                        try {
                            handler(JSON.parse(text));
                        } catch (handlerErr) {}
                    })
                    .catch((err) => {
                        if (err && err.name === 'ReplayError') return;
                        if (!hasDecryptedSuccessfully) showLinkError();
                    });
            }

            function setConnectionState(online, label) {
                if (linkErrorShown) return;
                if (online && hostPaused) {
                    connPill.className = 'status-pill paused';
                    connLabel.textContent = 'Paused';
                    return;
                }
                connPill.className = online ? 'status-pill' : 'status-pill offline';
                connLabel.textContent = label || (online ? 'Live' : 'Offline');
            }

            function updateViewerCount(count) {
                if (typeof count !== 'number') return;
                viewerCountEl.textContent = count > 0 ? (count === 1 ? '1 viewer' : count + ' viewers') : '';
            }

            function clearRenderedCards() {
                streamContainer.innerHTML = '';
                renderedIds.clear();
                finalizedCardsById.clear();
                liveSlots['You'] = null;
                liveSlots['Caller'] = null;
                emptyState.style.display = '';
                emptyStateLabel.textContent = 'Listening…';
            }

            function handleStatusEvent(status) {
                if (!status || typeof status !== 'object') return;
                if (typeof status.clearEpoch === 'number') {
                    if (lastClearEpoch !== null && status.clearEpoch !== lastClearEpoch && !status.clearAll && !status.clearCaller) {
                        clearRenderedCards();
                    }
                    lastClearEpoch = status.clearEpoch;
                }
                if (typeof status.paused === 'boolean') {
                    hostPaused = status.paused;
                    setConnectionState(true, hostPaused ? 'Paused' : 'Live');
                }
                if (typeof status.viewerCount === 'number') updateViewerCount(status.viewerCount);
                if (status.clearCaller) {
                    streamContainer.querySelectorAll('[data-speaker="Caller"]').forEach(card => {
                        const evictedId = card.getAttribute('data-event-id');
                        if (evictedId) {
                            finalizedCardsById.delete(evictedId);
                            renderedIds.delete(evictedId);
                        }
                        card.remove();
                    });
                    liveSlots['Caller'] = null;
                    if (streamContainer.children.length === 0) {
                        emptyState.style.display = '';
                        emptyStateLabel.textContent = 'Listening…';
                    }
                }
                if (status.clearAll) {
                    clearRenderedCards();
                }
            }

            document.getElementById('font-inc-btn').addEventListener('click', () => {
                currentFontSize = Math.min(30, currentFontSize + 2);
                document.documentElement.style.setProperty('--font-size', currentFontSize + 'px');
                scrollToBottom(true);
            });
            document.getElementById('font-dec-btn').addEventListener('click', () => {
                currentFontSize = Math.max(13, currentFontSize - 2);
                document.documentElement.style.setProperty('--font-size', currentFontSize + 'px');
                scrollToBottom(true);
            });
            const origBtn = document.getElementById('orig-toggle-btn');
            origBtn.addEventListener('click', () => {
                showOriginal = !showOriginal;
                document.body.classList.toggle('show-orig', showOriginal);
                origBtn.classList.toggle('active', showOriginal);
                origBtn.setAttribute('aria-pressed', showOriginal ? 'true' : 'false');
                scrollToBottom(true);
            });
            const viewModeBtn = document.getElementById('view-mode-btn');
            viewModeBtn.addEventListener('click', () => {
                hostFocusMode = !hostFocusMode;
                viewModeBtn.textContent = hostFocusMode ? 'Host' : 'All';
                viewModeBtn.classList.toggle('active', !hostFocusMode);
                viewModeBtn.setAttribute('aria-pressed', (!hostFocusMode) ? 'true' : 'false');
                streamContainer.querySelectorAll('.card').forEach(c => {
                    c.style.display = (hostFocusMode && c.getAttribute('data-speaker') === 'Caller') ? 'none' : 'block';
                });
                scrollToBottom(true);
            });
            autoscrollToggle.addEventListener('change', (e) => {
                autoScroll = e.target.checked;
                if (autoScroll) {
                    jumpLatestBtn.classList.remove('visible');
                    scrollToBottom(false);
                }
            });

            function createCardElement(speaker, isLive) {
                emptyState.style.display = 'none';
                const card = document.createElement('div');
                card.className = isLive ? 'card live' : 'card';
                card.setAttribute('data-speaker', speaker);
                const isHost = (speaker === 'You');
                card.innerHTML = `
                    <div class="card-meta">
                        <div>
                            <span class="speaker-badge ${isHost ? 'speaker-host' : 'speaker-caller'}">${isHost ? 'HOST' : 'CALLER'}</span>
                            <span class="untranslated-badge" style="display:none;">[Untranslated]</span>
                        </div>
                        <span class="time-label">Live</span>
                    </div>
                    <div class="translated-text" dir="auto"></div>
                    <div class="original-text" dir="auto"></div>
                `;
                if (hostFocusMode && speaker === 'Caller') card.style.display = 'none';
                return card;
            }

            function evictOldCardsIfNeeded() {
                let cursor = streamContainer.firstElementChild;
                while (streamContainer.children.length > 80 && cursor) {
                    const next = cursor.nextElementSibling;
                    if (!cursor.classList.contains('live')) {
                        const evictedId = cursor.getAttribute('data-event-id');
                        if (evictedId) finalizedCardsById.delete(evictedId);
                        streamContainer.removeChild(cursor);
                    }
                    cursor = next;
                }
            }

            function getOrCreateLiveCard(speaker) {
                if (liveSlots[speaker] && document.body.contains(liveSlots[speaker])) return liveSlots[speaker];
                const card = createCardElement(speaker, true);
                streamContainer.appendChild(card);
                evictOldCardsIfNeeded();
                liveSlots[speaker] = card;
                return card;
            }

            const renderedIds = new Set();
            const finalizedCardsById = new Map();

            function populateCardContent(card, ev) {
                const untransBadge = card.querySelector('.untranslated-badge');
                if (untransBadge) {
                    untransBadge.style.display = ev.isUntranslated ? 'inline' : 'none';
                }
                card.querySelector('.translated-text').textContent = ev.translatedText || ev.originalText;
                const origEl = card.querySelector('.original-text');
                origEl.textContent = (!ev.isUntranslated && ev.originalText && ev.originalText.toLowerCase() !== (ev.translatedText || '').toLowerCase()) ? ev.originalText : '';
                card.setAttribute('data-orig', ev.originalText || '');
                card.setAttribute('data-event-id', ev.id || '');
                const timeEl = card.querySelector('.time-label');
                if (ev.isFinal) {
                    card.classList.remove('live');
                    timeEl.textContent = ev.timestamp;
                } else {
                    timeEl.textContent = 'Live';
                }
            }

            function handleCaptionEvent(ev, isBatchHistory = false) {
                if (!ev.translatedText && !ev.originalText) return;
                if (ev.id && renderedIds.has(ev.id)) {
                    if (ev.isFinal) {
                        const existingCard = finalizedCardsById.get(ev.id);
                        if (existingCard && document.body.contains(existingCard)) populateCardContent(existingCard, ev);
                    }
                    return;
                }
                if (ev.isFinal && ev.id) {
                    renderedIds.add(ev.id);
                    if (renderedIds.size > 200) {
                        const oldest = renderedIds.values().next().value;
                        renderedIds.delete(oldest);
                        finalizedCardsById.delete(oldest);
                    }
                }
                if (ev.isFinal) {
                    const activeLive = liveSlots[ev.speaker];
                    let card = null;
                    if (activeLive && document.body.contains(activeLive)) {
                        const liveId = activeLive.getAttribute('data-event-id') || '';
                        if (ev.id && liveId && liveId === ev.id) {
                            card = activeLive;
                            liveSlots[ev.speaker] = null;
                        } else {
                            card = createCardElement(ev.speaker, false);
                            streamContainer.insertBefore(card, activeLive);
                        }
                    } else {
                        card = createCardElement(ev.speaker, false);
                        streamContainer.appendChild(card);
                    }
                    populateCardContent(card, ev);
                    if (ev.id) finalizedCardsById.set(ev.id, card);
                    evictOldCardsIfNeeded();
                } else {
                    populateCardContent(getOrCreateLiveCard(ev.speaker), ev);
                }
                if (!isBatchHistory) scrollToBottom(false);
            }

            let eventSource = null;
            let pollTimeout = null;
            let isPollingActive = false;
            let pollDelayMs = 1500;
            let pollCycleToken = 0;

            function scheduleNextPoll(token) {
                if (!isPollingActive || token !== pollCycleToken) return;
                if (pollTimeout) clearTimeout(pollTimeout);
                pollTimeout = setTimeout(() => {
                    pollTimeout = null;
                    runPollCycle(token);
                }, pollDelayMs);
            }

            async function runPollCycle(token) {
                if (!isPollingActive || token !== pollCycleToken) return;
                const shouldContinue = await pollState(token);
                if (shouldContinue && isPollingActive && token === pollCycleToken) {
                    scheduleNextPoll(token);
                }
            }

            function startPollingFallback() {
                if (isPollingActive || linkErrorShown) return;
                isPollingActive = true;
                pollDelayMs = 1500;
                pollCycleToken += 1;
                runPollCycle(pollCycleToken);
            }

            function stopPollingFallback() {
                isPollingActive = false;
                pollCycleToken += 1;
                if (pollTimeout) { clearTimeout(pollTimeout); pollTimeout = null; }
            }

            function connectSSE() {
                if (eventSource) eventSource.close();
                eventSource = new EventSource(BASE_PATH + '/events');
                eventSource.onopen = () => { stopPollingFallback(); setConnectionState(true, 'Live'); };
                eventSource.addEventListener('history', (e) => {
                    enqueueDecrypted(e.data, (history) => {
                        ['Caller', 'You'].forEach(sp => {
                            if (liveSlots[sp] && document.body.contains(liveSlots[sp])) {
                                liveSlots[sp].remove();
                            }
                            liveSlots[sp] = null;
                        });
                        if (history && history.length > 0) {
                            emptyState.style.display = 'none';
                            history.forEach(item => handleCaptionEvent(item, true));
                            scrollToBottom(true);
                        } else if (streamContainer.children.length === 0) {
                            emptyState.style.display = '';
                        }
                    }, 'history');
                });
                eventSource.addEventListener('caption', (e) => {
                    enqueueDecrypted(e.data, (ev) => handleCaptionEvent(ev, false), 'caption');
                });
                eventSource.addEventListener('status', (e) => {
                    enqueueDecrypted(e.data, handleStatusEvent, 'status');
                });
                eventSource.onerror = () => {
                    if (!eventSource || linkErrorShown) return;
                    setConnectionState(false, 'Reconnecting');
                    startPollingFallback();
                };
            }

            async function pollState(token) {
                let envelope;
                try {
                    const res = await fetch(BASE_PATH + '/api/state');
                    if (!isPollingActive || token !== pollCycleToken) return false;
                    if (res.status === 403 || res.status === 404) {
                        if (eventSource) { eventSource.close(); eventSource = null; }
                        stopPollingFallback();
                        setConnectionState(false, 'Session ended');
                        return false;
                    }
                    if (!res.ok) {
                        setConnectionState(false, 'Reconnecting');
                        pollDelayMs = Math.min(15000, pollDelayMs * 2);
                        return true;
                    }
                    envelope = await res.json();
                    if (!isPollingActive || token !== pollCycleToken) return false;
                } catch (e) {
                    if (!isPollingActive || token !== pollCycleToken) return false;
                    setConnectionState(false, 'Reconnecting');
                    pollDelayMs = Math.min(15000, pollDelayMs * 2);
                    return true;
                }
                let data;
                if (PAYLOAD_ENCRYPTED) {
                    try {
                        data = JSON.parse(await decryptEnvelope(envelope, 'state', false));
                        hasDecryptedSuccessfully = true;
                        if (!isPollingActive || token !== pollCycleToken) return false;
                    } catch (e) {
                        if (e && e.name === 'ReplayError') return true;
                        if (!hasDecryptedSuccessfully) showLinkError();
                        return !hasDecryptedSuccessfully ? false : true;
                    }
                } else {
                    data = envelope;
                }
                pollDelayMs = 1500;
                setConnectionState(true, 'Live');
                if (typeof data.clearEpoch === 'number') {
                    if (lastClearEpoch !== null && data.clearEpoch !== lastClearEpoch) {
                        clearRenderedCards();
                    }
                    lastClearEpoch = data.clearEpoch;
                }
                if (Array.isArray(data.history) && data.history.length > 0) {
                    data.history.forEach(item => handleCaptionEvent(item, true));
                }
                if (data.callerPartial) {
                    handleCaptionEvent(data.callerPartial, false);
                } else if (liveSlots['Caller']) {
                    if (document.body.contains(liveSlots['Caller'])) liveSlots['Caller'].remove();
                    liveSlots['Caller'] = null;
                }
                if (data.micPartial) {
                    handleCaptionEvent(data.micPartial, false);
                } else if (liveSlots['You']) {
                    if (document.body.contains(liveSlots['You'])) liveSlots['You'].remove();
                    liveSlots['You'] = null;
                }
                if (streamContainer.children.length === 0) {
                    emptyState.style.display = '';
                }
                handleStatusEvent({ paused: !!data.isPaused, viewerCount: data.viewerCount });
                scrollToBottom(false);
                return true;
            }

            (async () => {
                if (!(await initSessionCrypto())) {
                    showLinkError();
                    return;
                }
                connectSSE();
            })();
        </script>
    </body>
    </html>
    """
}
