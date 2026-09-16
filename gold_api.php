<?php
/**
 * NexusGGR / FiversCan API — seamless wallet endpoint (PHP 8.1+)
 * ===============================================================
 * In seamless mode the player's balance stays on YOUR site: the game server calls this endpoint
 * on every balance check and every bet/win instead of moving money through user_deposit/user_withdraw.
 *
 *   POST https://{YOUR_SITE}/gold_api          (JSON in, JSON out)
 *   You register the site base URL (https://{YOUR_SITE}) with NexusGGR and the game server appends /gold_api —
 *   no ".php" — so route that path to this file:
 *     nginx    location = /gold_api { rewrite ^ /gold_api.php last; }
 *     Apache   RewriteRule ^gold_api$ gold_api.php [L]          (.htaccess, mod_rewrite)
 *     php -S   php -S 127.0.0.1:8080 -t . router.php  with router.php:
 *              <?php if (parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) === '/gold_api') { require __DIR__.'/gold_api.php'; return true; } return false;
 *
 *   {"method":"user_balance", "agent_code", "agent_secret", "user_code", "user_token", "game_code"}
 *       -> {"status":1, "user_balance": 1000}                       (return the balance even when it is 0)
 *
 *   {"method":"transaction", "agent_code", "agent_secret", "user_code", "user_token", "game_type": "slot"|"live"|"SB"|"MN",
 *    "<game_type>": {provider_code, game_code, type, bet_money, win_money, round_id, txn_id, txn_id_v2, txn_type}}
 *       -> {"status":1, "user_balance": 800}                        after applying bet_money / win_money
 *       -> {"status":0, "msg":"INSUFFICIENT_USER_FUNDS"}            bet refused, the round is voided
 *
 *   txn_type: "debit" (bet only), "credit" (win only), "debit_credit" (both in one call).
 *   Deduplicate on txn_id_v2 — it is unique per transaction. txn_id repeats for every transaction of a bet
 *   (it is round_id as a string), so keying on it would drop the wins of a round whose bet you booked.
 *   Answer status 0 only for a definite refusal (bad auth, bad payload, insufficient funds): the game server voids
 *   the bet. If your code fails mid-way let it surface as HTTP 500 — the game server records the round as
 *   status 2 "unconfirmed" and it is reconciled later — instead of a status 0 that would silently drop a win.
 *
 * Storage: this sample keeps a tiny ledger in a flock()-guarded JSON file (outside the web root — never put it
 * where the web server can serve it) so it runs with no extensions. On a real site replace Ledger with your
 * database, keeping the same rules: one transaction per txn_id_v2, balance check and debit in one atomic step.
 *
 * Run (FVS_AGENT_SECRET is the seamless secret from your agent settings, not the agent_token; the endpoint refuses
 * to run with the placeholder):
 *   FVS_AGENT_CODE=... FVS_AGENT_SECRET=... php -S 127.0.0.1:8080 -t . router.php
 * API access: https://t.me/casino_api777  ·  https://nexusggr.games
 */

declare(strict_types=1);

const AGENT_CODE   = 'your_agent_code';     // overridden by FVS_AGENT_CODE
const AGENT_SECRET = 'your_agent_secret';   // overridden by FVS_AGENT_SECRET — the seamless secret, not the agent_token
const WALLET_FILE  = '/fvs-wallet.json';    // under sys_get_temp_dir(); overridden by WALLET_FILE. Keep it OUTSIDE the web root

header('Content-Type: application/json; charset=utf-8');

/** @return never */
function reply(array $payload, int $httpCode = 200): void
{
    http_response_code($httpCode);
    echo json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
    exit;
}

/** Minimal ledger: {"users": {"code": balance}, "txns": {"txn_id_v2": balance_after}} under an exclusive lock. */
final class Ledger
{
    /** @var resource */
    private $fh;
    private array $data;

    public function __construct(string $file)
    {
        $this->fh = fopen($file, 'c+') ?: throw new RuntimeException("cannot open $file");
        if (!flock($this->fh, LOCK_EX)) {
            throw new RuntimeException('cannot lock ledger');
        }
        $raw = stream_get_contents($this->fh);
        $this->data = ($raw !== '' && $raw !== false) ? json_decode($raw, true, 512, JSON_THROW_ON_ERROR) : [];
        $this->data += ['users' => [], 'txns' => []];
    }

    public function balance(string $user): float
    {
        return (float) ($this->data['users'][$user] ?? 0);
    }

    public function processed(string $txnIdV2): ?float
    {
        return isset($this->data['txns'][$txnIdV2]) ? (float) $this->data['txns'][$txnIdV2] : null;
    }

    /** Applies debit then credit atomically; returns the new balance, or null when funds are insufficient. */
    public function apply(string $user, string $txnIdV2, float $debit, float $credit): ?float
    {
        $balance = $this->balance($user);
        if ($balance < $debit) {
            return null;
        }
        $balance = round($balance - $debit + $credit, 2);
        $this->data['users'][$user] = $balance;
        $this->data['txns'][$txnIdV2] = $balance;
        return $balance;
    }

    public function commit(): void
    {
        rewind($this->fh);
        ftruncate($this->fh, 0);
        fwrite($this->fh, json_encode($this->data, JSON_THROW_ON_ERROR));
        fflush($this->fh);
        flock($this->fh, LOCK_UN);
        fclose($this->fh);
    }
}

try {
    $body = json_decode(file_get_contents('php://input') ?: '', true);
    if (!is_array($body)) {
        reply(['status' => 0, 'msg' => 'INVALID_JSON']);
    }

    // Authenticate the caller: agent_code + agent_secret must both match (constant-time compare).
    // Fail closed while the placeholders are still in place, otherwise anyone who read this file could credit balances.
    $agentCode = getenv('FVS_AGENT_CODE') ?: AGENT_CODE;
    $agentSecret = getenv('FVS_AGENT_SECRET') ?: AGENT_SECRET;
    if ($agentCode === 'your_agent_code' || $agentSecret === 'your_agent_secret' || $agentSecret === '') {
        error_log('gold_api.php: FVS_AGENT_CODE / FVS_AGENT_SECRET not configured');
        reply(['status' => 0, 'msg' => 'INTERNAL_ERROR'], 500);
    }
    if (!hash_equals($agentCode, (string) ($body['agent_code'] ?? '')) || !hash_equals($agentSecret, (string) ($body['agent_secret'] ?? ''))) {
        reply(['status' => 0, 'msg' => 'INVALID_AGENT']);
    }

    $user = (string) ($body['user_code'] ?? '');
    if ($user === '') {
        reply(['status' => 0, 'msg' => 'INVALID_USER']);
    }
    // user_token identifies the game session that was opened by game_launch; a real site checks it against the session it issued

    $ledger = new Ledger(getenv('WALLET_FILE') ?: sys_get_temp_dir() . WALLET_FILE);

    switch ($body['method'] ?? '') {
        case 'user_balance':
            reply(['status' => 1, 'user_balance' => $ledger->balance($user)]);

        case 'transaction':
            $gameType = (string) ($body['game_type'] ?? '');
            $txn = $body[$gameType] ?? null;   // the game object key equals game_type: slot / live / SB / MN
            if (!is_array($txn) || !isset($txn['txn_id_v2'], $txn['txn_type'])) {
                reply(['status' => 0, 'msg' => 'INVALID_PARAMETER']);
            }
            $txnIdV2 = (string) $txn['txn_id_v2'];

            // Idempotent: a retried transaction returns the balance it produced the first time and changes nothing
            if (($seen = $ledger->processed($txnIdV2)) !== null) {
                reply(['status' => 1, 'user_balance' => $seen]);
            }

            $debit  = in_array($txn['txn_type'], ['debit', 'debit_credit'], true) ? (float) ($txn['bet_money'] ?? 0) : 0.0;
            $credit = in_array($txn['txn_type'], ['credit', 'debit_credit'], true) ? (float) ($txn['win_money'] ?? 0) : 0.0;
            if ($debit < 0 || $credit < 0) {
                reply(['status' => 0, 'msg' => 'INVALID_PARAMETER']);
            }

            $balance = $ledger->apply($user, $txnIdV2, $debit, $credit);
            if ($balance === null) {
                reply(['status' => 0, 'msg' => 'INSUFFICIENT_USER_FUNDS']);
            }
            $ledger->commit();
            // Optional: persist $body['info'] (live / sportsbook result JSON) and $txn['round_id'] for your own bet history here
            reply(['status' => 1, 'user_balance' => $balance]);

        default:
            reply(['status' => 0, 'msg' => 'INVALID_METHOD']);
    }
} catch (Throwable $e) {
    // HTTP 500, not status 0: the game server then marks the round "unconfirmed" for reconciliation instead of voiding it
    error_log('gold_api.php: ' . $e->getMessage());
    reply(['status' => 0, 'msg' => 'INTERNAL_ERROR'], 500);
}
