/*
 * NexusGGR / FiversCan API — C11 integration sample (libcurl + cJSON)
 * ====================================================================
 * Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
 * Auth      : every request body carries agent_code + agent_token
 * Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
 *             {"status": 0, "msg": "<ERROR>"}        on failure
 * Methods   : provider_list, game_list, user_create, user_deposit,
 *             game_launch, money_info, user_withdraw
 * API access: https://t.me/casino_api777  ·  https://nexusggr.games
 *
 * Dependencies: libcurl (apt install libcurl4-openssl-dev), cJSON (apt install libcjson-dev)
 * Build & run:
 *   gcc -std=c11 -O2 index.c -lcurl -lcjson -o fvs
 *   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... ./fvs
 */

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <curl/curl.h>
#include <cjson/cJSON.h>

typedef struct {
    const char *api_url;
    const char *agent_code;
    const char *agent_token;
} fvs_client;

/* Set when fvs_call returns NULL: fvs_last_error is the printable message, fvs_last_msg the API error
 * code when the API answered status != 1 (empty for transport errors) */
static char fvs_last_error[512];
static char fvs_last_msg[256];

static const char *env_or(const char *name, const char *fallback) {
    const char *v = getenv(name);
    return (v && *v) ? v : fallback;
}

typedef struct {
    char *data;
    size_t len;
} buffer;

static size_t on_write(char *ptr, size_t size, size_t nmemb, void *userdata) {
    buffer *buf = (buffer *)userdata;
    size_t n = size * nmemb;
    char *grown = realloc(buf->data, buf->len + n + 1);
    if (!grown) return 0;
    buf->data = grown;
    memcpy(buf->data + buf->len, ptr, n);
    buf->len += n;
    buf->data[buf->len] = '\0';
    return n;
}

/*
 * Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status.
 * Takes ownership of `params` (may be NULL). Returns the parsed response (caller frees with cJSON_Delete)
 * or NULL with fvs_last_error / fvs_last_msg set.
 */
static cJSON *fvs_call(const fvs_client *c, const char *method, cJSON *params) {
    cJSON *body = params ? params : cJSON_CreateObject();
    cJSON_AddStringToObject(body, "method", method);
    cJSON_AddStringToObject(body, "agent_code", c->agent_code);
    cJSON_AddStringToObject(body, "agent_token", c->agent_token);
    char *payload = cJSON_PrintUnformatted(body);
    cJSON_Delete(body);
    fvs_last_error[0] = fvs_last_msg[0] = '\0';

    buffer res = {NULL, 0};
    cJSON *data = NULL;
    CURL *curl = curl_easy_init();
    if (!curl) { snprintf(fvs_last_error, sizeof fvs_last_error, "%s: curl_easy_init failed", method); free(payload); return NULL; }

    struct curl_slist *headers = curl_slist_append(NULL, "Content-Type: application/json");
    curl_easy_setopt(curl, CURLOPT_URL, c->api_url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 15L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, on_write);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &res);

    CURLcode rc = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

    if (rc != CURLE_OK) {
        snprintf(fvs_last_error, sizeof fvs_last_error, "%s: %s", method, curl_easy_strerror(rc));
    } else if (http_code != 200) {
        snprintf(fvs_last_error, sizeof fvs_last_error, "%s: HTTP %ld", method, http_code);
    } else if (!(data = cJSON_Parse(res.data ? res.data : ""))) {
        snprintf(fvs_last_error, sizeof fvs_last_error, "%s: invalid JSON response", method);
    } else if (cJSON_GetNumberValue(cJSON_GetObjectItem(data, "status")) != 1) {
        const char *msg = cJSON_GetStringValue(cJSON_GetObjectItem(data, "msg"));
        const char *detail = cJSON_GetStringValue(cJSON_GetObjectItem(data, "detail"));
        snprintf(fvs_last_msg, sizeof fvs_last_msg, "%s", msg ? msg : "unknown");
        snprintf(fvs_last_error, sizeof fvs_last_error, "%s failed: %s%s%s%s", method, fvs_last_msg, detail ? " (" : "", detail ? detail : "", detail ? ")" : "");
        cJSON_Delete(data);
        data = NULL;
    }

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    free(res.data);
    free(payload);
    return data;
}

static cJSON *fvs_provider_list(const fvs_client *c) {
    return fvs_call(c, "provider_list", NULL);
}

static cJSON *fvs_game_list(const fvs_client *c, const char *provider_code) {
    cJSON *p = cJSON_CreateObject();
    cJSON_AddStringToObject(p, "provider_code", provider_code);
    return fvs_call(c, "game_list", p);
}

static cJSON *fvs_user_create(const fvs_client *c, const char *user_code) {
    cJSON *p = cJSON_CreateObject();
    cJSON_AddStringToObject(p, "user_code", user_code);
    return fvs_call(c, "user_create", p);
}

/* amount is sent as a JSON number; agent_sign is an optional unique id ([A-Za-z0-9_], NULL to omit)
 * that prevents double-charging when a request is retried */
static cJSON *transfer_params(const char *user_code, double amount, const char *agent_sign) {
    cJSON *p = cJSON_CreateObject();
    cJSON_AddStringToObject(p, "user_code", user_code);
    cJSON_AddNumberToObject(p, "amount", amount);
    if (agent_sign) cJSON_AddStringToObject(p, "agent_sign", agent_sign);
    return p;
}

static cJSON *fvs_user_deposit(const fvs_client *c, const char *user_code, double amount, const char *agent_sign) {
    return fvs_call(c, "user_deposit", transfer_params(user_code, amount, agent_sign));
}

static cJSON *fvs_user_withdraw(const fvs_client *c, const char *user_code, double amount, const char *agent_sign) {
    return fvs_call(c, "user_withdraw", transfer_params(user_code, amount, agent_sign));
}

/* user_code NULL returns the agent balance only; add "all_users": true to list every user */
static cJSON *fvs_money_info(const fvs_client *c, const char *user_code) {
    cJSON *p = cJSON_CreateObject();
    if (user_code) cJSON_AddStringToObject(p, "user_code", user_code);
    return fvs_call(c, "money_info", p);
}

/* game_code may be "" for live-casino providers to open the lobby; rtp <= 0 omits the optional target RTP */
static cJSON *fvs_game_launch(const fvs_client *c, const char *user_code, const char *provider_code, const char *game_code,
                              const char *lang, const char *lobby_url, double rtp) {
    cJSON *p = cJSON_CreateObject();
    cJSON_AddStringToObject(p, "user_code", user_code);
    cJSON_AddStringToObject(p, "provider_code", provider_code);
    cJSON_AddStringToObject(p, "game_code", game_code ? game_code : "");
    cJSON_AddStringToObject(p, "lang", lang ? lang : "en");
    cJSON_AddStringToObject(p, "lobby_url", lobby_url ? lobby_url : "");
    if (rtp > 0) cJSON_AddNumberToObject(p, "rtp", rtp);
    return fvs_call(c, "game_launch", p);
}

static const char *str_of(const cJSON *obj, const char *key) {
    const char *s = cJSON_GetStringValue(cJSON_GetObjectItem(obj, key));
    return s ? s : "";
}

static double num_of(const cJSON *obj, const char *key) {
    return cJSON_GetNumberValue(cJSON_GetObjectItem(obj, key));
}

/* Wall-clock milliseconds for unique agent_sign values (C11 timespec_get) */
static long long now_millis(void) {
    struct timespec ts;
    if (timespec_get(&ts, TIME_UTC) != TIME_UTC) return (long long)time(NULL) * 1000;
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int contains_ignore_case(const char *haystack, const char *needle) {
    size_t n = strlen(needle);
    for (; *haystack; haystack++) {
        size_t i = 0;
        while (i < n && haystack[i] && tolower((unsigned char)haystack[i]) == tolower((unsigned char)needle[i])) i++;
        if (i == n) return 1;
    }
    return 0;
}

int main(void) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    fvs_client fvs = {
        env_or("FVS_API_URL", "https://api.example.com"), /* API server you received from NexusGGR */
        env_or("FVS_AGENT_CODE", "your_agent_code"),
        env_or("FVS_AGENT_TOKEN", "your_agent_token"),
    };
    const char *user_code = "demo_user";
    char provider_code[64] = "", game_code[64] = "", sign[64];
    int rc = 1;
    cJSON *res = NULL;

    /* 1. Providers available to this agent (status 1 = open, 0 = maintenance) */
    if (!(res = fvs_provider_list(&fvs))) goto done;
    cJSON *providers = cJSON_GetObjectItem(res, "providers");
    cJSON *provider = cJSON_GetArrayItem(providers, 0), *p;
    cJSON_ArrayForEach(p, providers) {
        if (num_of(p, "status") == 1) { provider = p; break; }
    }
    if (!provider) { snprintf(fvs_last_error, sizeof fvs_last_error, "no providers"); goto done; }
    snprintf(provider_code, sizeof provider_code, "%s", str_of(provider, "code"));
    printf("providers: %d, using %s\n", cJSON_GetArraySize(providers), provider_code);
    cJSON_Delete(res);

    /* 2. Games of that provider */
    if (!(res = fvs_game_list(&fvs, provider_code))) goto done;
    cJSON *games = cJSON_GetObjectItem(res, "games");
    cJSON *game = cJSON_GetArrayItem(games, 0);
    if (!game) { snprintf(fvs_last_error, sizeof fvs_last_error, "no games"); goto done; }
    snprintf(game_code, sizeof game_code, "%s", str_of(game, "game_code"));
    printf("games: %d, first: %s (%s)\n", cJSON_GetArraySize(games), game_code, str_of(game, "game_name"));
    cJSON_Delete(res);

    /* 3. Create the player (idempotent: an existing user is fine) */
    if ((res = fvs_user_create(&fvs, user_code))) {
        printf("user created: %s (%s)\n", str_of(res, "user_code"), str_of(res, "fc_code"));
        cJSON_Delete(res);
    } else if (contains_ignore_case(fvs_last_msg, "duplicated")) {
        printf("user exists: %s\n", user_code);
    } else {
        goto done;
    }

    /* 4. Move funds agent -> player */
    snprintf(sign, sizeof sign, "dep_%lld", now_millis());
    if (!(res = fvs_user_deposit(&fvs, user_code, 100, sign))) goto done;
    printf("deposit ok: agent=%g user=%g\n", num_of(res, "agent_balance"), num_of(res, "user_balance"));
    cJSON_Delete(res);

    /* 5. Get the game URL to open in the player's browser / iframe */
    if (!(res = fvs_game_launch(&fvs, user_code, provider_code, game_code, "en", "https://your-site.com/lobby", 0))) goto done;
    printf("launch_url: %s\n", str_of(res, "launch_url"));
    cJSON_Delete(res);

    /* 6. Balances */
    if (!(res = fvs_money_info(&fvs, user_code))) goto done;
    printf("balance: agent=%g user=%g\n", num_of(cJSON_GetObjectItem(res, "agent"), "balance"), num_of(cJSON_GetObjectItem(res, "user"), "balance"));
    cJSON_Delete(res);

    /* 7. Move funds player -> agent */
    snprintf(sign, sizeof sign, "wd_%lld", now_millis());
    if (!(res = fvs_user_withdraw(&fvs, user_code, 50, sign))) goto done;
    printf("withdraw ok: agent=%g user=%g\n", num_of(res, "agent_balance"), num_of(res, "user_balance"));
    rc = 0;

done:
    if (rc) fprintf(stderr, "%s\n", fvs_last_error);
    cJSON_Delete(res);
    curl_global_cleanup();
    return rc;
}
