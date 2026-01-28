{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Aeson (FromJSON, ToJSON, decode, encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types (status200, status400, status500)
import Network.Wai
import Network.Wai.Handler.Warp (run)
import System.IO (hPutStrLn, stderr)
import X12.DSL.Parser
import X12.DSL.RuleEngine (loadRules, evaluateSimpleJson, EvaluationReport(..))

main :: IO ()
main = do
  putStrLn "Starting X12 Fraud Detection DSL Server on port 8080..."
  run 8080 app

app :: Application
app request respond = do
  case pathInfo request of
    ["api", "evaluate"] -> handleEvaluate request respond
    ["api", "parse-rule"] -> handleParseRule request respond
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
              status500
              [("Content-Type", "application/json")]
              (encode $ object ["error" .= err])
        Right report ->
          respond $
            responseLBS
              status200
              [("Content-Type", "application/json")]
              (encode report)

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

-- Request/Response types

data EvaluationRequest = EvaluationRequest
  { evalRulesText :: T.Text,
    evalDocument :: Aeson.Value  -- Accept any JSON value
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

-- Business logic

processEvaluation :: EvaluationRequest -> IO (Either String EvaluationResponse)
processEvaluation req = do
  case loadRules (evalRulesText req) of
    Left err -> return $ Left err
    Right engine -> do
      -- Use simple JSON evaluation for any JSON document
      let report = evaluateSimpleJson engine (evalDocument req)
      return $ Right $ EvaluationResponse report

parseRuleRequest :: ParseRuleRequest -> Either String Aeson.Value
parseRuleRequest req =
  case parseRule (parseRuleText req) of
    Left err -> Left $ show err
    Right rule -> Right $ Aeson.toJSON rule
