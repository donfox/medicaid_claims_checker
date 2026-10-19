-- Copyright (c) 2024-2026 Don Fox. All rights reserved.

-- | Where and how the engine server listens, resolved from its environment
-- variables (@ENGINE_HOST@, @ENGINE_PORT@, @RULE_ENGINE_TLS_CERT@,
-- @RULE_ENGINE_TLS_KEY@). Kept pure so the startup rules can be tested.
module Claims.ListenConfig
  ( ListenConfig (..),
    resolveListen,
  )
where

import Control.Monad (mfilter)
import Data.Maybe (fromMaybe)
import Text.Read (readMaybe)

-- | Where and how the server listens.
data ListenConfig = ListenConfig
  { lcHost :: String,
    lcPort :: Int,
    -- | (certificate, key) paths; 'Nothing' means plain HTTP.
    lcTls :: Maybe (FilePath, FilePath)
  }
  deriving (Eq, Show)

-- | Plain HTTP is allowed only on loopback, so claim data and the shared
-- secret never cross a network in cleartext. Empty variables count as unset.
resolveListen :: Maybe String -> Maybe String -> Maybe String -> Maybe String -> Either String ListenConfig
resolveListen mHost mPort mCert mKey = do
  let set = mfilter (not . null)
      host = fromMaybe "127.0.0.1" (set mHost)
  port <- case set mPort of
    Nothing -> Right 8080
    Just p -> case readMaybe p of
      Just n | n > 0 && n < 65536 -> Right n
      _ -> Left ("ENGINE_PORT must be a port number, got " ++ show p)
  tls <- case (set mCert, set mKey) of
    (Just c, Just k) -> Right (Just (c, k))
    (Nothing, Nothing) -> Right Nothing
    _ -> Left "set both RULE_ENGINE_TLS_CERT and RULE_ENGINE_TLS_KEY, or neither"
  case tls of
    Nothing
      | host `notElem` ["127.0.0.1", "localhost", "::1"] ->
          Left ("ENGINE_HOST=" ++ host ++ " is not a loopback address; serving it needs RULE_ENGINE_TLS_CERT and RULE_ENGINE_TLS_KEY")
    _ -> Right (ListenConfig host port tls)
