{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Claims.Pipeline
-- Description : One claim evaluation end to end
--
-- Rules → evaluation (under a timeout) → ML score → combined decision.
-- The HTTP handlers decode requests and encode responses; everything in
-- between happens here, so it can be tested without a server.
module Claims.Pipeline
  ( -- * Request
    EvaluationRequest (..),

    -- * Configuration
    EngineConfig (..),
    loadEngineConfig,

    -- * Evaluation
    processEvaluation,
    EvaluationError (..),
    evaluationErrorJSON,
    evaluateClaim,
    evaluateClaimWithin,
    localToday,
    EvaluationResponse (..),
    reportToJSON,
  )
where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Data.Aeson (FromJSON, ToJSON (..), Value (..), object, withObject, (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Aeson.Types qualified as AesonTypes
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day)
import Data.Time.Clock (getCurrentTime)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Claims.Evaluator (EvaluationReport (..), evaluateSimpleJson)
import Claims.MLClient (MLClientConfig, MLResult, getMlClientConfig, mlErrorResult, mlStubResult, scoreClaimWithMl)
import Claims.Parser (loadRules)
import Claims.PolicyCombiner
  ( CombinedEnvelope,
    FallbackPolicy (..),
    PolicyConfig,
    buildCombinedEnvelope,
    defaultPolicyConfig,
    fallbackPolicy,
  )
import Claims.Syntax (Rule)
import Network.HTTP.Types (Status, status400, status503)

-- ----------------------------------------------------------------------------
-- Request
-- ----------------------------------------------------------------------------

-- | A validated request to the @\/api\/evaluate@ endpoint. The 'FromJSON'
-- instance enforces:
--
--   * @contract_version@ must be @"1.0"@
--   * @request_id@, @claim_id@, and @tenant_id@ must be non-empty strings
--
-- == Expected JSON shape
--
-- @
-- { "contract_version": "1.0",
--   "request_id":  "req-001",
--   "claim_id":    "CLM-12345",
--   "tenant_id":   "tenant-a",
--   "rulesText":   "RULE ImDates …",
--   "document":    { … claim fields … },
--   "context":     null
-- }
-- @
data EvaluationRequest = EvaluationRequest
  { evalContractVersion :: Text,        -- ^ Must be @"1.0"@
    evalRequestId :: Text,              -- ^ Caller-supplied correlation ID
    evalClaimId :: Text,                -- ^ Claim identifier to evaluate
    evalTenantId :: Text,               -- ^ Tenant / organisation scope
    evalRulesText :: Text,              -- ^ Raw DSL rule text to compile
    evalDocument :: Aeson.Value,        -- ^ Claim payload (arbitrary JSON)
    evalContext :: Maybe Aeson.Value     -- ^ Optional evaluation context
  }
  deriving (Show)

instance FromJSON EvaluationRequest where
  parseJSON = Aeson.withObject "EvaluationRequest" $ \v -> do
    contractVersion <- v Aeson..: "contract_version"
    requestId <- v Aeson..: "request_id"
    claimId <- v Aeson..: "claim_id"
    tenantId <- v Aeson..: "tenant_id"
    rulesText <- v Aeson..: "rulesText"
    document <- v Aeson..: "document"
    context <- v Aeson..:? "context"

    if contractVersion /= ("1.0" :: Text)
      then fail "Unsupported contract_version; expected 1.0"
      else pure ()

    ensureNonEmpty "request_id" requestId
    ensureNonEmpty "claim_id" claimId
    ensureNonEmpty "tenant_id" tenantId

    pure
      EvaluationRequest
        { evalContractVersion = contractVersion,
          evalRequestId = requestId,
          evalClaimId = claimId,
          evalTenantId = tenantId,
          evalRulesText = rulesText,
          evalDocument = document,
          evalContext = context
        }

-- | Fail the parse if the given field value is blank (empty or whitespace-only).
ensureNonEmpty :: Text -> Text -> AesonTypes.Parser ()
ensureNonEmpty fieldName value =
  if T.strip value == ""
    then fail (T.unpack fieldName <> " must not be empty")
    else pure ()

-- ----------------------------------------------------------------------------
-- Evaluation
-- ----------------------------------------------------------------------------

-- | Per-claim evaluation timeout in microseconds (30 s). Prevents a
-- pathological rule (e.g. FORALL over a very large array) from holding a
-- semaphore slot indefinitely after the Phoenix caller has disconnected.
evalTimeoutMicros :: Int
evalTimeoutMicros = 30 * 1000000

-- | Today's date where the engine runs (its local time zone, not UTC), so
-- "today" in rules (future dates, ages) matches the analysts' calendar.
localToday :: IO Day
localToday = localDay . zonedTimeToLocalTime <$> getZonedTime

-- | Evaluate a rule set against one claim, giving up after
-- 'evalTimeoutMicros' (30 s).
evaluateClaim :: [Rule] -> Day -> Value -> IO (Maybe EvaluationReport)
evaluateClaim = evaluateClaimWithin evalTimeoutMicros

-- | Evaluate a rule set against one claim, giving up after the given number
-- of microseconds. The whole report is worked out inside the limit: every
-- result's match, details (including the "not checked" reasons), counts,
-- risk and summary. Evaluation is lazy, so without forcing them this work
-- would happen later, while the reply is written, with no limit.
evaluateClaimWithin :: Int -> [Rule] -> Day -> Value -> IO (Maybe EvaluationReport)
evaluateClaimWithin limit rules today doc =
  timeout limit $ evaluate (force (evaluateSimpleJson rules today doc))

-- | Why a single-claim evaluation produced no report.
data EvaluationError
  = -- | The rules did not parse (the caller's mistake).
    RulesError String
  | -- | The claim took longer than 30 seconds (not the caller's mistake).
    TimedOut
  deriving (Show, Eq)

-- | The HTTP status and JSON body for an 'EvaluationError'. A timeout is
-- 503 with @"reason": "timeout"@, as the batch endpoint reports it per
-- claim; a rule error is 400.
evaluationErrorJSON :: EvaluationError -> (Status, Value)
evaluationErrorJSON = \case
  RulesError err -> (status400, object ["error" .= err])
  TimedOut ->
    ( status503,
      object
        [ "error" .= ("evaluation timed out after 30 s" :: Text),
          "reason" .= ("timeout" :: Text)
        ]
    )

-- | Settings the pipeline takes from the environment. They are read once,
-- at startup ('loadEngineConfig'), and passed to each request, so a request
-- never looks at the environment itself.
data EngineConfig = EngineConfig
  { -- | The ML scorer, or 'Nothing' to use the neutral stand-in
    -- ('mlStubResult'): @ML_SCORER_URL@ is unset or was refused.
    engineMlClient :: Maybe MLClientConfig,
    -- | @ALLOW_ML_TEST_OVERRIDE=true@: a claim's @_mlStatus: "error"@ field
    -- simulates a scorer failure. For tests only.
    engineAllowMlTestOverride :: Bool
  }
  deriving (Show, Eq)

-- | Read the pipeline settings from the environment.
loadEngineConfig :: IO EngineConfig
loadEngineConfig =
  EngineConfig
    <$> getMlClientConfig
    <*> ((== Just "true") <$> lookupEnv "ALLOW_ML_TEST_OVERRIDE")

-- | Evaluate one claim end to end: parse the rules, run them, score the
-- claim with the ML service (or its stand-in), and combine the two.
processEvaluation :: EngineConfig -> EvaluationRequest -> IO (Either EvaluationError EvaluationResponse)
processEvaluation cfg req = do
  case loadRules (evalRulesText req) of
    Left err -> return $ Left (RulesError err)
    Right engine -> do
      now <- getCurrentTime
      today <- localToday
      mReport <- evaluateClaim engine today (evalDocument req)
      case mReport of
        Nothing -> return $ Left TimedOut
        Just report -> do
          let evaluatedAt = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
          mlResult <- selectMlResult cfg req
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
-- 'engineAllowMlTestOverride' is set, so it cannot be triggered by crafted
-- claim payloads in production. A warning is emitted to stderr whenever the
-- override fires so it is auditable.
selectMlResult :: EngineConfig -> EvaluationRequest -> IO MLResult
selectMlResult cfg req
  | engineAllowMlTestOverride cfg && forcesMlError (evalDocument req) = do
      hPutStrLn stderr "WARNING: _mlStatus test override triggered — ML scorer bypassed"
      pure $ mlErrorResult "forced"
  | otherwise = fetchOrStub (engineMlClient cfg) (evalClaimId req) (evalDocument req)

-- | Whether a claim carries @"_mlStatus": "error"@ (in any letter case).
forcesMlError :: Value -> Bool
forcesMlError doc = case parseMaybe parseMlStatus doc of
  Just (Just s) -> T.toLower s == "error"
  _ -> False
  where
    parseMlStatus = withObject "MLStatus" $ \obj -> obj .:? "_mlStatus"

-- | Call the ML scorer when configured; fall back to a neutral stub result
-- when it is not, so the server runs without the scorer service.
fetchOrStub :: Maybe MLClientConfig -> T.Text -> Value -> IO MLResult
fetchOrStub Nothing _ _ = pure mlStubResult
fetchOrStub (Just mlCfg) claimId doc = do
  result <- scoreClaimWithMl mlCfg claimId doc
  pure $ either (applyFallback defaultPolicyConfig) id result

applyFallback :: PolicyConfig -> T.Text -> MLResult
applyFallback cfg errMsg =
  case fallbackPolicy cfg of
    FallbackDslOnly -> mlErrorResult errMsg

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
      "undecidedRules" .= reportUndecidedRules report,
      "overallRisk" .= show (reportOverallRisk report),
      "summary" .= reportSummary report
    ]
