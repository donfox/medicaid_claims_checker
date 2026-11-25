-- Copyright (c) 2024-2025 Don Fox. All rights reserved.
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
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
-- @ENGINE_RATE_LIMIT@ (default 1000) is the most requests one IP address may make
-- per 60 s; the use-case tests (../scripts/test.sh) raise it for their own engine.
--
-- Requests pass through "Middleware" (rate limit, then auth) to "Routes".
module Main where

import Control.Concurrent (forkIO, getNumCapabilities, threadDelay)
import Control.Concurrent.QSem (newQSem)
import Control.Monad (filterM, forever, unless)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.ByteString.Char8 qualified as BS8
import Network.Wai.Handler.Warp (runSettings, setHost, setPort)
import Network.Wai.Handler.WarpTLS (runTLS, tlsSettings)
import Data.String (fromString)
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.Environment (lookupEnv)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)
import Claims.ListenConfig (ListenConfig (..), resolveListen)
import Claims.MLClient (MLClientConfig (..))
import Claims.Pipeline (EngineConfig (..), loadEngineConfig)
import Data.Time.Clock (getCurrentTime)
import Middleware (authMiddleware, parseRateLimit, pruneRateMap, rateLimitMiddleware, rateLimitWindowSecs)
import Routes (app)
import ServerSettings (baseSettings)

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
  rateLimit <- parseRateLimit <$> lookupEnv "ENGINE_RATE_LIMIT" >>= \case
    Right n -> pure n
    Left err -> hPutStrLn stderr ("Engine not started: " ++ err) >> exitFailure
  let scheme = maybe "http" (const "https") (lcTls config)
  putStrLn $ "Starting Medicaid Claims Checker rule engine on " ++ scheme ++ "://" ++ lcHost config ++ ":" ++ show (lcPort config) ++ "..."
  numCaps <- getNumCapabilities
  let workerCount = max 1 numCaps
  sem <- newQSem workerCount
  secret <- BS8.pack . fromMaybe "" <$> lookupEnv "RULE_ENGINE_SECRET"
  engineCfg <- loadEngineConfig
  rateRef <- newIORef Map.empty
  -- Forget addresses with no requests in the last window (see pruneRateMap).
  _ <- forkIO $ forever $ do
    threadDelay (rateLimitWindowSecs * 1000000)
    now <- getCurrentTime
    atomicModifyIORef' rateRef (\m -> (pruneRateMap now m, ()))
  putStrLn $ "Worker pool: " ++ show workerCount ++ " concurrent claim evaluations"
  putStrLn $ "Auth: " ++ if BS8.null secret then "WARNING — RULE_ENGINE_SECRET not set, all requests will be rejected" else "shared-secret enabled"
  putStrLn $ "ML scorer: " ++ maybe "off (ML_SCORER_URL unset or refused) — using the neutral stand-in score" mlEndpointUrl (engineMlClient engineCfg)
  putStrLn $ "Rate limit: " ++ show rateLimit ++ " requests per " ++ show rateLimitWindowSecs ++ " s per IP"
  let settings = setHost (fromString (lcHost config)) (setPort (lcPort config) baseSettings)
      handler = rateLimitMiddleware rateLimit rateRef (authMiddleware secret (app engineCfg sem))
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
