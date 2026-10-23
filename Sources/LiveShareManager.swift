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

    public static let sshTunnelRegex = try! NSRegularExpression(pattern: #"https://(?!admin\.|www\.|docs\.|api\.)[a-zA-Z0-9-]+\.(?:lhr\.life|lhr\.rocks|localhost\.run)"#)

    private struct State: Sendable {
        var isSharing: Bool = false
        var sessionEpoch: UInt64 = 0
        var sessionToken: String = ""
        var sessionKeyFragment: String = ""
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

    private var listener: NWListener?
    private var sseClients: [ObjectIdentifier: SSEClient] = [:]
    private var tunnelProcess: Process?
    private var tunnelPipe: Pipe?
    private var tunnelOutputBuffer: String = ""
    private var tunnelTimeoutWorkItem: DispatchWorkItem?
    private var tunnelRestartWorkItem: DispatchWorkItem?
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
        if let hostsURL = Self.sshKnownHostsFileURL {
            try? Self.ensureSSHKnownHostsPopulated(at: hostsURL)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stopSharing()
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
        guard let firstLineEnd = normalized.range(of: "\n") else { return nil }
        let firstLine = normalized[..<firstLineEnd.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let fullPath = String(parts[1])
        let cleanPath = fullPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? fullPath

        var hostHeader: String? = nil
        let lines = normalized.components(separatedBy: "\n")
        for rawLine in lines.dropFirst() {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty { break }
            if line.lowercased().hasPrefix("host:") {
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("["), let closing = value.firstIndex(of: "]") {
                    hostHeader = String(value[...closing]).lowercased()
                } else {
                    hostHeader = value.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased()
                }
                break
            }
        }
        return ParsedHTTPRequest(method: method, path: cleanPath, host: hostHeader)
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
        let keyFragment = LiveShareCrypto().keyFragment
        let capturedEpoch: UInt64? = lock.withLock { state -> UInt64? in
            guard !state.isSharing else { return nil }
            state.isSharing = true
            state.sessionEpoch &+= 1
            state.sessionToken = token
            state.sessionKeyFragment = keyFragment
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
            state.sessionToken = ""
            state.sessionKeyFragment = ""
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
        pingTimer?.cancel()
        pingTimer = nil

        terminateTunnelProcessOnQueue(forceKillSynchronously: forceKillSynchronously)
        tunnelRestartAttempts = 0

        for (_, client) in sseClients {
            client.connection.stateUpdateHandler = nil
            client.connection.cancel()
        }
        sseClients.removeAll()

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
        parameters.allowLocalEndpointReuse = true

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
        startHeartbeatOnQueue()
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

    private func handleIncomingConnectionOnQueue(_ connection: NWConnection, epoch: UInt64) {
        let isStillValid = lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
        guard isStillValid else {
            connection.cancel()
            return
        }

        if sseClients.count >= maxSSEClients {
            connection.start(queue: serverQueue)
            sendSimpleResponse(connection: connection, status: "503 Service Unavailable", body: "Too many viewers")
            return
        }

        connection.start(queue: serverQueue)

        let timeoutItem = DispatchWorkItem { [weak connection] in
            connection?.cancel()
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
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data = content {
                buffer.append(data)
            }

            let requestString = String(decoding: buffer, as: UTF8.self)
            if requestString.contains("\r\n\r\n") || requestString.contains("\n\n") || isComplete {
                timeoutItem.cancel()
                self.routeHTTPRequestOnQueue(request: requestString, connection: connection, epoch: epoch)
            } else if buffer.count >= 8192 || isComplete {
                timeoutItem.cancel()
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
        let isLoopback = host.map { Self.isLoopbackHost($0) } ?? false
        let isTunnel = tunnelHost.map { host == $0.lowercased() } ?? false
        let encryptPayloads = isLoopback || isTunnel
        let includeBody = parsed.method != "HEAD"

        switch action {
        case .serveHTML:
            handleServeHTMLOnQueue(connection, token: token, encryptPayloads: encryptPayloads, includeBody: includeBody)
        case .serveAPIState:
            handleAPIStateOnQueue(connection, encryptPayloads: encryptPayloads, includeBody: includeBody)
        case .serveSSE:
            handleSSEConnectionOnQueue(connection, encryptPayloads: encryptPayloads)
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
    }

    private func handleAPIStateOnQueue(_ connection: NWConnection, encryptPayloads: Bool, includeBody: Bool = true) {
        let responseModel = lock.withLock { state -> APIStateResponse in
            APIStateResponse(
                foreignLanguage: AppSettings.shared.foreignLanguageCode,
                mainLanguage: AppSettings.shared.mainLanguageCode,
                callerPartial: state.callerPartial,
                micPartial: state.micPartial,
                history: Array(state.history.suffix(60)),
                isPaused: state.isPaused,
                viewerCount: state.activeClientCount
            )
        }

        guard let jsonData = try? JSONEncoder().encode(responseModel) else {
            connection.cancel()
            return
        }
        let responseData: Data?
        if encryptPayloads {
            responseData = encryptPayload(jsonData)
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

    private func handleSSEConnectionOnQueue(_ connection: NWConnection, encryptPayloads: Bool) {
        guard sseClients.count < maxSSEClients else {
            sendSimpleResponse(connection: connection, status: "503 Service Unavailable", body: "Server busy")
            return
        }

        let headerData = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache, no-transform\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nCross-Origin-Resource-Policy: same-origin\r\nConnection: keep-alive\r\n\r\n".utf8)

        let client = SSEClient(connection: connection, encryptPayloads: encryptPayloads)
        let id = client.id
        sseClients[id] = client
        updateActiveClientCountOnQueue()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeSSEClientOnQueue(id: id)
            default:
                break
            }
        }

        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if error != nil {
                self.removeSSEClientOnQueue(id: id)
                return
            }

            let (historySnapshot, callerPart, micPart) = self.lock.withLock {
                (Array($0.history.suffix(50)), $0.callerPartial, $0.micPartial)
            }
            if let histData = try? JSONEncoder().encode(historySnapshot),
               let histPayload = self.payloadData(histData, encrypt: client.encryptPayloads),
               let histStr = String(data: histPayload, encoding: .utf8) {
                self.sendSSEPayloadOnQueue(Data("event: history\ndata: \(histStr)\n\n".utf8), to: client)
            }
            if let cp = callerPart, let d = try? JSONEncoder().encode(cp),
               let payload = self.payloadData(d, encrypt: client.encryptPayloads),
               let s = String(data: payload, encoding: .utf8) {
                self.sendSSEPayloadOnQueue(Data("event: caption\ndata: \(s)\n\n".utf8), to: client)
            }
            if let mp = micPart, let d = try? JSONEncoder().encode(mp),
               let payload = self.payloadData(d, encrypt: client.encryptPayloads),
               let s = String(data: payload, encoding: .utf8) {
                self.sendSSEPayloadOnQueue(Data("event: caption\ndata: \(s)\n\n".utf8), to: client)
            }
            let (paused, viewerCount) = self.lock.withLock { ($0.isPaused, $0.activeClientCount) }
            if let statusData = try? JSONEncoder().encode(StatusEvent(paused: paused, viewerCount: viewerCount)),
               let statusString = String(data: statusData, encoding: .utf8) {
                self.sendSSEPayloadOnQueue(Data("event: status\ndata: \(statusString)\n\n".utf8), to: client)
            }
        })
    }

    private func sendSSEPayloadOnQueue(_ data: Data, to client: SSEClient) {
        guard sseClients[client.id] != nil else { return }
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
            updateActiveClientCountOnQueue()
        }
    }

    private func updateActiveClientCountOnQueue() {
        let count = sseClients.count
        let changed = lock.withLock { state -> Bool in
            guard state.activeClientCount != count else { return false }
            state.activeClientCount = count
            return true
        }
        if changed {
            sendStatusEvent(StatusEvent(viewerCount: count))
            notifyStateChange()
        }
    }

    private func startHeartbeatOnQueue() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: serverQueue)
        timer.schedule(deadline: .now() + 15.0, repeating: 15.0)
        let pingData = Data(": ping\n\n".utf8)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            for (_, client) in Array(self.sseClients) {
                self.sendSSEPayloadOnQueue(pingData, to: client)
            }
        }
        timer.resume()
        self.pingTimer = timer
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

        let event: LiveCaptionEvent? = lock.withLock { state -> LiveCaptionEvent? in
            guard state.isSharing else { return nil }
            if !AppSettings.shared.shareBothSpeakersOnLink && speaker.lowercased() == "caller" {
                return nil
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
                    if state.callerPartial?.id == eventToBroadcast.id {
                        state.callerPartial = nil
                    }
                } else {
                    if state.micPartial?.id == eventToBroadcast.id {
                        state.micPartial = nil
                    }
                }
                return eventToBroadcast
            } else {
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
                return partialEvent
            }
        }

        guard let event else { return }

        serverQueue.async { [weak self] in
            guard let self = self else { return }
            guard let jsonData = try? JSONEncoder().encode(event) else { return }
            let plainString = String(data: jsonData, encoding: .utf8)
            let encryptedString = self.encryptPayload(jsonData).flatMap { String(data: $0, encoding: .utf8) }

            for (_, client) in Array(self.sseClients) {
                let body: String?
                if client.encryptPayloads {
                    body = encryptedString
                } else {
                    body = plainString
                }
                guard let body else { continue }
                let payload = Data("event: caption\ndata: \(body)\n\n".utf8)
                self.sendSSEPayloadOnQueue(payload, to: client)
            }
        }
    }

    private func payloadData(_ data: Data, encrypt: Bool) -> Data? {
        if encrypt {
            return encryptPayload(data)
        }
        return data
    }

    private func encryptPayload(_ data: Data) -> Data? {
        let keyFragment = lock.withLock { $0.sessionKeyFragment }
        guard !keyFragment.isEmpty,
              let crypto = LiveShareCrypto(keyFragment: keyFragment) else { return nil }
        return try? crypto.seal(data)
    }

    private struct StatusEvent: Codable, Sendable {
        var paused: Bool? = nil
        var viewerCount: Int? = nil
        var clearCaller: Bool? = nil
        var clearAll: Bool? = nil
    }

    private func sendStatusEvent(_ status: StatusEvent) {
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            guard let data = try? JSONEncoder().encode(status),
                  let json = String(data: data, encoding: .utf8) else { return }
            let payload = Data("event: status\ndata: \(json)\n\n".utf8)
            for (_, client) in Array(self.sseClients) {
                self.sendSSEPayloadOnQueue(payload, to: client)
            }
        }
    }

    public func speakerSharingDidChange() {
        let shareCaller = AppSettings.shared.shareBothSpeakersOnLink
        guard !shareCaller else { return }
        let changed = lock.withLock { state -> Bool in
            let hadCallerData = state.history.contains { $0.speaker.lowercased() == "caller" }
                || state.callerPartial != nil
            state.history.removeAll { $0.speaker.lowercased() == "caller" }
            state.callerPartial = nil
            return hadCallerData
        }
        if changed {
            sendStatusEvent(StatusEvent(clearCaller: true))
            notifyStateChange()
        }
    }

    public func clearHistoryForPrivacy() {
        let changed = lock.withLock { state -> Bool in
            let hadData = !state.history.isEmpty || state.callerPartial != nil || state.micPartial != nil
            state.history.removeAll()
            state.callerPartial = nil
            state.micPartial = nil
            return hadData
        }
        if changed {
            sendStatusEvent(StatusEvent(clearAll: true))
            notifyStateChange()
        }
    }

    public func broadcastPauseState(_ paused: Bool) {
        let changed = lock.withLock { state -> Bool in
            guard state.isPaused != paused else { return false }
            state.isPaused = paused
            return true
        }
        guard changed else { return }
        let viewerCount = lock.withLock { $0.activeClientCount }
        sendStatusEvent(StatusEvent(paused: paused, viewerCount: viewerCount))
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
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
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

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        self.tunnelProcess = process
        self.tunnelPipe = pipe
        self.tunnelOutputBuffer = ""

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            self.serverQueue.async { [weak self] in
                guard let self = self else { return }
                self.tunnelOutputBuffer.append(chunk)
                if self.tunnelOutputBuffer.count > 16384 {
                    self.tunnelOutputBuffer = String(self.tunnelOutputBuffer.suffix(8192))
                }
                self.parseTunnelOutput(self.tunnelOutputBuffer, regex: Self.sshTunnelRegex, epoch: epoch)
            }
        }

        process.terminationHandler = { [weak self, weak process] _ in
            guard let self = self, let process = process else { return }
            self.serverQueue.async {
                guard self.tunnelProcess === process else { return }
                self.tunnelProcess = nil
                self.tunnelPipe = nil
                self.tunnelOutputBuffer = ""
                self.handleTunnelTerminatedOnQueue(epoch: epoch)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            if self.tunnelProcess === process {
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

        tunnelPipe?.fileHandleForReading.readabilityHandler = nil
        tunnelPipe = nil
        tunnelOutputBuffer = ""

        if let proc = tunnelProcess {
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
                for _ in 0..<3 where proc.isRunning {
                    usleep(20_000)
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
            self.scheduleTunnelRestart(epoch: epoch, port: state.3 > 0 ? state.3 : port)
        }
        tunnelTimeoutWorkItem = item
        serverQueue.asyncAfter(deadline: .now() + 20.0, execute: item)
    }

    private func handleTunnelTerminatedOnQueue(epoch: UInt64) {
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

    private func scheduleTunnelRestart(epoch: UInt64, port: UInt16) {
        guard AppSettings.shared.liveShareUseExternalTunnel else { return }
        let stillSharing = lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
        guard stillSharing else { return }

        tunnelTimeoutWorkItem?.cancel()
        tunnelTimeoutWorkItem = nil
        tunnelRestartWorkItem?.cancel()
        tunnelRestartWorkItem = nil

        guard tunnelRestartAttempts < 5 else {
            markTunnelFailed(epoch: epoch, message: "Public tunnel unavailable. Retry from the Live Link banner.")
            return
        }

        tunnelRestartAttempts += 1
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
        tunnelTimeoutWorkItem?.cancel()
        tunnelTimeoutWorkItem = nil
        tunnelRestartWorkItem?.cancel()
        tunnelRestartWorkItem = nil

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
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range, in: text) else { return }

        let baseURLString = String(text[range])
        guard let baseURL = URL(string: baseURLString),
              let host = baseURL.host else { return }

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
            tunnelRestartAttempts = 0
        }

        if let validURL = updatedURL {
            AppLog.liveShare.info("Public Live Share tunnel ready on host \(host, privacy: .public)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.urlDidUpdateNotification, object: self, userInfo: ["url": validURL])
                self.notifyStateChange()
            }
        }
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

            async function decryptEnvelope(payload) {
                const envelope = typeof payload === 'string' ? JSON.parse(payload) : payload;
                if (!envelope || envelope.v !== 1 || typeof envelope.d !== 'string') {
                    throw new Error('Unsupported envelope');
                }
                const combined = base64urlToBytes(envelope.d);
                if (combined.length < 28) throw new Error('Invalid envelope');
                const iv = combined.slice(0, 12);
                const ciphertext = combined.slice(12);
                const plaintext = await window.crypto.subtle.decrypt(
                    { name: 'AES-GCM', iv }, sessionCryptoKey, ciphertext
                );
                return new TextDecoder().decode(plaintext);
            }

            function showLinkError() {
                if (linkErrorShown) return;
                linkErrorShown = true;
                emptyState.style.display = '';
                emptyStateLabel.textContent = 'This Live Link is incomplete or corrupted. Copy the full link including the #key fragment.';
                connPill.className = 'status-pill offline';
                connLabel.textContent = 'Link error';
            }

            function enqueueDecrypted(payload, handler) {
                if (!PAYLOAD_ENCRYPTED) {
                    try { handler(JSON.parse(payload)); } catch (err) {}
                    return;
                }
                decryptChain = decryptChain
                    .then(async () => {
                        const text = await decryptEnvelope(payload);
                        handler(JSON.parse(text));
                    })
                    .catch(() => { showLinkError(); });
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
                if (typeof status.paused === 'boolean') {
                    hostPaused = status.paused;
                    setConnectionState(true, hostPaused ? 'Paused' : 'Live');
                }
                if (typeof status.viewerCount === 'number') updateViewerCount(status.viewerCount);
                if (status.clearCaller) {
                    streamContainer.querySelectorAll('[data-speaker="Caller"]').forEach(card => {
                        const evictedId = card.getAttribute('data-event-id');
                        if (evictedId) finalizedCardsById.delete(evictedId);
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

            function getOrCreateLiveCard(speaker) {
                if (liveSlots[speaker] && document.body.contains(liveSlots[speaker])) return liveSlots[speaker];
                const card = createCardElement(speaker, true);
                streamContainer.appendChild(card);
                while (streamContainer.children.length > 80) {
                    const first = streamContainer.firstElementChild;
                    if (first && !first.classList.contains('live')) {
                        const evictedId = first.getAttribute('data-event-id');
                        if (evictedId) finalizedCardsById.delete(evictedId);
                        streamContainer.removeChild(first);
                    } else break;
                }
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
                if (ev.isFinal && ev.id && renderedIds.has(ev.id)) {
                    const existingCard = finalizedCardsById.get(ev.id);
                    if (existingCard && document.body.contains(existingCard)) populateCardContent(existingCard, ev);
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
                } else {
                    populateCardContent(getOrCreateLiveCard(ev.speaker), ev);
                }
                if (!isBatchHistory) scrollToBottom(false);
            }

            let eventSource = null;
            let pollInterval = null;

            function startPollingFallback() {
                if (pollInterval) return;
                pollState();
                pollInterval = setInterval(pollState, 1500);
            }
            function stopPollingFallback() {
                if (pollInterval) { clearInterval(pollInterval); pollInterval = null; }
            }

            function connectSSE() {
                if (eventSource) eventSource.close();
                eventSource = new EventSource(BASE_PATH + '/events');
                eventSource.onopen = () => { stopPollingFallback(); setConnectionState(true, 'Live'); };
                eventSource.addEventListener('history', (e) => {
                    enqueueDecrypted(e.data, (history) => {
                        if (history && history.length > 0) {
                            emptyState.style.display = 'none';
                            history.forEach(item => handleCaptionEvent(item, true));
                            scrollToBottom(true);
                        }
                    });
                });
                eventSource.addEventListener('caption', (e) => {
                    enqueueDecrypted(e.data, (ev) => handleCaptionEvent(ev, false));
                });
                eventSource.addEventListener('status', (e) => {
                    try { handleStatusEvent(JSON.parse(e.data)); } catch (err) {}
                });
                eventSource.onerror = () => {
                    setConnectionState(false, 'Reconnecting');
                    startPollingFallback();
                };
            }

            async function pollState() {
                let envelope;
                try {
                    const res = await fetch(BASE_PATH + '/api/state');
                    if (!res.ok) {
                        setConnectionState(false, 'Reconnecting');
                        return;
                    }
                    envelope = await res.json();
                } catch (e) {
                    setConnectionState(false, 'Reconnecting');
                    return;
                }
                let data;
                if (PAYLOAD_ENCRYPTED) {
                    try {
                        data = JSON.parse(await decryptEnvelope(envelope));
                    } catch (e) {
                        showLinkError();
                        return;
                    }
                } else {
                    data = envelope;
                }
                setConnectionState(true, 'Live');
                if (data.history && Array.isArray(data.history)) {
                    emptyState.style.display = 'none';
                    data.history.forEach(item => handleCaptionEvent(item, true));
                }
                if (data.callerPartial) handleCaptionEvent(data.callerPartial, false);
                if (data.micPartial) handleCaptionEvent(data.micPartial, false);
                handleStatusEvent({ paused: !!data.isPaused, viewerCount: data.viewerCount });
                scrollToBottom(false);
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
