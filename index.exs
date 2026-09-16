# NexusGGR / FiversCan API — Elixir integration sample (Req via Mix.install)
# ===========================================================================
# Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
# Auth      : every request body carries agent_code + agent_token
# Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
#             {"status": 0, "msg": "<ERROR>"}        on failure
# Methods   : provider_list, game_list, user_create, user_deposit,
#             game_launch, money_info, user_withdraw
# API access: https://t.me/casino_api777  ·  https://nexusggr.games
#
# Run (Elixir 1.15+; Mix.install fetches Req on first run):
#   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... elixir index.exs

Mix.install([{:req, "~> 0.5"}])

defmodule FiversCan.Error do
  @moduledoc "Raised when the API answers status != 1; `msg` is the API error code."
  defexception [:method, :msg, :detail]

  @impl true
  def message(%{method: method, msg: msg, detail: detail}) do
    "#{method} failed: #{msg}" <> if(detail, do: " (#{detail})", else: "")
  end
end

defmodule FiversCan.Client do
  @moduledoc "Thin client over the FiversCan agent API."

  defstruct [:api_url, :agent_code, :agent_token]

  def new(api_url, agent_code, agent_token),
    do: %__MODULE__{api_url: api_url, agent_code: agent_code, agent_token: agent_token}

  @doc "Low-level call: POST %{method, agent_code, agent_token, ...params}; returns {:ok, data} | {:error, %FiversCan.Error{}}."
  def call(%__MODULE__{} = c, method, params \\ %{}) do
    body = Map.merge(%{method: method, agent_code: c.agent_code, agent_token: c.agent_token}, params)

    case Req.post!(c.api_url, json: body, receive_timeout: 15_000) do
      %Req.Response{status: 200, body: %{"status" => 1} = data} ->
        {:ok, data}

      %Req.Response{status: 200, body: %{} = data} ->
        {:error, %FiversCan.Error{method: method, msg: data["msg"] || "unknown", detail: data["detail"]}}

      %Req.Response{status: status} ->
        raise "#{method}: HTTP #{status}"
    end
  end

  @doc "Same as call/3 but raises FiversCan.Error on an API error."
  def call!(c, method, params \\ %{}) do
    case call(c, method, params) do
      {:ok, data} -> data
      {:error, err} -> raise err
    end
  end

  def provider_list(c), do: call!(c, "provider_list")

  def game_list(c, provider_code), do: call!(c, "game_list", %{provider_code: provider_code})

  def user_create(c, user_code), do: call(c, "user_create", %{user_code: user_code})

  # amount must be a number (JSON number); agent_sign is an optional unique id ([A-Za-z0-9_])
  # that prevents double-charging when a request is retried
  def user_deposit(c, user_code, amount, agent_sign \\ nil),
    do: call!(c, "user_deposit", transfer_params(user_code, amount, agent_sign))

  def user_withdraw(c, user_code, amount, agent_sign \\ nil),
    do: call!(c, "user_withdraw", transfer_params(user_code, amount, agent_sign))

  defp transfer_params(user_code, amount, nil), do: %{user_code: user_code, amount: amount}
  defp transfer_params(user_code, amount, sign), do: %{user_code: user_code, amount: amount, agent_sign: sign}

  # Without user_code returns the agent balance only; pass %{all_users: true} to list every user
  def money_info(c, user_code \\ nil),
    do: call!(c, "money_info", if(user_code, do: %{user_code: user_code}, else: %{}))

  # game_code may be "" for live-casino providers to open the lobby; rtp is optional
  def game_launch(c, opts) do
    params = %{
      user_code: Keyword.fetch!(opts, :user_code),
      provider_code: Keyword.fetch!(opts, :provider_code),
      game_code: Keyword.get(opts, :game_code, ""),
      lang: Keyword.get(opts, :lang, "en"),
      lobby_url: Keyword.get(opts, :lobby_url, "")
    }

    params = if rtp = Keyword.get(opts, :rtp), do: Map.put(params, :rtp, rtp), else: params
    call!(c, "game_launch", params)
  end
end

defmodule Demo do
  alias FiversCan.Client

  defp env(name, fallback) do
    case System.get_env(name) do
      nil -> fallback
      "" -> fallback
      value -> value
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  def run do
    fvs =
      Client.new(
        # API server you received from NexusGGR
        env("FVS_API_URL", "https://api.example.com"),
        env("FVS_AGENT_CODE", "your_agent_code"),
        env("FVS_AGENT_TOKEN", "your_agent_token")
      )

    user_code = "demo_user"

    # 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    %{"providers" => providers} = Client.provider_list(fvs)
    provider = Enum.find(providers, hd(providers), &(&1["status"] == 1))
    IO.puts("providers: #{length(providers)}, using #{provider["code"]}")

    # 2. Games of that provider
    %{"games" => games} = Client.game_list(fvs, provider["code"])
    game = hd(games)
    IO.puts("games: #{length(games)}, first: #{game["game_code"]} (#{game["game_name"]})")

    # 3. Create the player (idempotent: an existing user is fine)
    case Client.user_create(fvs, user_code) do
      {:ok, created} ->
        IO.puts("user created: #{created["user_code"]} (#{created["fc_code"]})")

      {:error, %FiversCan.Error{msg: msg} = err} ->
        if String.contains?(String.downcase(msg), "duplicated"),
          do: IO.puts("user exists: #{user_code}"),
          else: raise(err)
    end

    # 4. Move funds agent -> player
    dep = Client.user_deposit(fvs, user_code, 100, "dep_#{now_ms()}")
    IO.puts("deposit ok: agent=#{dep["agent_balance"]} user=#{dep["user_balance"]}")

    # 5. Get the game URL to open in the player's browser / iframe
    launch =
      Client.game_launch(fvs,
        user_code: user_code,
        provider_code: provider["code"],
        game_code: game["game_code"],
        lang: "en",
        lobby_url: "https://your-site.com/lobby"
      )

    IO.puts("launch_url: #{launch["launch_url"]}")

    # 6. Balances
    info = Client.money_info(fvs, user_code)
    IO.puts("balance: agent=#{info["agent"]["balance"]} user=#{info["user"]["balance"]}")

    # 7. Move funds player -> agent
    wd = Client.user_withdraw(fvs, user_code, 50, "wd_#{now_ms()}")
    IO.puts("withdraw ok: agent=#{wd["agent_balance"]} user=#{wd["user_balance"]}")
  end
end

try do
  Demo.run()
rescue
  e ->
    IO.puts(:stderr, Exception.message(e))
    System.halt(1)
end
