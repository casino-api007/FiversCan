// NexusGGR / FiversCan API — Go integration sample (standard library only)
// =========================================================================
// Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
// Auth      : every request body carries agent_code + agent_token
// Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
//             {"status": 0, "msg": "<ERROR>"}        on failure
// Methods   : provider_list, game_list, user_create, user_deposit,
//             game_launch, money_info, user_withdraw
// API access: https://t.me/casino_api777  ·  https://nexusggr.games
//
// Run:
//   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... go run index.go

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// ---- Response types (fields as documented by the API) ----

type Provider struct {
	Code   string `json:"code"`
	Name   string `json:"name"`
	Status int    `json:"status"` // 1 = open, 0 = maintenance
}

type Game struct {
	GameCode  string             `json:"game_code"`
	GameName  string             `json:"game_name"`
	Banner    string             `json:"banner,omitempty"`
	Status    int                `json:"status,omitempty"`
	BetLevels map[string]float64 `json:"bet_levels,omitempty"`
}

type Balance struct {
	AgentCode string  `json:"agent_code,omitempty"`
	UserCode  string  `json:"user_code,omitempty"`
	Balance   float64 `json:"balance"`
}

// APIResponse is the union of every field the sample reads; unused fields stay zero-valued.
type APIResponse struct {
	Status       int        `json:"status"`
	Msg          string     `json:"msg"`
	Detail       string     `json:"detail,omitempty"`
	Providers    []Provider `json:"providers,omitempty"`
	Games        []Game     `json:"games,omitempty"`
	FcCode       string     `json:"fc_code,omitempty"`
	UserCode     string     `json:"user_code,omitempty"`
	AgentBalance float64    `json:"agent_balance,omitempty"`
	UserBalance  float64    `json:"user_balance,omitempty"`
	Agent        *Balance   `json:"agent,omitempty"`
	User         *Balance   `json:"user,omitempty"`
	UserList     []Balance  `json:"user_list,omitempty"`
	LaunchURL    string     `json:"launch_url,omitempty"`
	Token        string     `json:"token,omitempty"`
}

// APIError is returned when the API answers status != 1; Msg is the API error code.
type APIError struct {
	Method string
	Msg    string
	Detail string
}

func (e *APIError) Error() string {
	if e.Detail != "" {
		return fmt.Sprintf("%s failed: %s (%s)", e.Method, e.Msg, e.Detail)
	}
	return fmt.Sprintf("%s failed: %s", e.Method, e.Msg)
}

type FiversCanClient struct {
	APIURL     string
	AgentCode  string
	AgentToken string
	HTTP       *http.Client
}

func NewFiversCanClient(apiURL, agentCode, agentToken string) *FiversCanClient {
	return &FiversCanClient{APIURL: apiURL, AgentCode: agentCode, AgentToken: agentToken, HTTP: &http.Client{Timeout: 15 * time.Second}}
}

// Call is the low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status.
func (c *FiversCanClient) Call(method string, params map[string]any) (*APIResponse, error) {
	body := map[string]any{"method": method, "agent_code": c.AgentCode, "agent_token": c.AgentToken}
	for k, v := range params {
		body[k] = v
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}

	res, err := c.HTTP.Post(c.APIURL, "application/json", bytes.NewReader(payload))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", method, err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %d", method, res.StatusCode)
	}

	raw, err := io.ReadAll(res.Body)
	if err != nil {
		return nil, err
	}
	var data APIResponse
	if err := json.Unmarshal(raw, &data); err != nil {
		return nil, fmt.Errorf("%s: invalid JSON: %w", method, err)
	}
	if data.Status != 1 {
		return nil, &APIError{Method: method, Msg: data.Msg, Detail: data.Detail}
	}
	return &data, nil
}

func (c *FiversCanClient) ProviderList() (*APIResponse, error) {
	return c.Call("provider_list", nil)
}

func (c *FiversCanClient) GameList(providerCode string) (*APIResponse, error) {
	return c.Call("game_list", map[string]any{"provider_code": providerCode})
}

func (c *FiversCanClient) UserCreate(userCode string) (*APIResponse, error) {
	return c.Call("user_create", map[string]any{"user_code": userCode})
}

// amount is sent as a JSON number; agentSign is an optional unique id ([A-Za-z0-9_])
// that prevents double-charging when a request is retried
func (c *FiversCanClient) UserDeposit(userCode string, amount float64, agentSign string) (*APIResponse, error) {
	return c.Call("user_deposit", transferParams(userCode, amount, agentSign))
}

func (c *FiversCanClient) UserWithdraw(userCode string, amount float64, agentSign string) (*APIResponse, error) {
	return c.Call("user_withdraw", transferParams(userCode, amount, agentSign))
}

func transferParams(userCode string, amount float64, agentSign string) map[string]any {
	params := map[string]any{"user_code": userCode, "amount": amount}
	if agentSign != "" {
		params["agent_sign"] = agentSign
	}
	return params
}

// MoneyInfo without userCode returns the agent balance only; send all_users=true to list every user
func (c *FiversCanClient) MoneyInfo(userCode string) (*APIResponse, error) {
	params := map[string]any{}
	if userCode != "" {
		params["user_code"] = userCode
	}
	return c.Call("money_info", params)
}

type LaunchParams struct {
	UserCode     string
	ProviderCode string
	GameCode     string   // may be empty for live-casino providers to open the lobby
	Lang         string   // e.g. "en"
	LobbyURL     string   // optional: where the player lands when leaving the game
	RTP          *float64 // optional target RTP for this launch
}

// GameLaunch omits lobby_url and rtp when unset: the server rejects "lobby_url": "" (Joi string, empty not allowed).
func (c *FiversCanClient) GameLaunch(p LaunchParams) (*APIResponse, error) {
	if p.Lang == "" {
		p.Lang = "en"
	}
	params := map[string]any{
		"user_code":     p.UserCode,
		"provider_code": p.ProviderCode,
		"game_code":     p.GameCode,
		"lang":          p.Lang,
	}
	if p.LobbyURL != "" {
		params["lobby_url"] = p.LobbyURL
	}
	if p.RTP != nil {
		params["rtp"] = *p.RTP
	}
	return c.Call("game_launch", params)
}

func run() error {
	fvs := NewFiversCanClient(
		env("FVS_API_URL", "https://api.example.com"), // API server you received from NexusGGR
		env("FVS_AGENT_CODE", "your_agent_code"),
		env("FVS_AGENT_TOKEN", "your_agent_token"),
	)
	userCode := "demo_user"

	// 1. Providers available to this agent (status 1 = open, 0 = maintenance)
	res, err := fvs.ProviderList()
	if err != nil {
		return err
	}
	provider := res.Providers[0]
	for _, p := range res.Providers {
		if p.Status == 1 {
			provider = p
			break
		}
	}
	fmt.Printf("providers: %d, using %s\n", len(res.Providers), provider.Code)

	// 2. Games of that provider
	res, err = fvs.GameList(provider.Code)
	if err != nil {
		return err
	}
	game := res.Games[0]
	fmt.Printf("games: %d, first: %s (%s)\n", len(res.Games), game.GameCode, game.GameName)

	// 3. Create the player (idempotent: an existing user is fine)
	created, err := fvs.UserCreate(userCode)
	var apiErr *APIError
	switch {
	case err == nil:
		fmt.Printf("user created: %s (%s)\n", created.UserCode, created.FcCode)
	case errors.As(err, &apiErr) && strings.Contains(strings.ToLower(apiErr.Msg), "duplicated"):
		fmt.Printf("user exists: %s\n", userCode)
	default:
		return err
	}

	// 4. Move funds agent -> player
	dep, err := fvs.UserDeposit(userCode, 100, fmt.Sprintf("dep_%d", time.Now().UnixMilli()))
	if err != nil {
		return err
	}
	fmt.Printf("deposit ok: agent=%v user=%v\n", dep.AgentBalance, dep.UserBalance)

	// 5. Get the game URL to open in the player's browser / iframe
	launch, err := fvs.GameLaunch(LaunchParams{UserCode: userCode, ProviderCode: provider.Code, GameCode: game.GameCode, Lang: "en", LobbyURL: "https://your-site.com/lobby"})
	if err != nil {
		return err
	}
	fmt.Printf("launch_url: %s\n", launch.LaunchURL)

	// 6. Balances
	info, err := fvs.MoneyInfo(userCode)
	if err != nil {
		return err
	}
	fmt.Printf("balance: agent=%v user=%v\n", info.Agent.Balance, info.User.Balance)

	// 7. Move funds player -> agent
	wd, err := fvs.UserWithdraw(userCode, 50, fmt.Sprintf("wd_%d", time.Now().UnixMilli()))
	if err != nil {
		return err
	}
	fmt.Printf("withdraw ok: agent=%v user=%v\n", wd.AgentBalance, wd.UserBalance)
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
