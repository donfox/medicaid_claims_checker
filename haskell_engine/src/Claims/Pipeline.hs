{-# LANGUAGE ImportQualifiedPost #-}
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

    -- * Evaluation
    processEvaluation,
    evaluateClaim,
    EvaluationResponse (..),
    reportToJSON,
  )
where

import Control.Exception (evaluate)
import Data.Aeson (FromJSON, ToJSON (..), Value (..), object, withObject, (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Aeson.Types qualified as AesonTypes
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day)
import Data.Time.Clock (getCurrentTime, utctDay)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Claims.Evaluator (EvaluationReport (..), evaluateSimpleJson)
import Claims.MLClient (MLResult, getMlClientConfig, mlErrorResult, mlStubResult, scoreClaimWithMl)
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

-- ----------------------------------------------------------------------------
-- Request
-- ----------------------------------------------------------------------------

-- | Inbound request contract for the @\/api\/evaluate@ endpoint.
--
-- Defines the 'EvaluationRequest' type that is deserialised from incoming
-- JSON.  The 'FromJSON' instance enforces:
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

-- | A validated evaluation request.  All fields have passed contract and
-- non-empty checks by the time this value is constructed.
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

-- | Evaluate a rule set against one claim, giving up after
-- 'evalTimeoutMicros'. Forcing the match count runs every predicate here,
-- inside the timeout; the rule list length alone does not.
evaluateClaim :: [Rule] -> Day -> Value -> IO (Maybe EvaluationReport)
evaluateClaim rules today doc =
  timeout evalTimeoutMicros $ do
    let report = evaluateSimpleJson rules today doc
    _ <- evaluate (reportMatchedRules report)
    pure report

-- | Evaluate one claim end to end: parse the rules, run them, score the
-- claim with the ML service (or its stand-in), and combine the two.
processEvaluation :: EvaluationRequest -> IO (Either String EvaluationResponse)
processEvaluation req = do
  case loadRules (evalRulesText req) of
    Left err -> return $ Left err
    Right engine -> do
      now <- getCurrentTime
      mReport <- evaluateClaim engine (utctDay now) (evalDocument req)
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
