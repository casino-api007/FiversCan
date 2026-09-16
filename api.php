<?php
/**
 * NexusGGR / FiversCan API — lobby backend for index.html (PHP 8.1+)
 * ===================================================================
 * The browser must never hold agent_token, so index.html talks to THIS file and this file talks to the
 * FiversCan API through FiversCanClient.php. Every response is JSON: {"ok": true, ...} or {"ok": false, "error": "..."}.
 *
 *   GET  api.php?action=providers                 -> { providers: [{code,name,status}] }        (cached, see CATALOG_TTL)
 *   GET  api.php?action=games&provider=PRAGMATIC  -> { games: [{game_code,game_name,banner,status}] }  (cached)
 *   GET  api.php?action=balance&user=player1      -> { agent_balance, user_balance }            (unknown user -> user_balance 0)
 *   POST api.php?action=deposit   {user, amount}  -> { agent_balance, user_balance }   transfer mode only
 *   POST api.php?action=withdraw  {user, amount}  -> { agent_balance, user_balance }   transfer mode only
 *   POST api.php?action=launch    {user, provider, game, lang} -> { launch_url }
 *
 * Players are created by the API on their first deposit or launch, so no user_create call is needed here.
 * In SEAMLESS mode the balance lives on your site (see gold_api.php): deposit/withdraw are refused by the API
 * ("Seamless agent can't use this API.") and your own cashier funds the ledger instead — only launch/games/providers apply.
 *
 * Demo simplification: the player identity comes from the request. On a real site take it from your
 * logged-in session instead and never trust a user code sent by the browser.
 *
 * Run (bind to localhost — this directory also holds the CLI walkthrough index.php, which refuses web requests):
 *   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... php -S 127.0.0.1:8080
 *   then open http://127.0.0.1:8080/index.html
 * API access: https://t.me/casino_api777  ·  https://nexusggr.games
 */

declare(strict_types=1);

require __DIR__ . '/FiversCanClient.php';

use FiversCan\FiversCanClient;
use FiversCan\FiversCanException;

/** provider_list / game_list are rate-limited to ONE call per second per agent, so never forward them per browser request. */
const CATALOG_TTL = 300;
const CACHE_DIR   = null; // null = sys_get_temp_dir(); on a real site use APCu/Redis and one cache per agent

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

/** @return never */
function respond(int $httpCode, array $payload): void
{
    http_response_code($httpCode);
    echo json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
    exit;
}

/** Player codes are restricted to what the API accepts everywhere (agent_sign shares the same alphabet). */
function userCode(array $src): string
{
    $user = (string) ($src['user'] ?? '');
    if (!preg_match('/^[A-Za-z0-9_]{1,32}$/', $user)) {
        respond(400, ['ok' => false, 'error' => 'user must be 1-32 chars of [A-Za-z0-9_]']);
    }
    return $user;
}

/** Amount must reach the API as a JSON number, never a numeric string. */
function amount(array $src): float
{
    $amount = $src['amount'] ?? null;
    if (!is_numeric($amount) || (float) $amount <= 0) {
        respond(400, ['ok' => false, 'error' => 'amount must be a number greater than 0']);
    }
    return (float) $amount;
}

/**
 * File cache for the game catalogue. Serves the cached copy while fresh, refreshes it otherwise, and falls back
 * to a stale copy when the API is unavailable or answers "Rate Limit Error" (another request refreshed a moment ago).
 */
function cached(string $key, int $ttl, callable $fetch): array
{
    $file = (CACHE_DIR ?? sys_get_temp_dir()) . '/fvs-catalog-' . hash('sha256', (getenv('FVS_AGENT_CODE') ?: 'agent') . '|' . $key) . '.json';
    $stale = is_file($file) ? json_decode((string) file_get_contents($file), true) : null;
    if (is_array($stale) && filemtime($file) > time() - $ttl) {
        return $stale;
    }
    try {
        $fresh = $fetch();
        file_put_contents($file, json_encode($fresh, JSON_THROW_ON_ERROR), LOCK_EX);
        return $fresh;
    } catch (FiversCanException | RuntimeException $e) {
        if (is_array($stale)) {
            error_log("api.php: serving stale $key: " . $e->getMessage());
            return $stale;
        }
        throw $e;
    }
}

/** Where the game sends the player back on exit: LOBBY_URL env, else this host's index.html. */
function lobbyUrl(): string
{
    if ($env = getenv('LOBBY_URL')) {
        return $env;
    }
    $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
    $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
    return "$scheme://$host/index.html";
}

/**
 * Deposit / withdraw with a stable idempotency key. If the API call times out the money may or may not have moved,
 * so instead of guessing we ask transfer_status for that sign and answer from what the API says.
 * The sign is logged before the call so an operator can always reconcile it later.
 */
function transfer(FiversCanClient $fvs, string $action, string $user, float $amount): array
{
    // In production derive the sign from YOUR transaction id so a retry of the same cashier request reuses it
    $sign = substr(($action === 'deposit' ? 'dep_' : 'wd_') . $user . '_' . bin2hex(random_bytes(6)), 0, 64);
    error_log("api.php: $action $user $amount sign=$sign");
    try {
        return $action === 'deposit' ? $fvs->userDeposit($user, $amount, $sign) : $fvs->userWithdraw($user, $amount, $sign);
    } catch (RuntimeException $timeoutOrNetwork) {
        try {
            $status = $fvs->transferStatus($user, $sign);   // "Completed": it did land — report it as success
            error_log("api.php: $sign reconciled as completed");
            return ['agent_balance' => $status['agent_balance'], 'user_balance' => $status['user_balance']];
        } catch (FiversCanException $e) {
            if (stripos($e->msg, 'not found') !== false) {
                respond(502, ['ok' => false, 'error' => 'game service unavailable, nothing was transferred']);
            }
            // "Processing": claimed but unfinished — tell the player to wait rather than sending a second transfer
            respond(202, ['ok' => false, 'error' => 'transfer pending, please refresh your balance in a moment', 'sign' => $sign]);
        } catch (RuntimeException) {
            respond(502, ['ok' => false, 'error' => 'game service unavailable, transfer outcome unknown', 'sign' => $sign]);
        }
    }
}

$fvs = FiversCanClient::fromEnv();
$action = (string) ($_GET['action'] ?? '');
$input = $_GET;
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $raw = file_get_contents('php://input') ?: '';
    $input = str_starts_with((string) ($_SERVER['CONTENT_TYPE'] ?? ''), 'application/json')
        ? (json_decode($raw, true) ?? [])
        : $_POST;
    $input = is_array($input) ? $input : [];
}

try {
    switch ($action) {
        case 'providers':
            respond(200, ['ok' => true, 'providers' => cached('providers', CATALOG_TTL, fn () => $fvs->providerList()['providers'])]);

        case 'games':
            $provider = (string) ($input['provider'] ?? '');
            if (!preg_match('/^[A-Za-z0-9_]{1,32}$/', $provider)) {
                respond(400, ['ok' => false, 'error' => 'provider is required']);
            }
            respond(200, ['ok' => true, 'games' => cached("games:$provider", CATALOG_TTL, fn () => $fvs->gameList($provider)['games'])]);

        case 'balance':
            $user = userCode($input);
            try {
                $info = $fvs->moneyInfo($user);
                respond(200, ['ok' => true, 'agent_balance' => $info['agent']['balance'], 'user_balance' => $info['user']['balance'] ?? 0]);
            } catch (FiversCanException $e) {
                if (stripos($e->msg, 'invalid user') === false) {
                    throw $e;
                }
                $info = $fvs->moneyInfo();
                respond(200, ['ok' => true, 'agent_balance' => $info['agent']['balance'], 'user_balance' => 0, 'new_user' => true]);
            }

        case 'deposit':
        case 'withdraw':
            if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
                respond(405, ['ok' => false, 'error' => 'POST required']);
            }
            $res = transfer($fvs, $action, userCode($input), amount($input));
            respond(200, ['ok' => true, 'agent_balance' => $res['agent_balance'], 'user_balance' => $res['user_balance']]);

        case 'launch':
            if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
                respond(405, ['ok' => false, 'error' => 'POST required']);
            }
            $user = userCode($input);
            $provider = (string) ($input['provider'] ?? '');
            if (!preg_match('/^[A-Za-z0-9_]{1,32}$/', $provider)) {
                respond(400, ['ok' => false, 'error' => 'provider is required']);
            }
            $game = (string) ($input['game'] ?? '');   // may be '' for live-casino providers (opens the provider lobby)
            $lang = preg_match('/^[a-z]{2}(-[a-z]{2,4})?$/i', (string) ($input['lang'] ?? '')) ? $input['lang'] : 'en';
            $url = $fvs->gameLaunch($user, $provider, $game, $lang, lobbyUrl())['launch_url'];
            if (!preg_match('~^https?://~i', $url)) {   // only ever hand the browser an http(s) URL
                error_log("api.php: unexpected launch_url $url");
                respond(502, ['ok' => false, 'error' => 'game service returned an invalid launch URL']);
            }
            respond(200, ['ok' => true, 'launch_url' => $url]);

        default:
            respond(404, ['ok' => false, 'error' => 'unknown action']);
    }
} catch (FiversCanException $e) {
    // The API refused the request: surface its own error text (e.g. "Insufficient user funds.") so the lobby can show it
    respond(400, ['ok' => false, 'error' => $e->msg, 'detail' => $e->detail, 'method' => $e->method]);
} catch (RuntimeException $e) {
    // Could not reach the API (cURL error / non-200): nothing the player did
    error_log('api.php: ' . $e->getMessage());
    respond(502, ['ok' => false, 'error' => 'game service unavailable']);
} catch (Throwable $e) {
    error_log('api.php: ' . $e->getMessage());
    respond(500, ['ok' => false, 'error' => 'internal error']);
}
