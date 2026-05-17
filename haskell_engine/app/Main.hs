-- Copyright (c) 2024-2025 Don Fox. All rights reserved.
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Warp HTTP server exposing the Medicaid claims engine on port 8080.
--
-- endpoints:
--
-- * @post /api/evaluate@          — evaluate one claim against a rule set
-- * @post /api/batch-evaluate@    — evaluate multiple claims in one request
-- * @post /api/compile-rules@     — parse and cache a rule set, return preflight counts
-- * @post /api/parse-rule@        — parse a single rule and return its AST as JSON
-- * @post /api/check-redundancy@  — detect overlap between a candidate and existing rules
-- * @get  /api/health@            — liveness probe
module Main where

import Control.Concurrent (getNumCapabilities)
import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_, evaluate)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), decode, encode, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (isInfixOf, isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime, utctDay)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Network.HTTP.Types (Status, status200, status400, status401, status429)
import Network.Socket (SockAddr)
import Network.Wai
import Network.Wai.Handler.Warp (run)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Text.Read (readMaybe)
import Claims.EvaluationContract (EvaluationRequest (..))
import Claims.MLClient (MLClientConfig (..), scoreClaimWithMl)
import Claims.Parser
import Claims.PolicyCombiner
  ( CombinedEnvelope,
    FallbackPolicy (..),
    MLResult,
    PolicyConfig,
    buildCombinedEnvelope,
    defaultPolicyConfig,
    fallbackPolicy,
    mlErrorResult,
    mlStubResult,
  )
import Claims.RuleCache
  ( CompilationResult (..),
    CompiledRuleCache,
    cacheCompiledRule,
    compileRules,
    newCompiledRuleCache,
  )
import Claims.RedundancyChecker (checkRedundancy)
import Claims.RuleEngine (EvaluationReport (..), evaluateSimpleJson, loadRules)

main :: IO ()
main = do
  putStrLn "Starting JSON Claims Integrity DSL Server on port 8080..."
  cache <- newCompiledRuleCache
  numCaps <- getNumCapabilities
  let workerCount = max 1 numCaps
  sem <- newQSem workerCount
  secret <- BS8.pack . fromMaybe "" <$> lookupEnv "RULE_ENGINE_SECRET"
  rateRef <- newIORef Map.empty
  putStrLn $ "Worker pool: " ++ show workerCount ++ " concurrent claim evaluations"
  putStrLn $ "Auth: " ++ if BS8.null secret then "WARNING — RULE_ENGINE_SECRET not set, all requests will be rejected" else "shared-secret enabled"
  putStrLn $ "Rate limit: " ++ show rateLimitMax ++ " requests per " ++ show rateLimitWindowSecs ++ " s per IP"
  run 8080 (rateLimitMiddleware rateRef (authMiddleware secret (app cache sem)))

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
-- Each unique remote address is allowed at most 'rateLimitMax' requests within
-- a rolling 'rateLimitWindowSecs' second window. Requests exceeding the limit
-- receive a 429 response before any body parsing or authentication occurs.
-- The /api/health endpoint is exempt so liveness probes are never throttled.
type RateMap = Map.Map SockAddr [UTCTime]

rateLimitMiddleware :: IORef RateMap -> Application -> Application
rateLimitMiddleware ref inner request respond
  | pathInfo request == ["api", "health"] = inner request respond
  | otherwise = do
      now <- getCurrentTime
      let addr = remoteHost request
          cutoff = addUTCTime (fromIntegral (negate rateLimitWindowSecs)) now
      allowed <- atomicModifyIORef' ref $ \m ->
        let recent = filter (> cutoff) (Map.findWithDefault [] addr m)
        in if length recent >= rateLimitMax
             then (m, False)
             else (Map.insert addr (now : recent) m, True)
      if allowed
        then inner request respond
        else respond $
               responseLBS
                 status429
                 [("Content-Type", "application/json"), ("Retry-After", "60")]
                 (encode $ object ["error" .= ("Rate limit exceeded — max 100 requests per 60 s" :: String)])

-- | Validate that an ML scorer URL does not target a private or cloud-metadata
-- hostname, preventing SSRF when ML_SCORER_URL is influenced by a misconfigured
-- secrets manager or CI pipeline. Blocks RFC-1918 ranges, loopback, link-local,
-- and known cloud metadata hostnames.
validateMlScorerUrl :: String -> Either String ()
validateMlScorerUrl url
  | not ("https://" `isPrefixOf` url) =
      Left "ML_SCORER_URL must begin with https://"
  | otherwise =
      let host = takeWhile (\c -> c /= '/' && c /= ':') (drop 8 url)
      in if any (`isPrefixOf` host) blockedPrefixes || any (`isInfixOf` host) blockedSubstrings
           then Left $ "ML_SCORER_URL hostname is blocked (SSRF prevention): " ++ host
           else Right ()
  where
    blockedPrefixes   = ["127.", "10.", "192.168.", "169.254.", "0.", "::1", "fc00:", "fd"]
    blockedSubstrings = ["localhost", "internal", "metadata", ".local"]

-- | Maximum allowed request body size (10 MB).
maxBodyBytes :: Int
maxBodyBytes = 10 * 1024 * 1024

-- | Maximum number of claims in a single batch request.
maxBatchClaims :: Int
maxBatchClaims = 500

-- | Maximum character length of an embedded rulesText field (512 KB).
-- The body-size limit guards the whole request; this guards the rules
-- substring specifically to prevent the O(rules × claims) blow-up.
maxRulesTextChars :: Int
maxRulesTextChars = 512 * 1024

-- | Per-claim evaluation timeout in microseconds (30 s). Prevents a
-- pathological rule (e.g. FORALL over a very large array) from holding a
-- semaphore slot indefinitely after the Phoenix caller has disconnected.
evalTimeoutMicros :: Int
evalTimeoutMicros = 30 * 1000000

-- | Sliding-window rate limit: maximum requests per IP per window.
rateLimitMax :: Int
rateLimitMax = 100

-- | Rate-limit window size in seconds.
rateLimitWindowSecs :: Int
rateLimitWindowSecs = 60

-- | Read the request body up to 'maxBodyBytes'. Returns 'Left' with an error
-- message if the body exceeds the limit, so the engine never buffers an
-- arbitrarily large payload into memory.
readBodyLimited :: Request -> IO (Either String BL.ByteString)
readBodyLimited req = go 0 []
  where
    go total chunks = do
      chunk <- getRequestBodyChunk req
      if BS.null chunk
        then pure $ Right (BL.fromChunks (reverse chunks))
        else
          let newTotal = total + BS.length chunk
           in if newTotal > maxBodyBytes
                then pure $ Left "Request body exceeds the 10 MB limit"
                else go newTotal (chunk : chunks)

app :: CompiledRuleCache -> QSem -> Application
app cache sem request respond = do
  case pathInfo request of
    ["api", "evaluate"] -> handleEvaluate request respond
    ["api", "batch-evaluate"] -> handleBatchEvaluate sem request respond
    ["api", "compile-rules"] -> handleCompileRules cache request respond
    ["api", "parse-rule"] -> handleParseRule request respond
    ["api", "check-redundancy"] -> handleCheckRedundancy request respond
    ["api", "health"] -> handleHealth respond
    _ -> respond $ responseLBS status400 [] "Not found"

-- | Liveness probe — always returns @{"status":"healthy"}@.
handleHealth :: (Response -> IO ResponseReceived) -> IO ResponseReceived
handleHealth respond =
  respond $
    responseLBS
      status200
      [("Content-Type", "application/json")]
      (encode $ object ["status" .= ("healthy" :: String)])

-- | Evaluate a single claim document against a DSL rule set, combining DSL
-- results with an ML score (or stub when @ML_SCORER_URL@ is unset).
handleEvaluate :: Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleEvaluate request respond = do
  bodyResult <- readBodyLimited request
  case bodyResult of
    Left sizeErr ->
      respond $ jsonResponse status400 $ object ["error" .= sizeErr]
    Right body ->
      case decode body of
        Nothing ->
          respond $
            responseLBS
              status400
              [("Content-Type", "application/json")]
              (encode $ object ["error" .= ("Invalid JSON" :: String)])
        Just evalReq -> do
          result <- processEvaluation evalReq
          case result of
            Left err ->
              respond $
                responseLBS
                  status400
                  [("Content-Type", "application/json")]
                  (encode $ object ["error" .= err])
            Right report ->
              respond $
                responseLBS
                  status200
                  [("Content-Type", "application/json")]
                  (encode report)

-- | Evaluate a batch of claims against a set of DSL rules.
--
-- Claims within the batch are evaluated in parallel, bounded by the worker
-- semaphore (one slot per GHC capability / CPU core).
handleBatchEvaluate :: QSem -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleBatchEvaluate sem request respond = do
  bodyResult <- readBodyLimited request
  case bodyResult of
    Left sizeErr ->
      respond $ jsonResponse status400 $ object ["error" .= sizeErr]
    Right body ->
      case decode body of
        Nothing ->
          respond $
            jsonResponse status400 $
              object ["error" .= ("Invalid JSON" :: String)]
        Just req ->
          if length (batchClaims req) > maxBatchClaims
            then
              respond $
                jsonResponse status400 $
                  object ["error" .= ("Batch exceeds maximum of 500 claims" :: String)]
            else if T.length (batchRulesText req) > maxRulesTextChars
            then
              respond $
                jsonResponse status400 $
                  object ["error" .= ("rulesText exceeds the 512 KB limit" :: String)]
            else
              case loadRules (batchRulesText req) of
                Left err ->
                  respond $
                    jsonResponse status400 $
                      object ["error" .= err]
                Right engine -> do
                  today <- utctDay <$> getCurrentTime
                  let claims = batchClaims req
                  results <- mapConcurrently
                    ( \(i, doc) ->
                        bracket_ (waitQSem sem) (signalQSem sem) $ do
                          mReport <- timeout evalTimeoutMicros $ do
                            let report = evaluateSimpleJson engine today doc
                            _ <- evaluate (reportTotalRules report)
                            pure report
                          pure $ case mReport of
                            Just report ->
                              object
                                [ "claimIndex" .= (i :: Int),
                                  "report" .= reportToJSON report
                                ]
                            Nothing ->
                              object
                                [ "claimIndex" .= (i :: Int),
                                  "error" .= ("evaluation timed out after 30 s" :: String)
                                ]
                    )
                    (zip [0 ..] claims)
                  respond $
                    jsonResponse status200 $
                      object
                        [ "batchResults" .= results,
                          "totalClaims" .= length claims
                        ]

-- | Parse a DSL rule set, cache the ASTs, and return preflight results.
handleCompileRules :: CompiledRuleCache -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleCompileRules cache request respond = do
  bodyResult <- readBodyLimited request
  case bodyResult of
    Left sizeErr ->
      respond $ jsonResponse status400 $ object ["error" .= sizeErr, "success" .= False]
    Right body ->
      case decode body of
        Nothing ->
          respond $
            jsonResponse status400 $
              object ["error" .= ("Invalid JSON" :: String), "success" .= False]
        Just req ->
          if T.length (compileRulesText req) > maxRulesTextChars
            then
              respond $
                jsonResponse status400 $
                  object ["error" .= ("rulesText exceeds the 512 KB limit" :: String), "success" .= False]
            else
          case parseRules (compileRulesText req) of
            Left err ->
              respond $
                jsonResponse status400 $
                  object ["error" .= show err, "success" .= False]
            Right rules -> do
              results <- compileRules rules
              let successes = [c | CompilationSuccess c <- results]
              mapM_ (cacheCompiledRule cache) successes
              respond $
                jsonResponse status200 $
                  object
                    [ "success" .= True,
                      "compiledCount" .= length successes,
                      "totalRules" .= length rules
                    ]

-- | Parse a single DSL rule and return its AST as JSON. Useful for editor
-- tooling and rule authoring validation without running a full evaluation.
handleParseRule :: Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleParseRule request respond = do
  bodyResult <- readBodyLimited request
  case bodyResult of
    Left sizeErr ->
      respond $ jsonResponse status400 $ object ["error" .= sizeErr]
    Right body ->
      case decode body of
        Nothing ->
          respond $
            responseLBS
              status400
              [("Content-Type", "application/json")]
              (encode $ object ["error" .= ("Invalid JSON" :: String)])
        Just parseReq ->
          case parseRuleRequest parseReq of
            Left err ->
              respond $
                responseLBS
                  status400
                  [("Content-Type", "application/json")]
                  (encode $ object ["error" .= err, "success" .= False])
            Right rule ->
              respond $
                responseLBS
                  status200
                  [("Content-Type", "application/json")]
                  (encode $ object ["rule" .= rule, "success" .= True])

-- Helper for JSON responses
jsonResponse :: Status -> Value -> Response
jsonResponse status val =
  responseLBS status [("Content-Type", "application/json")] (encode val)

data EvaluationResponse = EvaluationResponse
  { respReport :: EvaluationReport,
    respCombined :: CombinedEnvelope
  }
  deriving (Show)

instance ToJSON EvaluationResponse where
  toJSON (EvaluationResponse report combined) =
    object
      [ "report" .= reportToJSON report,
        "combined" .= combined
      ]

reportToJSON :: EvaluationReport -> Value
reportToJSON report =
  object
    [ "results" .= reportResults report,
      "totalRules" .= reportTotalRules report,
      "matchedRules" .= reportMatchedRules report,
      "overallRisk" .= show (reportOverallRisk report),
      "summary" .= reportSummary report
    ]

newtype ParseRuleRequest = ParseRuleRequest
  { parseRuleText :: T.Text
  }
  deriving (Show)

instance FromJSON ParseRuleRequest where
  parseJSON = withObject "ParseRuleRequest" $ \v ->
    ParseRuleRequest <$> v .: "ruleText"

data BatchEvaluationRequest = BatchEvaluationRequest
  { batchRulesText :: T.Text,
    batchClaims :: [Value]
  }
  deriving (Show)

instance FromJSON BatchEvaluationRequest where
  parseJSON = withObject "BatchEvaluationRequest" $ \v ->
    BatchEvaluationRequest
      <$> v .: "rulesText"
      <*> v .: "claims"

newtype CompileRulesRequest = CompileRulesRequest
  { compileRulesText :: T.Text
  }
  deriving (Show)

instance FromJSON CompileRulesRequest where
  parseJSON = withObject "CompileRulesRequest" $ \v ->
    CompileRulesRequest <$> v .: "rulesText"

-- Business logic

processEvaluation :: EvaluationRequest -> IO (Either String EvaluationResponse)
processEvaluation req = do
  case loadRules (evalRulesText req) of
    Left err -> return $ Left err
    Right engine -> do
      now <- getCurrentTime
      let today = utctDay now
      mReport <- timeout evalTimeoutMicros $ do
        let report = evaluateSimpleJson engine today (evalDocument req)
        _ <- evaluate (reportTotalRules report)
        pure report
      case mReport of
        Nothing -> return $ Left "Evaluation timed out after 30 s"
        Just report -> do
          let evaluatedAt = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
          mlResult <- selectMlResult req
          let combined =
                buildCombinedEnvelope
                  defaultPolicyConfig
                  (evalClaimId req)
                  evaluatedAt
                  (reportResults report)
                  mlResult
          return $ Right $ EvaluationResponse report combined

-- | Resolve the ML score for a claim.
--
-- The @_mlStatus: "error"@ test override is only honoured when
-- @ALLOW_ML_TEST_OVERRIDE=true@ is set in the environment, so it cannot be
-- triggered by crafted claim payloads in production.  A warning is emitted to
-- stderr whenever the override fires so it is auditable.
selectMlResult :: EvaluationRequest -> IO MLResult
selectMlResult req = do
  mOverride <- lookupEnv "ALLOW_ML_TEST_OVERRIDE"
  let allowOverride = mOverride == Just "true"
      doc = evalDocument req
      claimId = evalClaimId req
  if allowOverride
    then case doc of
      Object _ ->
        case parseMaybe parseMlStatus doc of
          Just (Just s) | T.toLower s == "error" -> do
            hPutStrLn stderr "WARNING: _mlStatus test override triggered — ML scorer bypassed"
            pure $ mlErrorResult "forced"
          _ -> fetchOrStub claimId doc
      _ -> fetchOrStub claimId doc
    else fetchOrStub claimId doc
  where
    parseMlStatus = withObject "MLStatus" $ \obj -> obj .:? "_mlStatus"

-- | Call the ML scorer when configured; fall back to a neutral stub result
-- when @ML_SCORER_URL@ is absent so the server runs without the scorer service.
fetchOrStub :: T.Text -> Value -> IO MLResult
fetchOrStub claimId doc = do
  mCfg <- getMlClientConfig
  case mCfg of
    Nothing -> pure mlStubResult
    Just cfg -> do
      result <- scoreClaimWithMl cfg claimId doc
      case result of
        Right ml -> pure ml
        Left errMsg -> pure $ applyFallback defaultPolicyConfig errMsg

getMlClientConfig :: IO (Maybe MLClientConfig)
getMlClientConfig = do
  mUrl <- lookupEnv "ML_SCORER_URL"
  mTimeout <- lookupEnv "ML_TIMEOUT_MS"
  let timeoutMs = fromMaybe 120 (mTimeout >>= readMaybe)
  case mUrl of
    Nothing -> pure Nothing
    Just url -> case validateMlScorerUrl url of
      Left err -> do
        hPutStrLn stderr $ "WARNING: ML_SCORER_URL rejected — " ++ err
        pure Nothing
      Right () -> pure $ Just $ MLClientConfig url timeoutMs

applyFallback :: PolicyConfig -> T.Text -> MLResult
applyFallback cfg errMsg =
  case fallbackPolicy cfg of
    FallbackDslOnly -> mlErrorResult errMsg

parseRuleRequest :: ParseRuleRequest -> Either String Value
parseRuleRequest req =
  case parseRules (parseRuleText req) of
    Left err -> Left $ show err
    Right rules -> Right $ toJSON rules

-- ----------------------------------------------------------------------------
-- Redundancy checking
-- ----------------------------------------------------------------------------

data CheckRedundancyRequest = CheckRedundancyRequest
  { candidateRuleText :: T.Text,
    existingRulesTexts :: [T.Text]
  }
  deriving (Show)

instance FromJSON CheckRedundancyRequest where
  parseJSON = withObject "CheckRedundancyRequest" $ \v ->
    CheckRedundancyRequest
      <$> v .: "candidateRuleText"
      <*> v .: "existingRulesTexts"

handleCheckRedundancy :: Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleCheckRedundancy request respond = do
  bodyResult <- readBodyLimited request
  case bodyResult of
    Left sizeErr ->
      respond $ jsonResponse status400 $ object ["error" .= sizeErr, "success" .= False]
    Right body ->
      case decode body of
        Nothing ->
          respond $
            jsonResponse status400 $
              object ["error" .= ("Invalid JSON" :: String), "success" .= False]
        Just req ->
          case parseRules (candidateRuleText req) of
            Left err ->
              respond $
                jsonResponse status400 $
                  object
                    [ "error" .= ("Could not parse candidate rule: " ++ show err),
                      "success" .= False
                    ]
            Right [] ->
              respond $
                jsonResponse status400 $
                  object
                    [ "error" .= ("No rules found in candidate text" :: String),
                      "success" .= False
                    ]
            Right (candidate : _) ->
              let existingRules = concatMap parseExistingRule (existingRulesTexts req)
                  matches = checkRedundancy candidate existingRules
               in respond $
                    jsonResponse status200 $
                      object
                        [ "success" .= True,
                          "matches" .= matches
                        ]
  where
    parseExistingRule txt = case parseRules txt of
      Right rules -> rules
      Left _ -> []
