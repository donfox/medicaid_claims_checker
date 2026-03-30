{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Combines DSL rule results and ML model scores into a single adjudication
-- envelope.  The central function 'buildCombinedEnvelope' applies a
-- threshold-based decision matrix:
--
--   1. Any DSL REJECT action → immediate denial.
--   2. ML service error → fall back to DSL-only (flag for review when DSL
--      rules matched, approve otherwise).
--   3. ML risk score compared against three thresholds (low / high / SIU)
--      to route claims into the appropriate review queue.
--
-- The output 'CombinedEnvelope' is serialised as the JSON response body of
-- the @\/api\/batch-evaluate@ endpoint.
module Claims.PolicyCombiner
  ( -- * Policy configuration
    PolicyConfig (..),
    Thresholds (..),
    FallbackPolicy (..),
    defaultPolicyConfig,

    -- * ML result types
    MLModelInfo (..),
    MLTopFactor (..),
    MLResult (..),
    mlStubResult,
    mlErrorResult,

    -- * Combined output envelope
    CombinedDecision (..),
    CombinedDSL (..),
    CombinedML (..),
    CombinedExplanations (..),
    CombinedAudit (..),
    CombinedEnvelope (..),
    buildCombinedEnvelope,
  )
where

import Data.Aeson (ToJSON)
import Data.Maybe (fromMaybe)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import GHC.Generics (Generic)
import Claims.Syntax (Action' (..), RuleResult (..))

-- | Risk-score thresholds that partition the ML probability space into bands:
--
-- @
--   [0, low)   → low risk  (auto-approve unless DSL flags)
--   [low, high) → medium   (manual review)
--   [high, siu) → high     (fraud priority queue)
--   [siu, 1.0]  → critical (SIU escalation)
-- @
data Thresholds = Thresholds
  { lowThreshold :: Double,
    highThreshold :: Double,
    siuThreshold :: Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON Thresholds

-- | Strategy when the ML service is unavailable.  Currently only
-- 'FallbackDslOnly' is supported (use DSL results alone).
data FallbackPolicy = FallbackDslOnly
  deriving (Show, Eq, Generic)

instance ToJSON FallbackPolicy

-- | Top-level configuration governing how DSL and ML signals are merged.
--
-- * 'allowMlReviewOnApprove' — when @True@, an ML score above the low
--   threshold can still route an otherwise-clean claim to review.
data PolicyConfig = PolicyConfig
  { policyVersion :: Text,
    contractVersion :: Text,
    allowMlReviewOnApprove :: Bool,
    thresholds :: Thresholds,
    fallbackPolicy :: FallbackPolicy
  }
  deriving (Show, Eq, Generic)

instance ToJSON PolicyConfig

-- | Production default: low 0.35, high 0.80, SIU 0.93, ML review enabled.
defaultPolicyConfig :: PolicyConfig
defaultPolicyConfig =
  PolicyConfig
    { policyVersion = "policy_2026_02",
      contractVersion = "1.0",
      allowMlReviewOnApprove = True,
      thresholds = Thresholds 0.35 0.80 0.93,
      fallbackPolicy = FallbackDslOnly
    }

-- | Identity metadata returned by the ML service for audit trails.
data MLModelInfo = MLModelInfo
  { modelId :: Text,
    modelVersion :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON MLModelInfo

-- | A single SHAP-style feature attribution from the ML model.
data MLTopFactor = MLTopFactor
  { feature :: Text,
    direction :: Text,
    contribution :: Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON MLTopFactor

-- | Normalised ML scoring result.  Constructed either from a live ML response
-- ('Claims.MLClient.parseMlResultFromValue'), a stub ('mlStubResult'), or an
-- error sentinel ('mlErrorResult').
data MLResult = MLResult
  { mlStatus :: Text,
    mlRiskScore :: Maybe Double,
    mlConfidence :: Maybe Double,
    mlModelInfo :: Maybe MLModelInfo,
    mlTopFactors :: [MLTopFactor]
  }
  deriving (Show, Eq, Generic)

instance ToJSON MLResult

-- | Deterministic stub for testing without a live ML service.
mlStubResult :: MLResult
mlStubResult =
  MLResult
    { mlStatus = "ok",
      mlRiskScore = Just 0.42,
      mlConfidence = Just 0.74,
      mlModelInfo = Just (MLModelInfo "fraud_stub_v1" "1.0.0"),
      mlTopFactors =
        [ MLTopFactor "provider_30d_outlier_rate" "up" 0.19,
          MLTopFactor "cpt_mix_divergence" "up" 0.12
        ]
    }

-- | Sentinel value used when the ML service call fails.  All score fields
-- are 'Nothing' and 'mlStatus' is @"error"@.
mlErrorResult :: Text -> MLResult
mlErrorResult _errMsg =
  MLResult
    { mlStatus = "error",
      mlRiskScore = Nothing,
      mlConfidence = Nothing,
      mlModelInfo = Nothing,
      mlTopFactors = []
    }

-- | Final adjudication: status (@APPROVE@ | @REJECT@ | @REQUIRE_REVIEW@),
-- machine-readable reason codes, and target queue name.
data CombinedDecision = CombinedDecision
  { status :: Text,
    reasonCodes :: [Text],
    queue :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON CombinedDecision where
  toJSON d =
    Aeson.object
      [ "status" Aeson..= status d,
        "reason_codes" Aeson..= reasonCodes d,
        "queue" Aeson..= queue d
      ]

-- | Summary of DSL rule evaluation: which rules matched and what actions
-- they triggered.
data CombinedDSL = CombinedDSL
  { matchedRules :: [Text],
    actionTypes :: [Text]
  }
  deriving (Show, Eq, Generic)

instance ToJSON CombinedDSL where
  toJSON d =
    Aeson.object
      [ "matched_rules" Aeson..= matchedRules d,
        "actions" Aeson..= actionTypes d
      ]

-- | ML model output projected into the envelope's JSON shape.
data CombinedML = CombinedML
  { statusMl :: Text,
    riskScore :: Maybe Double,
    confidence :: Maybe Double,
    modelIdOut :: Maybe Text,
    modelVersionOut :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON CombinedML where
  toJSON m =
    Aeson.object
      [ "status" Aeson..= statusMl m,
        "risk_score" Aeson..= riskScore m,
        "confidence" Aeson..= confidence m,
        "model_id" Aeson..= modelIdOut m,
        "model_version" Aeson..= modelVersionOut m
      ]

-- | Human-readable explanations: DSL rule detail strings and ML top feature
-- names, surfaced to the UI for adjudicator context.
data CombinedExplanations = CombinedExplanations
  { dsl :: [Text],
    mlTopFactorsOut :: [Text]
  }
  deriving (Show, Eq, Generic)

instance ToJSON CombinedExplanations where
  toJSON e =
    Aeson.object
      [ "dsl" Aeson..= dsl e,
        "ml_top_factors" Aeson..= mlTopFactorsOut e
      ]

-- | Audit metadata stamped on every response for reproducibility.
data CombinedAudit = CombinedAudit
  { policyVersionOut :: Text,
    contractVersionOut :: Text,
    evaluatedAtUtc :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON CombinedAudit where
  toJSON a =
    Aeson.object
      [ "policy_version" Aeson..= policyVersionOut a,
        "contract_version" Aeson..= contractVersionOut a,
        "evaluated_at_utc" Aeson..= evaluatedAtUtc a
      ]

-- | Top-level JSON envelope returned by @\/api\/batch-evaluate@.
data CombinedEnvelope = CombinedEnvelope
  { claimId :: Text,
    decision :: CombinedDecision,
    dslOut :: CombinedDSL,
    mlOut :: CombinedML,
    explanations :: CombinedExplanations,
    audit :: CombinedAudit
  }
  deriving (Show, Eq, Generic)

instance ToJSON CombinedEnvelope where
  toJSON e =
    Aeson.object
      [ "claim_id" Aeson..= claimId e,
        "decision" Aeson..= decision e,
        "dsl" Aeson..= dslOut e,
        "ml" Aeson..= mlOut e,
        "explanations" Aeson..= explanations e,
        "audit" Aeson..= audit e
      ]

-- | Build the combined adjudication envelope from DSL rule results and an ML
-- score.  The decision matrix is applied in priority order:
--
--   1. __DSL REJECT__ — any rule with a REJECT action → immediate denial.
--   2. __ML error__ — service unreachable or non-ok status:
--        * DSL flagged something → @REQUIRE_REVIEW@ (policy_default queue)
--        * No DSL concern       → @APPROVE@ with @ML:error_fallback@ reason
--   3. __ML thresholds__ (only when ML is ok):
--        * score >= SIU   → SIU escalation
--        * score >= high  → fraud priority queue
--        * score >= low   → manual review
--        * score <  low, DSL concern → manual review
--        * score <  low, no concern  → approve
--
-- When 'allowMlReviewOnApprove' is @False@ and no DSL rules matched, the
-- claim is approved regardless of ML score (ML scoring is advisory-only).
buildCombinedEnvelope :: PolicyConfig -> Text -> Text -> [RuleResult] -> MLResult -> CombinedEnvelope
buildCombinedEnvelope cfg claimIdValue evaluatedAt rules mlResult =
  let matched = filter resultMatched rules
      matchedNames = map resultRuleName matched
      flattenedActions = concatMap extractActionTypes matched
      hasReject = elem "REJECT" flattenedActions
      hasDslConcern = not (null matchedNames)
                        && not (all (== "APPROVE") flattenedActions)
      reasonsBase = if null matchedNames then [] else map ("DSL:" <>) matchedNames
      mlReasons = mlReasonCodes cfg mlResult
      -- Priority 1: explicit DSL rejection
      finalDecision
        | hasReject = CombinedDecision "REJECT" (reasonsBase <> ["DSL:reject"]) "denied"
        -- Priority 2: ML service unavailable — fall back to DSL signal
        | mlStatus mlResult /= "ok" =
            if hasDslConcern
              then CombinedDecision "REQUIRE_REVIEW" (reasonsBase <> ["ML:error_fallback"]) "policy_default"
              else CombinedDecision "APPROVE" ["ML:error_fallback"] "none"
        -- Priority 3: threshold-based routing using ML risk score
        | otherwise =
            let score = fromMaybe 0.0 (mlRiskScore mlResult)
                t = thresholds cfg
             in if not (allowMlReviewOnApprove cfg) && not hasDslConcern
                  then CombinedDecision "APPROVE" ("ML:risk_lt_" <> showThreshold (lowThreshold t) : mlReasons) "none"
                  else
                    if score >= siuThreshold t
                      then CombinedDecision "REQUIRE_REVIEW" (reasonsBase <> ["ML:risk_ge_siu"] <> mlReasons) "siu_escalation"
                      else
                        if score >= highThreshold t
                          then CombinedDecision "REQUIRE_REVIEW" (reasonsBase <> ["ML:risk_ge_high"] <> mlReasons) "fraud_priority"
                          else
                            if score >= lowThreshold t
                              then CombinedDecision "REQUIRE_REVIEW" (reasonsBase <> ["ML:risk_ge_low"] <> mlReasons) "manual_review"
                              else
                                if hasDslConcern
                                  then CombinedDecision "REQUIRE_REVIEW" reasonsBase "manual_review"
                                  else CombinedDecision "APPROVE" ("ML:risk_lt_" <> showThreshold (lowThreshold t) : mlReasons) "none"
      mlModelIdOut = modelId <$> mlModelInfo mlResult
      mlModelVersionOut = modelVersion <$> mlModelInfo mlResult
      dslExplanations = map resultDetails matched
      factorNames = map feature (mlTopFactors mlResult)
   in CombinedEnvelope
        { claimId = claimIdValue,
          decision = finalDecision,
          dslOut = CombinedDSL matchedNames flattenedActions,
          mlOut =
            CombinedML
              { statusMl = mlStatus mlResult,
                riskScore = mlRiskScore mlResult,
                confidence = mlConfidence mlResult,
                modelIdOut = mlModelIdOut,
                modelVersionOut = mlModelVersionOut
              },
          explanations = CombinedExplanations dslExplanations factorNames,
          audit =
            CombinedAudit
              { policyVersionOut = policyVersion cfg,
                contractVersionOut = contractVersion cfg,
                evaluatedAtUtc = evaluatedAt
              }
        }

-- | Extract action type tags from a rule result for decision routing.
extractActionTypes :: RuleResult -> [Text]
extractActionTypes result = maybe [] flatten (resultAction result)
  where
    flatten (FlagFraud' _) = ["FLAG_FRAUD"]
    flatten (AssignRiskScore' _) = ["RISK_SCORE"]
    flatten (RequireReview' _) = ["REQUIRE_REVIEW"]
    flatten (RejectClaim' _) = ["REJECT"]
    flatten (ApproveClaim' _) = ["APPROVE"]
    flatten (CompositeAction' actions) = concatMap flatten actions

-- | Render a threshold value as an underscore-separated reason-code suffix
-- (e.g. 0.35 → @"0_35"@).
showThreshold :: Double -> Text
showThreshold d
  | d == 0.35 = "0_35"
  | d == 0.80 = "0_80"
  | d == 0.93 = "0_93"
  | otherwise = "custom"

-- | Compute ML risk-band reason codes based on which threshold bracket the
-- score falls into.
mlReasonCodes :: PolicyConfig -> MLResult -> [Text]
mlReasonCodes cfg res =
  case mlRiskScore res of
    Nothing -> []
    Just score ->
      let t = thresholds cfg
       in if score >= siuThreshold t
            then ["ML:band_siu"]
            else
              if score >= highThreshold t
                then ["ML:band_high"]
                else
                  if score >= lowThreshold t
                    then ["ML:band_medium"]
                    else ["ML:band_low"]
