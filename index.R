# NexusGGR / FiversCan API — R integration sample (httr2 + jsonlite)
# ===================================================================
# Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
# Auth      : every request body carries agent_code + agent_token
# Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
#             {"status": 0, "msg": "<ERROR>"}        on failure
# Methods   : provider_list, game_list, user_create, user_deposit,
#             game_launch, money_info, user_withdraw
# API access: https://t.me/casino_api777  ·  https://nexusggr.games
#
# Dependencies: install.packages(c("httr2", "jsonlite"))
# Run:
#   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... Rscript index.R

library(httr2)
library(jsonlite)

env_or <- function(name, fallback) {
  value <- Sys.getenv(name, unset = "")
  if (nzchar(value)) value else fallback
}

API_URL     <- env_or("FVS_API_URL", "https://api.example.com") # API server you received from NexusGGR
AGENT_CODE  <- env_or("FVS_AGENT_CODE", "your_agent_code")
AGENT_TOKEN <- env_or("FVS_AGENT_TOKEN", "your_agent_token")

# Raised (as a classed condition) when the API answers status != 1; msg is the API error code.
fiverscan_error <- function(method, msg, detail = NULL) {
  structure(
    class = c("fiverscan_error", "error", "condition"),
    list(
      message = paste0(method, " failed: ", msg, if (!is.null(detail)) paste0(" (", detail, ")") else ""),
      method = method, msg = msg, detail = detail, call = NULL
    )
  )
}

fiverscan_client <- function(api_url, agent_code, agent_token) {
  self <- list(api_url = api_url, agent_code = agent_code, agent_token = agent_token)

  # Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status.
  # Values must be unboxed scalars so jsonlite emits `"amount": 100`, not `"amount": [100]`.
  self$call <- function(method, params = list()) {
    body <- c(list(method = method, agent_code = self$agent_code, agent_token = self$agent_token), params)

    resp <- request(self$api_url) |>
      req_method("POST") |>
      req_headers("Content-Type" = "application/json") |>
      req_body_raw(toJSON(body, auto_unbox = TRUE), type = "application/json") |>
      req_timeout(15) |>
      req_error(is_error = function(resp) FALSE) |>
      req_perform()
    if (resp_status(resp) != 200) stop(sprintf("%s: HTTP %d", method, resp_status(resp)))

    data <- fromJSON(resp_body_string(resp), simplifyVector = FALSE)
    if (is.null(data$status) || data$status != 1) {
      stop(fiverscan_error(method, if (is.null(data$msg)) "unknown" else data$msg, data$detail))
    }
    data
  }

  self$provider_list <- function() self$call("provider_list")

  self$game_list <- function(provider_code) self$call("game_list", list(provider_code = provider_code))

  self$user_create <- function(user_code) self$call("user_create", list(user_code = user_code))

  # amount must be numeric (JSON number); agent_sign is an optional unique id ([A-Za-z0-9_])
  # that prevents double-charging when a request is retried
  self$user_deposit <- function(user_code, amount, agent_sign = NULL) {
    self$call("user_deposit", transfer_params(user_code, amount, agent_sign))
  }

  self$user_withdraw <- function(user_code, amount, agent_sign = NULL) {
    self$call("user_withdraw", transfer_params(user_code, amount, agent_sign))
  }

  transfer_params <- function(user_code, amount, agent_sign) {
    params <- list(user_code = user_code, amount = as.numeric(amount))
    if (!is.null(agent_sign)) params$agent_sign <- agent_sign
    params
  }

  # Without user_code returns the agent balance only; pass list(all_users = TRUE) to list every user
  self$money_info <- function(user_code = NULL) {
    self$call("money_info", if (is.null(user_code)) list() else list(user_code = user_code))
  }

  # game_code may be "" for live-casino providers to open the lobby; rtp is optional
  self$game_launch <- function(user_code, provider_code, game_code = "", lang = "en", lobby_url = "", rtp = NULL) {
    params <- list(user_code = user_code, provider_code = provider_code, game_code = game_code, lang = lang, lobby_url = lobby_url)
    if (!is.null(rtp)) params$rtp <- as.numeric(rtp)
    self$call("game_launch", params)
  }

  self
}

now_millis <- function() format(round(as.numeric(Sys.time()) * 1000), scientific = FALSE)

main <- function() {
  fvs <- fiverscan_client(API_URL, AGENT_CODE, AGENT_TOKEN)
  user_code <- "demo_user"

  # 1. Providers available to this agent (status 1 = open, 0 = maintenance)
  providers <- fvs$provider_list()$providers
  open <- Filter(function(p) isTRUE(p$status == 1), providers)
  provider <- if (length(open) > 0) open[[1]] else providers[[1]]
  cat(sprintf("providers: %d, using %s\n", length(providers), provider$code))

  # 2. Games of that provider
  games <- fvs$game_list(provider$code)$games
  game <- games[[1]]
  cat(sprintf("games: %d, first: %s (%s)\n", length(games), game$game_code, game$game_name))

  # 3. Create the player (idempotent: an existing user is fine)
  tryCatch(
    {
      created <- fvs$user_create(user_code)
      cat(sprintf("user created: %s (%s)\n", created$user_code, created$fc_code))
    },
    fiverscan_error = function(e) {
      if (!grepl("duplicated", e$msg, ignore.case = TRUE)) stop(e)
      cat(sprintf("user exists: %s\n", user_code))
    }
  )

  # 4. Move funds agent -> player
  dep <- fvs$user_deposit(user_code, 100, paste0("dep_", now_millis()))
  cat(sprintf("deposit ok: agent=%s user=%s\n", dep$agent_balance, dep$user_balance))

  # 5. Get the game URL to open in the player's browser / iframe
  launch <- fvs$game_launch(user_code, provider$code, game$game_code, lang = "en", lobby_url = "https://your-site.com/lobby")
  cat(sprintf("launch_url: %s\n", launch$launch_url))

  # 6. Balances
  info <- fvs$money_info(user_code)
  cat(sprintf("balance: agent=%s user=%s\n", info$agent$balance, info$user$balance))

  # 7. Move funds player -> agent
  wd <- fvs$user_withdraw(user_code, 50, paste0("wd_", now_millis()))
  cat(sprintf("withdraw ok: agent=%s user=%s\n", wd$agent_balance, wd$user_balance))
}

tryCatch(main(), error = function(e) {
  message(conditionMessage(e))
  quit(status = 1)
})
