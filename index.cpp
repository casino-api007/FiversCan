// NexusGGR / FiversCan API — C++17 integration sample (libcurl + nlohmann/json)
// ==============================================================================
// Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
// Auth      : every request body carries agent_code + agent_token
// Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
//             {"status": 0, "msg": "<ERROR>"}        on failure
// Methods   : provider_list, game_list, user_create, user_deposit,
//             game_launch, money_info, user_withdraw
// API access: https://t.me/casino_api777  ·  https://nexusggr.games
//
// Dependencies: libcurl (apt install libcurl4-openssl-dev), nlohmann/json single header (apt install nlohmann-json3-dev)
// Build & run:
//   g++ -std=c++17 -O2 index.cpp -lcurl -o fvs
//   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... ./fvs

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>

#include <curl/curl.h>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

static std::string env(const char* name, const char* fallback) {
    const char* v = std::getenv(name);
    return (v && *v) ? v : fallback;
}

/// Thrown when the API answers status != 1; `msg` is the API error code.
class FiversCanError : public std::runtime_error {
public:
    const std::string method;
    const std::string msg;
    const std::string detail;

    FiversCanError(std::string m, std::string s, std::string d)
        : std::runtime_error(m + " failed: " + s + (d.empty() ? "" : " (" + d + ")")),
          method(std::move(m)), msg(std::move(s)), detail(std::move(d)) {}
};

class FiversCanClient {
public:
    FiversCanClient(std::string apiUrl, std::string agentCode, std::string agentToken)
        : apiUrl_(std::move(apiUrl)), agentCode_(std::move(agentCode)), agentToken_(std::move(agentToken)) {
        curl_global_init(CURL_GLOBAL_DEFAULT);
    }
    ~FiversCanClient() { curl_global_cleanup(); }
    FiversCanClient(const FiversCanClient&) = delete;
    FiversCanClient& operator=(const FiversCanClient&) = delete;

    /// Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status.
    json call(const std::string& method, json params = json::object()) {
        params["method"] = method;
        params["agent_code"] = agentCode_;
        params["agent_token"] = agentToken_;
        const std::string body = params.dump();

        CURL* curl = curl_easy_init();
        if (!curl) throw std::runtime_error("curl_easy_init failed");
        std::string response;
        curl_slist* headers = curl_slist_append(nullptr, "Content-Type: application/json");
        curl_easy_setopt(curl, CURLOPT_URL, apiUrl_.c_str());
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 15L);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, &FiversCanClient::onWrite);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);

        const CURLcode rc = curl_easy_perform(curl);
        long httpCode = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &httpCode);
        curl_slist_free_all(headers);
        curl_easy_cleanup(curl);

        if (rc != CURLE_OK) throw std::runtime_error(method + ": " + curl_easy_strerror(rc));
        if (httpCode != 200) throw std::runtime_error(method + ": HTTP " + std::to_string(httpCode));

        json data = json::parse(response);
        if (data.value("status", 0) != 1) {
            throw FiversCanError(method, data.value("msg", "unknown"), data.value("detail", ""));
        }
        return data;
    }

    json providerList() { return call("provider_list"); }

    json gameList(const std::string& providerCode) { return call("game_list", {{"provider_code", providerCode}}); }

    json userCreate(const std::string& userCode) { return call("user_create", {{"user_code", userCode}}); }

    // amount is sent as a JSON number; agentSign is an optional unique id ([A-Za-z0-9_])
    // that prevents double-charging when a request is retried
    json userDeposit(const std::string& userCode, double amount, std::optional<std::string> agentSign = std::nullopt) {
        return call("user_deposit", transferParams(userCode, amount, agentSign));
    }

    json userWithdraw(const std::string& userCode, double amount, std::optional<std::string> agentSign = std::nullopt) {
        return call("user_withdraw", transferParams(userCode, amount, agentSign));
    }

    // Without userCode returns the agent balance only; send "all_users": true to list every user
    json moneyInfo(std::optional<std::string> userCode = std::nullopt) {
        json params = json::object();
        if (userCode) params["user_code"] = *userCode;
        return call("money_info", params);
    }

    // gameCode may be empty for live-casino providers to open the lobby; rtp is optional
    json gameLaunch(const std::string& userCode, const std::string& providerCode, const std::string& gameCode = "",
                    const std::string& lang = "en", const std::string& lobbyUrl = "", std::optional<double> rtp = std::nullopt) {
        json params = {{"user_code", userCode}, {"provider_code", providerCode}, {"game_code", gameCode}, {"lang", lang}, {"lobby_url", lobbyUrl}};
        if (rtp) params["rtp"] = *rtp;
        return call("game_launch", params);
    }

private:
    static size_t onWrite(char* ptr, size_t size, size_t nmemb, void* userdata) {
        static_cast<std::string*>(userdata)->append(ptr, size * nmemb);
        return size * nmemb;
    }

    static json transferParams(const std::string& userCode, double amount, const std::optional<std::string>& agentSign) {
        json params = {{"user_code", userCode}, {"amount", amount}};
        if (agentSign) params["agent_sign"] = *agentSign;
        return params;
    }

    std::string apiUrl_;
    std::string agentCode_;
    std::string agentToken_;
};

static std::string nowMillis() {
    using namespace std::chrono;
    return std::to_string(duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count());
}

static bool containsIgnoreCase(std::string haystack, std::string needle) {
    std::transform(haystack.begin(), haystack.end(), haystack.begin(), ::tolower);
    std::transform(needle.begin(), needle.end(), needle.begin(), ::tolower);
    return haystack.find(needle) != std::string::npos;
}

int main() {
    try {
        FiversCanClient fvs(env("FVS_API_URL", "https://api.example.com"), // API server you received from NexusGGR
                            env("FVS_AGENT_CODE", "your_agent_code"),
                            env("FVS_AGENT_TOKEN", "your_agent_token"));
        const std::string userCode = "demo_user";

        // 1. Providers available to this agent (status 1 = open, 0 = maintenance)
        const json providers = fvs.providerList()["providers"];
        auto open = std::find_if(providers.begin(), providers.end(), [](const json& p) { return p.value("status", 0) == 1; });
        const json provider = open != providers.end() ? *open : providers.at(0);
        const std::string providerCode = provider.at("code");
        std::cout << "providers: " << providers.size() << ", using " << providerCode << "\n";

        // 2. Games of that provider
        const json games = fvs.gameList(providerCode)["games"];
        const json game = games.at(0);
        const std::string gameCode = game.at("game_code");
        std::cout << "games: " << games.size() << ", first: " << gameCode << " (" << game.value("game_name", "") << ")\n";

        // 3. Create the player (idempotent: an existing user is fine)
        try {
            const json created = fvs.userCreate(userCode);
            std::cout << "user created: " << created.value("user_code", "") << " (" << created.value("fc_code", "") << ")\n";
        } catch (const FiversCanError& e) {
            if (!containsIgnoreCase(e.msg, "duplicated")) throw;
            std::cout << "user exists: " << userCode << "\n";
        }

        // 4. Move funds agent -> player
        const json dep = fvs.userDeposit(userCode, 100, "dep_" + nowMillis());
        std::cout << "deposit ok: agent=" << dep["agent_balance"] << " user=" << dep["user_balance"] << "\n";

        // 5. Get the game URL to open in the player's browser / iframe
        const json launch = fvs.gameLaunch(userCode, providerCode, gameCode, "en", "https://your-site.com/lobby");
        std::cout << "launch_url: " << launch.value("launch_url", "") << "\n";

        // 6. Balances
        const json info = fvs.moneyInfo(userCode);
        std::cout << "balance: agent=" << info["agent"]["balance"] << " user=" << info["user"]["balance"] << "\n";

        // 7. Move funds player -> agent
        const json wd = fvs.userWithdraw(userCode, 50, "wd_" + nowMillis());
        std::cout << "withdraw ok: agent=" << wd["agent_balance"] << " user=" << wd["user_balance"] << "\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << e.what() << "\n";
        return 1;
    }
}
