-- Copyright (c) 2024-2025 Don Fox. All rights reserved.
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Warp server exposing the Medicaid claims engine.
--
-- Listening (see 'listenConfig'):
--
-- * @ENGINE_HOST@ (default @127.0.0.1@) and @ENGINE_PORT@ (default @8080@).
-- * Without @RULE_ENGINE_TLS_CERT@/@RULE_ENGINE_TLS_KEY@ the engine serves
--   plain HTTP and only on a loopback address; asking for any other host
--   without TLS stops the server at startup.
-- * With both set it serves HTTPS on any host.
--
-- @ENGINE_RATE_LIMIT@ (default 100) is the most requests one address may make
-- per 60 s; the use-case tests (../test.sh) raise it for their own engine.
--
-- Requests pass through "Middleware" (rate limit, then auth) to "Routes".
module Main where

import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.QSem (newQSem)
import Control.Monad (filterM, unless)
import Data.IORef (newIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.ByteString.Char8 qualified as BS8
import Network.Wai.Handler.Warp (defaultSettings, runSettings, setHost, setPort)
import Network.Wai.Handler.WarpTLS (runTLS, tlsSettings)
import Data.String (fromString)
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.Environment (lookupEnv)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)
import Text.Read (readMaybe)
import Claims.ListenConfig (ListenConfig (..), resolveListen)
import Middleware (authMiddleware, defaultRateLimit, rateLimitMiddleware, rateLimitWindowSecs)
import Routes (app)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  listen <- listenConfig
  config <- case listen of
    Left err -> hPutStrLn stderr ("Engine not started: " ++ err) >> exitFailure
    Right c -> pure c
  let missing p = not <$> doesFileExist p
  case lcTls config of
    Just (cert, key) -> do
      absent <- filterM missing [cert, key]
      unless (null absent) $ do
        hPutStrLn stderr ("Engine not started: TLS file not found: " ++ unwords absent)
        exitFailure
    Nothing -> pure ()
  let scheme = maybe "http" (const "https") (lcTls config)
  putStrLn $ "Starting JSON Claims Integrity DSL Server on " ++ scheme ++ "://" ++ lcHost config ++ ":" ++ show (lcPort config) ++ "..."
  numCaps <- getNumCapabilities
  let workerCount = max 1 numCaps
  sem <- newQSem workerCount
  secret <- BS8.pack . fromMaybe "" <$> lookupEnv "RULE_ENGINE_SECRET"
  rateLimit <- lookupEnv "ENGINE_RATE_LIMIT" >>= \v -> case v of
    Nothing -> pure defaultRateLimit
    Just s -> case readMaybe s of
      Just n | n > 0 -> pure n
      _ -> hPutStrLn stderr ("Engine not started: ENGINE_RATE_LIMIT must be a positive number, got " ++ show s) >> exitFailure
  rateRef <- newIORef Map.empty
  putStrLn $ "Worker pool: " ++ show workerCount ++ " concurrent claim evaluations"
  putStrLn $ "Auth: " ++ if BS8.null secret then "WARNING — RULE_ENGINE_SECRET not set, all requests will be rejected" else "shared-secret enabled"
  putStrLn $ "Rate limit: " ++ show rateLimit ++ " requests per " ++ show rateLimitWindowSecs ++ " s per IP"
  let settings = setHost (fromString (lcHost config)) (setPort (lcPort config) defaultSettings)
      handler = rateLimitMiddleware rateLimit rateRef (authMiddleware secret (app sem))
  case lcTls config of
    Just (cert, key) -> runTLS (tlsSettings cert key) settings handler
    Nothing -> runSettings settings handler

listenConfig :: IO (Either String ListenConfig)
listenConfig =
  resolveListen
    <$> lookupEnv "ENGINE_HOST"
    <*> lookupEnv "ENGINE_PORT"
    <*> lookupEnv "RULE_ENGINE_TLS_CERT"
    <*> lookupEnv "RULE_ENGINE_TLS_KEY"
