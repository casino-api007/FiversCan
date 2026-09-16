//> using scala 3.3
//> using dep com.lihaoyi::requests:0.9.0
//> using dep com.lihaoyi::ujson:4.4.3

// NexusGGR / FiversCan API — Scala 3 integration sample (requests-scala + uJson, run with scala-cli)
// ===================================================================================================
// Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
// Auth      : every request body carries agent_code + agent_token
// Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
//             {"status": 0, "msg": "<ERROR>"}        on failure
// Methods   : provider_list, game_list, user_create, user_deposit,
//             game_launch, money_info, user_withdraw
// API access: https://t.me/casino_api777  ·  https://nexusggr.games
//
// Run:
//   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... scala-cli run index.scala

import scala.util.{Failure, Success, Try}

def env(name: String, fallback: String): String =
  sys.env.get(name).filter(_.nonEmpty).getOrElse(fallback)

/** Thrown when the API answers status != 1; `msg` is the API error code. */
final case class FiversCanException(method: String, msg: String, detail: Option[String])
    extends RuntimeException(s"$method failed: $msg${detail.map(d => s" ($d)").getOrElse("")}")

final class FiversCanClient(apiUrl: String, agentCode: String, agentToken: String):

  /** Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status. */
  def call(method: String, params: (String, ujson.Value)*): ujson.Obj =
    val body = ujson.Obj("method" -> method, "agent_code" -> agentCode, "agent_token" -> agentToken)
    params.foreach { case (k, v) => body.value(k) = v }

    val response = requests.post(
      apiUrl,
      data = ujson.write(body),
      headers = Map("Content-Type" -> "application/json"),
      connectTimeout = 5000,
      readTimeout = 15000,
      check = false,
    )
    if response.statusCode != 200 then throw RuntimeException(s"$method: HTTP ${response.statusCode}")

    val data = ujson.read(response.text()).obj
    if data.get("status").flatMap(_.numOpt).contains(1.0) then ujson.Obj(data)
    else throw FiversCanException(method, data.get("msg").flatMap(_.strOpt).getOrElse("unknown"), data.get("detail").flatMap(_.strOpt))

  def providerList(): ujson.Obj = call("provider_list")

  def gameList(providerCode: String): ujson.Obj = call("game_list", "provider_code" -> providerCode)

  def userCreate(userCode: String): ujson.Obj = call("user_create", "user_code" -> userCode)

  // amount is sent as a JSON number; agentSign is an optional unique id ([A-Za-z0-9_])
  // that prevents double-charging when a request is retried
  def userDeposit(userCode: String, amount: Double, agentSign: Option[String] = None): ujson.Obj =
    call("user_deposit", transferParams(userCode, amount, agentSign)*)

  def userWithdraw(userCode: String, amount: Double, agentSign: Option[String] = None): ujson.Obj =
    call("user_withdraw", transferParams(userCode, amount, agentSign)*)

  private def transferParams(userCode: String, amount: Double, agentSign: Option[String]): Seq[(String, ujson.Value)] =
    Seq("user_code" -> ujson.Str(userCode), "amount" -> ujson.Num(amount)) ++ agentSign.map(s => "agent_sign" -> ujson.Str(s))

  // Without userCode returns the agent balance only; send "all_users" -> true to list every user
  def moneyInfo(userCode: Option[String] = None): ujson.Obj =
    call("money_info", userCode.map(c => "user_code" -> ujson.Str(c)).toSeq*)

  // gameCode may be empty for live-casino providers to open the lobby; rtp is optional
  def gameLaunch(userCode: String, providerCode: String, gameCode: String = "", lang: String = "en", lobbyUrl: String = "", rtp: Option[Double] = None): ujson.Obj =
    val params = Seq[(String, ujson.Value)](
      "user_code" -> ujson.Str(userCode),
      "provider_code" -> ujson.Str(providerCode),
      "game_code" -> ujson.Str(gameCode),
      "lang" -> ujson.Str(lang),
      "lobby_url" -> ujson.Str(lobbyUrl),
    ) ++ rtp.map(r => "rtp" -> ujson.Num(r))
    call("game_launch", params*)

@main def run(): Unit =
  val fvs = FiversCanClient(
    env("FVS_API_URL", "https://api.example.com"), // API server you received from NexusGGR
    env("FVS_AGENT_CODE", "your_agent_code"),
    env("FVS_AGENT_TOKEN", "your_agent_token"),
  )
  val userCode = "demo_user"

  val outcome = Try {
    // 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    val providers = fvs.providerList()("providers").arr
    val provider = providers.find(_("status").num == 1).getOrElse(providers.head)
    val providerCode = provider("code").str
    println(s"providers: ${providers.size}, using $providerCode")

    // 2. Games of that provider
    val games = fvs.gameList(providerCode)("games").arr
    val game = games.head
    val gameCode = game("game_code").str
    println(s"games: ${games.size}, first: $gameCode (${game.obj.get("game_name").flatMap(_.strOpt).getOrElse("")})")

    // 3. Create the player (idempotent: an existing user is fine)
    Try(fvs.userCreate(userCode)) match
      case Success(created) => println(s"user created: ${created("user_code").str} (${created("fc_code").str})")
      case Failure(e: FiversCanException) if e.msg.toLowerCase.contains("duplicated") => println(s"user exists: $userCode")
      case Failure(e) => throw e

    // 4. Move funds agent -> player
    val dep = fvs.userDeposit(userCode, 100, Some(s"dep_${System.currentTimeMillis()}"))
    println(s"deposit ok: agent=${dep("agent_balance")} user=${dep("user_balance")}")

    // 5. Get the game URL to open in the player's browser / iframe
    val launch = fvs.gameLaunch(userCode, providerCode, gameCode, lang = "en", lobbyUrl = "https://your-site.com/lobby")
    println(s"launch_url: ${launch("launch_url").str}")

    // 6. Balances
    val info = fvs.moneyInfo(Some(userCode))
    println(s"balance: agent=${info("agent")("balance")} user=${info("user")("balance")}")

    // 7. Move funds player -> agent
    val wd = fvs.userWithdraw(userCode, 50, Some(s"wd_${System.currentTimeMillis()}"))
    println(s"withdraw ok: agent=${wd("agent_balance")} user=${wd("user_balance")}")
  }

  outcome match
    case Success(_) => ()
    case Failure(e) =>
      System.err.println(e.getMessage)
      sys.exit(1)
