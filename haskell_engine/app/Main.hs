{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Aeson (FromJSON, ToJSON, decode, encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Text qualified as T
import Network.HTTP.Types (Status, status200, status400)
import Network.Wai
import Network.Wai.Handler.Warp (run)
import X12.DSL.Parser
import X12.DSL.RuleEngine (loadRules, evaluateSimpleJson, EvaluationReport(..))
import X12.DSL.Compiler
    ( CompiledRuleCache
    , CompiledRule(..)
    , newCompiledRuleCache
    , compileRule
    , cacheCompiledRule
    , lookupCompiledRule
    , getCacheStats
    , generateRuleCode
    , CompilationResult(..)
    )
import Data.Time.Clock (diffUTCTime, getCurrentTime)

main :: IO ()
main = do
  putStrLn "Starting X12 Fraud Detection DSL Server on port 8080..."
  cache <- newCompiledRuleCache
  run 8080 (app cache)

app :: CompiledRuleCache -> Application
app cache request respond = do
  case pathInfo request of
    ["api", "evaluate"]          -> handleEvaluate request respond
    ["api", "parse-rule"]        -> handleParseRule request respond
    ["api", "compile-rule"]      -> handleCompileRule cache request respond
    ["api", "evaluate-compiled"] -> handleEvaluateCompiled cache request respond
    ["api", "compiled-rules"]    -> handleListCompiled cache respond
    ["api", "health"]            -> handleHealth respond
    _                            -> respond $ responseLBS status400 [] "Not found"

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

-- | Compile a DSL rule to a native Haskell function via GHC.
handleCompileRule :: CompiledRuleCache -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleCompileRule cache request respond = do
  body <- strictRequestBody request
  case decode body of
    Nothing ->
      respond $ jsonResponse status400 $
        object ["error" .= ("Invalid JSON" :: String), "success" .= False]
    Just parseReq -> do
      case parseRule (parseRuleText parseReq) of
        Left err ->
          respond $ jsonResponse status400 $
            object ["error" .= show err, "success" .= False]
        Right rule -> do
          startTime <- getCurrentTime
          result <- compileRule rule
          endTime <- getCurrentTime
          let elapsedMs = realToFrac (diffUTCTime endTime startTime) * 1000 :: Double
          case result of
            CompilationSuccess compiled -> do
              cacheCompiledRule cache compiled
              respond $ jsonResponse status200 $
                object
                  [ "success"           .= True
                  , "ruleName"          .= compiledRuleName compiled
                  , "generatedSource"   .= compiledSource compiled
                  , "compilationTimeMs" .= elapsedMs
                  , "message"           .= ("Rule compiled successfully" :: String)
                  ]
            CompilationError err -> do
              let source = generateRuleCode rule
              respond $ jsonResponse status200 $
                object
                  [ "success"         .= False
                  , "error"           .= err
                  , "generatedSource" .= source
                  ]

-- | Evaluate a claim using a previously compiled rule.
handleEvaluateCompiled :: CompiledRuleCache -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleEvaluateCompiled cache request respond = do
  body <- strictRequestBody request
  case decode body of
    Nothing ->
      respond $ jsonResponse status400 $
        object ["error" .= ("Invalid JSON" :: String)]
    Just req -> do
      let name = compiledEvalRuleName req
          doc  = compiledEvalDocument req
      mCompiled <- lookupCompiledRule cache name
      case mCompiled of
        Nothing ->
          respond $ jsonResponse status400 $
            object ["error" .= ("Rule not compiled: " <> name)]
        Just compiled -> do
          let result = compiledFunction compiled doc
          respond $ jsonResponse status200 $
            object ["result" .= result, "mode" .= ("compiled" :: String)]

-- | List all currently compiled rules in the cache.
handleListCompiled :: CompiledRuleCache -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleListCompiled cache respond = do
  (count, names) <- getCacheStats cache
  respond $ jsonResponse status200 $
    object
      [ "compiledRules" .= names
      , "totalCount"    .= count
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

-- Request/Response types

data EvaluationRequest = EvaluationRequest
  { evalRulesText :: T.Text,
    evalDocument :: Aeson.Value
  }
  deriving (Show)

instance FromJSON EvaluationRequest where
  parseJSON = Aeson.withObject "EvaluationRequest" $ \v ->
    EvaluationRequest
      <$> v Aeson..: "rulesText"
      <*> v Aeson..: "document"

data EvaluationResponse = EvaluationResponse
  { respReport :: EvaluationReport
  }
  deriving (Show)

instance ToJSON EvaluationResponse where
  toJSON (EvaluationResponse report) =
    object ["report" .= reportToJSON report]

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

data CompiledEvalRequest = CompiledEvalRequest
  { compiledEvalRuleName :: T.Text
  , compiledEvalDocument :: Aeson.Value
  }
  deriving (Show)

instance FromJSON CompiledEvalRequest where
  parseJSON = Aeson.withObject "CompiledEvalRequest" $ \v ->
    CompiledEvalRequest
      <$> v Aeson..: "ruleName"
      <*> v Aeson..: "document"

-- Business logic

processEvaluation :: EvaluationRequest -> IO (Either String EvaluationResponse)
processEvaluation req = do
  case loadRules (evalRulesText req) of
    Left err -> return $ Left err
    Right engine -> do
      let report = evaluateSimpleJson engine (evalDocument req)
      return $ Right $ EvaluationResponse report

parseRuleRequest :: ParseRuleRequest -> Either String Aeson.Value
parseRuleRequest req =
  case parseRules (parseRuleText req) of
    Left err -> Left $ show err
    Right rules -> Right $ Aeson.toJSON rules
