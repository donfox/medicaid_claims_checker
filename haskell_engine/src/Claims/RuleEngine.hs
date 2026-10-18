{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Claims.RuleEngine
-- Description : Evaluate a rule set against a claim and summarise the result
--
-- Overall risk, from the actions of matched rules:
--
-- * 'CriticalRisk': any 'FlagFraud' or 'RejectClaim'
-- * 'HighRisk': any 'RequireReview', or a risk score >= 70
-- * 'LowRisk': otherwise
--
-- Phoenix flags 'HighRisk' and 'CriticalRisk' claims for analyst review.
-- 'MediumRisk' is kept for the wire format but is not produced.
module Claims.RuleEngine
  ( loadRules
  , evaluateSimpleJson
  , EvaluationReport (..)
  , RiskLevel (..)
  ) where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day)
import Claims.Parser (parseRules)
import Claims.SimpleEvaluator (evaluateRuleSimple)
import Claims.Syntax (Action (..), Rule, RuleResult (..))

-- | Parse a rule set.
loadRules :: Text -> Either String [Rule]
loadRules rulesText = case parseRules rulesText of
  Left err    -> Left $ "Parse error: " ++ show err
  Right rules -> Right rules

-- | Evaluate every rule against one claim.
evaluateSimpleJson :: [Rule] -> Day -> Aeson.Value -> EvaluationReport
evaluateSimpleJson rules today doc =
  let results    = map (evaluateRuleSimple today doc) rules
      matched    = filter resultMatched results
      matchCount = length matched
      undecided  = length (filter resultUndecided results)
      totalCount = length results
      riskLevel  = determineRiskLevel results
      summary    = generateSummary matchCount undecided totalCount riskLevel
  in EvaluationReport
       { reportResults        = results
       , reportTotalRules     = totalCount
       , reportMatchedRules   = matchCount
       , reportUndecidedRules = undecided
       , reportOverallRisk    = riskLevel
       , reportSummary        = summary
       }

-- ----------------------------------------------------------------------------
-- Evaluation Report
-- ----------------------------------------------------------------------------

data EvaluationReport = EvaluationReport
  { reportResults        :: [RuleResult]
  , reportTotalRules     :: Int
  , reportMatchedRules   :: Int
  , reportUndecidedRules :: Int
    -- ^ Rules not checked because data they need is missing
  , reportOverallRisk    :: RiskLevel
  , reportSummary        :: Text
  } deriving (Show)

-- | Overall risk level for a claim based on matched rules.
data RiskLevel
  = LowRisk       -- ^ No significant risk indicators
  | MediumRisk    -- ^ Not currently produced; kept for the wire format
  | HighRisk      -- ^ Review requested, or a risk score >= 70
  | CriticalRisk  -- ^ Fraud flag or rejection triggered
  deriving (Show, Eq, Ord)

-- ----------------------------------------------------------------------------
-- Risk Calculation
-- ----------------------------------------------------------------------------

-- | Overall risk from the matched rules' actions, composites included (see
-- the module header). A rule that asks for review, or scores a claim as
-- high risk, must reach 'HighRisk' on its own so Phoenix flags the claim.
determineRiskLevel :: [RuleResult] -> RiskLevel
determineRiskLevel results
  | any isCritical actions   = CriticalRisk
  | any needsReview actions  = HighRisk
  | otherwise                = LowRisk
  where
    actions = concatMap (maybe [] flattenAction . resultAction) (filter resultMatched results)

    isCritical (FlagFraud _)   = True
    isCritical (RejectClaim _) = True
    isCritical _               = False

    needsReview (RequireReview _)       = True
    needsReview (AssignRiskScore score) = score >= highRiskScore
    needsReview _                       = False

-- | Risk scores at or above this put a claim at 'HighRisk'.
highRiskScore :: Int
highRiskScore = 70

-- | The individual actions inside an action, unpacking composites.
flattenAction :: Action -> [Action]
flattenAction (CompositeAction as) = concatMap flattenAction as
flattenAction a                    = [a]

-- | Generate a human-readable summary of evaluation results.
generateSummary :: Int -> Int -> Int -> RiskLevel -> Text
generateSummary matched undecided total risk = T.concat
  [ "Evaluated ", T.pack (show total), " rules, "
  , T.pack (show matched), " matched"
  , if undecided > 0
      then ", " <> T.pack (show undecided) <> " not checked (missing data). "
      else ". "
  , "Overall risk: ", T.pack (show risk)
  ]
