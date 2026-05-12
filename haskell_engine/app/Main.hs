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
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime, utctDay)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Network.HTTP.Types (Status, status200, status400)
import Network.Wai
import Network.Wai.Handler.Warp (run)
import System.Environment (lookupEnv)
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
  putStrLn $ "Worker pool: " ++ show workerCount ++ " concurrent claim evaluations"
  run 8080 (app cache sem)

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
  body <- strictRequestBody request
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
  body <- strictRequestBody request
  case decode body of
    Nothing ->
      respond $
        jsonResponse status400 $
          object ["error" .= ("Invalid JSON" :: String)]
    Just req ->
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
                  let report = evaluateSimpleJson engine today doc
                  -- Force rule evaluation before releasing the semaphore slot
                  _ <- evaluate (reportTotalRules report)
                  return $
                    object
                      [ "claimIndex" .= (i :: Int),
                        "report" .= reportToJSON report
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
  body <- strictRequestBody request
  case decode body of
    Nothing ->
      respond $
        jsonResponse status400 $
          object ["error" .= ("Invalid JSON" :: String), "success" .= False]
    Just req ->
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
  body <- strictRequestBody request
  case decode body of
    Nothing ->
      respond $
        responseLBS
          status400
          [("Content-Type", "application/json")]
          (encode $ object ["error" .= ("Invalid JSON" :: String)])
    Just parseReq -> do
      let result = parseRuleRequest parseReq
      case result of
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
          report = evaluateSimpleJson engine today (evalDocument req)
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

-- | Resolve the ML score for a claim, with a test escape hatch: if the claim
-- document contains @"_mlStatus": "error"@ the ML path is short-circuited and
-- a forced error result is returned, letting integration tests exercise the
-- DSL-only fallback path without hitting the scorer service.
selectMlResult :: EvaluationRequest -> IO MLResult
selectMlResult req =
  let doc = evalDocument req
      claimId = evalClaimId req
   in case doc of
        Object _ ->
          case parseMaybe parseMlStatus doc of
            Just (Just s) | T.toLower s == "error" -> pure $ mlErrorResult "forced"
            _ -> fetchOrStub claimId doc
        _ -> fetchOrStub claimId doc
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
  pure $ MLClientConfig <$> mUrl <*> pure timeoutMs

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
  body <- strictRequestBody request
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
