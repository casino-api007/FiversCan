<?php
/**
 * NexusGGR / FiversCan API — PHP 8.1+ integration sample (CLI walkthrough)
 * =========================================================================
 * Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
 * Auth      : every request body carries agent_code + agent_token
 * Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
 *             {"status": 0, "msg": "<ERROR>"}        on failure
 * Methods   : provider_list, game_list, user_create, user_deposit,
 *             game_launch, money_info, user_withdraw
 * API access: https://t.me/casino_api777  ·  https://nexusggr.games
 *
 * The client itself lives in FiversCanClient.php (shared with api.php and gold_api.php).
 * Run:
 *   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... php index.php
 */

declare(strict_types=1);

// CLI only: this file moves money with the operator's credentials and must never be reachable through the web server
if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit;
}

require __DIR__ . '/FiversCanClient.php';

use FiversCan\FiversCanClient;
use FiversCan\FiversCanException;

function main(): void
{
    $fvs = FiversCanClient::fromEnv();
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
        if (!FiversCanClient::isDuplicateUser($e)) {
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
