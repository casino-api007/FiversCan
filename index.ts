/**
 * NexusGGR / FiversCan API — TypeScript integration sample
 * =========================================================
 * Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
 * Auth      : every request body carries agent_code + agent_token
 * Response  : { "status": 1, "msg": "SUCCESS", ... }   on success
 *             { "status": 0, "msg": "<ERROR>" }        on failure
 * Methods   : provider_list, game_list, user_create, user_deposit,
 *             game_launch, money_info, user_withdraw
 * API access: https://t.me/casino_api777  ·  https://nexusggr.games
 *
 * Run (Node 22.6+, no build step; from Node 23.6 / 22.18 plain `node index.ts` works):
 *   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... node --experimental-strip-types index.ts
 * or: npx tsx index.ts  /  deno run --allow-net --allow-env index.ts  /  bun index.ts
 */

const API_URL: string     = process.env.FVS_API_URL     ?? "https://api.example.com"; // API server you received from NexusGGR
const AGENT_CODE: string  = process.env.FVS_AGENT_CODE  ?? "your_agent_code";
const AGENT_TOKEN: string = process.env.FVS_AGENT_TOKEN ?? "your_agent_token";

// ---- Response types (fields as documented by the API) ----
interface ApiBase { status: 0 | 1; msg: string; detail?: string }
interface Provider { code: string; name: string; status: 0 | 1 }
interface Game { game_code: string; game_name: string; banner?: string; status?: 0 | 1; bet_levels?: Record<string, number> }
interface ProviderListRes extends ApiBase { providers: Provider[] }
interface GameListRes extends ApiBase { games: Game[] }
interface UserCreateRes extends ApiBase { fc_code: string; user_code: string; user_balance: number }
interface TransferRes extends ApiBase { agent_balance: number; user_balance: number }
interface MoneyInfoRes extends ApiBase { agent: { agent_code: string; balance: number }; user?: { user_code: string; balance: number }; user_list?: { user_code: string; balance: number }[] }
interface GameLaunchRes extends ApiBase { fc_code: string; launch_url: string; token?: string }

interface GameLaunchParams { userCode: string; providerCode: string; gameCode?: string; lang?: string; lobbyUrl?: string; rtp?: number }

class FiversCanError extends Error {
    method: string;
    msg: string;
    detail?: string;

    constructor(method: string, msg: string, detail?: string) {
        super(`${method} failed: ${msg}${detail ? ` (${detail})` : ""}`);
        this.method = method;
        this.msg = msg;
        this.detail = detail;
    }
}

class FiversCanClient {
    private apiUrl: string;
    private agentCode: string;
    private agentToken: string;

    constructor(apiUrl: string, agentCode: string, agentToken: string) {
        this.apiUrl = apiUrl;
        this.agentCode = agentCode;
        this.agentToken = agentToken;
    }

    /** Low-level call: POST { method, agent_code, agent_token, ...params } and unwrap status. */
    async call<T extends ApiBase>(method: string, params: Record<string, unknown> = {}): Promise<T> {
        const res = await fetch(this.apiUrl, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ method, agent_code: this.agentCode, agent_token: this.agentToken, ...params }),
            signal: AbortSignal.timeout(15_000),
        });
        if (!res.ok) throw new Error(`${method}: HTTP ${res.status}`);

        const data = (await res.json()) as T;
        if (data.status !== 1) throw new FiversCanError(method, data.msg, data.detail);
        return data;
    }

    providerList() {
        return this.call<ProviderListRes>("provider_list");
    }

    gameList(providerCode: string) {
        return this.call<GameListRes>("game_list", { provider_code: providerCode });
    }

    userCreate(userCode: string) {
        return this.call<UserCreateRes>("user_create", { user_code: userCode });
    }

    // amount must be a JSON number; agent_sign is an optional unique id ([A-Za-z0-9_]) that prevents double-charging on retries
    userDeposit(userCode: string, amount: number, agentSign?: string) {
        return this.call<TransferRes>("user_deposit", { user_code: userCode, amount, ...(agentSign && { agent_sign: agentSign }) });
    }

    userWithdraw(userCode: string, amount: number, agentSign?: string) {
        return this.call<TransferRes>("user_withdraw", { user_code: userCode, amount, ...(agentSign && { agent_sign: agentSign }) });
    }

    // Without user_code returns the agent balance only; with all_users: true returns every user
    moneyInfo(userCode?: string) {
        return this.call<MoneyInfoRes>("money_info", userCode ? { user_code: userCode } : {});
    }

    // game_code may be empty for live-casino providers to open the lobby.
    // lobby_url and rtp are optional and must be OMITTED when unset: the server rejects "lobby_url": "" (Joi string, empty not allowed)
    gameLaunch({ userCode, providerCode, gameCode = "", lang = "en", lobbyUrl, rtp }: GameLaunchParams) {
        return this.call<GameLaunchRes>("game_launch", {
            user_code: userCode,
            provider_code: providerCode,
            game_code: gameCode,
            lang,
            ...(lobbyUrl && { lobby_url: lobbyUrl }),
            ...(rtp != null && { rtp }),
        });
    }
}

async function main(): Promise<void> {
    const fvs = new FiversCanClient(API_URL, AGENT_CODE, AGENT_TOKEN);
    const userCode = "demo_user";

    // 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    const { providers } = await fvs.providerList();
    const provider = providers.find((p) => p.status === 1) ?? providers[0];
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
    console.log(`balance: agent=${info.agent.balance} user=${info.user?.balance}`);

    // 7. Move funds player -> agent
    const wd = await fvs.userWithdraw(userCode, 50, `wd_${Date.now()}`);
    console.log(`withdraw ok: agent=${wd.agent_balance} user=${wd.user_balance}`);
}

main().catch((err: Error) => {
    console.error(err.message);
    process.exit(1);
});
