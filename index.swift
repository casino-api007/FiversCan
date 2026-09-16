// NexusGGR / FiversCan API — Swift 5 integration sample (Foundation URLSession + JSONSerialization)
// =================================================================================================
// Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
// Auth      : every request body carries agent_code + agent_token
// Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
//             {"status": 0, "msg": "<ERROR>"}        on failure
// Methods   : provider_list, game_list, user_create, user_deposit,
//             game_launch, money_info, user_withdraw
// API access: https://t.me/casino_api777  ·  https://nexusggr.games
//
// Run (Swift 5.7+; macOS, or Linux with swift-corelibs-foundation):
//   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... swift index.swift

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func env(_ name: String, _ fallback: String) -> String {
    let value = ProcessInfo.processInfo.environment[name] ?? ""
    return value.isEmpty ? fallback : value
}

let apiURL = env("FVS_API_URL", "https://api.example.com") // API server you received from NexusGGR
let agentCode = env("FVS_AGENT_CODE", "your_agent_code")
let agentToken = env("FVS_AGENT_TOKEN", "your_agent_token")

typealias JSONObject = [String: Any]

/// Thrown when the API answers status != 1; `msg` is the API error code.
struct FiversCanError: Error, CustomStringConvertible {
    let method: String
    let msg: String
    let detail: String?

    var description: String { "\(method) failed: \(msg)" + (detail.map { " (\($0))" } ?? "") }
}

struct TransportError: Error, CustomStringConvertible {
    let description: String
}

final class FiversCanClient {
    private let apiURL: URL
    private let agentCode: String
    private let agentToken: String
    private let session: URLSession

    init(apiURL: String, agentCode: String, agentToken: String) {
        self.apiURL = URL(string: apiURL)!
        self.agentCode = agentCode
        self.agentToken = agentToken
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    /// Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status.
    func call(_ method: String, _ params: JSONObject = [:]) async throws -> JSONObject {
        var body: JSONObject = ["method": method, "agent_code": agentCode, "agent_token": agentToken]
        params.forEach { body[$0.key] = $0.value }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TransportError(description: "\(method): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw TransportError(description: "\(method): invalid JSON")
        }
        guard (json["status"] as? Int) == 1 else {
            throw FiversCanError(method: method, msg: json["msg"] as? String ?? "unknown", detail: json["detail"] as? String)
        }
        return json
    }

    func providerList() async throws -> JSONObject { try await call("provider_list") }

    func gameList(providerCode: String) async throws -> JSONObject { try await call("game_list", ["provider_code": providerCode]) }

    func userCreate(userCode: String) async throws -> JSONObject { try await call("user_create", ["user_code": userCode]) }

    // amount is sent as a JSON number; agentSign is an optional unique id ([A-Za-z0-9_])
    // that prevents double-charging when a request is retried
    func userDeposit(userCode: String, amount: Double, agentSign: String? = nil) async throws -> JSONObject {
        try await call("user_deposit", transferParams(userCode, amount, agentSign))
    }

    func userWithdraw(userCode: String, amount: Double, agentSign: String? = nil) async throws -> JSONObject {
        try await call("user_withdraw", transferParams(userCode, amount, agentSign))
    }

    private func transferParams(_ userCode: String, _ amount: Double, _ agentSign: String?) -> JSONObject {
        var params: JSONObject = ["user_code": userCode, "amount": amount]
        if let agentSign = agentSign { params["agent_sign"] = agentSign }
        return params
    }

    // Without userCode returns the agent balance only; send "all_users": true to list every user
    func moneyInfo(userCode: String? = nil) async throws -> JSONObject {
        try await call("money_info", userCode.map { ["user_code": $0] } ?? [:])
    }

    // gameCode may be empty for live-casino providers to open the lobby; rtp is optional
    func gameLaunch(userCode: String, providerCode: String, gameCode: String = "", lang: String = "en", lobbyURL: String = "", rtp: Double? = nil) async throws -> JSONObject {
        var params: JSONObject = ["user_code": userCode, "provider_code": providerCode, "game_code": gameCode, "lang": lang, "lobby_url": lobbyURL]
        if let rtp = rtp { params["rtp"] = rtp }
        return try await call("game_launch", params)
    }
}

func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

func run() async throws {
    let fvs = FiversCanClient(apiURL: apiURL, agentCode: agentCode, agentToken: agentToken)
    let userCode = "demo_user"

    // 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    let providers = try await fvs.providerList()["providers"] as? [JSONObject] ?? []
    guard let provider = providers.first(where: { ($0["status"] as? Int) == 1 }) ?? providers.first else { throw TransportError(description: "no providers") }
    let providerCode = provider["code"] as? String ?? ""
    print("providers: \(providers.count), using \(providerCode)")

    // 2. Games of that provider
    let games = try await fvs.gameList(providerCode: providerCode)["games"] as? [JSONObject] ?? []
    guard let game = games.first else { throw TransportError(description: "no games") }
    let gameCode = game["game_code"] as? String ?? ""
    print("games: \(games.count), first: \(gameCode) (\(game["game_name"] as? String ?? ""))")

    // 3. Create the player (idempotent: an existing user is fine)
    do {
        let created = try await fvs.userCreate(userCode: userCode)
        print("user created: \(created["user_code"] ?? "") (\(created["fc_code"] ?? ""))")
    } catch let e as FiversCanError where e.msg.lowercased().contains("duplicated") {
        print("user exists: \(userCode)")
    }

    // 4. Move funds agent -> player
    let dep = try await fvs.userDeposit(userCode: userCode, amount: 100, agentSign: "dep_\(nowMillis())")
    print("deposit ok: agent=\(dep["agent_balance"] ?? 0) user=\(dep["user_balance"] ?? 0)")

    // 5. Get the game URL to open in the player's browser / iframe
    let launch = try await fvs.gameLaunch(userCode: userCode, providerCode: providerCode, gameCode: gameCode, lang: "en", lobbyURL: "https://your-site.com/lobby")
    print("launch_url: \(launch["launch_url"] ?? "")")

    // 6. Balances
    let info = try await fvs.moneyInfo(userCode: userCode)
    let agent = info["agent"] as? JSONObject ?? [:]
    let user = info["user"] as? JSONObject ?? [:]
    print("balance: agent=\(agent["balance"] ?? 0) user=\(user["balance"] ?? 0)")

    // 7. Move funds player -> agent
    let wd = try await fvs.userWithdraw(userCode: userCode, amount: 50, agentSign: "wd_\(nowMillis())")
    print("withdraw ok: agent=\(wd["agent_balance"] ?? 0) user=\(wd["user_balance"] ?? 0)")
}

do {
    try await run()
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
