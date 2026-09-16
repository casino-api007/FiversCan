<?php
/**
 * NexusGGR / FiversCan API — PHP 8 integration sample (ext-curl + ext-json)
 * ==========================================================================
 * Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
 * Auth      : every request body carries agent_code + agent_token
 * Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
 *             {"status": 0, "msg": "<ERROR>"}        on failure
 * Methods   : provider_list, game_list, user_create, user_deposit,
 *             game_launch, money_info, user_withdraw
 * API access: https://t.me/casino_api777  ·  https://nexusggr.games
 *
 * Run:
 *   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... php index.php
 */

declare(strict_types=1);

const API_URL     = 'https://api.example.com'; // API server you received from NexusGGR
const AGENT_CODE  = 'your_agent_code';
const AGENT_TOKEN = 'your_agent_token';

final class FiversCanException extends RuntimeException
{
    public function __construct(public readonly string $method, public readonly string $msg, public readonly ?string $detail = null)
    {
        parent::__construct(sprintf('%s failed: %s%s', $method, $msg, $detail ? " ($detail)" : ''));
    }
}

final class FiversCanClient
{
    public function __construct(
        private readonly string $apiUrl,
        private readonly string $agentCode,
        private readonly string $agentToken,
        private readonly int $timeout = 15,
    ) {
    }

    /** Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status. */
    public function call(string $method, array $params = []): array
    {
        $body = json_encode(
            ['method' => $method, 'agent_code' => $this->agentCode, 'agent_token' => $this->agentToken] + $params,
            JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES,
        );

        $ch = curl_init($this->apiUrl);
        curl_setopt_array($ch, [
            CURLOPT_POST           => true,
            CURLOPT_POSTFIELDS     => $body,
            CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_TIMEOUT        => $this->timeout,
        ]);
        $raw = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        $curlErr = curl_error($ch);
        curl_close($ch);

        if ($raw === false) {
            throw new RuntimeException("$method: cURL error: $curlErr");
        }
        if ($httpCode !== 200) {
            throw new RuntimeException("$method: HTTP $httpCode");
        }

        $data = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
        if (($data['status'] ?? 0) !== 1) {
            throw new FiversCanException($method, (string) ($data['msg'] ?? 'unknown'), $data['detail'] ?? null);
        }
        return $data;
    }

    public function providerList(): array
    {
        return $this->call('provider_list');
    }

    public function gameList(string $providerCode): array
    {
        return $this->call('game_list', ['provider_code' => $providerCode]);
    }

    public function userCreate(string $userCode): array
    {
        return $this->call('user_create', ['user_code' => $userCode]);
    }

    // amount must be a JSON number (int|float, never a numeric string); agent_sign is an optional unique id
    // ([A-Za-z0-9_]) that prevents double-charging when a request is retried
    public function userDeposit(string $userCode, int|float $amount, ?string $agentSign = null): array
    {
        return $this->call('user_deposit', ['user_code' => $userCode, 'amount' => $amount] + ($agentSign ? ['agent_sign' => $agentSign] : []));
    }

    public function userWithdraw(string $userCode, int|float $amount, ?string $agentSign = null): array
    {
        return $this->call('user_withdraw', ['user_code' => $userCode, 'amount' => $amount] + ($agentSign ? ['agent_sign' => $agentSign] : []));
    }

    // Without user_code returns the agent balance only; with all_users => true returns every user
    public function moneyInfo(?string $userCode = null): array
    {
        return $this->call('money_info', $userCode ? ['user_code' => $userCode] : []);
    }

    // game_code may be empty for live-casino providers to open the lobby; rtp is optional
    public function gameLaunch(string $userCode, string $providerCode, string $gameCode = '', string $lang = 'en', string $lobbyUrl = '', int|float|null $rtp = null): array
    {
        $params = [
            'user_code'     => $userCode,
            'provider_code' => $providerCode,
            'game_code'     => $gameCode,
            'lang'          => $lang,
            'lobby_url'     => $lobbyUrl,
        ];
        if ($rtp !== null) {
            $params['rtp'] = $rtp;
        }
        return $this->call('game_launch', $params);
    }
}

function main(): void
{
    $fvs = new FiversCanClient(
        getenv('FVS_API_URL') ?: API_URL,
        getenv('FVS_AGENT_CODE') ?: AGENT_CODE,
        getenv('FVS_AGENT_TOKEN') ?: AGENT_TOKEN,
    );
    $userCode = 'demo_user';

    // 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    $providers = $fvs->providerList()['providers'];
    $open = array_values(array_filter($providers, fn (array $p) => $p['status'] === 1));
    $provider = $open[0] ?? $providers[0];
    printf("providers: %d, using %s\n", count($providers), $provider['code']);

    // 2. Games of that provider
    $games = $fvs->gameList($provider['code'])['games'];
    $game = $games[0];
    printf("games: %d, first: %s (%s)\n", count($games), $game['game_code'], $game['game_name']);

    // 3. Create the player (idempotent: an existing user is fine)
    try {
        $created = $fvs->userCreate($userCode);
        printf("user created: %s (%s)\n", $created['user_code'], $created['fc_code']);
    } catch (FiversCanException $e) {
        if (stripos($e->msg, 'duplicated') === false) {
            throw $e;
        }
        printf("user exists: %s\n", $userCode);
    }

    // 4. Move funds agent -> player
    $dep = $fvs->userDeposit($userCode, 100, 'dep_' . (int) (microtime(true) * 1000));
    printf("deposit ok: agent=%s user=%s\n", $dep['agent_balance'], $dep['user_balance']);

    // 5. Get the game URL to open in the player's browser / iframe
    $launch = $fvs->gameLaunch($userCode, $provider['code'], $game['game_code'], 'en', 'https://your-site.com/lobby');
    printf("launch_url: %s\n", $launch['launch_url']);

    // 6. Balances
    $info = $fvs->moneyInfo($userCode);
    printf("balance: agent=%s user=%s\n", $info['agent']['balance'], $info['user']['balance']);

    // 7. Move funds player -> agent
    $wd = $fvs->userWithdraw($userCode, 50, 'wd_' . (int) (microtime(true) * 1000));
    printf("withdraw ok: agent=%s user=%s\n", $wd['agent_balance'], $wd['user_balance']);
}

try {
    main();
} catch (Throwable $e) {
    fwrite(STDERR, $e->getMessage() . PHP_EOL);
    exit(1);
}
