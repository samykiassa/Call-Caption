import Foundation
import Network
import AppKit
import CoreImage

public class WebCaptionServer {
    public static let shared = WebCaptionServer()
    
    private var listener: NWListener?
    private var activeConnections: [NWConnection] = []
    private let connectionLock = NSLock()
    
    public private(set) var port: UInt16 = 8765
    public private(set) var isRunning: Bool = false
    
    // Callback when speech is received directly from the phone client (e.g. caller speaking Spanish on their phone)
    public var onMobileSpeechReceived: ((_ speaker: String, _ text: String, _ lang: String, _ isFinal: Bool) -> Void)?
    
    // Active Languages (Dynamically synced between Mac HUD and Web App)
    public private(set) var hostLangCode: String = "en"
    public private(set) var hostLangName: String = "English"
    public private(set) var callerLangCode: String = "es"
    public private(set) var callerLangName: String = "Spanish"
    
    // Callback when languages are changed from the mobile web client
    public var onLanguagesChangedFromWeb: ((_ hostCode: String, _ callerCode: String) -> Void)?
    
    // Last subtitle state
    private var lastSpeaker: String = ""
    private var lastOriginal: String = ""
    private var lastTranslated: String = ""
    
    private init() {}
    
    public func setLanguages(hostCode: String, callerCode: String) {
        connectionLock.lock()
        self.hostLangCode = hostCode
        self.hostLangName = SupportedLanguages.item(forCode: hostCode)?.name ?? hostCode.uppercased()
        self.callerLangCode = callerCode
        self.callerLangName = SupportedLanguages.item(forCode: callerCode)?.name ?? callerCode.uppercased()
        connectionLock.unlock()
        
        broadcastLanguages()
    }
    
    public func start(port: UInt16 = 8765) {
        if isRunning { return }
        self.port = port
        
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(8765)
            let newListener = try NWListener(using: parameters, on: nwPort)
            
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    NSLog("[WebCaptionServer] Listening on port \(port)")
                    self?.isRunning = true
                    // Start Public HTTPS Tunnel in background
                    TunnelManager.shared.start(localPort: port)
                case .failed(let error):
                    NSLog("[WebCaptionServer] Listener failed on port \(port): \(error)")
                    self?.isRunning = false
                    // Auto-retry in 1 second in case port is in TIME_WAIT from previous instance
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.start(port: port)
                    }
                default:
                    break
                }
            }
            
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            newListener.start(queue: .global(qos: .userInitiated))
            self.listener = newListener
            self.isRunning = true
        } catch {
            NSLog("[WebCaptionServer] Failed to start listener: \(error)")
        }
    }
    
    public func stop() {
        isRunning = false
        connectionLock.lock()
        for conn in activeConnections {
            conn.cancel()
        }
        activeConnections.removeAll()
        connectionLock.unlock()
        
        listener?.cancel()
        listener = nil
        
        TunnelManager.shared.stop()
    }
    
    // MARK: - Subtitle & Call Link Broadcast
    
    public func broadcastSubtitle(
        speaker: String,
        original: String,
        translated: String,
        displayForCaller: String = ""
    ) {
        lastSpeaker = speaker
        lastOriginal = original
        lastTranslated = translated
        
        let callerText = displayForCaller.isEmpty ? translated : displayForCaller
        
        let payload: [String: Any] = [
            "type": "subtitle",
            "speaker": speaker,
            "original": original,
            "translated": translated,
            "displayForCaller": callerText,
            "time": Date().timeIntervalSince1970
        ]
        
        sendSSEPayload(payload)
    }
    
    public func broadcastLanguages() {
        let payload: [String: Any] = [
            "type": "languages",
            "hostLangCode": hostLangCode,
            "hostLangName": hostLangName,
            "callerLangCode": callerLangCode,
            "callerLangName": callerLangName,
            "time": Date().timeIntervalSince1970
        ]
        sendSSEPayload(payload)
    }
    
    private func sendSSEPayload(_ payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        
        let sseMessage = "data: \(jsonString)\n\n"
        guard let sseData = sseMessage.data(using: .utf8) else { return }
        
        connectionLock.lock()
        let conns = activeConnections
        connectionLock.unlock()
        
        for conn in conns {
            conn.send(content: sseData, completion: .contentProcessed { [weak self, weak conn] error in
                if error != nil, let conn = conn {
                    self?.removeConnection(conn)
                }
            })
        }
    }
    
    // MARK: - Connection Handling
    
    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        readHTTPRequest(connection)
    }
    
    private func readHTTPRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self, let content = content, error == nil else {
                connection.cancel()
                return
            }
            
            let requestString = String(decoding: content, as: UTF8.self)
            let lines = requestString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                connection.cancel()
                return
            }
            
            let parts = requestLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }
            
            let method = parts[0]
            let fullPath = parts[1]
            let pathOnly = fullPath.components(separatedBy: "?").first ?? fullPath
            
            if method == "OPTIONS" {
                self.handleCORSPreflight(connection)
            } else if pathOnly == "/events" {
                self.handleSSE(connection)
            } else if pathOnly == "/qr" {
                self.handleQR(connection)
            } else if pathOnly == "/speech" && method == "POST" {
                self.handleSpeechPOST(connection, requestString: requestString)
            } else if pathOnly == "/set-languages" {
                self.handleSetLanguages(connection, fullPath: fullPath)
            } else {
                self.handleWebPage(connection, fullPath: fullPath)
            }
        }
    }
    
    private func handleCORSPreflight(_ connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Access-Control-Allow-Origin: *\r\n" +
                      "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
                      "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" +
                      "Content-Length: 0\r\n" +
                      "Connection: close\r\n\r\n"
        if let data = headers.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { [weak connection] _ in
                connection?.cancel()
            })
        }
    }
    
    private func handleSpeechPOST(_ connection: NWConnection, requestString: String) {
        // Extract body after \r\n\r\n
        var bodyString = ""
        if let range = requestString.range(of: "\r\n\r\n") {
            bodyString = String(requestString[range.upperBound...])
        }
        
        if let data = bodyString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let text = json["text"] as? String ?? ""
            let speaker = json["speaker"] as? String ?? "Caller (Phone)"
            let lang = json["lang"] as? String ?? self.callerLangCode
            let isFinal = json["isFinal"] as? Bool ?? true
            
            if !text.isEmpty {
                NSLog("[WebCaptionServer] Received phone speech: '\(text)' in \(lang) (isFinal: \(isFinal))")
                DispatchQueue.main.async { [weak self] in
                    self?.onMobileSpeechReceived?(speaker, text, lang, isFinal)
                }
            }
        }
        
        let responseJson = "{\"status\":\"ok\"}"
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Content-Type: application/json; charset=utf-8\r\n" +
                      "Access-Control-Allow-Origin: *\r\n" +
                      "Content-Length: \(responseJson.utf8.count)\r\n" +
                      "Connection: close\r\n\r\n"
        let full = headers + responseJson
        if let data = full.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { [weak connection] _ in
                connection?.cancel()
            })
        }
    }
    
    private func handleSetLanguages(_ connection: NWConnection, fullPath: String) {
        var host = self.hostLangCode
        var caller = self.callerLangCode
        
        if let queryIndex = fullPath.firstIndex(of: "?") {
            let queryString = String(fullPath[fullPath.index(after: queryIndex)...])
            let queryItems = queryString.components(separatedBy: "&")
            for item in queryItems {
                let kv = item.components(separatedBy: "=")
                if kv.count == 2 {
                    if kv[0] == "host" { host = kv[1].removingPercentEncoding ?? kv[1] }
                    if kv[0] == "caller" { caller = kv[1].removingPercentEncoding ?? kv[1] }
                }
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.setLanguages(hostCode: host, callerCode: caller)
            self?.onLanguagesChangedFromWeb?(host, caller)
        }
        
        let responseJson = "{\"status\":\"ok\",\"host\":\"\(host)\",\"caller\":\"\(caller)\"}"
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Content-Type: application/json; charset=utf-8\r\n" +
                      "Access-Control-Allow-Origin: *\r\n" +
                      "Content-Length: \(responseJson.utf8.count)\r\n" +
                      "Connection: close\r\n\r\n"
        if let data = (headers + responseJson).data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { [weak connection] _ in
                connection?.cancel()
            })
        }
    }
    
    private func handleSSE(_ connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Content-Type: text/event-stream\r\n" +
                      "Cache-Control: no-cache\r\n" +
                      "Connection: keep-alive\r\n" +
                      "Access-Control-Allow-Origin: *\r\n\r\n"
        
        guard let headerData = headers.data(using: .utf8) else { return }
        
        connection.send(content: headerData, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self = self, let connection = connection, error == nil else { return }
            
            self.connectionLock.lock()
            self.activeConnections.append(connection)
            self.connectionLock.unlock()
            
            // Send initial state including language configuration
            let initialPayload: [String: Any] = [
                "type": "init",
                "hostLangCode": self.hostLangCode,
                "hostLangName": self.hostLangName,
                "callerLangCode": self.callerLangCode,
                "callerLangName": self.callerLangName,
                "speaker": self.lastSpeaker,
                "original": self.lastOriginal,
                "translated": self.lastTranslated,
                "displayForCaller": self.lastTranslated,
                "time": Date().timeIntervalSince1970
            ]
            if let initJson = try? JSONSerialization.data(withJSONObject: initialPayload),
               let initStr = String(data: initJson, encoding: .utf8),
               let sseData = "data: \(initStr)\n\n".data(using: .utf8) {
                connection.send(content: sseData, completion: .contentProcessed { _ in })
            }
        })
    }
    
    private func handleWebPage(_ connection: NWConnection, fullPath: String) {
        let html = MobileClientHTML.page(
            hostLangCode: self.hostLangCode,
            hostLangName: self.hostLangName,
            callerLangCode: self.callerLangCode,
            callerLangName: self.callerLangName
        )
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Content-Type: text/html; charset=utf-8\r\n" +
                      "Access-Control-Allow-Origin: *\r\n" +
                      "Content-Length: \(html.utf8.count)\r\n" +
                      "Connection: close\r\n\r\n"
        
        let response = headers + html
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { [weak connection] _ in
                connection?.cancel()
            })
        }
    }
    
    private func handleQR(_ connection: NWConnection) {
        let url = getShareableURL()
        guard let qrImage = generateQRCodeImage(from: url),
              let tiff = qrImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            connection.cancel()
            return
        }
        
        let headers = "HTTP/1.1 200 OK\r\n" +
                      "Content-Type: image/png\r\n" +
                      "Access-Control-Allow-Origin: *\r\n" +
                      "Content-Length: \(pngData.count)\r\n" +
                      "Connection: close\r\n\r\n"
        
        var responseData = headers.data(using: .utf8) ?? Data()
        responseData.append(pngData)
        
        connection.send(content: responseData, completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
    }
    
    private func removeConnection(_ connection: NWConnection) {
        connectionLock.lock()
        activeConnections.removeAll { $0 === connection }
        connectionLock.unlock()
    }
    
    // MARK: - Utilities
    
    public func getShareableURL() -> String {
        if let pub = TunnelManager.shared.publicURL, !pub.isEmpty {
            return pub
        }
        return getLocalURL() ?? "http://localhost:\(port)"
    }
    
    public func getLocalIPAddress() -> String {
        var address: String = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            
            // Check for IPv4 interface that is UP and not LOOPBACK
            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) {
                    let name = String(cString: ptr.pointee.ifa_name)
                    if name == "en0" || name.starts(with: "en") {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                            address = String(cString: hostname)
                            break
                        }
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
    
    public func getLocalURL() -> String? {
        let ip = getLocalIPAddress()
        return "http://\(ip):\(port)"
    }
    
    public func generateQRCodeImage(from string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(string.data(using: .utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
    
    public var effectiveShareableURL: String {
        return TunnelManager.shared.publicURL ?? getLocalURL() ?? "http://localhost:8765"
    }
}
