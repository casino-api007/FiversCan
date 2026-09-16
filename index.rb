# frozen_string_literal: true

# NexusGGR / FiversCan API — Ruby integration sample (standard library only)
# ===========================================================================
# Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
# Auth      : every request body carries agent_code + agent_token
# Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
#             {"status": 0, "msg": "<ERROR>"}        on failure
# Methods   : provider_list, game_list, user_create, user_deposit,
#             game_launch, money_info, user_withdraw
# API access: https://t.me/casino_api777  ·  https://nexusggr.games
#
# Run:
#   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... ruby index.rb

require "json"
require "net/http"
require "uri"

API_URL     = ENV.fetch("FVS_API_URL", "https://api.example.com") # API server you received from NexusGGR
AGENT_CODE  = ENV.fetch("FVS_AGENT_CODE", "your_agent_code")
AGENT_TOKEN = ENV.fetch("FVS_AGENT_TOKEN", "your_agent_token")

# Raised when the API answers status != 1; +msg+ is the API error code.
class FiversCanError < StandardError
  attr_reader :method_name, :msg, :detail

  def initialize(method_name, msg, detail = nil)
    @method_name = method_name
    @msg = msg
    @detail = detail
    super("#{method_name} failed: #{msg}#{detail ? " (#{detail})" : ''}")
  end
end

class FiversCanClient
  def initialize(api_url, agent_code, agent_token, timeout: 15)
    @uri = URI(api_url)
    @agent_code = agent_code
    @agent_token = agent_token
    @timeout = timeout
  end

  # Low-level call: POST {method, agent_code, agent_token, **params} and unwrap status.
  def call(method, **params)
    body = { method: method, agent_code: @agent_code, agent_token: @agent_token }.merge(params)

    req = Net::HTTP::Post.new(@uri, "Content-Type" => "application/json")
    req.body = JSON.generate(body)
    res = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https", open_timeout: 5, read_timeout: @timeout) do |http|
      http.request(req)
    end
    raise "#{method}: HTTP #{res.code}" unless res.is_a?(Net::HTTPOK)

    data = JSON.parse(res.body)
    raise FiversCanError.new(method, data["msg"] || "unknown", data["detail"]) unless data["status"] == 1

    data
  end

  def provider_list
    call("provider_list")
  end

  def game_list(provider_code)
    call("game_list", provider_code: provider_code)
  end

  def user_create(user_code)
    call("user_create", user_code: user_code)
  end

  # amount must be a JSON number (Integer/Float, not a String); agent_sign is an optional unique id
  # ([A-Za-z0-9_]) that prevents double-charging when a request is retried
  def user_deposit(user_code, amount, agent_sign = nil)
    call("user_deposit", user_code: user_code, amount: amount, **(agent_sign ? { agent_sign: agent_sign } : {}))
  end

  def user_withdraw(user_code, amount, agent_sign = nil)
    call("user_withdraw", user_code: user_code, amount: amount, **(agent_sign ? { agent_sign: agent_sign } : {}))
  end

  # Without user_code returns the agent balance only; with all_users: true returns every user
  def money_info(user_code = nil)
    call("money_info", **(user_code ? { user_code: user_code } : {}))
  end

  # game_code may be empty for live-casino providers to open the lobby; rtp is optional
  def game_launch(user_code:, provider_code:, game_code: "", lang: "en", lobby_url: "", rtp: nil)
    params = { user_code: user_code, provider_code: provider_code, game_code: game_code, lang: lang, lobby_url: lobby_url }
    params[:rtp] = rtp unless rtp.nil?
    call("game_launch", **params)
  end
end

def main
  fvs = FiversCanClient.new(API_URL, AGENT_CODE, AGENT_TOKEN)
  user_code = "demo_user"

  # 1. Providers available to this agent (status 1 = open, 0 = maintenance)
  providers = fvs.provider_list["providers"]
  provider = providers.find { |p| p["status"] == 1 } || providers.first
  puts "providers: #{providers.size}, using #{provider['code']}"

  # 2. Games of that provider
  games = fvs.game_list(provider["code"])["games"]
  game = games.first
  puts "games: #{games.size}, first: #{game['game_code']} (#{game['game_name']})"

  # 3. Create the player (idempotent: an existing user is fine)
  begin
    created = fvs.user_create(user_code)
    puts "user created: #{created['user_code']} (#{created['fc_code']})"
  rescue FiversCanError => e
    raise unless e.msg =~ /duplicated/i

    puts "user exists: #{user_code}"
  end

  # 4. Move funds agent -> player
  dep = fvs.user_deposit(user_code, 100, "dep_#{(Time.now.to_f * 1000).to_i}")
  puts "deposit ok: agent=#{dep['agent_balance']} user=#{dep['user_balance']}"

  # 5. Get the game URL to open in the player's browser / iframe
  launch = fvs.game_launch(user_code: user_code, provider_code: provider["code"], game_code: game["game_code"], lang: "en", lobby_url: "https://your-site.com/lobby")
  puts "launch_url: #{launch['launch_url']}"

  # 6. Balances
  info = fvs.money_info(user_code)
  puts "balance: agent=#{info['agent']['balance']} user=#{info['user']['balance']}"

  # 7. Move funds player -> agent
  wd = fvs.user_withdraw(user_code, 50, "wd_#{(Time.now.to_f * 1000).to_i}")
  puts "withdraw ok: agent=#{wd['agent_balance']} user=#{wd['user_balance']}"
end

begin
  main
rescue StandardError => e
  warn e.message
  exit 1
end
