/**
 * NexusGGR / FiversCan API — Java 11+ integration sample (java.net.http + org.json)
 * =================================================================================
 * Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
 * Auth      : every request body carries agent_code + agent_token
 * Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
 *             {"status": 0, "msg": "<ERROR>"}        on failure
 * Methods   : provider_list, game_list, user_create, user_deposit,
 *             game_launch, money_info, user_withdraw
 * API access: https://t.me/casino_api777  ·  https://nexusggr.games
 *
 * Dependency: org.json:json (https://mvnrepository.com/artifact/org.json/json)
 * Run:
 *   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... \
 *     java -cp json-20240303.jar Index.java
 */

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Collections;
import java.util.Map;
import java.util.Optional;

import org.json.JSONArray;
import org.json.JSONObject;

public class Index {

    static final String API_URL     = env("FVS_API_URL", "https://api.example.com"); // API server you received from NexusGGR
    static final String AGENT_CODE  = env("FVS_AGENT_CODE", "your_agent_code");
    static final String AGENT_TOKEN = env("FVS_AGENT_TOKEN", "your_agent_token");

    static String env(String name, String fallback) {
        String v = System.getenv(name);
        return v == null || v.isEmpty() ? fallback : v;
    }

    /** Raised when the API answers status != 1; {@code msg} is the API error code. */
    public static class FiversCanException extends RuntimeException {
        public final String method;
        public final String msg;
        public final String detail;

        FiversCanException(String method, String msg, String detail) {
            super(method + " failed: " + msg + (detail != null ? " (" + detail + ")" : ""));
            this.method = method;
            this.msg = msg;
            this.detail = detail;
        }
    }

    public static class FiversCanClient {
        private final String apiUrl;
        private final String agentCode;
        private final String agentToken;
        private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

        public FiversCanClient(String apiUrl, String agentCode, String agentToken) {
            this.apiUrl = apiUrl;
            this.agentCode = agentCode;
            this.agentToken = agentToken;
        }

        /** Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status. */
        public JSONObject call(String method, Map<String, ?> params) throws IOException, InterruptedException {
            JSONObject body = new JSONObject()
                    .put("method", method)
                    .put("agent_code", agentCode)
                    .put("agent_token", agentToken);
            params.forEach(body::put);

            HttpRequest request = HttpRequest.newBuilder(URI.create(apiUrl))
                    .timeout(Duration.ofSeconds(15))
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(body.toString()))
                    .build();
            HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() != 200) {
                throw new IOException(method + ": HTTP " + response.statusCode());
            }

            JSONObject data = new JSONObject(response.body());
            if (data.optInt("status", 0) != 1) {
                throw new FiversCanException(method, data.optString("msg", "unknown"), data.optString("detail", null));
            }
            return data;
        }

        public JSONObject providerList() throws IOException, InterruptedException {
            return call("provider_list", Collections.emptyMap());
        }

        public JSONObject gameList(String providerCode) throws IOException, InterruptedException {
            return call("game_list", Map.of("provider_code", providerCode));
        }

        public JSONObject userCreate(String userCode) throws IOException, InterruptedException {
            return call("user_create", Map.of("user_code", userCode));
        }

        // amount is sent as a JSON number; agentSign is an optional unique id ([A-Za-z0-9_])
        // that prevents double-charging when a request is retried
        public JSONObject userDeposit(String userCode, double amount, String agentSign) throws IOException, InterruptedException {
            return call("user_deposit", transferParams(userCode, amount, agentSign));
        }

        public JSONObject userWithdraw(String userCode, double amount, String agentSign) throws IOException, InterruptedException {
            return call("user_withdraw", transferParams(userCode, amount, agentSign));
        }

        private static Map<String, Object> transferParams(String userCode, double amount, String agentSign) {
            return agentSign == null || agentSign.isEmpty()
                    ? Map.of("user_code", userCode, "amount", amount)
                    : Map.of("user_code", userCode, "amount", amount, "agent_sign", agentSign);
        }

        // Without userCode returns the agent balance only; send all_users=true to list every user
        public JSONObject moneyInfo(String userCode) throws IOException, InterruptedException {
            return call("money_info", userCode == null ? Collections.emptyMap() : Map.of("user_code", userCode));
        }

        // gameCode may be empty for live-casino providers to open the lobby.
        // lobbyUrl and rtp are optional and are OMITTED when null/empty: the server rejects "lobby_url": "" (Joi string, empty not allowed)
        public JSONObject gameLaunch(String userCode, String providerCode, String gameCode, String lang, String lobbyUrl, Double rtp)
                throws IOException, InterruptedException {
            JSONObject params = new JSONObject()
                    .put("user_code", userCode)
                    .put("provider_code", providerCode)
                    .put("game_code", gameCode == null ? "" : gameCode)
                    .put("lang", lang);
            if (lobbyUrl != null && !lobbyUrl.isEmpty()) {
                params.put("lobby_url", lobbyUrl);
            }
            if (rtp != null) {
                params.put("rtp", rtp.doubleValue());
            }
            return call("game_launch", params.toMap());
        }
    }

    public static void main(String[] args) throws Exception {
        FiversCanClient fvs = new FiversCanClient(API_URL, AGENT_CODE, AGENT_TOKEN);
        String userCode = "demo_user";

        // 1. Providers available to this agent (status 1 = open, 0 = maintenance)
        JSONArray providers = fvs.providerList().getJSONArray("providers");
        JSONObject provider = providers.getJSONObject(0);
        for (int i = 0; i < providers.length(); i++) {
            if (providers.getJSONObject(i).optInt("status") == 1) { provider = providers.getJSONObject(i); break; }
        }
        System.out.printf("providers: %d, using %s%n", providers.length(), provider.getString("code"));

        // 2. Games of that provider
        JSONArray games = fvs.gameList(provider.getString("code")).getJSONArray("games");
        JSONObject game = games.getJSONObject(0);
        System.out.printf("games: %d, first: %s (%s)%n", games.length(), game.getString("game_code"), game.optString("game_name"));

        // 3. Create the player (idempotent: an existing user is fine)
        try {
            JSONObject created = fvs.userCreate(userCode);
            System.out.printf("user created: %s (%s)%n", created.getString("user_code"), created.getString("fc_code"));
        } catch (FiversCanException e) {
            if (!e.msg.toLowerCase().contains("duplicated")) throw e;
            System.out.printf("user exists: %s%n", userCode);
        }

        // 4. Move funds agent -> player
        JSONObject dep = fvs.userDeposit(userCode, 100, "dep_" + System.currentTimeMillis());
        System.out.printf("deposit ok: agent=%s user=%s%n", dep.get("agent_balance"), dep.get("user_balance"));

        // 5. Get the game URL to open in the player's browser / iframe
        JSONObject launch = fvs.gameLaunch(userCode, provider.getString("code"), game.getString("game_code"), "en", "https://your-site.com/lobby", null);
        System.out.printf("launch_url: %s%n", launch.getString("launch_url"));

        // 6. Balances
        JSONObject info = fvs.moneyInfo(userCode);
        System.out.printf("balance: agent=%s user=%s%n", info.getJSONObject("agent").get("balance"), info.getJSONObject("user").get("balance"));

        // 7. Move funds player -> agent
        JSONObject wd = fvs.userWithdraw(userCode, 50, "wd_" + System.currentTimeMillis());
        System.out.printf("withdraw ok: agent=%s user=%s%n", wd.get("agent_balance"), wd.get("user_balance"));
    }
}
