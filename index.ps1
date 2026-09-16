<#
NexusGGR / FiversCan API — PowerShell 7 integration sample (Invoke-RestMethod, no modules)
==========================================================================================
Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
Auth      : every request body carries agent_code + agent_token
Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
            {"status": 0, "msg": "<ERROR>"}        on failure
Methods   : provider_list, game_list, user_create, user_deposit,
            game_launch, money_info, user_withdraw
API access: https://t.me/casino_api777  ·  https://nexusggr.games

Run:
  $env:FVS_API_URL='https://api.example.com'; $env:FVS_AGENT_CODE='...'; $env:FVS_AGENT_TOKEN='...'
  pwsh ./index.ps1
#>

#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvOrDefault([string]$Name, [string]$Fallback) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($value)) { $Fallback } else { $value }
}

$script:ApiUrl     = Get-EnvOrDefault 'FVS_API_URL'     'https://api.example.com'   # API server you received from NexusGGR
$script:AgentCode  = Get-EnvOrDefault 'FVS_AGENT_CODE'  'your_agent_code'
$script:AgentToken = Get-EnvOrDefault 'FVS_AGENT_TOKEN' 'your_agent_token'

# Thrown when the API answers status != 1; Msg is the API error code.
class FiversCanException : System.Exception {
    [string]$Method
    [string]$Msg
    [string]$Detail

    FiversCanException([string]$method, [string]$msg, [string]$detail)
        : base("$method failed: $msg" + $(if ($detail) { " ($detail)" } else { '' })) {
        $this.Method = $method
        $this.Msg = $msg
        $this.Detail = $detail
    }
}

# Low-level call: POST {method, agent_code, agent_token, ...Params} and unwrap status.
function Invoke-FvsApi {
    param(
        [Parameter(Mandatory)] [string]$Method,
        [hashtable]$Params = @{}
    )
    $body = @{ method = $Method; agent_code = $script:AgentCode; agent_token = $script:AgentToken } + $Params

    $data = Invoke-RestMethod -Uri $script:ApiUrl -Method Post -ContentType 'application/json' `
        -Body ($body | ConvertTo-Json -Compress) -TimeoutSec 15

    if ($data.status -ne 1) {
        $detail = if ($data.PSObject.Properties['detail']) { $data.detail } else { $null }
        throw [FiversCanException]::new($Method, "$($data.msg)", $detail)
    }
    return $data
}

function Get-FvsProviderList { Invoke-FvsApi -Method 'provider_list' }

function Get-FvsGameList([string]$ProviderCode) { Invoke-FvsApi -Method 'game_list' -Params @{ provider_code = $ProviderCode } }

function New-FvsUser([string]$UserCode) { Invoke-FvsApi -Method 'user_create' -Params @{ user_code = $UserCode } }

# Amount must be numeric so ConvertTo-Json emits a JSON number; AgentSign is an optional unique id
# ([A-Za-z0-9_]) that prevents double-charging when a request is retried
function Add-FvsUserDeposit([string]$UserCode, [decimal]$Amount, [string]$AgentSign) {
    $p = @{ user_code = $UserCode; amount = $Amount }
    if ($AgentSign) { $p.agent_sign = $AgentSign }
    Invoke-FvsApi -Method 'user_deposit' -Params $p
}

function Add-FvsUserWithdraw([string]$UserCode, [decimal]$Amount, [string]$AgentSign) {
    $p = @{ user_code = $UserCode; amount = $Amount }
    if ($AgentSign) { $p.agent_sign = $AgentSign }
    Invoke-FvsApi -Method 'user_withdraw' -Params $p
}

# Without UserCode returns the agent balance only; pass @{ all_users = $true } to list every user
function Get-FvsMoneyInfo([string]$UserCode) {
    Invoke-FvsApi -Method 'money_info' -Params $(if ($UserCode) { @{ user_code = $UserCode } } else { @{} })
}

# GameCode may be empty for live-casino providers to open the lobby; Rtp is optional
function Get-FvsGameLaunch {
    param(
        [Parameter(Mandatory)] [string]$UserCode,
        [Parameter(Mandatory)] [string]$ProviderCode,
        [string]$GameCode = '',
        [string]$Lang = 'en',
        [string]$LobbyUrl = '',
        [Nullable[decimal]]$Rtp = $null
    )
    $p = @{ user_code = $UserCode; provider_code = $ProviderCode; game_code = $GameCode; lang = $Lang; lobby_url = $LobbyUrl }
    if ($null -ne $Rtp) { $p.rtp = $Rtp }
    Invoke-FvsApi -Method 'game_launch' -Params $p
}

function Get-UnixMillis { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

try {
    $userCode = 'demo_user'

    # 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    $providers = @((Get-FvsProviderList).providers)
    $open = @($providers | Where-Object { $_.status -eq 1 })
    $provider = if ($open.Count -gt 0) { $open[0] } else { $providers[0] }
    Write-Host "providers: $($providers.Count), using $($provider.code)"

    # 2. Games of that provider
    $games = @((Get-FvsGameList -ProviderCode $provider.code).games)
    $game = $games[0]
    Write-Host "games: $($games.Count), first: $($game.game_code) ($($game.game_name))"

    # 3. Create the player (idempotent: an existing user is fine)
    try {
        $created = New-FvsUser -UserCode $userCode
        Write-Host "user created: $($created.user_code) ($($created.fc_code))"
    }
    catch [FiversCanException] {
        if ($_.Exception.Msg -notmatch 'duplicated') { throw }
        Write-Host "user exists: $userCode"
    }

    # 4. Move funds agent -> player
    $dep = Add-FvsUserDeposit -UserCode $userCode -Amount 100 -AgentSign "dep_$(Get-UnixMillis)"
    Write-Host "deposit ok: agent=$($dep.agent_balance) user=$($dep.user_balance)"

    # 5. Get the game URL to open in the player's browser / iframe
    $launch = Get-FvsGameLaunch -UserCode $userCode -ProviderCode $provider.code -GameCode $game.game_code -Lang 'en' -LobbyUrl 'https://your-site.com/lobby'
    Write-Host "launch_url: $($launch.launch_url)"

    # 6. Balances
    $info = Get-FvsMoneyInfo -UserCode $userCode
    Write-Host "balance: agent=$($info.agent.balance) user=$($info.user.balance)"

    # 7. Move funds player -> agent
    $wd = Add-FvsUserWithdraw -UserCode $userCode -Amount 50 -AgentSign "wd_$(Get-UnixMillis)"
    Write-Host "withdraw ok: agent=$($wd.agent_balance) user=$($wd.user_balance)"
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
