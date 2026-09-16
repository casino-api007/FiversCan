// NexusGGR / FiversCan API — C# (.NET 6+) integration sample (HttpClient + System.Text.Json)
// ===========================================================================================
// Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
// Auth      : every request body carries agent_code + agent_token
// Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
//             {"status": 0, "msg": "<ERROR>"}        on failure
// Methods   : provider_list, game_list, user_create, user_deposit,
//             game_launch, money_info, user_withdraw
// API access: https://t.me/casino_api777  ·  https://nexusggr.games
//
// Run (top-level statements; drop this file into a console project as Program.cs):
//   dotnet new console -n FiversCanSample && cp index.cs FiversCanSample/Program.cs
//   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... dotnet run --project FiversCanSample

using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

string Env(string name, string fallback) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : fallback;

var fvs = new FiversCanClient(
    Env("FVS_API_URL", "https://api.example.com"), // API server you received from NexusGGR
    Env("FVS_AGENT_CODE", "your_agent_code"),
    Env("FVS_AGENT_TOKEN", "your_agent_token"));
const string userCode = "demo_user";

try
{
    // 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    var providers = (await fvs.ProviderListAsync())["providers"]!.AsArray();
    var provider = providers.FirstOrDefault(p => p!["status"]!.GetValue<int>() == 1) ?? providers[0]!;
    Console.WriteLine($"providers: {providers.Count}, using {provider["code"]}");

    // 2. Games of that provider
    var games = (await fvs.GameListAsync(provider["code"]!.GetValue<string>()))["games"]!.AsArray();
    var game = games[0]!;
    Console.WriteLine($"games: {games.Count}, first: {game["game_code"]} ({game["game_name"]})");

    // 3. Create the player (idempotent: an existing user is fine)
    try
    {
        var created = await fvs.UserCreateAsync(userCode);
        Console.WriteLine($"user created: {created["user_code"]} ({created["fc_code"]})");
    }
    catch (FiversCanException e) when (e.Msg.Contains("duplicated", StringComparison.OrdinalIgnoreCase))
    {
        Console.WriteLine($"user exists: {userCode}");
    }

    // 4. Move funds agent -> player
    var dep = await fvs.UserDepositAsync(userCode, 100, $"dep_{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
    Console.WriteLine($"deposit ok: agent={dep["agent_balance"]} user={dep["user_balance"]}");

    // 5. Get the game URL to open in the player's browser / iframe
    var launch = await fvs.GameLaunchAsync(userCode, provider["code"]!.GetValue<string>(), game["game_code"]!.GetValue<string>(), "en", "https://your-site.com/lobby");
    Console.WriteLine($"launch_url: {launch["launch_url"]}");

    // 6. Balances
    var info = await fvs.MoneyInfoAsync(userCode);
    Console.WriteLine($"balance: agent={info["agent"]!["balance"]} user={info["user"]!["balance"]}");

    // 7. Move funds player -> agent
    var wd = await fvs.UserWithdrawAsync(userCode, 50, $"wd_{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
    Console.WriteLine($"withdraw ok: agent={wd["agent_balance"]} user={wd["user_balance"]}");
}
catch (Exception e)
{
    Console.Error.WriteLine(e.Message);
    Environment.Exit(1);
}

/// <summary>Raised when the API answers status != 1; <see cref="Msg"/> is the API error code.</summary>
public sealed class FiversCanException : Exception
{
    public string Method { get; }
    public string Msg { get; }
    public string? Detail { get; }

    public FiversCanException(string method, string msg, string? detail)
        : base($"{method} failed: {msg}{(detail is null ? "" : $" ({detail})")}")
    {
        Method = method;
        Msg = msg;
        Detail = detail;
    }
}

public sealed class FiversCanClient
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly string _apiUrl;
    private readonly string _agentCode;
    private readonly string _agentToken;

    public FiversCanClient(string apiUrl, string agentCode, string agentToken)
    {
        _apiUrl = apiUrl;
        _agentCode = agentCode;
        _agentToken = agentToken;
    }

    /// <summary>Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status.</summary>
    public async Task<JsonObject> CallAsync(string method, IDictionary<string, object?>? params_ = null)
    {
        var body = new JsonObject { ["method"] = method, ["agent_code"] = _agentCode, ["agent_token"] = _agentToken };
        if (params_ is not null)
            foreach (var (key, value) in params_)
                body[key] = JsonSerializer.SerializeToNode(value);

        using var content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await Http.PostAsync(_apiUrl, content);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException($"{method}: HTTP {(int)response.StatusCode}");

        var data = JsonNode.Parse(await response.Content.ReadAsStringAsync())!.AsObject();
        if (data["status"]?.GetValue<int>() != 1)
            throw new FiversCanException(method, data["msg"]?.GetValue<string>() ?? "unknown", data["detail"]?.GetValue<string>());
        return data;
    }

    public Task<JsonObject> ProviderListAsync() => CallAsync("provider_list");

    public Task<JsonObject> GameListAsync(string providerCode) =>
        CallAsync("game_list", new Dictionary<string, object?> { ["provider_code"] = providerCode });

    public Task<JsonObject> UserCreateAsync(string userCode) =>
        CallAsync("user_create", new Dictionary<string, object?> { ["user_code"] = userCode });

    // amount is sent as a JSON number; agentSign is an optional unique id ([A-Za-z0-9_])
    // that prevents double-charging when a request is retried
    public Task<JsonObject> UserDepositAsync(string userCode, decimal amount, string? agentSign = null) =>
        CallAsync("user_deposit", TransferParams(userCode, amount, agentSign));

    public Task<JsonObject> UserWithdrawAsync(string userCode, decimal amount, string? agentSign = null) =>
        CallAsync("user_withdraw", TransferParams(userCode, amount, agentSign));

    private static Dictionary<string, object?> TransferParams(string userCode, decimal amount, string? agentSign)
    {
        var p = new Dictionary<string, object?> { ["user_code"] = userCode, ["amount"] = amount };
        if (agentSign is not null) p["agent_sign"] = agentSign;
        return p;
    }

    // Without userCode returns the agent balance only; send all_users = true to list every user
    public Task<JsonObject> MoneyInfoAsync(string? userCode = null) =>
        CallAsync("money_info", userCode is null ? null : new Dictionary<string, object?> { ["user_code"] = userCode });

    // gameCode may be empty for live-casino providers to open the lobby; rtp is optional
    public Task<JsonObject> GameLaunchAsync(string userCode, string providerCode, string gameCode = "", string lang = "en", string lobbyUrl = "", decimal? rtp = null)
    {
        var p = new Dictionary<string, object?>
        {
            ["user_code"] = userCode,
            ["provider_code"] = providerCode,
            ["game_code"] = gameCode,
            ["lang"] = lang,
            ["lobby_url"] = lobbyUrl,
        };
        if (rtp is not null) p["rtp"] = rtp.Value;
        return CallAsync("game_launch", p);
    }
}
