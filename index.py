"""
NexusGGR / FiversCan API — Python 3 integration sample (standard library only)
==============================================================================
Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
Auth      : every request body carries agent_code + agent_token
Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
            {"status": 0, "msg": "<ERROR>"}        on failure
Methods   : provider_list, game_list, user_create, user_deposit,
            game_launch, money_info, user_withdraw
API access: https://t.me/casino_api777  ·  https://nexusggr.games

Run:
  FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... python3 index.py
"""

import json
import os
import re
import sys
import time
import urllib.request
from typing import Any, Dict, Optional

API_URL = os.environ.get("FVS_API_URL", "https://api.example.com")  # API server you received from NexusGGR
AGENT_CODE = os.environ.get("FVS_AGENT_CODE", "your_agent_code")
AGENT_TOKEN = os.environ.get("FVS_AGENT_TOKEN", "your_agent_token")


class FiversCanError(Exception):
    def __init__(self, method: str, msg: str, detail: Optional[str] = None):
        super().__init__(f"{method} failed: {msg}" + (f" ({detail})" if detail else ""))
        self.method = method
        self.msg = msg
        self.detail = detail


class FiversCanClient:
    def __init__(self, api_url: str, agent_code: str, agent_token: str, timeout: float = 15.0):
        self.api_url = api_url
        self.agent_code = agent_code
        self.agent_token = agent_token
        self.timeout = timeout

    def call(self, method: str, **params: Any) -> Dict[str, Any]:
        """Low-level call: POST {method, agent_code, agent_token, **params} and unwrap status."""
        body = {"method": method, "agent_code": self.agent_code, "agent_token": self.agent_token, **params}
        req = urllib.request.Request(
            self.api_url,
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=self.timeout) as res:
            data = json.loads(res.read().decode("utf-8"))

        if data.get("status") != 1:
            raise FiversCanError(method, data.get("msg", "unknown"), data.get("detail"))
        return data

    def provider_list(self) -> Dict[str, Any]:
        return self.call("provider_list")

    def game_list(self, provider_code: str) -> Dict[str, Any]:
        return self.call("game_list", provider_code=provider_code)

    def user_create(self, user_code: str) -> Dict[str, Any]:
        return self.call("user_create", user_code=user_code)

    # amount must be a JSON number (int/float, not str); agent_sign is an optional unique id ([A-Za-z0-9_])
    # that prevents double-charging when a request is retried
    def user_deposit(self, user_code: str, amount: float, agent_sign: Optional[str] = None) -> Dict[str, Any]:
        params: Dict[str, Any] = {"user_code": user_code, "amount": amount}
        if agent_sign:
            params["agent_sign"] = agent_sign
        return self.call("user_deposit", **params)

    def user_withdraw(self, user_code: str, amount: float, agent_sign: Optional[str] = None) -> Dict[str, Any]:
        params: Dict[str, Any] = {"user_code": user_code, "amount": amount}
        if agent_sign:
            params["agent_sign"] = agent_sign
        return self.call("user_withdraw", **params)

    # Without user_code returns the agent balance only; with all_users=True returns every user
    def money_info(self, user_code: Optional[str] = None) -> Dict[str, Any]:
        return self.call("money_info", **({"user_code": user_code} if user_code else {}))

    # game_code may be empty for live-casino providers to open the lobby; rtp is optional
    def game_launch(self, user_code: str, provider_code: str, game_code: str = "", lang: str = "en",
                    lobby_url: str = "", rtp: Optional[float] = None) -> Dict[str, Any]:
        params: Dict[str, Any] = {
            "user_code": user_code,
            "provider_code": provider_code,
            "game_code": game_code,
            "lang": lang,
            "lobby_url": lobby_url,
        }
        if rtp is not None:
            params["rtp"] = rtp
        return self.call("game_launch", **params)


def main() -> None:
    fvs = FiversCanClient(API_URL, AGENT_CODE, AGENT_TOKEN)
    user_code = "demo_user"

    # 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    providers = fvs.provider_list()["providers"]
    provider = next((p for p in providers if p["status"] == 1), providers[0])
    print(f"providers: {len(providers)}, using {provider['code']}")

    # 2. Games of that provider
    games = fvs.game_list(provider["code"])["games"]
    game = games[0]
    print(f"games: {len(games)}, first: {game['game_code']} ({game['game_name']})")

    # 3. Create the player (idempotent: an existing user is fine)
    try:
        created = fvs.user_create(user_code)
        print(f"user created: {created['user_code']} ({created['fc_code']})")
    except FiversCanError as err:
        if not re.search("duplicated", err.msg, re.IGNORECASE):
            raise
        print(f"user exists: {user_code}")

    # 4. Move funds agent -> player
    dep = fvs.user_deposit(user_code, 100, f"dep_{int(time.time() * 1000)}")
    print(f"deposit ok: agent={dep['agent_balance']} user={dep['user_balance']}")

    # 5. Get the game URL to open in the player's browser / iframe
    launch = fvs.game_launch(user_code, provider["code"], game["game_code"], lang="en", lobby_url="https://your-site.com/lobby")
    print(f"launch_url: {launch['launch_url']}")

    # 6. Balances
    info = fvs.money_info(user_code)
    print(f"balance: agent={info['agent']['balance']} user={info['user']['balance']}")

    # 7. Move funds player -> agent
    wd = fvs.user_withdraw(user_code, 50, f"wd_{int(time.time() * 1000)}")
    print(f"withdraw ok: agent={wd['agent_balance']} user={wd['user_balance']}")


if __name__ == "__main__":
    try:
        main()
    except Exception as err:  # noqa: BLE001 - sample: surface any failure and exit non-zero
        print(err, file=sys.stderr)
        sys.exit(1)
