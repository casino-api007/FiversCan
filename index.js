/**
 * NexusGGR / FiversCan API — JavaScript (Node.js 18+) integration sample
 * ======================================================================
 * Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
 * Auth      : every request body carries agent_code + agent_token
 * Response  : { "status": 1, "msg": "SUCCESS", ... }   on success
 *             { "status": 0, "msg": "<ERROR>" }        on failure
 * Methods   : provider_list, game_list, user_create, user_deposit,
 *             game_launch, money_info, user_withdraw
 * API access: https://t.me/casino_api777  ·  https://nexusggr.games
 *
 * Run:
 *   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... node index.js
 */

const API_URL     = process.env.FVS_API_URL     || "https://api.example.com"; // API server you received from NexusGGR
const AGENT_CODE  = process.env.FVS_AGENT_CODE  || "your_agent_code";
const AGENT_TOKEN = process.env.FVS_AGENT_TOKEN || "your_agent_token";

class FiversCanError extends Error {
    constructor(method, msg, detail) {
        super(`${method} failed: ${msg}${detail ? ` (${detail})` : ""}`);
        this.method = method;
        this.msg = msg;
        this.detail = detail;
    }
}

class FiversCanClient {
    constructor({ apiUrl, agentCode, agentToken }) {
        this.apiUrl = apiUrl;
        this.agentCode = agentCode;
        this.agentToken = agentToken;
    }

    /** Low-level call: POST { method, agent_code, agent_token, ...params } and unwrap status. */
    async call(method, params = {}) {
        const res = await fetch(this.apiUrl, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ method, agent_code: this.agentCode, agent_token: this.agentToken, ...params }),
            signal: AbortSignal.timeout(15_000),
        });
        if (!res.ok) throw new Error(`${method}: HTTP ${res.status}`);

        const data = await res.json();
        if (data.status !== 1) throw new FiversCanError(method, data.msg, data.detail);
        return data;
    }

    providerList() {
        return this.call("provider_list");
    }

    gameList(providerCode) {
        return this.call("game_list", { provider_code: providerCode });
    }

    userCreate(userCode) {
        return this.call("user_create", { user_code: userCode });
    }

    // amount must be a JSON number (not a string); agent_sign is an optional unique id ([A-Za-z0-9_]) that prevents double-charging on retries
    userDeposit(userCode, amount, agentSign) {
        return this.call("user_deposit", { user_code: userCode, amount, ...(agentSign && { agent_sign: agentSign }) });
    }

    userWithdraw(userCode, amount, agentSign) {
        return this.call("user_withdraw", { user_code: userCode, amount, ...(agentSign && { agent_sign: agentSign }) });
    }

    // Without user_code returns the agent balance only; with all_users: true returns every user
    moneyInfo(userCode) {
        return this.call("money_info", userCode ? { user_code: userCode } : {});
    }

    // game_code may be empty for live-casino providers to open the lobby.
    // lobby_url and rtp are optional and must be OMITTED when unset: the server rejects "lobby_url": "" (Joi string, empty not allowed)
    gameLaunch({ userCode, providerCode, gameCode = "", lang = "en", lobbyUrl, rtp }) {
        return this.call("game_launch", {
            user_code: userCode,
            provider_code: providerCode,
            game_code: gameCode,
            lang,
            ...(lobbyUrl && { lobby_url: lobbyUrl }),
            ...(rtp != null && { rtp }),
        });
    }
}

async function main() {
    const fvs = new FiversCanClient({ apiUrl: API_URL, agentCode: AGENT_CODE, agentToken: AGENT_TOKEN });
    const userCode = "demo_user";

    // 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    const { providers } = await fvs.providerList();
    const provider = providers.find((p) => p.status === 1) || providers[0];
    console.log(`providers: ${providers.length}, using ${provider.code}`);

    // 2. Games of that provider
    const { games } = await fvs.gameList(provider.code);
    const game = games[0];
    console.log(`games: ${games.length}, first: ${game.game_code} (${game.game_name})`);

    // 3. Create the player (idempotent: an existing user is fine)
    try {
        const created = await fvs.userCreate(userCode);
        console.log(`user created: ${created.user_code} (${created.fc_code})`);
    } catch (err) {
        if (!(err instanceof FiversCanError && /duplicated/i.test(err.msg))) throw err;
        console.log(`user exists: ${userCode}`);
    }

    // 4. Move funds agent -> player
    const dep = await fvs.userDeposit(userCode, 100, `dep_${Date.now()}`);
    console.log(`deposit ok: agent=${dep.agent_balance} user=${dep.user_balance}`);

    // 5. Get the game URL to open in the player's browser / iframe
    const launch = await fvs.gameLaunch({ userCode, providerCode: provider.code, gameCode: game.game_code, lang: "en", lobbyUrl: "https://your-site.com/lobby" });
    console.log(`launch_url: ${launch.launch_url}`);

    // 6. Balances
    const info = await fvs.moneyInfo(userCode);
    console.log(`balance: agent=${info.agent.balance} user=${info.user.balance}`);

    // 7. Move funds player -> agent
    const wd = await fvs.userWithdraw(userCode, 50, `wd_${Date.now()}`);
    console.log(`withdraw ok: agent=${wd.agent_balance} user=${wd.user_balance}`);
}

main().catch((err) => {
    console.error(err.message);
    process.exit(1);
});
