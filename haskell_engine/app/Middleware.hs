-- Copyright (c) 2024-2026 Don Fox. All rights reserved.
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Checks applied to every request before it reaches "Routes": a
-- per-address rate limit, then the shared-secret Bearer token. Both let
-- @\/api\/health@ through so liveness probes always work.
module Middleware
  ( rateLimitMiddleware,
    RateMap,
    defaultRateLimit,
    rateLimitWindowSecs,
    authMiddleware,
  )
where

import Data.Aeson (encode, object, (.=))
import Data.IORef (IORef, atomicModifyIORef')
import Data.Map.Strict qualified as Map
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.ByteString.Char8 qualified as BS8
import Network.HTTP.Types (status401, status429)
import Network.Socket (SockAddr)
import Network.Wai

-- | Reject every request that lacks a matching Bearer token.
-- The /api/health liveness probe is always allowed through unauthenticated
-- so that load-balancers and monitoring tools can reach it without a token.
-- When RULE_ENGINE_SECRET is unset (empty), ALL non-health requests are rejected
-- so a misconfigured deployment fails closed rather than open.
authMiddleware :: BS8.ByteString -> Application -> Application
authMiddleware secret inner request respond
  | pathInfo request == ["api", "health"] = inner request respond
  | BS8.null secret =
      respond $
        responseLBS
          status401
          [("Content-Type", "application/json")]
          (encode $ object ["error" .= ("RULE_ENGINE_SECRET not configured — server is locked" :: String)])
  | otherwise =
      case lookup "authorization" (requestHeaders request) of
        Just h | h == "Bearer " <> secret -> inner request respond
        _ ->
          respond $
            responseLBS
              status401
              [("Content-Type", "application/json")]
              (encode $ object ["error" .= ("Unauthorized" :: String)])

-- | Sliding-window rate-limiter middleware.
--
-- Each unique remote address is allowed at most @limit@ requests within
-- a rolling 'rateLimitWindowSecs' second window. Requests exceeding the limit
-- receive a 429 response before any body parsing or authentication occurs.
-- The /api/health endpoint is exempt so liveness probes are never throttled.
type RateMap = Map.Map SockAddr [UTCTime]

rateLimitMiddleware :: Int -> IORef RateMap -> Application -> Application
rateLimitMiddleware limit ref inner request respond
  | pathInfo request == ["api", "health"] = inner request respond
  | otherwise = do
      now <- getCurrentTime
      let addr = remoteHost request
          cutoff = addUTCTime (fromIntegral (negate rateLimitWindowSecs)) now
      allowed <- atomicModifyIORef' ref $ \m ->
        let recent = filter (> cutoff) (Map.findWithDefault [] addr m)
        in if length recent >= limit
             then (m, False)
             else (Map.insert addr (now : recent) m, True)
      if allowed
        then inner request respond
        else respond $
               responseLBS
                 status429
                 [("Content-Type", "application/json"), ("Retry-After", "60")]
                 (encode $ object ["error" .= ("Rate limit exceeded — max " ++ show limit ++ " requests per " ++ show rateLimitWindowSecs ++ " s")])

-- | Sliding-window rate limit: maximum requests per IP per window, unless
-- ENGINE_RATE_LIMIT sets another.
defaultRateLimit :: Int
defaultRateLimit = 100

-- | Rate-limit window size in seconds.
rateLimitWindowSecs :: Int
rateLimitWindowSecs = 60
