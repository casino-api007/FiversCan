#!/usr/bin/env bash
# NexusGGR / FiversCan API — Bash integration sample (curl + jq)
# ===============================================================
# Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
# Auth      : every request body carries agent_code + agent_token
# Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
#             {"status": 0, "msg": "<ERROR>"}        on failure
# Methods   : provider_list, game_list, user_create, user_deposit,
#             game_launch, money_info, user_withdraw
# API access: https://t.me/casino_api777  ·  https://nexusggr.games
#
# Run:
#   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... bash index.sh

set -euo pipefail

API_URL="${FVS_API_URL:-https://api.example.com}"   # API server you received from NexusGGR
AGENT_CODE="${FVS_AGENT_CODE:-your_agent_code}"
AGENT_TOKEN="${FVS_AGENT_TOKEN:-your_agent_token}"

# Low-level call: fvs_call <method> [jq-args that add fields, e.g. --arg user_code demo]
# Builds {method, agent_code, agent_token, ...$ARGS.named} with jq so values are typed correctly
# (use --argjson for numbers such as amount, --arg for strings). Prints the response JSON,
# returns non-zero and prints the error to stderr when status != 1.
fvs_call() {
    local method="$1"; shift
    local body response
    body="$(jq -cn --arg method "$method" --arg agent_code "$AGENT_CODE" --arg agent_token "$AGENT_TOKEN" "$@" \
        '$ARGS.named')"
    response="$(curl -sS --fail --connect-timeout 5 --max-time 15 \
        -X POST "$API_URL" -H 'Content-Type: application/json' --data "$body")"

    if [[ "$(jq -r '.status' <<<"$response")" != "1" ]]; then
        echo "$method failed: $(jq -r '.msg + (if .detail then " (" + .detail + ")" else "" end)' <<<"$response")" >&2
        return 1
    fi
    printf '%s\n' "$response"
}

fvs_provider_list() { fvs_call provider_list; }

fvs_game_list() { fvs_call game_list --arg provider_code "$1"; }

fvs_user_create() { fvs_call user_create --arg user_code "$1"; }

# amount must be a JSON number (--argjson); agent_sign is an optional unique id ([A-Za-z0-9_])
# that prevents double-charging when a request is retried
fvs_user_deposit() { fvs_call user_deposit --arg user_code "$1" --argjson amount "$2" ${3:+--arg agent_sign "$3"}; }

fvs_user_withdraw() { fvs_call user_withdraw --arg user_code "$1" --argjson amount "$2" ${3:+--arg agent_sign "$3"}; }

# Without user_code returns the agent balance only; add --argjson all_users true to list every user
fvs_money_info() { fvs_call money_info ${1:+--arg user_code "$1"}; }

# fvs_game_launch <user_code> <provider_code> [game_code] [lang] [lobby_url]
# game_code may be empty for live-casino providers to open the lobby; add --argjson rtp 96 for a target RTP
fvs_game_launch() {
    fvs_call game_launch --arg user_code "$1" --arg provider_code "$2" --arg game_code "${3:-}" \
        --arg lang "${4:-en}" --arg lobby_url "${5:-}"
}

main() {
    local user_code="demo_user"
    local providers provider games game res

    # 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    providers="$(fvs_provider_list)"
    provider="$(jq -r '(.providers | map(select(.status == 1)) | .[0] // .providers[0]) | .code' <<<"$providers")"
    echo "providers: $(jq '.providers | length' <<<"$providers"), using $provider"

    # 2. Games of that provider
    games="$(fvs_game_list "$provider")"
    game="$(jq -r '.games[0].game_code' <<<"$games")"
    echo "games: $(jq '.games | length' <<<"$games"), first: $game ($(jq -r '.games[0].game_name' <<<"$games"))"

    # 3. Create the player (idempotent: an existing user is fine)
    if res="$(fvs_user_create "$user_code" 2>/tmp/fvs_err.$$)"; then
        echo "user created: $(jq -r '.user_code' <<<"$res") ($(jq -r '.fc_code' <<<"$res"))"
    elif grep -qi duplicated /tmp/fvs_err.$$; then
        echo "user exists: $user_code"
    else
        cat /tmp/fvs_err.$$ >&2; rm -f /tmp/fvs_err.$$; return 1
    fi
    rm -f /tmp/fvs_err.$$

    # 4. Move funds agent -> player
    res="$(fvs_user_deposit "$user_code" 100 "dep_$(date +%s%3N)")"
    echo "deposit ok: agent=$(jq '.agent_balance' <<<"$res") user=$(jq '.user_balance' <<<"$res")"

    # 5. Get the game URL to open in the player's browser / iframe
    res="$(fvs_game_launch "$user_code" "$provider" "$game" en "https://your-site.com/lobby")"
    echo "launch_url: $(jq -r '.launch_url' <<<"$res")"

    # 6. Balances
    res="$(fvs_money_info "$user_code")"
    echo "balance: agent=$(jq '.agent.balance' <<<"$res") user=$(jq '.user.balance' <<<"$res")"

    # 7. Move funds player -> agent
    res="$(fvs_user_withdraw "$user_code" 50 "wd_$(date +%s%3N)")"
    echo "withdraw ok: agent=$(jq '.agent_balance' <<<"$res") user=$(jq '.user_balance' <<<"$res")"
}

main "$@"
