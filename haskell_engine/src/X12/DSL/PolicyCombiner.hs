{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module X12.DSL.PolicyCombiner
  ( PolicyConfig (..),
    Thresholds (..),
    FallbackPolicy (..),
    MLModelInfo (..),
    MLTopFactor (..),
    MLResult (..),
    defaultPolicyConfig,
    mlStubResult,
    mlErrorResult,
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
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import GHC.Generics (Generic)
import X12.DSL.X12Types (Action' (..), RuleResult (..))

data Thresholds = Thresholds
  { lowThreshold :: Double,
    highThreshold :: Double,
    siuThreshold :: Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON Thresholds

data FallbackPolicy = FallbackDslOnly
  deriving (Show, Eq, Generic)

instance ToJSON FallbackPolicy

data PolicyConfig = PolicyConfig
  { policyVersion :: Text,
    contractVersion :: Text,
    allowMlReviewOnApprove :: Bool,
    thresholds :: Thresholds,
    fallbackPolicy :: FallbackPolicy
  }
  deriving (Show, Eq, Generic)

instance ToJSON PolicyConfig

defaultPolicyConfig :: PolicyConfig
defaultPolicyConfig =
  PolicyConfig
    { policyVersion = "policy_2026_02",
      contractVersion = "1.0",
      allowMlReviewOnApprove = True,
      thresholds = Thresholds 0.35 0.80 0.93,
      fallbackPolicy = FallbackDslOnly
    }

data MLModelInfo = MLModelInfo
  { modelId :: Text,
    modelVersion :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON MLModelInfo

data MLTopFactor = MLTopFactor
  { feature :: Text,
    direction :: Text,
    contribution :: Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON MLTopFactor

data MLResult = MLResult
  { mlStatus :: Text,
    mlRiskScore :: Maybe Double,
    mlConfidence :: Maybe Double,
    mlModelInfo :: Maybe MLModelInfo,
    mlTopFactors :: [MLTopFactor]
  }
  deriving (Show, Eq, Generic)

instance ToJSON MLResult

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

mlErrorResult :: Text -> MLResult
mlErrorResult _errMsg =
  MLResult
    { mlStatus = "error",
      mlRiskScore = Nothing,
      mlConfidence = Nothing,
      mlModelInfo = Nothing,
      mlTopFactors = []
    }

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

buildCombinedEnvelope :: PolicyConfig -> Text -> Text -> [RuleResult] -> MLResult -> CombinedEnvelope
buildCombinedEnvelope cfg claimIdValue evaluatedAt rules mlResult =
  let matched = filter resultMatched rules
      matchedNames = map resultRuleName matched
      flattenedActions = concatMap extractActionTypes matched
      hasReject = any (== "REJECT") flattenedActions
      hasDslConcern = not (null matchedNames)
      reasonsBase = if null matchedNames then [] else map ("DSL:" <>) matchedNames
      mlReasons = mlReasonCodes cfg mlResult
      finalDecision
        | hasReject = CombinedDecision "REJECT" (reasonsBase <> ["DSL:reject"]) "denied"
        | mlStatus mlResult /= "ok" =
            if hasDslConcern
              then CombinedDecision "REQUIRE_REVIEW" (reasonsBase <> ["ML:error_fallback"]) "policy_default"
              else CombinedDecision "APPROVE" ["ML:error_fallback"] "none"
        | otherwise =
            let score = maybe 0.0 id (mlRiskScore mlResult)
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

extractActionTypes :: RuleResult -> [Text]
extractActionTypes result =
  case resultAction result of
    Nothing -> []
    Just action -> flatten action
  where
    flatten (FlagFraud' _) = ["FLAG_FRAUD"]
    flatten (AssignRiskScore' _) = ["RISK_SCORE"]
    flatten (RequireReview' _) = ["REQUIRE_REVIEW"]
    flatten (RejectClaim' _) = ["REJECT"]
    flatten (CompositeAction' actions) = concatMap flatten actions

showThreshold :: Double -> Text
showThreshold d
  | d == 0.35 = "0_35"
  | d == 0.80 = "0_80"
  | d == 0.93 = "0_93"
  | otherwise = "custom"

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
