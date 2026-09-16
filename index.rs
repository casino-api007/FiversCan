//! NexusGGR / FiversCan API — Rust integration sample (reqwest + serde_json)
//! ==========================================================================
//! Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
//! Auth      : every request body carries agent_code + agent_token
//! Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
//!             {"status": 0, "msg": "<ERROR>"}        on failure
//! Methods   : provider_list, game_list, user_create, user_deposit,
//!             game_launch, money_info, user_withdraw
//! API access: https://t.me/casino_api777  ·  https://nexusggr.games
//!
//! Cargo.toml:
//!   [dependencies]
//!   reqwest    = { version = "0.12", features = ["blocking", "json"] }
//!   serde_json = "1"
//!
//! Run (copy this file to src/main.rs):
//!   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... cargo run

use std::env;
use std::error::Error;
use std::fmt;
use std::process;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use reqwest::blocking::Client;
use serde_json::{json, Map, Value};

fn env_or(name: &str, fallback: &str) -> String {
    env::var(name).ok().filter(|v| !v.is_empty()).unwrap_or_else(|| fallback.to_string())
}

/// Returned when the API answers status != 1; `msg` is the API error code.
#[derive(Debug)]
pub struct FiversCanError {
    pub method: String,
    pub msg: String,
    pub detail: Option<String>,
}

impl fmt::Display for FiversCanError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} failed: {}", self.method, self.msg)?;
        if let Some(detail) = &self.detail {
            write!(f, " ({detail})")?;
        }
        Ok(())
    }
}

impl Error for FiversCanError {}

pub struct FiversCanClient {
    api_url: String,
    agent_code: String,
    agent_token: String,
    http: Client,
}

impl FiversCanClient {
    pub fn new(api_url: &str, agent_code: &str, agent_token: &str) -> Result<Self, Box<dyn Error>> {
        Ok(Self {
            api_url: api_url.to_string(),
            agent_code: agent_code.to_string(),
            agent_token: agent_token.to_string(),
            http: Client::builder().connect_timeout(Duration::from_secs(5)).timeout(Duration::from_secs(15)).build()?,
        })
    }

    /// Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status.
    pub fn call(&self, method: &str, params: Value) -> Result<Value, Box<dyn Error>> {
        let mut body = Map::new();
        body.insert("method".into(), json!(method));
        body.insert("agent_code".into(), json!(self.agent_code));
        body.insert("agent_token".into(), json!(self.agent_token));
        if let Value::Object(extra) = params {
            body.extend(extra);
        }

        let response = self.http.post(&self.api_url).json(&Value::Object(body)).send()?;
        if !response.status().is_success() {
            return Err(format!("{method}: HTTP {}", response.status().as_u16()).into());
        }

        let data: Value = response.json()?;
        if data["status"].as_i64() != Some(1) {
            return Err(Box::new(FiversCanError {
                method: method.to_string(),
                msg: data["msg"].as_str().unwrap_or("unknown").to_string(),
                detail: data["detail"].as_str().map(str::to_string),
            }));
        }
        Ok(data)
    }

    pub fn provider_list(&self) -> Result<Value, Box<dyn Error>> {
        self.call("provider_list", json!({}))
    }

    pub fn game_list(&self, provider_code: &str) -> Result<Value, Box<dyn Error>> {
        self.call("game_list", json!({ "provider_code": provider_code }))
    }

    pub fn user_create(&self, user_code: &str) -> Result<Value, Box<dyn Error>> {
        self.call("user_create", json!({ "user_code": user_code }))
    }

    /// `amount` is sent as a JSON number; `agent_sign` is an optional unique id ([A-Za-z0-9_])
    /// that prevents double-charging when a request is retried.
    pub fn user_deposit(&self, user_code: &str, amount: f64, agent_sign: Option<&str>) -> Result<Value, Box<dyn Error>> {
        self.call("user_deposit", Self::transfer_params(user_code, amount, agent_sign))
    }

    pub fn user_withdraw(&self, user_code: &str, amount: f64, agent_sign: Option<&str>) -> Result<Value, Box<dyn Error>> {
        self.call("user_withdraw", Self::transfer_params(user_code, amount, agent_sign))
    }

    fn transfer_params(user_code: &str, amount: f64, agent_sign: Option<&str>) -> Value {
        let mut params = json!({ "user_code": user_code, "amount": amount });
        if let Some(sign) = agent_sign {
            params["agent_sign"] = json!(sign);
        }
        params
    }

    /// Without `user_code` returns the agent balance only; send `all_users: true` to list every user.
    pub fn money_info(&self, user_code: Option<&str>) -> Result<Value, Box<dyn Error>> {
        self.call("money_info", match user_code {
            Some(code) => json!({ "user_code": code }),
            None => json!({}),
        })
    }

    /// `game_code` may be empty for live-casino providers to open the lobby; `rtp` is optional.
    pub fn game_launch(&self, user_code: &str, provider_code: &str, game_code: &str, lang: &str, lobby_url: &str, rtp: Option<f64>) -> Result<Value, Box<dyn Error>> {
        let mut params = json!({
            "user_code": user_code,
            "provider_code": provider_code,
            "game_code": game_code,
            "lang": lang,
            "lobby_url": lobby_url,
        });
        if let Some(rtp) = rtp {
            params["rtp"] = json!(rtp);
        }
        self.call("game_launch", params)
    }
}

fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

fn run() -> Result<(), Box<dyn Error>> {
    let fvs = FiversCanClient::new(
        &env_or("FVS_API_URL", "https://api.example.com"), // API server you received from NexusGGR
        &env_or("FVS_AGENT_CODE", "your_agent_code"),
        &env_or("FVS_AGENT_TOKEN", "your_agent_token"),
    )?;
    let user_code = "demo_user";

    // 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    let res = fvs.provider_list()?;
    let providers = res["providers"].as_array().ok_or("providers missing")?;
    let provider = providers.iter().find(|p| p["status"].as_i64() == Some(1)).or_else(|| providers.first()).ok_or("no providers")?;
    let provider_code = provider["code"].as_str().unwrap_or_default();
    println!("providers: {}, using {}", providers.len(), provider_code);

    // 2. Games of that provider
    let res = fvs.game_list(provider_code)?;
    let games = res["games"].as_array().ok_or("games missing")?;
    let game = games.first().ok_or("no games")?;
    let game_code = game["game_code"].as_str().unwrap_or_default();
    println!("games: {}, first: {} ({})", games.len(), game_code, game["game_name"].as_str().unwrap_or_default());

    // 3. Create the player (idempotent: an existing user is fine)
    match fvs.user_create(user_code) {
        Ok(created) => println!("user created: {} ({})", created["user_code"].as_str().unwrap_or_default(), created["fc_code"].as_str().unwrap_or_default()),
        Err(e) => match e.downcast_ref::<FiversCanError>() {
            Some(api) if api.msg.to_lowercase().contains("duplicated") => println!("user exists: {user_code}"),
            _ => return Err(e),
        },
    }

    // 4. Move funds agent -> player
    let dep = fvs.user_deposit(user_code, 100.0, Some(&format!("dep_{}", now_ms())))?;
    println!("deposit ok: agent={} user={}", dep["agent_balance"], dep["user_balance"]);

    // 5. Get the game URL to open in the player's browser / iframe
    let launch = fvs.game_launch(user_code, provider_code, game_code, "en", "https://your-site.com/lobby", None)?;
    println!("launch_url: {}", launch["launch_url"].as_str().unwrap_or_default());

    // 6. Balances
    let info = fvs.money_info(Some(user_code))?;
    println!("balance: agent={} user={}", info["agent"]["balance"], info["user"]["balance"]);

    // 7. Move funds player -> agent
    let wd = fvs.user_withdraw(user_code, 50.0, Some(&format!("wd_{}", now_ms())))?;
    println!("withdraw ok: agent={} user={}", wd["agent_balance"], wd["user_balance"]);
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        process::exit(1);
    }
}
