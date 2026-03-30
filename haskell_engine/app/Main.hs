-- Copyright (c) 2024-2026 Don Fox. All rights reserved.
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Aeson (FromJSON, ToJSON, decode, encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
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
  run 8080 (app cache)

app :: CompiledRuleCache -> Application
app cache request respond = do
  case pathInfo request of
    ["api", "evaluate"] -> handleEvaluate request respond
    ["api", "batch-evaluate"] -> handleBatchEvaluate request respond
    ["api", "compile-rules"] -> handleCompileRules cache request respond
    ["api", "parse-rule"] -> handleParseRule request respond
    ["api", "check-redundancy"] -> handleCheckRedundancy request respond
    ["api", "health"] -> handleHealth respond
    _ -> respond $ responseLBS status400 [] "Not found"

handleHealth :: (Response -> IO ResponseReceived) -> IO ResponseReceived
handleHealth respond =
  respond $
    responseLBS
      status200
      [("Content-Type", "application/json")]
      (encode $ object ["status" .= ("healthy" :: String)])

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
handleBatchEvaluate :: Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleBatchEvaluate request respond = do
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
              results =
                zipWith
                  ( \i doc ->
                      object
                        [ "claimIndex" .= (i :: Int),
                          "report" .= reportToJSON (evaluateSimpleJson engine today doc)
                        ]
                  )
                  [0 ..]
                  claims
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
jsonResponse :: Status -> Aeson.Value -> Response
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

reportToJSON :: EvaluationReport -> Aeson.Value
reportToJSON report =
  object
    [ "results" .= reportResults report,
      "totalRules" .= reportTotalRules report,
      "matchedRules" .= reportMatchedRules report,
      "overallRisk" .= show (reportOverallRisk report),
      "summary" .= reportSummary report
    ]

data ParseRuleRequest = ParseRuleRequest
  { parseRuleText :: T.Text
  }
  deriving (Show)

instance FromJSON ParseRuleRequest where
  parseJSON = Aeson.withObject "ParseRuleRequest" $ \v ->
    ParseRuleRequest <$> v Aeson..: "ruleText"

data BatchEvaluationRequest = BatchEvaluationRequest
  { batchRulesText :: T.Text,
    batchClaims :: [Aeson.Value]
  }
  deriving (Show)

instance FromJSON BatchEvaluationRequest where
  parseJSON = Aeson.withObject "BatchEvaluationRequest" $ \v ->
    BatchEvaluationRequest
      <$> v Aeson..: "rulesText"
      <*> v Aeson..: "claims"

data CompileRulesRequest = CompileRulesRequest
  { compileRulesText :: T.Text
  }
  deriving (Show)

instance FromJSON CompileRulesRequest where
  parseJSON = Aeson.withObject "CompileRulesRequest" $ \v ->
    CompileRulesRequest <$> v Aeson..: "rulesText"

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

selectMlResult :: EvaluationRequest -> IO MLResult
selectMlResult req =
  let doc = evalDocument req
      claimId = evalClaimId req
   in case doc of
        Aeson.Object _ ->
          case AesonTypes.parseMaybe parseMlStatus doc of
            Just (Just s) | T.toLower s == "error" -> pure $ mlErrorResult "forced"
            _ -> fetchOrStub claimId doc
        _ -> fetchOrStub claimId doc
  where
    parseMlStatus = Aeson.withObject "MLStatus" $ \obj -> obj Aeson..:? "_mlStatus"

fetchOrStub :: T.Text -> Aeson.Value -> IO MLResult
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
  let timeoutMs = maybe 120 id (mTimeout >>= readMaybe)
  pure $ MLClientConfig <$> mUrl <*> pure timeoutMs

applyFallback :: PolicyConfig -> T.Text -> MLResult
applyFallback cfg errMsg =
  case fallbackPolicy cfg of
    FallbackDslOnly -> mlErrorResult errMsg

parseRuleRequest :: ParseRuleRequest -> Either String Aeson.Value
parseRuleRequest req =
  case parseRules (parseRuleText req) of
    Left err -> Left $ show err
    Right rules -> Right $ Aeson.toJSON rules

-- ----------------------------------------------------------------------------
-- Redundancy checking
-- ----------------------------------------------------------------------------

data CheckRedundancyRequest = CheckRedundancyRequest
  { candidateRuleText :: T.Text,
    existingRulesTexts :: [T.Text]
  }
  deriving (Show)

instance FromJSON CheckRedundancyRequest where
  parseJSON = Aeson.withObject "CheckRedundancyRequest" $ \v ->
    CheckRedundancyRequest
      <$> v Aeson..: "candidateRuleText"
      <*> v Aeson..: "existingRulesTexts"

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
