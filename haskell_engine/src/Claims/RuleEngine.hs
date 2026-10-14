{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Claims.RuleEngine
Description : High-level API for loading and evaluating fraud detection rules
Stability   : experimental

This module provides the main entry point for the fraud detection rule engine.
It orchestrates rule loading, document evaluation, and result aggregation.

== Typical Usage

@
import Claims.RuleEngine
import Data.Aeson (decode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T

main :: IO ()
main = do
    -- Load rules from a file
    rulesText <- readFile "rules.dsl"
    let Right engine = loadRules (T.pack rulesText)

    -- Load and evaluate a claim
    claimJson <- BL.readFile "claim.json"
    let Just claim = decode claimJson
        report = evaluateSimpleJson engine claim

    -- Check results
    print $ reportOverallRisk report
    mapM_ print $ filter resultMatched $ reportResults report
@

== Risk Level Determination

The engine assigns an overall risk level based on matched rules:

* 'CriticalRisk' - Any 'FlagFraud' or 'RejectClaim' action
* 'HighRisk' - Any 'RequireReview' action, or any risk score >= 70
* 'LowRisk' - No significant risk indicators

'MediumRisk' is kept for the wire format but is not currently produced.

== Thread Safety

The 'RuleEngine' is immutable once created and can be safely shared
across threads for concurrent evaluation.
-}
module Claims.RuleEngine
  ( -- * Rule Engine
    RuleEngine
  , newRuleEngine
  , loadRules
  , engineRules
    -- * Evaluation
  , evaluateSimpleJson
    -- * Results
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

-- ----------------------------------------------------------------------------
-- Rule Engine
-- ----------------------------------------------------------------------------

-- | Container for loaded fraud detection rules.
--
-- Create with 'newRuleEngine' (empty) or 'loadRules' (from DSL text).
-- Once created, the engine is immutable and thread-safe.
data RuleEngine = RuleEngine
  { engineRules :: [Rule]
    -- ^ The loaded rules (in order they were defined)
  } deriving (Show)

-- | Create an empty rule engine with no rules loaded.
--
-- Useful as a starting point or for testing.
newRuleEngine :: RuleEngine
newRuleEngine = RuleEngine []

-- | Parse DSL text and create a rule engine.
--
-- Returns 'Left' with an error message if parsing fails,
-- or 'Right' with the loaded engine on success.
--
-- ==== Example
--
-- @
-- case loadRules rulesText of
--   Left err     -> putStrLn $ "Failed to load rules: " ++ err
--   Right engine -> print $ length (engineRules engine)
-- @
loadRules :: Text -> Either String RuleEngine
loadRules rulesText = case parseRules rulesText of
  Left err    -> Left $ "Parse error: " ++ show err
  Right rules -> Right $ RuleEngine rules

-- ----------------------------------------------------------------------------
-- Evaluation
-- ----------------------------------------------------------------------------

-- | Evaluate a JSON document against all loaded rules.
--
-- Uses "Claims.SimpleEvaluator" which works with any JSON structure.
-- This is the recommended evaluation function for most use cases.
--
-- ==== Example
--
-- @
-- let claim = Aeson.object ["amount" .= (15000 :: Int), "provider" .= "NPI123"]
--     report = evaluateSimpleJson engine claim
-- when (reportOverallRisk report >= HighRisk) $
--   flagForReview claim
-- @
evaluateSimpleJson :: RuleEngine -> Day -> Aeson.Value -> EvaluationReport
evaluateSimpleJson engine today doc =
  let results    = map (evaluateRuleSimple today doc) (engineRules engine)
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

-- | Comprehensive report from evaluating all rules against a document.
data EvaluationReport = EvaluationReport
  { reportResults      :: [RuleResult]
    -- ^ Individual result for each rule
  , reportTotalRules   :: Int
    -- ^ Total number of rules evaluated
  , reportMatchedRules :: Int
    -- ^ Number of rules that matched
  , reportUndecidedRules :: Int
    -- ^ Number of rules that could not be decided because of missing data
  , reportOverallRisk  :: RiskLevel
    -- ^ Aggregated risk assessment
  , reportSummary      :: Text
    -- ^ Human-readable summary
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

-- | Determine overall risk level from rule evaluation results.
--
-- Logic, over the actions of matched rules (composite actions included):
--
-- 1. Any 'FlagFraud' or 'RejectClaim' → 'CriticalRisk'
-- 2. Any 'RequireReview', or any risk score >= 70 → 'HighRisk'
-- 3. Otherwise → 'LowRisk'
--
-- Phoenix counts HighRisk and CriticalRisk as flagged for analyst review,
-- so a rule that asks for review, or scores a claim as high risk, must
-- reach at least 'HighRisk' on its own. 'MediumRisk' is not produced.
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
