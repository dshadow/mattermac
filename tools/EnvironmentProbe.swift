import Foundation
import Darwin
import CryptoKit

// Discovery only: no posts, persistent credentials, or response-body logging.
enum ProbeError: Error { case failed(String) }

@main
struct EnvironmentProbe {
    static func main() async {
        let production = CommandLine.arguments.dropFirst() == ["--production"]
        if production { print("--- BEGIN PHASE 0 PRODUCTION REPORT ---") }
        var failed = false
        do { try await run() }
        catch {
            let message = (error as? ProbeError).map { error -> String in
                switch error { case .failed(let message): return message }
            } ?? "Transport or decoding failure (details suppressed)."
            print("FAIL: \(message)")
            failed = true
        }
        if production { print("--- END PHASE 0 PRODUCTION REPORT ---") }
        if failed { exit(1) }
    }

    static func run() async throws {
        if CommandLine.arguments.dropFirst() == ["--self-test"] {
            try TOTP.selfTest()
            let url = try apiURL(base: URL(string: "https://example.com/mattermost/")!, path: "config/client?format=old")
            guard url.path == "/mattermost/api/v4/config/client", url.query == "format=old",
                  safeVersion("11.7.11.custom-build") == "11.7.11 (build metadata redacted)",
                  safeVersion("secret") == "not reported (custom metadata redacted)"
            else { throw ProbeError.failed("URL or redaction self-test failed.") }
            print("PASS: RFC 6238 vectors, Base32 validation, subpath/query URLs, version redaction")
            return
        }
        let production = CommandLine.arguments.dropFirst() == ["--production"]
        let environment = ProcessInfo.processInfo.environment
        let prefix = production ? "MATTERMOST_PROD_" : "MATTERMOST_TEST_"
        let baseText = production ? environment["MATTERMOST_PROD_URL"] ?? "" : CommandLine.arguments.last ?? ""
        guard CommandLine.arguments.count == 2,
              let base = URL(string: baseText),
              let host = base.host, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil,
              base.scheme == "https" || (!production && base.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
        else { throw ProbeError.failed("Supply HTTPS base URL, or HTTP loopback URL for local testing.") }
        let login: String
        let password: String
        if production || environment.keys.contains(where: { $0.hasPrefix(prefix) }) {
            login = environment[prefix + "USERNAME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? environment[prefix + "EMAIL"] ?? ""
            password = environment[prefix + "PASSWORD"] ?? ""
        } else {
            login = readLine() ?? ""
            password = readLine() ?? ""
        }
        guard !login.isEmpty, !password.isEmpty
        else { throw ProbeError.failed("Supply test username (or email) and password through environment variables, or two stdin lines.") }
        let totpKey = try environment[prefix + "TOTP_SECRET"].map(TOTP.decodeSecret)
        let mfaCode = environment[prefix + "MFA_CODE"]
        if let mfaCode {
            guard totpKey == nil, mfaCode.utf8.count == 6,
                  mfaCode.utf8.allSatisfy({ (48...57).contains($0) })
            else { throw ProbeError.failed("Supply one six-digit MFA_CODE or TOTP_SECRET, never both.") }
        }
        print("INFO: target=\(production ? "production" : "local/explicit"); deployment=\(base.path.isEmpty || base.path == "/" ? "root" : "subpath (redacted)"); system TLS verification; redirects rejected")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        func request(_ path: String, method: String = "GET", token: String? = nil,
                     body: [String: String]? = nil, allowDisabledPlugins: Bool = false) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: try apiURL(base: base, path: path))
            request.httpMethod = method
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ProbeError.failed("Missing HTTP response.") }
            guard (200..<300).contains(response.statusCode) ||
                    (allowDisabledPlugins && path == "plugins/webapp" && response.statusCode == 501)
            else {
                let label = path.hasPrefix("users/me/teams/") ? "users/me/teams/{team}/channels" : path
                throw ProbeError.failed("\(method) \(label): HTTP \(response.statusCode)")
            }
            return (data, response)
        }

        // Run after login so a manually entered MFA code is not delayed by public checks.
        func inspectPublicConfiguration() async throws {
            let (pingData, _) = try await request("system/ping")
            let ping = try JSONDecoder().decode(Ping.self, from: pingData)
            guard ping.status == "OK" else { throw ProbeError.failed("REST ping status is not OK.") }
            print("PASS: REST v4 ping; HTTPS trust=\(base.scheme == "https" ? "verified" : "loopback HTTP")")
            do {
            let (data, _) = try await request("config/client?format=old")
            let config = try JSONDecoder().decode([String: String].self, from: data)
            print("INFO: public server version=\(safeVersion(config["Version"] ?? ""))")
            for key in ["EnableSignInWithEmail", "EnableSignInWithUsername", "EnableMultifactorAuthentication",
                        "EnforceMultifactorAuthentication", "EnableLdap", "EnableSaml", "EnableSignUpWithGoogle",
                        "EnableSignUpWithOffice365", "EnableOpenId", "EnableSignUpWithOpenId",
                        "EnablePlugins", "PluginsEnabled", "EnableCustomBrand"] {
                let value = config[key].flatMap { ["true", "false"].contains($0) ? $0 : nil } ?? "not reported"
                print("INFO: \(key)=\(value)")
            }
            } catch { print("INFO: optional public configuration unavailable (details suppressed)") }
        }

        var loginBody = ["login_id": login, "password": password]
        if let totpKey {
            loginBody["token"] = TOTP.code(key: totpKey, time: UInt64(Date().timeIntervalSince1970))
        }
        if let mfaCode { loginBody["token"] = mfaCode }
        let (_, loginResponse) = try await request("users/login", method: "POST", body: loginBody)
        guard let token = loginResponse.value(forHTTPHeaderField: "Token"), !token.isEmpty
        else { throw ProbeError.failed("Login response has no session token.") }
        print("PASS: \(totpKey == nil && mfaCode == nil ? "password" : "password + MFA") login; token received in memory")
        do {
            try await inspectPublicConfiguration()
            let (data, _) = try await request("users/me", token: token)
            let me = try JSONDecoder().decode(CurrentUser.self, from: data)
            guard !me.id.isEmpty else { throw ProbeError.failed("Current user has no ID.") }
            let matches = me.username == login || me.email == login
            let authService = me.auth_service.map { $0.isEmpty ? "email/password" : (["ldap", "saml", "google", "office365", "openid"].contains($0) ? $0 : "other (redacted)") } ?? "not reported"
            print("PASS: authenticated current user; login matches username/email=\(matches); auth service=\(authService); MFA=\(me.mfa_active.map(String.init) ?? "not reported")")
            let (teamsData, _) = try await request("users/me/teams", token: token)
            let teams = try JSONDecoder().decode([Team].self, from: teamsData)
            var channels: [String: String] = [:]
            for team in teams {
                let (data, _) = try await request("users/me/teams/\(team.id)/channels", token: token)
                for channel in try JSONDecoder().decode([Channel].self, from: data) {
                    channels[channel.id] = channel.type
                }
            }
            print("PASS: accessible teams=\(teams.count), unique channel memberships=\(channels.count)")
            for (type, label) in [("O", "public"), ("P", "private"), ("D", "direct"), ("G", "group")] {
                print("INFO: \(label) channel memberships=\(channels.values.filter { $0 == type }.count)")
            }
            do {
                let (pluginData, pluginResponse) = try await request("plugins/webapp", token: token, allowDisabledPlugins: true)
                if pluginResponse.statusCode == 501 {
                    print("INFO: webapp plugin endpoint unavailable (HTTP 501)")
                } else {
                    let plugins = try JSONDecoder().decode([Plugin].self, from: pluginData)
                    print("INFO: active webapp plugin count=\(plugins.count); IDs redacted")
                }
            } catch { print("INFO: optional webapp plugin metadata unavailable (details suppressed)") }

            guard var components = URLComponents(url: base.appendingPathComponent("api/v4/websocket"), resolvingAgainstBaseURL: false)
            else { throw ProbeError.failed("Invalid WebSocket URL.") }
            components.scheme = base.scheme == "https" ? "wss" : "ws"
            guard let websocketURL = components.url else { throw ProbeError.failed("Invalid WebSocket URL.") }
            var socketRequest = URLRequest(url: websocketURL)
            socketRequest.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let socket = session.webSocketTask(with: socketRequest)
            defer { socket.cancel(with: .normalClosure, reason: nil) }
            socket.resume()
            // Cancellation closes the receive operation so discovery cannot wait indefinitely.
            let deadline = Task {
                try await Task.sleep(for: .seconds(15))
                socket.cancel(with: .goingAway, reason: nil)
            }
            defer { deadline.cancel() }
            var foundHello = false
            for _ in 0..<20 {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let bytes): data = bytes
                case .string(let string): data = Data(string.utf8)
                @unknown default: continue
                }
                let event = try JSONDecoder().decode(Event.self, from: data)
                if event.event == "hello" {
                    guard let version = event.data?.server_version, !version.isEmpty
                    else { throw ProbeError.failed("Hello has no server version.") }
                    print("PASS: authenticated WebSocket hello; server version=\(safeVersion(version))")
                    foundHello = true
                    break
                }
            }
            guard foundHello else { throw ProbeError.failed("No authenticated WebSocket hello.") }
            socket.cancel(with: .normalClosure, reason: nil)
        } catch {
            do {
                _ = try await request("users/logout", method: "POST", token: token)
                print("PASS: test session revoked after probe failure")
            }
            catch { print("WARNING: test session cleanup failed; revoke session manually.") }
            throw error
        }
        _ = try await request("users/logout", method: "POST", token: token)
        print("PASS: test session revoked; no messages posted")
    }

    static func safeVersion(_ text: String) -> String {
        let parts = text.split(separator: ".").prefix(3)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else { return "not reported (custom metadata redacted)" }
        return parts.joined(separator: ".") + " (build metadata redacted)"
    }

    static func apiURL(base: URL, path: String) throws -> URL {
        let parts = path.split(separator: "?", maxSplits: 1)
        guard var components = URLComponents(url: base.appendingPathComponent("api/v4/" + String(parts[0])), resolvingAgainstBaseURL: false)
        else { throw ProbeError.failed("Invalid API URL.") }
        if parts.count == 2 { components.percentEncodedQuery = String(parts[1]) }
        guard let url = components.url else { throw ProbeError.failed("Invalid API URL.") }
        return url
    }
}

private enum TOTP {
    static func decodeSecret(_ input: String) throws -> Data {
        let text = input.uppercased().filter { !$0.isWhitespace }
        let symbols = Array(text.prefix { $0 != "=" })
        let padding = text.count - symbols.count
        let remainder = symbols.count % 8
        let expectedPadding = [0: 0, 2: 6, 4: 4, 5: 3, 7: 1]
        guard !symbols.isEmpty, let expected = expectedPadding[remainder],
              padding == 0 || (padding == expected && text.suffix(padding).allSatisfy { $0 == "=" })
        else { throw ProbeError.failed("Invalid Base32 TOTP secret.") }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt32 = 0
        var bits = 0
        var bytes = Data()
        for symbol in symbols {
            guard let value = alphabet.firstIndex(of: symbol)
            else { throw ProbeError.failed("Invalid Base32 TOTP secret.") }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 255))
            }
            buffer &= (1 << bits) - 1
        }
        guard buffer == 0 else { throw ProbeError.failed("Invalid Base32 TOTP secret.") }
        return bytes
    }

    static func code(key: Data, time: UInt64, digits: Int = 6) -> String {
        var counter = (time / 30).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        let offset = Int(digest[digest.count - 1] & 15)
        let number = digest[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7fffffff
        return String(format: "%0*u", digits, number % (digits == 8 ? 100_000_000 : 1_000_000))
    }

    static func selfTest() throws {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let key = try decodeSecret(secret)
        guard key == Data("12345678901234567890".utf8) else { throw ProbeError.failed("Base32 vector failed.") }
        let vectors: [(UInt64, String)] = [(59, "94287082"), (1_111_111_109, "07081804"),
            (1_111_111_111, "14050471"), (1_234_567_890, "89005924"),
            (2_000_000_000, "69279037"), (20_000_000_000, "65353130")]
        for (time, expected) in vectors {
            guard code(key: key, time: time, digits: 8) == expected,
                  code(key: key, time: time) == String(expected.suffix(6))
            else { throw ProbeError.failed("TOTP vector failed.") }
        }
        guard try decodeSecret("my======") == Data("f".utf8),
              code(key: key, time: 1_111_111_110) == "050471"
        else { throw ProbeError.failed("TOTP formatting or padding failed.") }
        for invalid in ["", "A", "MZ", "MY=====", "MY======A", "123!"] {
            do { _ = try decodeSecret(invalid) }
            catch { continue }
            throw ProbeError.failed("Invalid Base32 accepted.")
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
private struct CurrentUser: Decodable {
    let id: String
    let username: String
    let email: String
    let auth_service: String?
    let mfa_active: Bool?
}
private struct Team: Decodable { let id: String }
private struct Channel: Decodable { let id: String; let type: String }
private struct Ping: Decodable { let status: String }
private struct Plugin: Decodable { let id: String }
private struct Event: Decodable {
    let event: String?
    let data: Hello?
    struct Hello: Decodable { let server_version: String? }
}
