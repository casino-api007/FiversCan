<?php
/**
 * NexusGGR / FiversCan API — reusable PHP 8.1+ client (ext-curl + ext-json)
 * ==========================================================================
 * Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
 * Auth      : every request body carries agent_code + agent_token
 * Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
 *             {"status": 0, "msg": "<ERROR>"}        on failure  -> thrown as FiversCanException
 * API access: https://t.me/casino_api777  ·  https://nexusggr.games
 *
 * Used by index.php (CLI walkthrough) and api.php (lobby backend). gold_api.php is the INBOUND seamless
 * endpoint the game server calls on your site and needs no client.
 *
 *   require __DIR__ . '/FiversCanClient.php';
 *   $fvs = new FiversCan\FiversCanClient('https://api.example.com', 'your_agent_code', 'your_agent_token');
 *   $url = $fvs->gameLaunch('player1', 'PRAGMATIC', 'vs20doghouse', 'en', 'https://your-site.com/lobby')['launch_url'];
 */

declare(strict_types=1);

namespace FiversCan;

use RuntimeException;

/** Thrown when the API answers status != 1; $msg is the API error text (e.g. "Insufficient agent funds."). */
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

    /** Build a client from FVS_API_URL / FVS_AGENT_CODE / FVS_AGENT_TOKEN environment variables. */
    public static function fromEnv(): self
    {
        return new self(
            getenv('FVS_API_URL') ?: 'https://api.example.com', // API server you received from NexusGGR
            getenv('FVS_AGENT_CODE') ?: 'your_agent_code',
            getenv('FVS_AGENT_TOKEN') ?: 'your_agent_token',
        );
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

    /** @return array{providers: list<array{code: string, name: string, status: int}>} status 1 = open, 0 = maintenance */
    public function providerList(): array
    {
        return $this->call('provider_list');
    }

    /** @return array{games: list<array{game_code: string, game_name: string, banner?: string, status?: int, bet_levels?: array}>} */
    public function gameList(string $providerCode): array
    {
        return $this->call('game_list', ['provider_code' => $providerCode]);
    }

    /** @return array{fc_code: string, user_code: string, user_balance: int|float} */
    public function userCreate(string $userCode): array
    {
        return $this->call('user_create', ['user_code' => $userCode]);
    }

    /** True when the user already exists (server msg "Duplicated User"). */
    public static function isDuplicateUser(FiversCanException $e): bool
    {
        return stripos($e->msg, 'duplicated user') !== false;
    }

    /**
     * Move funds agent -> player. A missing player is created by the server, so user_create is not required first.
     * Amount must be int|float (never a numeric string: the server validates a strict JSON number).
     *
     * $agentSign ([A-Za-z0-9_], unique per transfer) is your idempotency key. The server claims it BEFORE moving money
     * and answers a reused sign with "Duplicated Agent Sign." instead of replaying the result, so after a timeout
     * (RuntimeException — the transfer may or may not have landed) do NOT retry blindly: call transferStatus() with the
     * same sign and act on "Completed" / "Processing" / "Not found". Keep the sign with your own transaction record.
     * @return array{agent_balance: int|float, user_balance: int|float}
     */
    public function userDeposit(string $userCode, int|float $amount, ?string $agentSign = null): array
    {
        return $this->call('user_deposit', self::transferParams($userCode, $amount, $agentSign));
    }

    /** Move funds player -> agent. Same agent_sign semantics as userDeposit(). @return array{agent_balance: int|float, user_balance: int|float} */
    public function userWithdraw(string $userCode, int|float $amount, ?string $agentSign = null): array
    {
        return $this->call('user_withdraw', self::transferParams($userCode, $amount, $agentSign));
    }

    private static function transferParams(string $userCode, int|float $amount, ?string $agentSign): array
    {
        $params = ['user_code' => $userCode, 'amount' => $amount];
        if ($agentSign !== null && $agentSign !== '') {
            $params['agent_sign'] = $agentSign;
        }
        return $params;
    }

    /**
     * Outcome of an earlier deposit/withdraw identified by its agent_sign — the way to resolve a timed-out transfer.
     * Returns status 1 with msg "Completed" plus amount, agent_balance, user_balance and type ("user_deposit"|"user_withdraw");
     * throws FiversCanException with msg "Not found" (the transfer never happened — safe to send again with a NEW sign)
     * or "Processing" (claimed but not finished — check again shortly; if it stays there, treat as not applied).
     * @return array{amount: int|float, agent_balance: int|float, user_balance: int|float, type: string}
     */
    public function transferStatus(string $userCode, string $agentSign): array
    {
        return $this->call('transfer_status', ['user_code' => $userCode, 'agent_sign' => $agentSign]);
    }

    /**
     * Agent balance, plus the given user under `user` and/or every user under `user_list` (the two are independent).
     * @return array{agent: array{agent_code: string, balance: int|float}, user?: array{user_code: string, balance: int|float}, user_list?: list<array>}
     */
    public function moneyInfo(?string $userCode = null, bool $allUsers = false): array
    {
        $params = [];
        if ($userCode !== null && $userCode !== '') {
            $params['user_code'] = $userCode;
        }
        if ($allUsers) {
            $params['all_users'] = true;
        }
        return $this->call('money_info', $params);
    }

    /**
     * $gameCode may be '' for live-casino providers to open the provider lobby.
     * $lobbyUrl (return URL when the player exits) and $rtp are optional and are OMITTED when empty/null:
     * the server rejects "lobby_url": "" (Joi string, empty not allowed).
     * @return array{fc_code: string, launch_url: string, token?: string}
     */
    public function gameLaunch(string $userCode, string $providerCode, string $gameCode = '', string $lang = 'en', string $lobbyUrl = '', int|float|null $rtp = null): array
    {
        $params = [
            'user_code'     => $userCode,
            'provider_code' => $providerCode,
            'game_code'     => $gameCode,
            'lang'          => $lang,
        ];
        if ($lobbyUrl !== '') {
            $params['lobby_url'] = $lobbyUrl;
        }
        if ($rtp !== null) {
            $params['rtp'] = $rtp;
        }
        return $this->call('game_launch', $params);
    }
}
