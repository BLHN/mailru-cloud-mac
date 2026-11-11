import Foundation

/// Checks an e-mail and an app password against Mail.ru WebDAV directly: one `PROPFIND` of the
/// cloud root with Basic auth, before anything is stored. Faster than rclone and it gives the exact
/// HTTP status. Nothing is cached: an ephemeral session without cookies or credential storage.
enum WebDAVProbe {
    static let endpoint = URL(string: "https://webdav.cloud.mail.ru/")!

    struct Quota: Equatable, Sendable {
        var available: Int64?
        var used: Int64?
        var total: Int64? {
            guard let a = available, let u = used else { return nil }
            return a + u
        }
    }

    enum Failure: Equatable, Sendable {
        /// Mail.ru did not accept the e-mail and password: 401 (no or empty credentials) or, as seen
        /// on 11.11.2026, 403 with the body "Wrong credentials" for a wrong pair.
        case wrongPassword
        /// 403 with another body, or 402: the box does not let outside apps into the cloud (assumed meaning).
        case accessDenied(Int)
        /// 5xx: a failure on Mail.ru's side.
        case serverError(Int)
        /// Any other answer (404, 405, …): WebDAV is not offered as expected.
        case noWebDAV(Int)
        /// No internet connection at all.
        case offline
        /// The server could not be reached in time (DNS, connect, timeout).
        case notResponding
        /// The TLS certificate was not accepted: usually an antivirus, VPN or proxy in between.
        case tls
        case other(String)

        /// Text for the user, on «вы», without long dashes.
        var message: String {
            switch self {
            case .wrongPassword:
                return "Mail.ru не принял пароль. Нужен пароль для внешнего приложения с доступом к Облаку, обычный пароль от почты не подойдёт. Проверьте почту и пароль."
            case .accessDenied:
                return "Mail.ru не пускает внешние приложения в Облако этого ящика. Так бывает на некоторых тарифах и у новых ящиков, из приложения это не обойти."
            case .serverError(let code):
                return "У Облака временный сбой (ответ \(code)). Попробуйте через несколько минут."
            case .noWebDAV(let code):
                return "Облако ответило не так, как ожидалось (ответ \(code)). Похоже, доступ для внешних приложений у этого ящика закрыт."
            case .offline:
                return "Нет интернета. Проверьте подключение и попробуйте ещё раз."
            case .notResponding:
                return "Облако не отвечает. Проверьте интернет или попробуйте чуть позже."
            case .tls:
                return "Не получилось установить защищённое соединение с Облаком. Похоже, его перехватывает антивирус, VPN или прокси."
            case .other(let text):
                return "Не получилось проверить вход: \(text)"
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case ok(Quota)
        case failed(Failure)
    }

    private static let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:quota-available-bytes/><d:quota-used-bytes/></d:prop></d:propfind>
        """

    /// `endpoint` is replaced only by the dev self-test (a local redirecting server).
    static func check(email: String, password: String, endpoint: URL = endpoint) async -> Outcome {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let token = Data("\(email):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(body.utf8)

        do {
            // Redirects are not followed: a 3xx is the final answer (`.noWebDAV`), so a 2xx from
            // some other host can never pass for an accepted password.
            let (data, response) = try await session.data(for: request, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else { return .failed(.other("нет ответа HTTP")) }
            return outcome(status: http.statusCode, body: data)
        } catch let e as URLError {
            return .failed(failure(for: e))
        } catch {
            return .failed(.other(error.localizedDescription))
        }
    }

    /// Refuses every redirect of the probe.
    final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    /// Maps an HTTP answer. Pure, for tests.
    static func outcome(status: Int, body: Data) -> Outcome {
        switch status {
        case 200...299: return .ok(quota(in: body))
        case 401: return .failed(.wrongPassword)
        case 403 where String(decoding: body.prefix(512), as: UTF8.self).lowercased().contains("wrong credentials"):
            return .failed(.wrongPassword)
        case 402, 403: return .failed(.accessDenied(status))
        case 500...599: return .failed(.serverError(status))
        default: return .failed(.noWebDAV(status))
        }
    }

    static func failure(for e: URLError) -> Failure {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .notResponding
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected:
            return .tls
        default:
            return .other(e.localizedDescription)
        }
    }

    /// `quota-available-bytes` and `quota-used-bytes` of a multistatus body, when the server sent them.
    static func quota(in body: Data) -> Quota {
        let text = String(decoding: body, as: UTF8.self)
        func number(_ name: String) -> Int64? {
            let pattern = "<(?:[A-Za-z0-9]+:)?\(name)[^>]*>\\s*([0-9]+)\\s*<"
            guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
            let digits = text[r].split(separator: ">").dropFirst().first?.prefix { $0.isNumber || $0 == " " || $0 == "\n" }
            return digits.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return Quota(available: number("quota-available-bytes"), used: number("quota-used-bytes"))
    }
}
