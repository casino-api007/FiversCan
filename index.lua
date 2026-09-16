--[[
NexusGGR / FiversCan API — Lua 5.x integration sample (luasocket + luasec + lua-cjson)
=======================================================================================
Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
Auth      : every request body carries agent_code + agent_token
Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
            {"status": 0, "msg": "<ERROR>"}        on failure
Methods   : provider_list, game_list, user_create, user_deposit,
            game_launch, money_info, user_withdraw
API access: https://t.me/casino_api777  ·  https://nexusggr.games

Dependencies: luarocks install luasocket luasec lua-cjson
Run:
  FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... lua index.lua
]]

local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local cjson = require("cjson")

local function env(name, fallback)
    local v = os.getenv(name)
    if v == nil or v == "" then return fallback end
    return v
end

local API_URL = env("FVS_API_URL", "https://api.example.com") -- API server you received from NexusGGR
local AGENT_CODE = env("FVS_AGENT_CODE", "your_agent_code")
local AGENT_TOKEN = env("FVS_AGENT_TOKEN", "your_agent_token")

local FiversCanClient = {}
FiversCanClient.__index = FiversCanClient

function FiversCanClient.new(api_url, agent_code, agent_token)
    return setmetatable({ api_url = api_url, agent_code = agent_code, agent_token = agent_token }, FiversCanClient)
end

-- Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status.
-- Returns data, or nil + error table { method, msg, detail } when the API answers status != 1.
-- Transport failures raise an error.
function FiversCanClient:call(method, params)
    local body = { method = method, agent_code = self.agent_code, agent_token = self.agent_token }
    for k, v in pairs(params or {}) do body[k] = v end
    local payload = cjson.encode(body)

    local chunks = {}
    -- luasec (ssl.https) is only loaded for https:// endpoints, so plain-http dev setups need only luasocket
    local transport = self.api_url:match("^https://") and require("ssl.https") or http
    local _, code, _, status_line = transport.request({
        url = self.api_url,
        method = "POST",
        headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#payload) },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(chunks),
    })
    if code ~= 200 then
        error(string.format("%s: HTTP %s", method, tostring(status_line or code)))
    end

    local data = cjson.decode(table.concat(chunks))
    if data.status ~= 1 then
        return nil, { method = method, msg = data.msg or "unknown", detail = data.detail }
    end
    return data
end

function FiversCanClient:provider_list()
    return self:call("provider_list")
end

function FiversCanClient:game_list(provider_code)
    return self:call("game_list", { provider_code = provider_code })
end

function FiversCanClient:user_create(user_code)
    return self:call("user_create", { user_code = user_code })
end

-- amount must be a Lua number so cjson emits a JSON number; agent_sign is an optional unique id
-- ([A-Za-z0-9_]) that prevents double-charging when a request is retried
function FiversCanClient:user_deposit(user_code, amount, agent_sign)
    return self:call("user_deposit", { user_code = user_code, amount = amount, agent_sign = agent_sign })
end

function FiversCanClient:user_withdraw(user_code, amount, agent_sign)
    return self:call("user_withdraw", { user_code = user_code, amount = amount, agent_sign = agent_sign })
end

-- Without user_code returns the agent balance only; pass all_users = true to list every user
function FiversCanClient:money_info(user_code)
    return self:call("money_info", { user_code = user_code })
end

-- game_code may be "" for live-casino providers to open the lobby; rtp is optional (nil omits it)
function FiversCanClient:game_launch(opts)
    return self:call("game_launch", {
        user_code = opts.user_code,
        provider_code = opts.provider_code,
        game_code = opts.game_code or "",
        lang = opts.lang or "en",
        lobby_url = opts.lobby_url or "",
        rtp = opts.rtp,
    })
end

local function now_millis()
    return math.floor(socket.gettime() * 1000)
end

local function describe(err)
    return string.format("%s failed: %s%s", err.method, err.msg, err.detail and (" (" .. err.detail .. ")") or "")
end

-- Unwrap (data, err) into data, raising a readable error otherwise
local function must(data, err)
    if data == nil then error(describe(err), 0) end
    return data
end

local function main()
    local fvs = FiversCanClient.new(API_URL, AGENT_CODE, AGENT_TOKEN)
    local user_code = "demo_user"

    -- 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    local providers = must(fvs:provider_list()).providers
    local provider = providers[1]
    for _, p in ipairs(providers) do
        if p.status == 1 then provider = p; break end
    end
    print(string.format("providers: %d, using %s", #providers, provider.code))

    -- 2. Games of that provider
    local games = must(fvs:game_list(provider.code)).games
    local game = games[1]
    print(string.format("games: %d, first: %s (%s)", #games, game.game_code, game.game_name or ""))

    -- 3. Create the player (idempotent: an existing user is fine)
    local created, err = fvs:user_create(user_code)
    if created then
        print(string.format("user created: %s (%s)", created.user_code, created.fc_code))
    elseif err.msg:lower():find("duplicated", 1, true) then
        print("user exists: " .. user_code)
    else
        error(describe(err), 0)
    end

    -- 4. Move funds agent -> player
    local dep = must(fvs:user_deposit(user_code, 100, "dep_" .. now_millis()))
    print(string.format("deposit ok: agent=%s user=%s", dep.agent_balance, dep.user_balance))

    -- 5. Get the game URL to open in the player's browser / iframe
    local launch = must(fvs:game_launch({ user_code = user_code, provider_code = provider.code, game_code = game.game_code, lang = "en", lobby_url = "https://your-site.com/lobby" }))
    print("launch_url: " .. launch.launch_url)

    -- 6. Balances
    local info = must(fvs:money_info(user_code))
    print(string.format("balance: agent=%s user=%s", info.agent.balance, info.user.balance))

    -- 7. Move funds player -> agent
    local wd = must(fvs:user_withdraw(user_code, 50, "wd_" .. now_millis()))
    print(string.format("withdraw ok: agent=%s user=%s", wd.agent_balance, wd.user_balance))
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write(tostring(err), "\n")
    os.exit(1)
end
