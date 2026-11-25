import Foundation
import Network
import AppKit
import Security
import Darwin
import Compression
import zlib
import os

struct LiveCaptionEvent: Codable, Sendable, Equatable {
    let id: String
    let timestamp: String
    let timestampMs: Int64
    let speaker: String
    let originalText: String
    let translatedText: String
    let sourceLangCode: String
    let targetLangCode: String
    let isFinal: Bool
    let isUntranslated: Bool

    init(
        id: String = UUID().uuidString,
        timestamp: String,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
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
        self.timestampMs = timestampMs
        self.speaker = speaker
        self.originalText = originalText
        self.translatedText = translatedText
        self.sourceLangCode = sourceLangCode
        self.targetLangCode = targetLangCode
        self.isFinal = isFinal
        self.isUntranslated = isUntranslated
    }
}

struct ParsedHTTPRequest: Sendable, Equatable {
    let method: String
    let path: String
    let host: String?
    let hasProxyHeaders: Bool
    let viewerID: String?
    let acceptLanguage: String?
    let acceptsGzip: Bool

    init(
        method: String,
        path: String,
        host: String?,
        hasProxyHeaders: Bool = false,
        viewerID: String? = nil,
        acceptLanguage: String? = nil,
        acceptsGzip: Bool = false
    ) {
        self.method = method
        self.path = path
        self.host = host
        self.hasProxyHeaders = hasProxyHeaders
        self.viewerID = viewerID
        self.acceptLanguage = acceptLanguage
        self.acceptsGzip = acceptsGzip
    }
}

enum HTTPRouteAction: Sendable, Equatable {
    case serveHTML
    case serveAPIState
    case serveSSE
    case forbidden
    case notFound
    case methodNotAllowed
}

final class LiveShareManager: @unchecked Sendable {
    static let shared = LiveShareManager()

    static let stateDidChangeNotification = Notification.Name("LiveShareManagerStateDidChangeNotification")
    static let urlDidUpdateNotification = Notification.Name("LiveShareManagerURLDidUpdateNotification")

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .medium
        return df
    }()
    private static let formatterLock = OSAllocatedUnfairLock()

    static let sshTunnelRegex = try! NSRegularExpression(
        pattern: #"https://(?!(?:admin|www|docs|api|status|app|login|auth|blog|help|support|mail|dashboard)\.)(?:[a-zA-Z0-9-]+\.)+(?:lhr\.life|lhr\.rocks|localhost\.run)(?!(?:\.[a-zA-Z0-9-]+)|[a-zA-Z0-9-])"#
    )

    static func extractTunnelURL(
        from text: String,
        regex: NSRegularExpression = sshTunnelRegex
    ) -> URL? {
        let lines = text.components(separatedBy: .newlines)
        for line in lines.reversed() where line.localizedCaseInsensitiveContains("tunneled with tls termination") {
            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.matches(in: line, options: [], range: lineRange).last,
               let range = Range(match.range, in: line),
               let url = URL(string: String(line[range])) {
                return url
            }
        }
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
        var lanIPUnavailable: Bool = false
        var publicURL: URL? = nil
        var lastPublishedPublicURL: URL? = nil
        var publicLinkRotated: Bool = false
        var tunnelHost: String? = nil
        var isTunnelStarting: Bool = false
        var tunnelError: String? = nil
        var serverError: String? = nil
        var activeClientCount: Int = 0
        var isPaused: Bool = false
        var allowLAN: Bool = false
        var useExternalTunnel: Bool = true
        var shareBothSpeakers: Bool = true
        var foreignLanguageCode: String = "es"
        var mainLanguageCode: String = "en"
        var history: [LiveCaptionEvent] = []
        var callerPartial: LiveCaptionEvent? = nil
        var micPartial: LiveCaptionEvent? = nil
    }

    private final class SSEClient: @unchecked Sendable {
        let id: ObjectIdentifier
        let connection: NWConnection
        let encryptPayloads: Bool
        let viewerID: String?
        var pendingSends: Int = 0

        init(connection: NWConnection, encryptPayloads: Bool, viewerID: String? = nil) {
            self.id = ObjectIdentifier(connection)
            self.connection = connection
            self.encryptPayloads = encryptPayloads
            self.viewerID = viewerID
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

    private final class DeferredTeardownState: @unchecked Sendable {
        var didRun: Bool = false
        let oldListener: NWListener?
        let capturedProc: Process?
        var closingConnections: [NWConnection]
        var flushWorkItem: DispatchWorkItem?

        init(oldListener: NWListener?, capturedProc: Process?, closingConnections: [NWConnection]) {
            self.oldListener = oldListener
            self.capturedProc = capturedProc
            self.closingConnections = closingConnections
        }
    }

    private final class ConnectionCloseGate: @unchecked Sendable {
        var didClose: Bool = false
    }

    private struct HTMLCacheKey: Hashable {
        let token: String
        let resolvedLang: String
        let encryptPayloads: Bool
    }

    private struct CachedHTMLResponse {
        let rawData: Data
        var gzipData: Data?
        var didComputeGzip: Bool = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let maxSSEClients = 20
    private let maxPendingSendsPerClient = 8
    private let maxActiveHTTPConnections = 64
    private let maxNonLoopbackHTTPConnections = 48

    private let jsonEncoder = JSONEncoder()
    private var listener: NWListener?
    private var listenerStartupTimeoutWorkItem: DispatchWorkItem?
    private var deferredTeardownListener: NWListener?
    private var deferredTeardownWorkItem: DispatchWorkItem?
    private var deferredTeardownState: DeferredTeardownState?
    private var htmlResponseCache: [HTMLCacheKey: CachedHTMLResponse] = [:]
    private var activeHTTPConnections: [ObjectIdentifier: NWConnection] = [:]
    private var nonLoopbackHTTPConnectionIDs: Set<ObjectIdentifier> = []
    private var sseClients: [ObjectIdentifier: SSEClient] = [:]
    private var pendingSSEHandshakes: [ObjectIdentifier: NWConnection] = [:]
    private var sseStreamSequence: UInt64 = 0
    private var stateSequence: UInt64 = 0
    private var tunnelProcess: Process?
    private var terminatingTunnelProcess: Process?
    private var tunnelPipe: Pipe?
    private var tunnelReadSource: DispatchSourceRead?
    private var tunnelGeneration: UInt64 = 0
    private var tunnelOutputBuffer: String = ""
    private var tunnelPendingLineBuffer: String = ""
    private var hasEstablishedTunnelURLInGeneration: Bool = false
    private var tunnelPartialUTF8Data = Data()
    private var tunnelConnectedUptime: TimeInterval = 0
    private var tunnelTimeoutWorkItem: DispatchWorkItem?
    private var tunnelRestartWorkItem: DispatchWorkItem?
    private var tunnelStabilityWorkItem: DispatchWorkItem?
    private var tunnelRestartAttempts: Int = 0
    private var pingTimer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private var pollingViewers: [String: TimeInterval] = [:]
    private var pollingPruneWorkItem: DispatchWorkItem?
    private let pollingViewerTTL: TimeInterval = 5.0
    private let serverQueue = DispatchQueue(label: "com.callcaption.liveshare.server", qos: .userInitiated)
    private let serverQueueKey = DispatchSpecificKey<Void>()

    var isSharing: Bool {
        lock.withLock { $0.isSharing }
    }

    var publicShareURL: URL? {
        lock.withLock { $0.publicURL }
    }

    var localShareURL: URL? {
        lock.withLock { $0.localURL }
    }

    var displayLANURL: URL? {
        lock.withLock { state in
            guard state.allowLAN, !state.lanIPUnavailable else { return nil }
            return state.localURL
        }
    }

    var effectiveShareURL: URL? {
        lock.withLock { state in
            if let publicURL = state.publicURL {
                return publicURL
            }
            guard (state.allowLAN || !state.useExternalTunnel), !state.lanIPUnavailable else {
                return nil
            }
            return state.localURL
        }
    }

    var isTunnelStarting: Bool {
        lock.withLock { $0.isTunnelStarting }
    }

    var tunnelError: String? {
        lock.withLock { $0.tunnelError }
    }

    var serverError: String? {
        lock.withLock { $0.serverError }
    }

    var lanIPUnavailable: Bool {
        lock.withLock { $0.lanIPUnavailable }
    }

    var publicLinkRotated: Bool {
        lock.withLock { $0.publicLinkRotated }
    }

    var activeClientCount: Int {
        lock.withLock { $0.activeClientCount }
    }

    func acknowledgePublicLinkRotation() {
        let changed = lock.withLock { state -> Bool in
            guard state.publicLinkRotated else { return false }
            state.publicLinkRotated = false
            return true
        }
        if changed {
            notifyStateChange()
        }
    }

    func clearServerError() {
        let changed = lock.withLock { state -> Bool in
            guard !state.isSharing, state.serverError != nil else { return false }
            state.serverError = nil
            return true
        }
        if changed {
            notifyStateChange()
        }
    }

    private init() {
        serverQueue.setSpecific(key: serverQueueKey, value: ())
        Self.reapOrphanedSSHTunnelIfNeeded()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stopSharingSynchronously()
        }
    }


    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1"
    }

    static func buildLocalShareURL(
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


    static func generateSessionToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func extractViewerID(fromQuery query: String) -> String? {
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, kv[0] == "viewer" else { continue }
            let rawValue = String(kv[1])
            let decoded = rawValue.removingPercentEncoding ?? rawValue
            guard !decoded.isEmpty, decoded.count <= 64 else { return nil }
            let valid = decoded.unicodeScalars.allSatisfy { scalar in
                (scalar >= "0" && scalar <= "9")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "a" && scalar <= "z")
                || scalar == "-" || scalar == "_"
            }
            return valid ? decoded : nil
        }
        return nil
    }

    static func parseHTTPRequest(_ raw: String) -> ParsedHTTPRequest? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.utf8.contains(0x0D) else { return nil }
        guard let firstLineEnd = normalized.range(of: "\n") else { return nil }
        let firstLine = String(normalized[..<firstLineEnd.lowerBound])
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let fullPath = String(parts[1])
        let pathParts = fullPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let cleanPath = pathParts.first.map(String.init) ?? fullPath
        let viewerID = pathParts.count > 1 ? extractViewerID(fromQuery: String(pathParts[1])) : nil

        var hostHeader: String? = nil
        var hasProxyHeaders = false
        var acceptLanguageHeader: String? = nil
        var acceptsGzip = false
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
            } else if lowerLine.hasPrefix("accept-language:") {
                let value = line.dropFirst("accept-language:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && acceptLanguageHeader == nil {
                    acceptLanguageHeader = String(value.prefix(256))
                }
            } else if lowerLine.hasPrefix("accept-encoding:") {
                let value = lowerLine.dropFirst("accept-encoding:".count)
                for rawToken in value.split(separator: ",") {
                    let parts = rawToken.split(separator: ";")
                    let encoding = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
                    guard encoding == "gzip" else { continue }
                    let qZero = parts.dropFirst().contains { param in
                        let trimmed = param.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("q=") else { return false }
                        return Double(trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)) == 0.0
                    }
                    if !qZero {
                        acceptsGzip = true
                    }
                }
            }
        }
        return ParsedHTTPRequest(
            method: method,
            path: cleanPath,
            host: hostHeader,
            hasProxyHeaders: hasProxyHeaders,
            viewerID: viewerID,
            acceptLanguage: acceptLanguageHeader,
            acceptsGzip: acceptsGzip
        )
    }

    static func isAllowedHost(
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

    static func evaluateRoute(
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


    func configure(
        allowLAN: Bool? = nil,
        useExternalTunnel: Bool? = nil,
        shareBothSpeakers: Bool? = nil,
        foreignLanguageCode: String? = nil,
        mainLanguageCode: String? = nil
    ) {
        let previousShareBoth = lock.withLock { state -> Bool in
            let prev = state.shareBothSpeakers
            if let allowLAN { state.allowLAN = allowLAN }
            if let useExternalTunnel { state.useExternalTunnel = useExternalTunnel }
            if let shareBothSpeakers {
                state.shareBothSpeakers = shareBothSpeakers
                if !shareBothSpeakers {
                    state.callerPartial = nil
                }
            }
            if let foreignLanguageCode { state.foreignLanguageCode = foreignLanguageCode }
            if let mainLanguageCode { state.mainLanguageCode = mainLanguageCode }
            return prev
        }
        if let shareBothSpeakers, !shareBothSpeakers, previousShareBoth {
            speakerSharingDidChange()
        }
    }

    func startSharing(
        allowLAN: Bool? = nil,
        useExternalTunnel: Bool? = nil,
        shareBothSpeakers: Bool? = nil,
        foreignLanguageCode: String? = nil,
        mainLanguageCode: String? = nil
    ) {
        let token = Self.generateSessionToken()
        let crypto = LiveShareCrypto()
        let keyFragment = crypto.keyFragment
        let capturedEpoch: UInt64? = lock.withLock { state -> UInt64? in
            if let allowLAN { state.allowLAN = allowLAN }
            if let useExternalTunnel { state.useExternalTunnel = useExternalTunnel }
            if let shareBothSpeakers { state.shareBothSpeakers = shareBothSpeakers }
            if let foreignLanguageCode { state.foreignLanguageCode = foreignLanguageCode }
            if let mainLanguageCode { state.mainLanguageCode = mainLanguageCode }
            guard !state.isSharing else { return nil }
            state.isSharing = true
            state.sessionEpoch &+= 1
            state.clearGeneration = 0
            state.sessionToken = token
            state.sessionKeyFragment = keyFragment
            state.sessionCrypto = crypto
            state.port = 0
            state.localIP = "127.0.0.1"
            state.lanIPUnavailable = false
            state.isTunnelStarting = state.useExternalTunnel
            state.tunnelError = nil
            state.serverError = nil
            state.isPaused = false
            state.publicURL = nil
            state.lastPublishedPublicURL = nil
            state.publicLinkRotated = false
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

    private func clearStateLocked(_ state: inout State, clearServerError: Bool) {
        state.isSharing = false
        state.sessionEpoch &+= 1
        state.clearGeneration = 0
        state.sessionToken = ""
        state.sessionKeyFragment = ""
        state.sessionCrypto = nil
        state.port = 0
        state.localIP = "127.0.0.1"
        state.localURL = nil
        state.lanIPUnavailable = false
        state.isTunnelStarting = false
        state.tunnelError = nil
        if clearServerError {
            state.serverError = nil
        }
        state.publicURL = nil
        state.lastPublishedPublicURL = nil
        state.publicLinkRotated = false
        state.tunnelHost = nil
        state.activeClientCount = 0
        state.isPaused = false
        state.history.removeAll()
        state.callerPartial = nil
        state.micPartial = nil
    }

    @discardableResult
    private func resetSharingState(clearServerError: Bool = true) -> (wasSharing: Bool, crypto: LiveShareCrypto?) {
        lock.withLock { state in
            guard state.isSharing else {
                if clearServerError {
                    state.serverError = nil
                }
                return (false, nil)
            }
            let crypto = state.sessionCrypto
            clearStateLocked(&state, clearServerError: clearServerError)
            return (true, crypto)
        }
    }

    private func failSharingWithServerErrorOnQueue(epoch: UInt64, message: String) {
        let result = lock.withLock { state -> (didFail: Bool, crypto: LiveShareCrypto?) in
            guard state.isSharing && state.sessionEpoch == epoch else { return (false, nil) }
            let crypto = state.sessionCrypto
            clearStateLocked(&state, clearServerError: false)
            state.serverError = message
            return (true, crypto)
        }
        guard result.didFail else { return }
        tearDownServerAndTunnelOnQueue(endingCrypto: result.crypto)
        notifyStateChange()
    }

    func stopSharing() {
        let prevServerError = lock.withLock { $0.serverError }
        let result = resetSharingState(clearServerError: true)
        guard result.wasSharing else {
            if prevServerError != nil {
                notifyStateChange()
            }
            return
        }

        serverQueue.async { [weak self] in
            self?.tearDownServerAndTunnelOnQueue(endingCrypto: result.crypto)
        }

        notifyStateChange()
    }

    func stopSharingSynchronously() {
        let result = resetSharingState(clearServerError: true)
        let work = { [weak self] in
            self?.tearDownServerAndTunnelOnQueue(forceKillSynchronously: true)
        }
        if DispatchQueue.getSpecific(key: serverQueueKey) != nil {
            work()
        } else {
            serverQueue.sync(execute: work)
        }
        if result.wasSharing {
            notifyStateChange()
        }
    }

    private func flushPendingDeferredTeardownOnQueue(forceKillSynchronously: Bool) {
        deferredTeardownWorkItem?.cancel()
        deferredTeardownWorkItem = nil
        if let state = deferredTeardownState {
            deferredTeardownState = nil
            state.didRun = true
            state.flushWorkItem?.cancel()
            state.flushWorkItem = nil
            for conn in state.closingConnections {
                conn.stateUpdateHandler = nil
                conn.cancel()
            }
            state.closingConnections.removeAll()
        }
        if let pendingListener = deferredTeardownListener {
            deferredTeardownListener = nil
            pendingListener.stateUpdateHandler = nil
            pendingListener.newConnectionHandler = nil
            pendingListener.cancel()
        }
        if forceKillSynchronously {
            terminateTunnelProcessOnQueue(forceKillSynchronously: true)
        }
    }

    private func tearDownServerAndTunnelOnQueue(forceKillSynchronously: Bool = false, endingCrypto: LiveShareCrypto? = nil) {
        flushPendingDeferredTeardownOnQueue(forceKillSynchronously: forceKillSynchronously)
        listenerStartupTimeoutWorkItem?.cancel()
        listenerStartupTimeoutWorkItem = nil
        htmlResponseCache.removeAll()
        stopHeartbeatOnQueue()
        stopPathMonitorOnQueue()
        pollingPruneWorkItem?.cancel()
        pollingPruneWorkItem = nil
        pollingViewers.removeAll()
        tunnelRestartAttempts = 0

        let clientsToClose = Array(sseClients.values)
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
        nonLoopbackHTTPConnectionIDs.removeAll()

        let oldListener = listener
        listener = nil
        oldListener?.stateUpdateHandler = nil
        oldListener?.newConnectionHandler = nil

        if !forceKillSynchronously, !clientsToClose.isEmpty {
            tunnelTimeoutWorkItem?.cancel()
            tunnelTimeoutWorkItem = nil
            tunnelRestartWorkItem?.cancel()
            tunnelRestartWorkItem = nil
            tunnelStabilityWorkItem?.cancel()
            tunnelStabilityWorkItem = nil

            let endedData = Data("{}".utf8)
            let needsPlain = clientsToClose.contains { !$0.encryptPayloads }
            let needsEncrypted = clientsToClose.contains { $0.encryptPayloads }
            let plainEndedFrame: Data? = needsPlain ? Self.makeSSEFrame(event: "ended", payload: endedData) : nil
            let encryptedEndedFrame: Data?
            if needsEncrypted, let endingCrypto {
                sseStreamSequence &+= 1
                let seq = sseStreamSequence
                encryptedEndedFrame = (try? endingCrypto.seal(endedData, type: "ended", sequence: seq))
                    .map { Self.makeSSEFrame(event: "ended", payload: $0) }
            } else {
                encryptedEndedFrame = nil
            }
            sseStreamSequence = 0
            stateSequence = 0

            let sendGroup = DispatchGroup()
            var closingConnections: [NWConnection] = []
            closingConnections.reserveCapacity(clientsToClose.count)
            for client in clientsToClose {
                let conn = client.connection
                conn.stateUpdateHandler = nil
                if let frame = client.encryptPayloads ? encryptedEndedFrame : plainEndedFrame {
                    closingConnections.append(conn)
                    sendGroup.enter()
                    conn.send(content: frame, completion: .contentProcessed { _ in
                        conn.cancel()
                        sendGroup.leave()
                    })
                } else {
                    conn.cancel()
                }
            }

            deferredTeardownListener = oldListener
            let teardownState = DeferredTeardownState(
                oldListener: oldListener,
                capturedProc: tunnelProcess,
                closingConnections: closingConnections
            )
            deferredTeardownState = teardownState
            let item = DispatchWorkItem { [weak self] in
                self?.completeDeferredTeardownOnQueue(teardownState)
            }
            deferredTeardownWorkItem = item
            serverQueue.asyncAfter(deadline: .now() + 0.15, execute: item)
            sendGroup.notify(queue: serverQueue) { [weak self] in
                guard let self = self,
                      self.deferredTeardownState === teardownState,
                      !teardownState.didRun else { return }
                let flushItem = DispatchWorkItem { [weak self] in
                    self?.completeDeferredTeardownOnQueue(teardownState)
                }
                teardownState.flushWorkItem = flushItem
                // Allow a brief flush window for /usr/bin/ssh to forward the loopback frame before SIGTERM.
                self.serverQueue.asyncAfter(deadline: .now() + 0.12, execute: flushItem)
            }
        } else {
            for client in clientsToClose {
                client.connection.stateUpdateHandler = nil
                client.connection.cancel()
            }
            sseStreamSequence = 0
            stateSequence = 0
            oldListener?.cancel()
            terminateTunnelProcessOnQueue(forceKillSynchronously: forceKillSynchronously)
        }
    }

    private func completeDeferredTeardownOnQueue(_ state: DeferredTeardownState) {
        guard !state.didRun, deferredTeardownState === state else { return }
        state.didRun = true
        deferredTeardownState = nil
        state.flushWorkItem?.cancel()
        state.flushWorkItem = nil
        deferredTeardownWorkItem?.cancel()
        deferredTeardownWorkItem = nil
        if deferredTeardownListener === state.oldListener {
            deferredTeardownListener = nil
        }
        for conn in state.closingConnections {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        state.closingConnections.removeAll()
        state.oldListener?.cancel()
        if let capturedProc = state.capturedProc, tunnelProcess === capturedProc {
            terminateTunnelProcessOnQueue(forceKillSynchronously: false)
        }
    }


    private func scheduleListenerStartupTimeoutOnQueue(epoch: UInt64, message: String) {
        listenerStartupTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.listenerStartupTimeoutWorkItem = nil
            let stillWaiting = self.lock.withLock { $0.isSharing && $0.sessionEpoch == epoch && $0.port == 0 }
            guard stillWaiting else { return }
            AppLog.liveShare.error("NWListener startup timed out while waiting for network")
            self.failSharingWithServerErrorOnQueue(epoch: epoch, message: message)
        }
        listenerStartupTimeoutWorkItem = item
        serverQueue.asyncAfter(deadline: .now() + 9.0, execute: item)
    }

    private func startLocalServerOnQueue(epoch: UInt64) {
        tearDownServerAndTunnelOnQueue()
        tunnelRestartAttempts = 0

        let (isStillValid, allowLAN) = lock.withLock { ($0.isSharing && $0.sessionEpoch == epoch, $0.allowLAN) }
        guard isStillValid else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false

        if !allowLAN {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        }

        let serverFailedMessage = AppL10n.string(
            "share.server.failed",
            fallback: "Local live link server failed to start."
        )

        guard let validListener = try? NWListener(using: parameters) else {
            AppLog.liveShare.error("Failed to create NWListener")
            failSharingWithServerErrorOnQueue(epoch: epoch, message: serverFailedMessage)
            return
        }

        self.listener = validListener
        scheduleListenerStartupTimeoutOnQueue(epoch: epoch, message: serverFailedMessage)

        validListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            let stillActive = self.lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
            guard stillActive else {
                validListener.cancel()
                return
            }

            switch state {
            case .ready:
                self.listenerStartupTimeoutWorkItem?.cancel()
                self.listenerStartupTimeoutWorkItem = nil
                guard let boundPort = validListener.port?.rawValue, boundPort > 0 else {
                    self.failSharingWithServerErrorOnQueue(epoch: epoch, message: serverFailedMessage)
                    return
                }
                let existingPort = self.lock.withLock { $0.sessionEpoch == epoch ? $0.port : 0 }
                if existingPort == boundPort {
                    if allowLAN {
                        self.refreshLANAddressOnQueue(epoch: epoch)
                    }
                    return
                }
                AppLog.liveShare.info("Live Share server listening on port \(boundPort, privacy: .public) (LAN: \(allowLAN, privacy: .public))")
                self.setupLocalAndTunnelURLsOnQueue(port: boundPort, allowLAN: allowLAN, epoch: epoch)
            case .waiting(let error):
                AppLog.liveShare.error("NWListener waiting: \(error.localizedDescription, privacy: .public)")
                let hasBoundPort = self.lock.withLock { $0.sessionEpoch == epoch && $0.port > 0 }
                if !hasBoundPort && self.listenerStartupTimeoutWorkItem == nil {
                    self.scheduleListenerStartupTimeoutOnQueue(epoch: epoch, message: serverFailedMessage)
                }
            case .failed(let error):
                self.listenerStartupTimeoutWorkItem?.cancel()
                self.listenerStartupTimeoutWorkItem = nil
                AppLog.liveShare.error("NWListener failed: \(error.localizedDescription, privacy: .public)")
                self.failSharingWithServerErrorOnQueue(epoch: epoch, message: serverFailedMessage)
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
        let detectedLANIP = allowLAN ? Self.getLocalIPAddress() : "127.0.0.1"
        let hasRealLAN = !allowLAN || detectedLANIP != nil
        let effectiveIP = detectedLANIP ?? "127.0.0.1"
        let (updated, initialURL): (Bool, URL?) = lock.withLock { state -> (Bool, URL?) in
            guard state.isSharing && state.sessionEpoch == epoch else { return (false, nil) }
            state.port = port
            state.localIP = effectiveIP
            state.lanIPUnavailable = allowLAN && !hasRealLAN
            state.localURL = Self.buildLocalShareURL(
                host: effectiveIP,
                port: port,
                sessionToken: state.sessionToken,
                sessionKeyFragment: state.sessionKeyFragment
            )
            let url = (state.allowLAN || !state.useExternalTunnel) && !state.lanIPUnavailable ? state.localURL : nil
            return (true, url)
        }
        guard updated else { return }

        if allowLAN {
            startPathMonitorOnQueue(epoch: epoch)
        }
        if let initialURL {
            notifyURLUpdate(initialURL)
        }
        notifyStateChange()
        startTunnelProcessOnQueue(port: port, epoch: epoch)
    }

    private func startPathMonitorOnQueue(epoch: UInt64) {
        stopPathMonitorOnQueue()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.refreshLANAddressOnQueue(epoch: epoch)
        }
        monitor.start(queue: serverQueue)
        pathMonitor = monitor
    }

    private func stopPathMonitorOnQueue() {
        pathMonitor?.pathUpdateHandler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func refreshLANAddressOnQueue(epoch: UInt64) {
        let detectedLANIP = Self.getLocalIPAddress()
        let (changed, updatedURL): (Bool, URL?) = lock.withLock { state -> (Bool, URL?) in
            guard state.isSharing, state.sessionEpoch == epoch, state.allowLAN, state.port > 0 else {
                return (false, nil)
            }
            let newIP = detectedLANIP ?? "127.0.0.1"
            let newUnavailable = (detectedLANIP == nil)
            let newLocalURL = Self.buildLocalShareURL(
                host: newIP,
                port: state.port,
                sessionToken: state.sessionToken,
                sessionKeyFragment: state.sessionKeyFragment
            )
            let ipOrFlagChanged = (state.localIP != newIP)
                || (state.lanIPUnavailable != newUnavailable)
                || (state.localURL != newLocalURL)
            guard ipOrFlagChanged else { return (false, nil) }
            state.localIP = newIP
            state.lanIPUnavailable = newUnavailable
            state.localURL = newLocalURL
            let activeURL = state.publicURL ?? ((state.allowLAN || !state.useExternalTunnel) && !newUnavailable ? newLocalURL : nil)
            return (true, activeURL)
        }
        guard changed else { return }
        if let updatedURL {
            notifyURLUpdate(updatedURL)
        }
        notifyStateChange()
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

    private static func isVerifiedNonLoopbackIP(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let addr):
            let bytes = addr.rawValue
            guard bytes.count == 4 else { return false }
            return bytes[0] != 127 && bytes != Data([0, 0, 0, 0])
        case .ipv6(let addr):
            if addr == .loopback || addr == .any { return false }
            let bytes = addr.rawValue
            guard bytes.count == 16 else { return false }
            if bytes.starts(with: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127]) {
                return false
            }
            return true
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    private func untrackHTTPConnectionOnQueue(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        activeHTTPConnections.removeValue(forKey: id)
        nonLoopbackHTTPConnectionIDs.remove(id)
    }

    private func handleIncomingConnectionOnQueue(_ connection: NWConnection, epoch: UInt64) {
        let isStillValid = lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
        let remoteEndpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        let isNonLoopback = Self.isVerifiedNonLoopbackIP(remoteEndpoint)
            && !Self.isLoopbackEndpoint(connection.currentPath?.localEndpoint)
        let withinCapacity = activeHTTPConnections.count < maxActiveHTTPConnections
            && (!isNonLoopback || nonLoopbackHTTPConnectionIDs.count < maxNonLoopbackHTTPConnections)
        guard isStillValid, withinCapacity else {
            connection.cancel()
            return
        }

        let connID = ObjectIdentifier(connection)
        activeHTTPConnections[connID] = connection
        if isNonLoopback {
            nonLoopbackHTTPConnectionIDs.insert(connID)
        }

        let timeoutItem = DispatchWorkItem { [weak self, weak connection] in
            guard let connection = connection else { return }
            self?.untrackHTTPConnectionOnQueue(connection)
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        let timeoutToken = HeaderTimeoutToken(timeoutItem)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                timeoutToken.cancel()
                if let connection {
                    self?.untrackHTTPConnectionOnQueue(connection)
                }
            default:
                break
            }
        }

        connection.start(queue: serverQueue)
        serverQueue.asyncAfter(deadline: .now() + 5.0, execute: timeoutItem)

        receiveHTTPHeaderOnQueue(connection: connection, accumulated: Data(), timeoutItem: timeoutToken, epoch: epoch)
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

            let prevCount = accumulated.count
            var buffer = accumulated
            if let data = content {
                buffer.append(data)
            }

            let hasHeaderTerminator: Bool = buffer.withUnsafeBytes { rawBuf in
                let total = rawBuf.count
                guard total >= 2, let bytes = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return false }
                let start = max(0, prevCount - 3)
                guard start <= total - 2 else { return false }
                for i in start...(total - 2) {
                    if bytes[i] == 0x0A && bytes[i + 1] == 0x0A {
                        return true
                    }
                    if i + 3 < total
                        && bytes[i] == 0x0D
                        && bytes[i + 1] == 0x0A
                        && bytes[i + 2] == 0x0D
                        && bytes[i + 3] == 0x0A {
                        return true
                    }
                }
                return false
            }

            if hasHeaderTerminator {
                let requestString = String(decoding: buffer, as: UTF8.self)
                timeoutItem.cancel()
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

        let (isSharingNow, token, localIP, tunnelHost, allowLAN) = lock.withLock { state -> (Bool, String, String, String?, Bool) in
            guard state.isSharing && state.sessionEpoch == epoch else {
                return (false, "", "127.0.0.1", nil, false)
            }
            return (true, state.sessionToken, state.localIP, state.tunnelHost, state.allowLAN)
        }
        guard isSharingNow else {
            untrackHTTPConnectionOnQueue(connection)
            connection.cancel()
            return
        }

        let action = Self.evaluateRoute(
            request: parsed,
            sessionToken: token,
            localIP: localIP,
            allowLAN: allowLAN,
            tunnelHost: tunnelHost
        )

        let host = parsed.host?.lowercased()
        let isLoopbackHeader = host.map { Self.isLoopbackHost($0) } ?? false
        let isTunnelHeader = tunnelHost.map { host == $0.lowercased() } ?? false
        let remoteEndpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        let isVerifiedNonLoopbackSocket = Self.isVerifiedNonLoopbackIP(remoteEndpoint)
            && Self.isVerifiedNonLoopbackIP(connection.currentPath?.localEndpoint)
        let arrivedOnLoopbackSocket = !isVerifiedNonLoopbackSocket
        let includeBody = parsed.method != "HEAD"

        // Prevent tunnel intermediaries or local loopback clients from downgrading payload
        // encryption by spoofing the LAN Host header. Fail closed if socket endpoints are unknown.
        if !isLoopbackHeader && !isTunnelHeader && (arrivedOnLoopbackSocket || parsed.hasProxyHeaders) {
            sendSimpleResponse(connection: connection, status: "403 Forbidden", body: "Forbidden", includeBody: includeBody)
            return
        }
        let isVerifiedLANRequest = allowLAN && isVerifiedNonLoopbackSocket && !isLoopbackHeader && !isTunnelHeader && !parsed.hasProxyHeaders
        let encryptPayloads = !isVerifiedLANRequest

        switch action {
        case .serveHTML:
            handleServeHTMLOnQueue(
                connection,
                token: token,
                encryptPayloads: encryptPayloads,
                includeBody: includeBody,
                acceptLanguage: parsed.acceptLanguage,
                acceptsGzip: parsed.acceptsGzip
            )
        case .serveAPIState:
            handleAPIStateOnQueue(connection, encryptPayloads: encryptPayloads, includeBody: includeBody, epoch: epoch, viewerID: parsed.viewerID)
        case .serveSSE:
            handleSSEConnectionOnQueue(connection, encryptPayloads: encryptPayloads, epoch: epoch, viewerID: parsed.viewerID)
        case .forbidden:
            sendSimpleResponse(connection: connection, status: "403 Forbidden", body: "Forbidden", includeBody: includeBody)
        case .notFound:
            sendSimpleResponse(connection: connection, status: "404 Not Found", body: "Not Found", includeBody: includeBody)
        case .methodNotAllowed:
            sendSimpleResponse(connection: connection, status: "405 Method Not Allowed", body: "Method Not Allowed", includeBody: includeBody)
        }
    }

    static func gzipCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let dstCapacity = max(64, data.count + 512)
        var dstBuffer = [UInt8](repeating: 0, count: dstCapacity)
        let compressedCount = data.withUnsafeBytes { rawBuf -> Int in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&dstBuffer, dstCapacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard compressedCount > 0 else { return nil }

        let crc: UInt32 = data.withUnsafeBytes { rawBuf in
            var running = zlib.crc32(0, nil, 0)
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else {
                return UInt32(truncatingIfNeeded: running)
            }
            var offset = 0
            while offset < rawBuf.count {
                let chunk = min(rawBuf.count - offset, Int(UInt32.max))
                running = zlib.crc32(running, base.advanced(by: offset), uInt(chunk))
                offset += chunk
            }
            return UInt32(truncatingIfNeeded: running)
        }

        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        out.append(contentsOf: dstBuffer[..<compressedCount])
        var crcLE = crc.littleEndian
        var sizeLE = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crcLE) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &sizeLE) { out.append(contentsOf: $0) }
        return out
    }

    private func sendHTTPResponseAndCloseOnQueue(connection: NWConnection, data: Data) {
        let closeGate = ConnectionCloseGate()
        let finishClose: @Sendable (LiveShareManager?, NWConnection?) -> Void = { manager, conn in
            guard !closeGate.didClose else { return }
            closeGate.didClose = true
            guard let conn else { return }
            manager?.untrackHTTPConnectionOnQueue(conn)
            conn.stateUpdateHandler = nil
            conn.cancel()
        }

        let sendTimeout = DispatchWorkItem { [weak self, weak connection] in
            finishClose(self, connection)
        }
        let sendTimeoutToken = HeaderTimeoutToken(sendTimeout)
        serverQueue.asyncAfter(deadline: .now() + 20.0, execute: sendTimeout)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed({ [weak self, weak connection] sendError in
            sendTimeoutToken.cancel()
            guard let connection else { return }
            if sendError != nil || closeGate.didClose {
                finishClose(self, connection)
                return
            }
            guard let self else {
                finishClose(nil, connection)
                return
            }
            let graceClose = DispatchWorkItem { [weak self, weak connection] in
                finishClose(self, connection)
            }
            let graceToken = HeaderTimeoutToken(graceClose)
            self.serverQueue.asyncAfter(deadline: .now() + 0.5, execute: graceClose)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak connection] _, _, _, _ in
                graceToken.cancel()
                finishClose(self, connection)
            }
        }))
    }

    private func sendSimpleResponse(connection: NWConnection, status: String, body: String, includeBody: Bool = true) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var fullData = Data(header.utf8)
        if includeBody {
            fullData.append(bodyData)
        }
        sendHTTPResponseAndCloseOnQueue(connection: connection, data: fullData)
    }

    private func handleServeHTMLOnQueue(
        _ connection: NWConnection,
        token: String,
        encryptPayloads: Bool,
        includeBody: Bool = true,
        acceptLanguage: String? = nil,
        acceptsGzip: Bool = false
    ) {
        let langKey = ReceiverWebAppHTML.resolvedLanguageKey(acceptLanguage: acceptLanguage)
        let cacheKey = HTMLCacheKey(token: token, resolvedLang: langKey, encryptPayloads: encryptPayloads)
        var cached: CachedHTMLResponse
        if let existing = htmlResponseCache[cacheKey] {
            cached = existing
        } else {
            let html = ReceiverWebAppHTML.html(
                forToken: token,
                encryptPayloads: encryptPayloads,
                acceptLanguage: acceptLanguage
            )
            cached = CachedHTMLResponse(rawData: Data(html.utf8))
            htmlResponseCache[cacheKey] = cached
        }

        let rawData = cached.rawData
        let compressed: Data?
        if acceptsGzip && rawData.count >= 256 {
            if !cached.didComputeGzip {
                cached.gzipData = Self.gzipCompress(rawData)
                cached.didComputeGzip = true
                htmlResponseCache[cacheKey] = cached
            }
            compressed = cached.gzipData
        } else {
            compressed = nil
        }
        let isGzipped = compressed != nil && compressed!.count < rawData.count
        let responseBody = isGzipped ? compressed! : rawData
        let encodingHeader = isGzipped ? "Content-Encoding: gzip\r\n" : ""
        let csp = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\(encodingHeader)Content-Length: \(responseBody.count)\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: \(csp)\r\nCross-Origin-Resource-Policy: same-origin\r\nReferrer-Policy: no-referrer\r\nVary: Accept-Encoding, Accept-Language\r\nConnection: close\r\nCache-Control: no-cache, no-store, must-revalidate\r\n\r\n"

        var fullData = Data(header.utf8)
        if includeBody {
            fullData.append(responseBody)
        }

        sendHTTPResponseAndCloseOnQueue(connection: connection, data: fullData)
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

    private func handleAPIStateOnQueue(_ connection: NWConnection, encryptPayloads: Bool, includeBody: Bool = true, epoch: UInt64, viewerID: String? = nil) {
        if includeBody, let viewerID {
            registerPollingViewerOnQueue(viewerID, epoch: epoch)
        }
        let (responseModel, crypto) = lock.withLock { state -> (APIStateResponse?, LiveShareCrypto?) in
            guard state.isSharing && state.sessionEpoch == epoch else { return (nil, nil) }
            let model = APIStateResponse(
                foreignLanguage: state.foreignLanguageCode,
                mainLanguage: state.mainLanguageCode,
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
            untrackHTTPConnectionOnQueue(connection)
            connection.cancel()
            return
        }

        guard let jsonData = try? jsonEncoder.encode(responseModel) else {
            untrackHTTPConnectionOnQueue(connection)
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
            untrackHTTPConnectionOnQueue(connection)
            connection.cancel()
            return
        }

        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(responseData.count)\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nCross-Origin-Resource-Policy: same-origin\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var fullData = Data(header.utf8)
        if includeBody {
            fullData.append(responseData)
        }

        sendHTTPResponseAndCloseOnQueue(connection: connection, data: fullData)
    }

    private func handleSSEConnectionOnQueue(_ connection: NWConnection, encryptPayloads: Bool, epoch: UInt64, viewerID: String? = nil) {
        guard sseClients.count + pendingSSEHandshakes.count < maxSSEClients else {
            sendSimpleResponse(connection: connection, status: "503 Service Unavailable", body: "Server busy")
            return
        }

        untrackHTTPConnectionOnQueue(connection)
        let headerData = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache, no-transform\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nCross-Origin-Resource-Policy: same-origin\r\nConnection: keep-alive\r\n\r\n".utf8)

        let client = SSEClient(connection: connection, encryptPayloads: encryptPayloads, viewerID: viewerID)
        let id = client.id
        pendingSSEHandshakes[id] = connection

        let handshakeTimeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self = self else { return }
            if self.pendingSSEHandshakes.removeValue(forKey: id) != nil {
                connection?.stateUpdateHandler = nil
                connection?.cancel()
            }
        }
        let handshakeTimeoutToken = HeaderTimeoutToken(handshakeTimeout)
        serverQueue.asyncAfter(deadline: .now() + 5.0, execute: handshakeTimeout)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                handshakeTimeoutToken.cancel()
                self?.pendingSSEHandshakes.removeValue(forKey: id)
                self?.removeSSEClientOnQueue(id: id)
            default:
                break
            }
        }

        connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
            handshakeTimeoutToken.cancel()
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
            if let viewerID, self.pollingViewers.removeValue(forKey: viewerID) != nil {
                let earliest = self.pollingViewers.values.min()
                self.schedulePollingPruneOnQueue(
                    nextExpiration: earliest,
                    now: ProcessInfo.processInfo.systemUptime,
                    epoch: epoch
                )
            }
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

    private func pruneExpiredPollingViewersOnQueue(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        guard !pollingViewers.isEmpty else { return nil }
        pollingViewers = pollingViewers.filter { $0.value > now }
        return pollingViewers.values.min()
    }

    private func schedulePollingPruneOnQueue(nextExpiration: TimeInterval?, now: TimeInterval, epoch: UInt64) {
        pollingPruneWorkItem?.cancel()
        pollingPruneWorkItem = nil
        guard let nextExpiration else { return }
        let delay = max(0.25, (nextExpiration - now) + 0.1)
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pollingPruneWorkItem = nil
            let currentNow = ProcessInfo.processInfo.systemUptime
            let earliest = self.pruneExpiredPollingViewersOnQueue(now: currentNow)
            self.updateActiveClientCountOnQueue()
            let stillActive = self.lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
            if stillActive, let earliest {
                self.schedulePollingPruneOnQueue(nextExpiration: earliest, now: currentNow, epoch: epoch)
            }
        }
        pollingPruneWorkItem = item
        serverQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func registerPollingViewerOnQueue(_ viewerID: String, epoch: UInt64) {
        let isStillActive = lock.withLock { $0.isSharing && $0.sessionEpoch == epoch }
        guard isStillActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        _ = pruneExpiredPollingViewersOnQueue(now: now)
        if pollingViewers[viewerID] != nil || pollingViewers.count < 100 {
            pollingViewers[viewerID] = now + pollingViewerTTL
        }
        let earliest = pollingViewers.values.min()
        schedulePollingPruneOnQueue(nextExpiration: earliest, now: now, epoch: epoch)
        updateActiveClientCountOnQueue()
    }

    private func updateActiveClientCountOnQueue(excluding excludedClientID: ObjectIdentifier? = nil) {
        _ = pruneExpiredPollingViewersOnQueue()
        let sseViewerIDs = Set(sseClients.values.compactMap(\.viewerID))
        let uniquePollingCount = pollingViewers.keys.reduce(into: 0) { count, viewerID in
            if !sseViewerIDs.contains(viewerID) {
                count += 1
            }
        }
        let count = sseClients.count + uniquePollingCount
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
        let pingData = Self.makeSSEFrame(event: "ping", payload: Data("{}".utf8))
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


    func broadcastCaption(
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

        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let idStr = utteranceID.uuidString
        let isCaller = speaker.lowercased() == "caller"

        let (event, epoch, clearGen, crypto): (LiveCaptionEvent?, UInt64, UInt64, LiveShareCrypto?) = lock.withLock { state -> (LiveCaptionEvent?, UInt64, UInt64, LiveShareCrypto?) in
            guard state.isSharing else { return (nil, 0, 0, nil) }
            if !state.shareBothSpeakers && isCaller {
                return (nil, 0, 0, nil)
            }
            if isFinal {
                var eventToBroadcast: LiveCaptionEvent
                if let idx = state.history.firstIndex(where: { $0.id == idStr }) {
                    let prev = state.history[idx]
                    eventToBroadcast = LiveCaptionEvent(
                        id: prev.id,
                        timestamp: prev.timestamp,
                        timestampMs: prev.timestampMs,
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
                    let locale = AppL10n.effectiveUILocale
                    let timeStr = Self.formatterLock.withLock {
                        if Self.timeFormatter.locale != locale {
                            Self.timeFormatter.locale = locale
                        }
                        return Self.timeFormatter.string(from: now)
                    }
                    eventToBroadcast = LiveCaptionEvent(
                        id: idStr,
                        timestamp: timeStr,
                        timestampMs: nowMs,
                        speaker: speaker,
                        originalText: original,
                        translatedText: translated,
                        sourceLangCode: sourceLangCode,
                        targetLangCode: targetLangCode,
                        isFinal: true,
                        isUntranslated: isUntranslated
                    )
                    state.history.append(eventToBroadcast)
                }

                if state.history.count > 100 {
                    state.history.removeFirst(state.history.count - 100)
                }
                if isCaller {
                    if state.callerPartial?.id == eventToBroadcast.id {
                        state.callerPartial = nil
                    }
                } else {
                    if state.micPartial?.id == eventToBroadcast.id {
                        state.micPartial = nil
                    }
                }
                return (eventToBroadcast, state.sessionEpoch, state.clearGeneration, state.sessionCrypto)
            } else {
                if state.history.contains(where: { $0.id == idStr }) {
                    return (nil, 0, 0, nil)
                }
                let partialEvent = LiveCaptionEvent(
                    id: idStr,
                    timestamp: "",
                    timestampMs: nowMs,
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

    func speakerSharingDidChange() {
        let shareCaller = lock.withLock { $0.shareBothSpeakers }
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

    func clearHistoryForPrivacy() {
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

    func broadcastPauseState(_ paused: Bool) {
        let (changed, viewerCount, epoch) = lock.withLock { state -> (Bool, Int, UInt64) in
            if paused {
                state.callerPartial = nil
                state.micPartial = nil
            }
            guard state.isSharing, state.isPaused != paused else { return (false, 0, 0) }
            state.isPaused = paused
            return (true, state.activeClientCount, state.sessionEpoch)
        }
        guard changed else { return }
        sendStatusEvent(StatusEvent(paused: paused, viewerCount: viewerCount), epoch: epoch)
    }


    private static let appSupportDirectory: URL = {
        if ProcessInfo.processInfo.environment["CALLCAPTION_TEST"] == "1",
           let testPath = ProcessInfo.processInfo.environment["CALLCAPTION_TEST_DIR"],
           !testPath.isEmpty {
            return URL(fileURLWithPath: testPath, isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("CallCaption", isDirectory: true)
    }()

    static func ensurePrivateDirectory(_ url: URL, permissions: Int = 0o700) throws {
        let standardizedURL = url.standardizedFileURL
        let appSupportURL = appSupportDirectory.standardizedFileURL
        if standardizedURL != appSupportURL,
           standardizedURL.path.hasPrefix(appSupportURL.path + "/") {
            try ensurePrivateDirectory(appSupportURL, permissions: 0o700)
        }

        var st = Darwin.stat()
        if Darwin.lstat(standardizedURL.path, &st) == 0 {
            let fileType = st.st_mode & S_IFMT
            if fileType == S_IFLNK {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ELOOP),
                    userInfo: [NSLocalizedDescriptionKey: "Refusing symlink directory at \(standardizedURL.path)"]
                )
            }
            if fileType == S_IFDIR {
                if (Int(st.st_mode) & 0o777) == permissions {
                    return
                }
                let fd = Darwin.open(standardizedURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if fd >= 0 {
                    defer { Darwin.close(fd) }
                    if Darwin.fchmod(fd, mode_t(permissions)) == 0 {
                        return
                    }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
                }
            }
        }

        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: permissions)]
        )
        let fd = Darwin.open(standardizedURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
        defer { Darwin.close(fd) }
        guard Darwin.fchmod(fd, mode_t(permissions)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
    }

    static func writePrivateData(_ data: Data, to url: URL) throws {
        let targetURL = url.standardizedFileURL
        var targetStat = Darwin.stat()
        if Darwin.lstat(targetURL.path, &targetStat) == 0 {
            if (targetStat.st_mode & S_IFMT) == S_IFLNK {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ELOOP),
                    userInfo: [NSLocalizedDescriptionKey: "Refusing symlink file at \(targetURL.path)"]
                )
            }
        }

        let parentURL = targetURL.deletingLastPathComponent().standardizedFileURL
        var st = Darwin.stat()
        let needsEnsure: Bool
        if Darwin.lstat(parentURL.path, &st) == 0 {
            let fileType = st.st_mode & S_IFMT
            needsEnsure = (fileType != S_IFDIR) || ((Int(st.st_mode) & 0o777) != 0o700)
        } else {
            needsEnsure = true
        }
        if needsEnsure {
            try ensurePrivateDirectory(parentURL, permissions: 0o700)
        }

        let tempURL = parentURL.appendingPathComponent(".\(targetURL.lastPathComponent).tmp.\(UUID().uuidString)")
        let fd = Darwin.open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        if fd < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var fdOpen = true
        var moved = false
        defer {
            if fdOpen { _ = Darwin.close(fd) }
            if !moved { try? FileManager.default.removeItem(at: tempURL) }
        }

        _ = Darwin.fchmod(fd, mode_t(0o600))
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress, !rawBuffer.isEmpty else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                offset += written
            }
        }

        fdOpen = false
        if Darwin.close(fd) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if Darwin.rename(tempURL.path, targetURL.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        moved = true
    }

    static let pinnedSSHKnownHosts: String = """
    localhost.run,*.localhost.run,ssh.localhost.run,*.lhr.life ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILVqOuSMnyeGDVO1lG6EaG5In/dXABCchhmHKkuRU2s9
    localhost.run,*.localhost.run,ssh.localhost.run,*.lhr.life ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC3lJnhW1oCXuAYV9IBdcJA+Vx7AHL5S/ZQvV2fhceOAPgO2kNQZla6xvUwoE4iw8lYu3zoE1KtieCU9yInWOVI6W/wFaT/ETH1tn55T2FVsK/zaxPiHZVJGLPPdEEid0vS2p1JDfc9onZ0pNSHLl1QusIOeMUyZ2bUMMLLgw46KOT9S3s/LmxgoJ3PocVUn5rVXz/Dng7Y8jYNe4IFrZOAUsi7hNBa+OYja6ceefpDvNDEJ1BdhbYfGolBdNA7f+FNl0kfaWru4Cblr843wBe2ckO/sNqgeAMXO/qH+SSgQxUXF2AgAw+TGp3yCIyYoOPvOgvcPsQziJLmDbUuQpnH
    """ + "\n"

    static func ensureSSHKnownHostsPopulated(at url: URL) throws {
        try ensurePrivateDirectory(url.deletingLastPathComponent())
        let standardizedURL = url.standardizedFileURL
        let expectedTrimmed = Self.pinnedSSHKnownHosts.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedData = Data(Self.pinnedSSHKnownHosts.utf8)

        var st = Darwin.stat()
        if Darwin.lstat(standardizedURL.path, &st) == 0 {
            let fileType = st.st_mode & S_IFMT
            if fileType == S_IFLNK {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ELOOP),
                    userInfo: [NSLocalizedDescriptionKey: "Refusing symlink file at \(standardizedURL.path)"]
                )
            }
            if fileType == S_IFREG {
                let fd = Darwin.open(standardizedURL.path, O_RDONLY | O_NOFOLLOW)
                if fd >= 0 {
                    defer { Darwin.close(fd) }
                    var existingData = Data()
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while existingData.count < 65536 {
                        let n = Darwin.read(fd, &buf, buf.count)
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 { break }
                        existingData.append(contentsOf: buf[..<n])
                    }
                    let existing = String(data: existingData, encoding: .utf8) ?? ""
                    if existing.trimmingCharacters(in: .whitespacesAndNewlines) == expectedTrimmed {
                        if (Int(st.st_mode) & 0o777) != 0o600 {
                            _ = Darwin.fchmod(fd, mode_t(0o600))
                        }
                        return
                    }
                }
            }
        }
        try writePrivateData(pinnedData, to: standardizedURL)
    }

    static var sshKnownHostsURL: URL {
        appSupportDirectory.appendingPathComponent("ssh_known_hosts")
    }

    static var sshTunnelPIDURL: URL {
        appSupportDirectory.appendingPathComponent("ssh_tunnel.pid")
    }

    private static func readNoFollowTextFile(at url: URL, maxBytes: Int = 256) -> String? {
        let path = url.standardizedFileURL.path
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: min(512, maxBytes))
        while data.count < maxBytes {
            let n = Darwin.read(fd, &buf, min(buf.count, maxBytes - data.count))
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            data.append(contentsOf: buf[..<n])
        }
        return String(data: data, encoding: .utf8)
    }

    private static func writeSSHTunnelPIDFile(_ pid: Int32) {
        guard pid > 1 else { return }
        try? writePrivateData(Data("\(pid)\n".utf8), to: sshTunnelPIDURL)
    }

    private static func removeSSHTunnelPIDFile(matchingPID: Int32? = nil) {
        let url = sshTunnelPIDURL.standardizedFileURL
        if let matchingPID {
            if let content = readNoFollowTextFile(at: url),
               let storedPID = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)),
               storedPID != matchingPID {
                return
            }
        }
        _ = Darwin.unlink(url.path)
    }

    private static func isOrphanedSSHTunnelProcess(pid: Int32) -> Bool {
        guard pid > 1, pid != getpid(), Darwin.kill(pid, 0) == 0 else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        if Darwin.sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size, size <= 65536 {
            var buffer = [UInt8](repeating: 0, count: size)
            if Darwin.sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size {
                let slice = buffer[MemoryLayout<Int32>.size..<size].map { $0 == 0 ? UInt8(0x20) : $0 }
                let commandLine = String(decoding: slice, as: UTF8.self).lowercased()
                if commandLine.contains("ssh") && commandLine.contains("localhost.run") {
                    return true
                }
            }
        }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
            try? pipe.fileHandleForWriting.close()
            let outputData = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            try? pipe.fileHandleForReading.close()
            ps.waitUntilExit()
            let cmd = String(decoding: outputData, as: UTF8.self).lowercased()
            return cmd.contains("ssh") && cmd.contains("localhost.run")
        } catch {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
            return false
        }
    }

    static func reapOrphanedSSHTunnelIfNeeded() {
        let url = sshTunnelPIDURL.standardizedFileURL
        guard let content = readNoFollowTextFile(at: url) else {
            var st = Darwin.stat()
            if Darwin.lstat(url.path, &st) == 0 {
                _ = Darwin.unlink(url.path)
            }
            return
        }
        _ = Darwin.unlink(url.path)
        guard let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              pid != getpid(),
              isOrphanedSSHTunnelProcess(pid: pid) else {
            return
        }
        _ = Darwin.kill(pid, SIGTERM)
        for _ in 0..<3 where Darwin.kill(pid, 0) == 0 {
            usleep(20_000)
        }
        if Darwin.kill(pid, 0) == 0 {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    private func startTunnelProcessOnQueue(port: UInt16, epoch: UInt64) {
        let (isStillValid, useExternalTunnel) = lock.withLock {
            ($0.isSharing && $0.sessionEpoch == epoch, $0.useExternalTunnel)
        }
        guard isStillValid else { return }

        guard useExternalTunnel else {
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

        if ProcessInfo.processInfo.environment["CALLCAPTION_TEST"] == "1" {
            terminateTunnelProcessOnQueue()
            return
        }

        let knownHostsURL = Self.sshKnownHostsURL
        do {
            try Self.ensureSSHKnownHostsPopulated(at: knownHostsURL)
        } catch {
            AppLog.liveShare.error("Failed to prepare SSH known-hosts path: \(error.localizedDescription, privacy: .private)")
            markTunnelFailed(
                epoch: epoch,
                message: AppL10n.string("share.tunnel.unavailable", fallback: "Tunnel unavailable")
            )
            return
        }

        terminateTunnelProcessOnQueue()
        scheduleTunnelStartupTimeout(epoch: epoch, port: port)
        launchSSHTunnelOnQueue(port: port, epoch: epoch, knownHostsURL: knownHostsURL)
    }

    static func buildSSHTunnelArguments(port: UInt16, knownHostsURL: URL) -> [String] {
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
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "UserKnownHostsFile=\(quotedKnownHostsPath)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-R", "80:127.0.0.1:\(port)",
            "nokey@localhost.run"
        ]
    }

    @discardableResult
    private func drainTunnelPipeNonBlockingOnQueue(fd: Int32, epoch: UInt64) -> Bool {
        guard fd >= 0 else { return true }
        var drained = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        var reachedEOF = false
        while drained.count < 32768 {
            let n = Darwin.read(fd, &scratch, scratch.count)
            if n > 0 {
                drained.append(contentsOf: scratch[..<n])
            } else if n == 0 {
                reachedEOF = true
                break
            } else {
                let err = errno
                if err == EINTR {
                    continue
                }
                if err != EAGAIN && err != EWOULDBLOCK {
                    reachedEOF = true
                }
                break
            }
        }
        if !drained.isEmpty {
            let chunk = Self.decodeUTF8Chunk(newData: drained, remainder: &tunnelPartialUTF8Data)
            if !chunk.isEmpty {
                appendAndScanTunnelOutputOnQueue(chunk, epoch: epoch)
            }
        }
        return reachedEOF
    }

    static func drainCompleteLines(from pendingBuffer: inout String, appending chunk: String) -> [String] {
        pendingBuffer.append(chunk)
        var lines: [String] = []
        // Use `.literal` so `\r\n` (a single Swift Character grapheme cluster) still matches `\n`.
        while let newlineRange = pendingBuffer.range(of: "\n", options: .literal) {
            let line = String(pendingBuffer[..<newlineRange.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            pendingBuffer.removeSubrange(..<newlineRange.upperBound)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        if pendingBuffer.count > 16384 {
            pendingBuffer = String(pendingBuffer.suffix(4096))
        }
        return lines
    }

    private func appendAndScanTunnelOutputOnQueue(_ chunk: String, epoch: UInt64) {
        tunnelOutputBuffer.append(chunk)
        if tunnelOutputBuffer.count > 32768 {
            tunnelOutputBuffer = String(tunnelOutputBuffer.suffix(8192))
        }
        for line in Self.drainCompleteLines(from: &tunnelPendingLineBuffer, appending: chunk) {
            parseTunnelOutputLine(line, regex: Self.sshTunnelRegex, epoch: epoch)
        }
    }

    private func launchSSHTunnelOnQueue(port: UInt16, epoch: UInt64, knownHostsURL: URL) {
        if ProcessInfo.processInfo.environment["CALLCAPTION_TEST"] == "1" {
            return
        }
        let (isStillValid, useExternalTunnel) = lock.withLock {
            ($0.isSharing && $0.sessionEpoch == epoch, $0.useExternalTunnel)
        }
        guard isStillValid, useExternalTunnel else { return }

        Self.reapOrphanedSSHTunnelIfNeeded()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.buildSSHTunnelArguments(port: port, knownHostsURL: knownHostsURL)
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        self.tunnelReadSource?.cancel()
        self.tunnelReadSource = nil
        self.tunnelProcess = process
        self.tunnelPipe = pipe
        self.tunnelGeneration &+= 1
        let launchGen = self.tunnelGeneration
        self.tunnelOutputBuffer = ""
        self.tunnelPendingLineBuffer = ""
        self.hasEstablishedTunnelURLInGeneration = false
        self.tunnelPartialUTF8Data.removeAll(keepingCapacity: false)
        self.tunnelConnectedUptime = 0

        let readHandle = pipe.fileHandleForReading

        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            let status = proc.terminationStatus
            let pid = proc.processIdentifier
            self.serverQueue.async { [weak self] in
                guard let self = self else { return }
                Self.removeSSHTunnelPIDFile(matchingPID: pid)
                if self.terminatingTunnelProcess === proc {
                    self.terminatingTunnelProcess = nil
                }
                guard self.tunnelGeneration == launchGen,
                      self.tunnelProcess != nil else { return }
                if let activeSource = self.tunnelReadSource {
                    let fd = readHandle.fileDescriptor
                    if fd >= 0 {
                        let prevFlags = Darwin.fcntl(fd, F_GETFL)
                        if prevFlags != -1 && (prevFlags & O_NONBLOCK) == 0 {
                            _ = Darwin.fcntl(fd, F_SETFL, prevFlags | O_NONBLOCK)
                        }
                        self.drainTunnelPipeNonBlockingOnQueue(fd: fd, epoch: epoch)
                    }
                    self.tunnelReadSource = nil
                    activeSource.cancel()
                }
                let tailSnippet = String(self.tunnelOutputBuffer.suffix(300))
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                AppLog.liveShare.error("SSH tunnel process exited (status \(status, privacy: .public)): \(tailSnippet, privacy: .private)")
                self.tunnelGeneration &+= 1
                self.tunnelProcess = nil
                self.tunnelPipe = nil
                self.tunnelPendingLineBuffer = ""
                self.hasEstablishedTunnelURLInGeneration = false
                self.tunnelPartialUTF8Data.removeAll(keepingCapacity: false)
                self.handleTunnelTerminatedOnQueue(epoch: epoch)
                self.tunnelOutputBuffer = ""
            }
        }

        do {
            try process.run()
            let pid = process.processIdentifier
            Self.writeSSHTunnelPIDFile(pid)
            try? pipe.fileHandleForWriting.close()
            let readFD = readHandle.fileDescriptor
            if readFD >= 0 {
                let flags = Darwin.fcntl(readFD, F_GETFL)
                if flags != -1 {
                    _ = Darwin.fcntl(readFD, F_SETFL, flags | O_NONBLOCK)
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: serverQueue)
                source.setEventHandler { [weak self] in
                    guard let self = self,
                          self.tunnelGeneration == launchGen,
                          self.tunnelPipe != nil,
                          self.tunnelProcess != nil else { return }
                    let reachedEOF = self.drainTunnelPipeNonBlockingOnQueue(fd: readFD, epoch: epoch)
                    if reachedEOF, let activeSource = self.tunnelReadSource {
                        self.tunnelReadSource = nil
                        self.tunnelPipe = nil
                        activeSource.cancel()
                    }
                }
                source.setCancelHandler {
                    try? readHandle.close()
                }
                self.tunnelReadSource = source
                source.resume()
            }
        } catch {
            process.terminationHandler = nil
            try? pipe.fileHandleForWriting.close()
            try? readHandle.close()
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

        if let readSource = tunnelReadSource {
            tunnelReadSource = nil
            readSource.cancel()
        } else if let pipe = tunnelPipe {
            try? pipe.fileHandleForReading.close()
        }
        tunnelPipe = nil
        tunnelOutputBuffer = ""
        tunnelPendingLineBuffer = ""
        hasEstablishedTunnelURLInGeneration = false
        tunnelPartialUTF8Data.removeAll(keepingCapacity: false)

        let activeProc = tunnelProcess
        tunnelProcess = nil

        if let proc = activeProc {
            proc.terminationHandler = nil
            let pid = proc.processIdentifier
            if proc.isRunning {
                proc.terminate()
                if forceKillSynchronously {
                    for _ in 0..<3 where proc.isRunning {
                        usleep(20_000)
                    }
                    if proc.isRunning {
                        _ = Darwin.kill(pid, SIGKILL)
                    }
                    if terminatingTunnelProcess === proc {
                        terminatingTunnelProcess = nil
                    }
                    Self.removeSSHTunnelPIDFile(matchingPID: pid)
                } else {
                    if let prevTerm = terminatingTunnelProcess, prevTerm !== proc, prevTerm.isRunning {
                        _ = Darwin.kill(prevTerm.processIdentifier, SIGKILL)
                    }
                    terminatingTunnelProcess = proc
                    serverQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        if proc.isRunning {
                            _ = Darwin.kill(pid, SIGKILL)
                        }
                        if self?.terminatingTunnelProcess === proc {
                            self?.terminatingTunnelProcess = nil
                        }
                        Self.removeSSHTunnelPIDFile(matchingPID: pid)
                    }
                }
            } else {
                Self.removeSSHTunnelPIDFile(matchingPID: pid)
            }
        }

        if forceKillSynchronously, let termProc = terminatingTunnelProcess {
            terminatingTunnelProcess = nil
            let pid = termProc.processIdentifier
            if termProc.isRunning {
                termProc.terminate()
                for _ in 0..<3 where termProc.isRunning {
                    usleep(20_000)
                }
                if termProc.isRunning {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
            Self.removeSSHTunnelPIDFile(matchingPID: pid)
        }
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
        let recentOutput = tunnelOutputBuffer
        tunnelOutputBuffer = ""
        let nowUptime = ProcessInfo.processInfo.systemUptime
        if tunnelConnectedUptime > 0, (nowUptime - tunnelConnectedUptime) >= 20.0 {
            tunnelRestartAttempts = 0
        }
        tunnelConnectedUptime = 0
        tunnelStabilityWorkItem?.cancel()
        tunnelStabilityWorkItem = nil

        guard lock.withLock({ $0.useExternalTunnel }) else {
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

        if recentOutput.contains("Host key verification failed")
            || recentOutput.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            markTunnelFailed(
                epoch: epoch,
                message: AppL10n.string(
                    "share.tunnel.host_key_failed",
                    fallback: "Public tunnel blocked: SSH host key verification failed."
                )
            )
            return
        }

        let tunnelFailedMessage = AppL10n.string(
            "share.tunnel.failed",
            fallback: "Public tunnel unavailable."
        )
        guard tunnelRestartAttempts < 5 else {
            markTunnelFailed(epoch: epoch, message: tunnelFailedMessage)
            return
        }

        let updated = lock.withLock { state -> Bool in
            guard state.isSharing && state.sessionEpoch == epoch else { return false }
            state.publicURL = nil
            state.tunnelHost = nil
            state.isTunnelStarting = true
            state.tunnelError = hadPublicURL
                ? AppL10n.string("share.tunnel.reconnecting", fallback: "Public tunnel disconnected; reconnecting…")
                : AppL10n.format(
                    "share.tunnel.connecting_attempt",
                    fallback: "Connecting to public tunnel (attempt %ld/%ld)…",
                    min(5, tunnelRestartAttempts + 1),
                    5
                )
            return true
        }
        if updated { notifyStateChange() }
        scheduleTunnelRestart(epoch: epoch, port: port)
    }

    private func scheduleTunnelRestart(epoch: UInt64, port: UInt16, updateConnectingStatus: Bool = false) {
        let stillSharingAndTunnelEnabled = lock.withLock {
            $0.isSharing && $0.sessionEpoch == epoch && $0.useExternalTunnel
        }
        guard stillSharingAndTunnelEnabled else { return }

        terminateTunnelProcessOnQueue()

        let tunnelFailedMessage = AppL10n.string(
            "share.tunnel.failed",
            fallback: "Public tunnel unavailable."
        )
        guard tunnelRestartAttempts < 5 else {
            markTunnelFailed(epoch: epoch, message: tunnelFailedMessage)
            return
        }

        tunnelRestartAttempts += 1
        if updateConnectingStatus {
            let attempt = tunnelRestartAttempts
            let updated = lock.withLock { state -> Bool in
                guard state.isSharing && state.sessionEpoch == epoch else { return false }
                state.isTunnelStarting = true
                state.tunnelError = AppL10n.format(
                    "share.tunnel.connecting_attempt",
                    fallback: "Connecting to public tunnel (attempt %ld/%ld)…",
                    min(5, attempt),
                    5
                )
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

    func retryTunnel() {
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            self.tunnelRestartWorkItem?.cancel()
            self.tunnelRestartWorkItem = nil
            let retryTarget: (epoch: UInt64, port: UInt16)? = self.lock.withLock { state in
                guard state.isSharing, state.useExternalTunnel, state.port > 0 else { return nil }
                state.publicURL = nil
                state.tunnelHost = nil
                state.tunnelError = nil
                state.isTunnelStarting = true
                return (state.sessionEpoch, state.port)
            }
            guard let target = retryTarget else { return }
            self.tunnelRestartAttempts = 0
            self.notifyStateChange()
            self.startTunnelProcessOnQueue(port: target.port, epoch: target.epoch)
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

    private func parseTunnelOutputLine(_ line: String, regex: NSRegularExpression, epoch: UInt64) {
        if hasEstablishedTunnelURLInGeneration {
            guard line.localizedCaseInsensitiveContains("tunneled with tls termination") else { return }
        }
        guard let baseURL = Self.extractTunnelURL(from: line, regex: regex),
              let host = baseURL.host else { return }
        let baseURLString = baseURL.absoluteString

        let (updatedURL, didEstablish): (URL?, Bool) = lock.withLock { state -> (URL?, Bool) in
            guard state.isSharing && state.sessionEpoch == epoch else { return (nil, false) }
            guard !state.sessionKeyFragment.isEmpty,
                  let tokenizedURL = URL(string: "\(baseURLString)/s/\(state.sessionToken)#\(state.sessionKeyFragment)") else { return (nil, false) }
            if state.publicURL == tokenizedURL { return (nil, true) }
            if let previous = state.lastPublishedPublicURL, previous != tokenizedURL {
                state.publicLinkRotated = true
            }
            state.lastPublishedPublicURL = tokenizedURL
            state.publicURL = tokenizedURL
            state.tunnelHost = host
            state.isTunnelStarting = false
            state.tunnelError = nil
            return (tokenizedURL, true)
        }
        if didEstablish {
            hasEstablishedTunnelURLInGeneration = true
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
            notifyURLUpdate(validURL)
            notifyStateChange()
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

    private func notifyURLUpdate(_ url: URL) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.urlDidUpdateNotification, object: self, userInfo: ["url": url])
        }
    }

    static func getLocalIPAddress() -> String? {
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


