{- |
NexusGGR / FiversCan API — Haskell integration sample (http-conduit + aeson)
============================================================================
Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
Auth      : every request body carries agent_code + agent_token
Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
            {"status": 0, "msg": "<ERROR>"}        on failure
Methods   : provider_list, game_list, user_create, user_deposit,
            game_launch, money_info, user_withdraw
API access: https://t.me/casino_api777  ·  https://nexusggr.games

Dependencies: aeson, http-conduit, http-client, scientific, text, vector, time
Run:
  cabal install --lib aeson http-conduit http-client scientific text vector time   (or a stack script header)
  FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... runghc index.hs
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Applicative ((<|>))
import Control.Exception (Exception, throwIO, try)
import Control.Monad (unless)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.Key as Key
import Data.Aeson.KeyMap (KeyMap)
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Scientific (FPFormat (Fixed), Scientific, formatScientific)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import qualified Data.Vector as V
import Network.HTTP.Client (responseTimeoutMicro)
import Network.HTTP.Simple
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

envOr :: String -> String -> IO String
envOr name fallback = do
  v <- lookupEnv name
  pure $ case v of
    Just s | not (null s) -> s
    _ -> fallback

-- | Thrown when the API answers status /= 1; 'fvsMsg' is the API error code.
data FiversCanError = FiversCanError
  { fvsMethod :: T.Text
  , fvsMsg :: T.Text
  , fvsDetail :: Maybe T.Text
  }
  deriving (Show)

instance Exception FiversCanError

describeError :: FiversCanError -> String
describeError (FiversCanError m s d) = T.unpack $ m <> " failed: " <> s <> maybe "" (\x -> " (" <> x <> ")") d

data Client = Client
  { apiUrl :: String
  , agentCode :: T.Text
  , agentToken :: T.Text
  }

-- | Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status.
call :: Client -> T.Text -> [(T.Text, Value)] -> IO (KeyMap Value)
call client method params = do
  let body = object $ ["method" .= method, "agent_code" .= agentCode client, "agent_token" .= agentToken client] ++ [Key.fromText k .= v | (k, v) <- params]
  request <- setRequestMethod "POST" . setRequestBodyJSON body . setRequestResponseTimeout (responseTimeoutMicro (15 * 1000000)) <$> parseRequest (apiUrl client)
  response <- httpJSON request :: IO (Response Value)
  let status = getResponseStatusCode response
  unless (status == 200) $ fail (T.unpack method ++ ": HTTP " ++ show status)

  case getResponseBody response of
    Object o
      | KM.lookup "status" o == Just (Number 1) -> pure o
      | otherwise -> throwIO $ FiversCanError method (fromMaybe "unknown" (str "msg" o)) (str "detail" o)
    _ -> fail (T.unpack method ++ ": invalid JSON response")

-- ---- Field helpers over aeson's generic Value ----

str :: T.Text -> KeyMap Value -> Maybe T.Text
str k o = case KM.lookup (Key.fromText k) o of
  Just (String s) -> Just s
  _ -> Nothing

num :: T.Text -> KeyMap Value -> Maybe Scientific
num k o = case KM.lookup (Key.fromText k) o of
  Just (Number n) -> Just n
  _ -> Nothing

obj :: T.Text -> KeyMap Value -> Maybe (KeyMap Value)
obj k o = case KM.lookup (Key.fromText k) o of
  Just (Object x) -> Just x
  _ -> Nothing

arr :: T.Text -> KeyMap Value -> [KeyMap Value]
arr k o = case KM.lookup (Key.fromText k) o of
  Just (Array xs) -> [x | Object x <- V.toList xs]
  _ -> []

showNum :: Maybe Scientific -> String
showNum = maybe "?" (formatScientific Fixed Nothing)

-- ---- API methods ----

providerList :: Client -> IO (KeyMap Value)
providerList c = call c "provider_list" []

gameList :: Client -> T.Text -> IO (KeyMap Value)
gameList c providerCode = call c "game_list" [("provider_code", String providerCode)]

userCreate :: Client -> T.Text -> IO (KeyMap Value)
userCreate c userCode = call c "user_create" [("user_code", String userCode)]

-- | amount is sent as a JSON number; agentSign is an optional unique id ([A-Za-z0-9_])
-- that prevents double-charging when a request is retried.
userDeposit :: Client -> T.Text -> Double -> Maybe T.Text -> IO (KeyMap Value)
userDeposit c userCode amount agentSign = call c "user_deposit" (transferParams userCode amount agentSign)

userWithdraw :: Client -> T.Text -> Double -> Maybe T.Text -> IO (KeyMap Value)
userWithdraw c userCode amount agentSign = call c "user_withdraw" (transferParams userCode amount agentSign)

transferParams :: T.Text -> Double -> Maybe T.Text -> [(T.Text, Value)]
transferParams userCode amount agentSign =
  [("user_code", String userCode), ("amount", Number (realToFrac amount))] ++ maybe [] (\s -> [("agent_sign", String s)]) agentSign

-- | Without a user code returns the agent balance only; send ("all_users", Bool True) to list every user.
moneyInfo :: Client -> Maybe T.Text -> IO (KeyMap Value)
moneyInfo c userCode = call c "money_info" (maybe [] (\u -> [("user_code", String u)]) userCode)

-- | gameCode may be empty for live-casino providers to open the lobby; rtp is optional.
gameLaunch :: Client -> T.Text -> T.Text -> T.Text -> T.Text -> T.Text -> Maybe Double -> IO (KeyMap Value)
gameLaunch c userCode providerCode gameCode lang lobbyUrl rtp =
  call c "game_launch" $
    [ ("user_code", String userCode)
    , ("provider_code", String providerCode)
    , ("game_code", String gameCode)
    , ("lang", String lang)
    , ("lobby_url", String lobbyUrl)
    ]
      ++ maybe [] (\r -> [("rtp", Number (realToFrac r))]) rtp

nowMillis :: IO Integer
nowMillis = round . (* 1000) <$> getPOSIXTime

run :: IO ()
run = do
  url <- envOr "FVS_API_URL" "https://api.example.com" -- API server you received from NexusGGR
  code <- envOr "FVS_AGENT_CODE" "your_agent_code"
  token <- envOr "FVS_AGENT_TOKEN" "your_agent_token"
  let fvs = Client url (T.pack code) (T.pack token)
      userCode = "demo_user"

  -- 1. Providers available to this agent (status 1 = open, 0 = maintenance)
  providers <- arr "providers" <$> providerList fvs
  provider <- maybe (fail "no providers") pure $ listToMaybe [p | p <- providers, num "status" p == Just 1] <|> listToMaybe providers
  let providerCode = fromMaybe "" (str "code" provider)
  putStrLn $ "providers: " ++ show (length providers) ++ ", using " ++ T.unpack providerCode

  -- 2. Games of that provider
  games <- arr "games" <$> gameList fvs providerCode
  game <- maybe (fail "no games") pure (listToMaybe games)
  let gameCode = fromMaybe "" (str "game_code" game)
  putStrLn $ "games: " ++ show (length games) ++ ", first: " ++ T.unpack gameCode ++ " (" ++ T.unpack (fromMaybe "" (str "game_name" game)) ++ ")"

  -- 3. Create the player (idempotent: an existing user is fine)
  created <- try (userCreate fvs userCode)
  case created of
    Right o -> TIO.putStrLn $ "user created: " <> fromMaybe "" (str "user_code" o) <> " (" <> fromMaybe "" (str "fc_code" o) <> ")"
    Left (e :: FiversCanError)
      | "duplicated" `T.isInfixOf` T.toLower (fvsMsg e) -> TIO.putStrLn $ "user exists: " <> userCode
      | otherwise -> throwIO e

  -- 4. Move funds agent -> player
  depSign <- ("dep_" <>) . T.pack . show <$> nowMillis
  dep <- userDeposit fvs userCode 100 (Just depSign)
  putStrLn $ "deposit ok: agent=" ++ showNum (num "agent_balance" dep) ++ " user=" ++ showNum (num "user_balance" dep)

  -- 5. Get the game URL to open in the player's browser / iframe
  launch <- gameLaunch fvs userCode providerCode gameCode "en" "https://your-site.com/lobby" Nothing
  TIO.putStrLn $ "launch_url: " <> fromMaybe "" (str "launch_url" launch)

  -- 6. Balances
  info <- moneyInfo fvs (Just userCode)
  putStrLn $ "balance: agent=" ++ showNum (obj "agent" info >>= num "balance") ++ " user=" ++ showNum (obj "user" info >>= num "balance")

  -- 7. Move funds player -> agent
  wdSign <- ("wd_" <>) . T.pack . show <$> nowMillis
  wd <- userWithdraw fvs userCode 50 (Just wdSign)
  putStrLn $ "withdraw ok: agent=" ++ showNum (num "agent_balance" wd) ++ " user=" ++ showNum (num "user_balance" wd)

main :: IO ()
main = do
  result <- try run
  case result of
    Right () -> pure ()
    Left (e :: FiversCanError) -> hPutStrLn stderr (describeError e) >> exitFailure
