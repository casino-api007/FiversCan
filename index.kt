/**
 * NexusGGR / FiversCan API — Kotlin (JVM) integration sample (java.net.http + kotlinx.serialization.json)
 * ========================================================================================================
 * Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
 * Auth      : every request body carries agent_code + agent_token
 * Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
 *             {"status": 0, "msg": "<ERROR>"}        on failure
 * Methods   : provider_list, game_list, user_create, user_deposit,
 *             game_launch, money_info, user_withdraw
 * API access: https://t.me/casino_api777  ·  https://nexusggr.games
 *
 * Dependency: org.jetbrains.kotlinx:kotlinx-serialization-json (the JsonObject DSL only, no compiler plugin needed)
 * Run:
 *   kotlinc index.kt -cp kotlinx-serialization-json-jvm-1.7.3.jar:kotlinx-serialization-core-jvm-1.7.3.jar -include-runtime -d fvs.jar
 *   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... \
 *     java -cp fvs.jar:kotlinx-serialization-json-jvm-1.7.3.jar:kotlinx-serialization-core-jvm-1.7.3.jar IndexKt
 */

import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration
import kotlin.system.exitProcess
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

private fun env(name: String, fallback: String): String = System.getenv(name)?.takeIf { it.isNotEmpty() } ?: fallback

val API_URL = env("FVS_API_URL", "https://api.example.com") // API server you received from NexusGGR
val AGENT_CODE = env("FVS_AGENT_CODE", "your_agent_code")
val AGENT_TOKEN = env("FVS_AGENT_TOKEN", "your_agent_token")

/** Raised when the API answers status != 1; [msg] is the API error code. */
class FiversCanException(val method: String, val msg: String, val detail: String? = null) :
    RuntimeException("$method failed: $msg${detail?.let { " ($it)" } ?: ""}")

class FiversCanClient(private val apiUrl: String, private val agentCode: String, private val agentToken: String) {
    private val http: HttpClient = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build()

    /** Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status. */
    fun call(method: String, params: Map<String, JsonElement> = emptyMap()): JsonObject {
        val body = buildJsonObject {
            put("method", JsonPrimitive(method))
            put("agent_code", JsonPrimitive(agentCode))
            put("agent_token", JsonPrimitive(agentToken))
            params.forEach { (k, v) -> put(k, v) }
        }

        val request = HttpRequest.newBuilder(URI.create(apiUrl))
            .timeout(Duration.ofSeconds(15))
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(body.toString()))
            .build()
        val response = http.send(request, HttpResponse.BodyHandlers.ofString())
        if (response.statusCode() != 200) error("$method: HTTP ${response.statusCode()}")

        val data = Json.parseToJsonElement(response.body()).jsonObject
        if (data["status"]?.jsonPrimitive?.int != 1) {
            throw FiversCanException(method, data["msg"]?.jsonPrimitive?.contentOrNull ?: "unknown", data["detail"]?.jsonPrimitive?.contentOrNull)
        }
        return data
    }

    fun providerList(): JsonObject = call("provider_list")

    fun gameList(providerCode: String): JsonObject = call("game_list", mapOf("provider_code" to JsonPrimitive(providerCode)))

    fun userCreate(userCode: String): JsonObject = call("user_create", mapOf("user_code" to JsonPrimitive(userCode)))

    // amount is sent as a JSON number; agentSign is an optional unique id ([A-Za-z0-9_])
    // that prevents double-charging when a request is retried
    fun userDeposit(userCode: String, amount: Number, agentSign: String? = null): JsonObject =
        call("user_deposit", transferParams(userCode, amount, agentSign))

    fun userWithdraw(userCode: String, amount: Number, agentSign: String? = null): JsonObject =
        call("user_withdraw", transferParams(userCode, amount, agentSign))

    private fun transferParams(userCode: String, amount: Number, agentSign: String?): Map<String, JsonElement> =
        buildMap {
            put("user_code", JsonPrimitive(userCode))
            put("amount", JsonPrimitive(amount))
            agentSign?.let { put("agent_sign", JsonPrimitive(it)) }
        }

    // Without userCode returns the agent balance only; send all_users = true to list every user
    fun moneyInfo(userCode: String? = null): JsonObject =
        call("money_info", userCode?.let { mapOf("user_code" to JsonPrimitive(it)) } ?: emptyMap())

    // gameCode may be empty for live-casino providers to open the lobby; rtp is optional
    fun gameLaunch(userCode: String, providerCode: String, gameCode: String = "", lang: String = "en", lobbyUrl: String = "", rtp: Number? = null): JsonObject =
        call(
            "game_launch",
            buildMap {
                put("user_code", JsonPrimitive(userCode))
                put("provider_code", JsonPrimitive(providerCode))
                put("game_code", JsonPrimitive(gameCode))
                put("lang", JsonPrimitive(lang))
                put("lobby_url", JsonPrimitive(lobbyUrl))
                rtp?.let { put("rtp", JsonPrimitive(it)) }
            },
        )
}

private fun JsonObject.str(key: String): String = this[key]?.jsonPrimitive?.contentOrNull ?: ""

fun main() {
    try {
        val fvs = FiversCanClient(API_URL, AGENT_CODE, AGENT_TOKEN)
        val userCode = "demo_user"

        // 1. Providers available to this agent (status 1 = open, 0 = maintenance)
        val providers = fvs.providerList()["providers"]!!.jsonArray.map { it.jsonObject }
        val provider = providers.firstOrNull { it["status"]?.jsonPrimitive?.int == 1 } ?: providers.first()
        println("providers: ${providers.size}, using ${provider.str("code")}")

        // 2. Games of that provider
        val games = fvs.gameList(provider.str("code"))["games"]!!.jsonArray.map { it.jsonObject }
        val game = games.first()
        println("games: ${games.size}, first: ${game.str("game_code")} (${game.str("game_name")})")

        // 3. Create the player (idempotent: an existing user is fine)
        try {
            val created = fvs.userCreate(userCode)
            println("user created: ${created.str("user_code")} (${created.str("fc_code")})")
        } catch (e: FiversCanException) {
            if (!e.msg.contains("duplicated", ignoreCase = true)) throw e
            println("user exists: $userCode")
        }

        // 4. Move funds agent -> player
        val dep = fvs.userDeposit(userCode, 100, "dep_${System.currentTimeMillis()}")
        println("deposit ok: agent=${dep["agent_balance"]} user=${dep["user_balance"]}")

        // 5. Get the game URL to open in the player's browser / iframe
        val launch = fvs.gameLaunch(userCode, provider.str("code"), game.str("game_code"), lang = "en", lobbyUrl = "https://your-site.com/lobby")
        println("launch_url: ${launch.str("launch_url")}")

        // 6. Balances
        val info = fvs.moneyInfo(userCode)
        println("balance: agent=${info["agent"]!!.jsonObject["balance"]} user=${info["user"]!!.jsonObject["balance"]}")

        // 7. Move funds player -> agent
        val wd = fvs.userWithdraw(userCode, 50, "wd_${System.currentTimeMillis()}")
        println("withdraw ok: agent=${wd["agent_balance"]} user=${wd["user_balance"]}")
    } catch (e: Exception) {
        System.err.println(e.message)
        exitProcess(1)
    }
}
