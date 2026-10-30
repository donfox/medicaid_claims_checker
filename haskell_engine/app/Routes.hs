-- Copyright (c) 2024-2026 Don Fox. All rights reserved.
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The engine's HTTP endpoints. Each handler reads and size-checks the
-- body, decodes the request, calls into the library ("Claims.Pipeline",
-- "Claims.Parser", "Claims.RedundancyChecker") and encodes the response.
--
-- endpoints:
--
-- * @post /api/evaluate@          — evaluate one claim against a rule set
-- * @post /api/batch-evaluate@    — evaluate multiple claims in one request
-- * @post /api/parse-rule@        — parse a single rule and return its AST as JSON
-- * @post /api/check-redundancy@  — detect overlap between a candidate and existing rules
-- * @get  /api/health@            — liveness probe
module Routes (app) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.QSem (QSem, signalQSem, waitQSem)
import Control.Exception (bracket_)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), decode, encode, object, withObject, (.:), (.=))
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime, utctDay)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Network.HTTP.Types (Status, status200, status400)
import Network.Wai
import Claims.Parser (loadRules, parseRules)
import Claims.Pipeline (evaluateClaim, processEvaluation, reportToJSON)
import Claims.RedundancyChecker (checkRedundancy)

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

app :: QSem -> Application
app sem request respond = do
  case pathInfo request of
    ["api", "evaluate"] -> handleEvaluate request respond
    ["api", "batch-evaluate"] -> handleBatchEvaluate sem request respond
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
                          mReport <- evaluateClaim engine today doc
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
