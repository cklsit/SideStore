import CryptoKit
import Foundation
import Network
import UIKit

private struct NonameDeploymentRequest: Decodable {
    let bundleID: String
    let ipaURL: URL
    let sha256: String
}

private struct NonameDeploymentResponse: Encodable {
    let ok: Bool
    let deviceID: String?
    let jobID: String?
    let status: String?
    let message: String?
}

private struct NonameDeploymentJob {
    var status: String
    var message: String?
}

private struct NonameHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private enum NonameDeploymentError: LocalizedError {
    case disabled
    case invalidRequest(String)
    case unauthorized
    case busy
    case invalidDigest
    case unsupportedBundle(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Noname deployment is not configured"
        case .invalidRequest(let reason):
            return "Invalid deployment request: \(reason)"
        case .unauthorized:
            return "Deployment request authentication failed"
        case .busy:
            return "Another deployment is already running"
        case .invalidDigest:
            return "Downloaded IPA SHA-256 does not match the request"
        case .unsupportedBundle(let bundleID):
            return "Bundle is not allowed for automated deployment: \(bundleID)"
        }
    }
}

/// Authenticated, local-network-only deployment endpoint used by the self-hosted
/// macOS runner to uninstall and reinstall the Noname IPA.
@MainActor
final class NonameDeploymentServer {
    static let shared = NonameDeploymentServer()

    static let port: UInt16 = 49321
    static let serviceType = "_noname-deploy._tcp"
    static let allowedBundleIDs: Set<String> = ["com.libnoname.noname"]

    private let queue = DispatchQueue(label: "com.sidestore.noname.deployment")
    private let maxRequestBytes = 64 * 1024
    private let maxTimestampSkew: TimeInterval = 300

    private var listener: NWListener?
    private var jobs: [String: NonameDeploymentJob] = [:]
    private var usedNonces: [String: Date] = [:]
    private var deploymentTask: Task<Void, Never>?

    private init() {}

    var isConfigured: Bool {
        guard let token = Keychain.shared.nonameDeploymentToken else { return false }
        return token.count >= 32
    }

    var deviceID: String {
        if let existing = Keychain.shared.nonameDeploymentDeviceID {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        Keychain.shared.nonameDeploymentDeviceID = generated
        return generated
    }

    func configure(token: String) throws {
        guard token.count >= 32 else {
            throw NonameDeploymentError.invalidRequest("token must contain at least 32 characters")
        }
        Keychain.shared.nonameDeploymentToken = token
        start()
    }

    func startIfConfigured() {
        guard isConfigured else { return }
        start()
    }

    func start() {
        guard listener == nil, isConfigured else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true

            guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
            let listener = try NWListener(using: parameters, on: port)
            listener.service = NWListener.Service(
                name: "noname-\(deviceID.prefix(8))",
                type: Self.serviceType
            )
            listener.stateUpdateHandler = { state in
                debugLog("[NonameDeployment] listener state: \(String(describing: state))")
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            debugLog("[NonameDeployment] listening on port \(Self.port)")
        } catch {
            debugLog("[NonameDeployment] failed to start listener: \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(from: connection, buffer: Data())
    }

    private func receive(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var next = buffer
            if let data {
                next.append(data)
            }

            if next.count > self.maxRequestBytes {
                Task { @MainActor in
                    self.sendError(connection, status: 413, message: "request is too large")
                }
                return
            }

            if let request = Self.parseHTTPRequest(next) {
                Task { @MainActor in
                    self.handle(request, connection: connection)
                }
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                Task { @MainActor in
                    self.receive(from: connection, buffer: next)
                }
            }
        }
    }

    private func handle(_ request: NonameHTTPRequest, connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/v1/hello"):
            send(
                connection,
                status: 200,
                payload: NonameDeploymentResponse(
                    ok: true,
                    deviceID: deviceID,
                    jobID: nil,
                    status: deploymentTask == nil ? "idle" : "busy",
                    message: nil
                )
            )

        case ("POST", "/v1/deploy"):
            do {
                try authenticate(request)
                let deployment = try JSONDecoder().decode(NonameDeploymentRequest.self, from: request.body)
                let jobID = try enqueue(deployment)
                send(
                    connection,
                    status: 202,
                    payload: NonameDeploymentResponse(
                        ok: true,
                        deviceID: deviceID,
                        jobID: jobID,
                        status: "queued",
                        message: nil
                    )
                )
            } catch {
                sendError(connection, status: 400, message: error.localizedDescription)
            }

        default:
            if request.method == "GET", request.path.hasPrefix("/v1/jobs/") {
                let jobID = String(request.path.dropFirst("/v1/jobs/".count))
                if let job = jobs[jobID] {
                    send(
                        connection,
                        status: 200,
                        payload: NonameDeploymentResponse(
                            ok: true,
                            deviceID: deviceID,
                            jobID: jobID,
                            status: job.status,
                            message: job.message
                        )
                    )
                } else {
                    sendError(connection, status: 404, message: "unknown job")
                }
            } else {
                sendError(connection, status: 404, message: "not found")
            }
        }
    }

    private func authenticate(_ request: NonameHTTPRequest) throws {
        guard let secret = Keychain.shared.nonameDeploymentToken else {
            throw NonameDeploymentError.disabled
        }
        guard
            let timestampString = request.headers["x-noname-timestamp"],
            let timestamp = TimeInterval(timestampString),
            abs(Date().timeIntervalSince1970 - timestamp) <= maxTimestampSkew,
            let nonce = request.headers["x-noname-nonce"],
            (16...128).contains(nonce.count),
            let signature = request.headers["x-noname-signature"]
        else {
            throw NonameDeploymentError.unauthorized
        }

        pruneNonces()
        guard usedNonces[nonce] == nil else {
            throw NonameDeploymentError.unauthorized
        }

        let digest = SHA256.hash(data: request.body).map { String(format: "%02x", $0) }.joined()
        let canonical = [
            request.method,
            request.path,
            timestampString,
            nonce,
            digest,
        ].joined(separator: "\n")

        let key = SymmetricKey(data: Data(secret.utf8))
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key))
        guard let provided = Data(hexString: signature), Self.constantTimeEqual(expected, provided) else {
            throw NonameDeploymentError.unauthorized
        }

        usedNonces[nonce] = Date()
    }

    private func enqueue(_ request: NonameDeploymentRequest) throws -> String {
        guard Self.allowedBundleIDs.contains(request.bundleID) else {
            throw NonameDeploymentError.unsupportedBundle(request.bundleID)
        }
        guard deploymentTask == nil else {
            throw NonameDeploymentError.busy
        }
        guard request.sha256.count == 64, Data(hexString: request.sha256) != nil else {
            throw NonameDeploymentError.invalidRequest("sha256 must be 64 hexadecimal characters")
        }
        guard ["http", "https"].contains(request.ipaURL.scheme?.lowercased() ?? "") else {
            throw NonameDeploymentError.invalidRequest("ipaURL must use http or https")
        }

        let jobID = UUID().uuidString.lowercased()
        jobs[jobID] = NonameDeploymentJob(status: "queued", message: nil)
        deploymentTask = Task { [weak self] in
            guard let self else { return }
            await self.performDeployment(jobID: jobID, request: request)
            self.deploymentTask = nil
        }
        return jobID
    }

    private func performDeployment(jobID: String, request: NonameDeploymentRequest) async {
        jobs[jobID] = NonameDeploymentJob(status: "running", message: "starting")
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NonameDeployment")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        var temporaryIPA: URL?
        do {
            jobs[jobID] = NonameDeploymentJob(status: "running", message: "starting SideStore database")
            try await DatabaseManager.shared.start()

            jobs[jobID] = NonameDeploymentJob(status: "running", message: "downloading IPA")
            let (downloadedURL, response) = try await URLSession.shared.download(from: request.ipaURL)
            if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                throw NonameDeploymentError.invalidRequest("IPA download failed with HTTP \(response.statusCode)")
            }

            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("noname-\(jobID).ipa")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloadedURL, to: destination)
            temporaryIPA = destination

            jobs[jobID] = NonameDeploymentJob(status: "running", message: "verifying IPA")
            let data = try Data(contentsOf: destination, options: .mappedIfSafe)
            let actualDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actualDigest == request.sha256.lowercased() else {
                throw NonameDeploymentError.invalidDigest
            }

            jobs[jobID] = NonameDeploymentJob(status: "running", message: "uninstalling existing app")
            let installedApp = try await MainActor.run {
                let fetchRequest = InstalledApp.fetchRequest()
                fetchRequest.predicate = NSPredicate(
                    format: "%K == %@",
                    #keyPath(InstalledApp.bundleIdentifier),
                    request.bundleID
                )
                return try DatabaseManager.shared.viewContext.fetch(fetchRequest).first
            }

            if let installedApp {
                try await deleteManagedApp(installedApp)
            } else {
                try await removeApp(request.bundleID)
            }

            jobs[jobID] = NonameDeploymentJob(status: "running", message: "installing IPA")
            try await installIPA(destination)

            jobs[jobID] = NonameDeploymentJob(status: "succeeded", message: "deployment completed")
            debugLog("[NonameDeployment] deployment completed: \(request.bundleID)")
        } catch {
            jobs[jobID] = NonameDeploymentJob(status: "failed", message: error.localizedDescription)
            debugLog("[NonameDeployment] deployment failed: \(error)")
        }

        if let temporaryIPA {
            try? FileManager.default.removeItem(at: temporaryIPA)
        }
    }

    private func deleteManagedApp(_ app: InstalledApp) async throws {
        try await withCheckedThrowingContinuation { continuation in
            AppManager.shared.deleteApp(app, presentingViewController: nil) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func installIPA(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            AppManager.shared.install(.url(url), presentingViewController: nil) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func sendError(_ connection: NWConnection, status: Int, message: String) {
        send(
            connection,
            status: status,
            payload: NonameDeploymentResponse(
                ok: false,
                deviceID: nil,
                jobID: nil,
                status: "error",
                message: message
            )
        )
    }

    private func send<T: Encodable>(_ connection: NWConnection, status: Int, payload: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(payload)) ?? Data("{}".utf8)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        let headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")

        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func pruneNonces() {
        let cutoff = Date().addingTimeInterval(-maxTimestampSkew * 2)
        usedNonces = usedNonces.filter { $0.value > cutoff }
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func parseHTTPRequest(_ data: Data) -> NonameHTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = data[bodyStart..<(bodyStart + contentLength)]
        return NonameHTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            body: Data(body)
        )
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
