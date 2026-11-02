import Foundation

/// Errors of the Microsoft → Xbox Live → Minecraft chain, phrased so the
/// Player screen can show them as they are.
enum AuthError: Error, LocalizedError {
    case http(status: Int, message: String)
    case refused(String)
    case notPurchased
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            return "Microsoft answered \(status): \(message)"
        case .refused(let message):
            return message
        case .notPurchased:
            return "This Microsoft account does not own Minecraft: Java Edition."
        case .badResponse(let message):
            return message
        }
    }
}

/// What the device code endpoint hands back: the code the player types in the
/// browser, and how often the app may ask whether it was used.
struct AuthDeviceCode: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresAt: Date
    let interval: TimeInterval
}

/// The tokens one sign-in leaves behind. The Microsoft half is renewed with
/// `offline_access`; the Minecraft half is derived from it and expires on its
/// own schedule.
struct MicrosoftSession: Codable, Hashable, Sendable {
    var msaAccessToken: String
    var msaRefreshToken: String
    var msaExpiresAt: Date
    var minecraftAccessToken: String
    var minecraftExpiresAt: Date
}

/// A Minecraft profile and the tokens that prove it — what the Keychain holds.
struct SignedInAccount: Codable, Hashable, Sendable {
    var uuid: UUID
    var name: String
    var session: MicrosoftSession
}

/// Minosoft's Microsoft authentication, ported from
/// `util/account/microsoft/MicrosoftOAuthUtils.kt` and `util/account/AccountUtil.kt`:
/// the same client id, the same consumer tenant, and the same chain —
/// device code → MSA token → Xbox Live → XSTS → Minecraft services → profile.
///
/// The device-code flow replaces a web view because it needs no redirect URI
/// and no client secret, and the player's password never reaches the app.
enum MicrosoftAuth {
    /// Minosoft 2's own Azure application (microsoft-bixilon2).
    static let clientID = "feb3836f-0333-4185-8eb9-4cbf0498f947"

    private static let tenant = "consumers"
    private static let scope = "XboxLive.signin offline_access"

    private static let deviceCodeURL = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/devicecode")!
    private static let tokenURL = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
    private static let xboxLiveURL = URL(string: "https://user.auth.xboxlive.com/user/authenticate")!
    private static let xstsURL = URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!
    private static let loginWithXboxURL = URL(string: "https://api.minecraftservices.com/authentication/login_with_xbox")!
    private static let profileURL = URL(string: "https://api.minecraftservices.com/minecraft/profile")!
    private static let joinURL = URL(string: "https://sessionserver.mojang.com/session/minecraft/join")!

    /// Tokens are refreshed inside the last two minutes of their life, so a
    /// join never races the expiry.
    private static let refreshWindow: TimeInterval = 120

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    // MARK: Sign-in

    /// Runs the whole chain: reports the device code, waits until the player
    /// confirmed it in the browser, then resolves Xbox Live, XSTS and the
    /// Minecraft profile.
    static func signIn(onDeviceCode: @escaping @Sendable (AuthDeviceCode) -> Void) async throws -> SignedInAccount {
        let code = try await requestDeviceCode()
        onDeviceCode(code)

        let microsoft = try await waitForAuthorization(code)
        let session = try await authenticateMinecraft(microsoft)
        let profile = try await fetchProfile(accessToken: session.minecraftAccessToken)
        return SignedInAccount(uuid: profile.uuid, name: profile.name, session: session)
    }

    static func requestDeviceCode() async throws -> AuthDeviceCode {
        let response = try await postForm(deviceCodeURL, [
            "client_id": clientID,
            "scope": scope,
        ])

        guard response.status == 200,
              let deviceCode = response.body["device_code"] as? String,
              let userCode = response.body["user_code"] as? String,
              let uri = (response.body["verification_uri"] as? String).flatMap(URL.init(string:)),
              let expiresIn = response.body["expires_in"] as? Int else {
            throw AuthError.http(status: response.status, message: message(from: response.body))
        }
        guard uri.scheme == "https" else {
            throw AuthError.badResponse("Microsoft sent an insecure sign-in address.")
        }

        // Minosoft accepts 1…20 s; anything outside that is a broken answer.
        let interval = TimeInterval(response.body["interval"] as? Int ?? 5)
        return AuthDeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: uri,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            interval: min(max(interval, 1), 20)
        )
    }

    private static func waitForAuthorization(_ code: AuthDeviceCode) async throws -> MicrosoftTokenSet {
        var interval = code.interval

        while Date() < code.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            let response = try await postForm(tokenURL, [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": clientID,
                "device_code": code.deviceCode,
            ])
            if response.status == 200 {
                return try tokenSet(from: response.body)
            }

            switch response.body["error"] as? String {
            case "authorization_pending":
                continue // the player is still in the browser
            case "slow_down":
                interval += 5
                continue
            case "expired_token":
                throw AuthError.refused("The sign-in code expired. Start again.")
            case "authorization_declined", "access_denied":
                throw AuthError.refused("The sign-in was declined in the browser.")
            default:
                throw AuthError.http(status: response.status, message: message(from: response.body))
            }
        }

        throw AuthError.refused("The sign-in code expired before it was used. Start again.")
    }

    // MARK: Token lifetime

    /// Renews what an account needs before a session: the Microsoft token
    /// first, then the Minecraft token derived from it, and only when either
    /// is close to running out.
    static func refreshing(_ account: Account) async throws -> Account {
        guard let signedIn = account.signedIn else { return account }

        let now = Date()
        var session = signedIn.session
        var microsoft = MicrosoftTokenSet(
            accessToken: session.msaAccessToken,
            refreshToken: session.msaRefreshToken,
            expiresAt: session.msaExpiresAt
        )

        var renewed = false
        if microsoft.expiresAt.timeIntervalSince(now) < refreshWindow {
            microsoft = try await refreshMicrosoftToken(microsoft.refreshToken)
            renewed = true
        }

        if renewed || session.minecraftExpiresAt.timeIntervalSince(now) < refreshWindow {
            session = try await authenticateMinecraft(microsoft)
        }

        var account = account
        account.session = session
        return account
    }

    private static func refreshMicrosoftToken(_ refreshToken: String) async throws -> MicrosoftTokenSet {
        let response = try await postForm(tokenURL, [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "scope": scope,
            "refresh_token": refreshToken,
        ])

        guard response.status == 200 else {
            if (response.body["error"] as? String) == "invalid_grant" {
                throw AuthError.refused("The Microsoft sign-in expired. Sign in again.")
            }
            throw AuthError.http(status: response.status, message: message(from: response.body))
        }
        return try tokenSet(from: response.body, fallbackRefreshToken: refreshToken)
    }

    // MARK: The Minecraft chain

    private static func authenticateMinecraft(_ microsoft: MicrosoftTokenSet) async throws -> MicrosoftSession {
        let xbox = try await xboxLiveToken(msaAccessToken: microsoft.accessToken)
        let xsts = try await xstsToken(xboxLiveToken: xbox.token)
        let minecraft = try await minecraftToken(userHash: xsts.userHash, xstsToken: xsts.token)

        return MicrosoftSession(
            msaAccessToken: microsoft.accessToken,
            msaRefreshToken: microsoft.refreshToken,
            msaExpiresAt: microsoft.expiresAt,
            minecraftAccessToken: minecraft.accessToken,
            minecraftExpiresAt: minecraft.expiresAt
        )
    }

    private static func xboxLiveToken(msaAccessToken: String) async throws -> XboxToken {
        let response = try await postJSON(xboxLiveURL, [
            "Properties": [
                "AuthMethod": "RPS",
                "SiteName": "user.auth.xboxlive.com",
                "RpsTicket": "d=\(msaAccessToken)",
            ],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT",
        ])

        guard response.status == 200 else {
            throw AuthError.http(status: response.status, message: message(from: response.body))
        }
        return try xboxToken(from: response.body)
    }

    private static func xstsToken(xboxLiveToken: String) async throws -> XboxToken {
        let response = try await postJSON(xstsURL, [
            "Properties": [
                "SandboxId": "RETAIL",
                "UserTokens": [xboxLiveToken],
            ],
            "RelyingParty": "rp://api.minecraftservices.com/",
            "TokenType": "JWT",
        ])

        if response.status == 200 {
            return try xboxToken(from: response.body)
        }

        // XSTS answers 401 with an XErr that says exactly what is wrong.
        let code = (response.body["XErr"] as? Int) ?? Int(response.body["XErr"] as? String ?? "")
        switch code {
        case 2148916233:
            throw AuthError.refused("This Microsoft account has no Xbox profile. Create one at xbox.com, then try again.")
        case 2148916235:
            throw AuthError.refused("Xbox Live is not available in this account's country.")
        case 2148916236, 2148916237:
            throw AuthError.refused("This account needs adult verification before it can play.")
        case 2148916238:
            throw AuthError.refused("This is a child account. A parent has to add it to a Microsoft family first.")
        default:
            throw AuthError.http(status: response.status, message: message(from: response.body))
        }
    }

    private static func minecraftToken(userHash: String, xstsToken: String) async throws -> (accessToken: String, expiresAt: Date) {
        let response = try await postJSON(loginWithXboxURL, [
            "identityToken": "XBL3.0 x=\(userHash);\(xstsToken)",
            "ensureLegacyEnabled": true,
        ])

        guard response.status == 200,
              let accessToken = response.body["access_token"] as? String else {
            throw AuthError.http(status: response.status, message: message(from: response.body))
        }

        let expiresIn = TimeInterval(response.body["expires_in"] as? Int ?? 86_400)
        return (accessToken, Date().addingTimeInterval(expiresIn))
    }

    private static func fetchProfile(accessToken: String) async throws -> Profile {
        var request = URLRequest(url: profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            throw AuthError.notPurchased
        }
        guard status == 200 else {
            throw AuthError.http(status: status, message: String(decoding: data, as: UTF8.self))
        }

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = object["id"] as? String,
              let name = object["name"] as? String,
              let uuid = UUID(uuidString: dashedUUID(id)) else {
            throw AuthError.badResponse("The Minecraft profile could not be read.")
        }
        return Profile(uuid: uuid, name: name)
    }

    /// Tells Mojang's session server this client is joining, which is what the
    /// server checks before it accepts an online-mode login. `hash` is the
    /// signed SHA-1 of the encryption handshake.
    static func joinServer(hash: String, uuid: UUID, accessToken: String) async throws {
        let response = try await postJSON(joinURL, [
            "accessToken": accessToken,
            "selectedProfile": uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "serverId": hash,
        ])

        guard response.status == 204 || response.status == 200 else {
            throw AuthError.http(status: response.status, message: message(from: response.body))
        }
    }

    // MARK: Pieces

    private struct HTTPResult {
        let status: Int
        let body: [String: Any]
    }

    private struct MicrosoftTokenSet {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    private struct XboxToken {
        let token: String
        let userHash: String
    }

    private struct Profile {
        let uuid: UUID
        let name: String
    }

    private static func tokenSet(from body: [String: Any], fallbackRefreshToken: String? = nil) throws -> MicrosoftTokenSet {
        guard let accessToken = body["access_token"] as? String,
              let refreshToken = (body["refresh_token"] as? String) ?? fallbackRefreshToken else {
            throw AuthError.badResponse("Microsoft's token response had no tokens in it.")
        }
        let expiresIn = TimeInterval(body["expires_in"] as? Int ?? 3600)
        return MicrosoftTokenSet(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    /// Both XBL and XSTS answer with a JWT plus `DisplayClaims.xui[0].uhs`.
    private static func xboxToken(from body: [String: Any]) throws -> XboxToken {
        guard let token = body["Token"] as? String,
              let claims = body["DisplayClaims"] as? [String: Any],
              let users = claims["xui"] as? [[String: Any]],
              let userHash = users.first?["uhs"] as? String else {
            throw AuthError.badResponse("Xbox Live's response had no token in it.")
        }
        return XboxToken(token: token, userHash: userHash)
    }

    private static func dashedUUID(_ id: String) -> String {
        guard id.count == 32 else { return id }
        let hex = Array(id)
        return "\(String(hex[0..<8]))-\(String(hex[8..<12]))-\(String(hex[12..<16]))-\(String(hex[16..<20]))-\(String(hex[20..<32]))"
    }

    // MARK: HTTP

    private static func postForm(_ url: URL, _ fields: [String: String]) async throws -> HTTPResult {
        let body = fields
            .map { "\(formEscape($0.key))=\(formEscape($0.value))" }
            .joined(separator: "&")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return try await perform(request)
    }

    private static func postJSON(_ url: URL, _ object: [String: Any]) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        return try await perform(request)
    }

    private static func perform(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return HTTPResult(status: status, body: object)
    }

    private static func formEscape(_ string: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func message(from body: [String: Any]) -> String {
        (body["error_description"] as? String)
            ?? (body["errorMessage"] as? String)
            ?? (body["error"] as? String)
            ?? "no details"
    }
}
