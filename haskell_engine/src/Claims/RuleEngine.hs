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
* 'HighRisk' - More than 2 rules with risk score >= 70
* 'MediumRisk' - 1-2 rules with risk score >= 70
* 'LowRisk' - No significant risk indicators

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
import Claims.Syntax (Action' (..), Rule, RuleResult (..))

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
      totalCount = length results
      riskLevel  = determineRiskLevel results
      summary    = generateSummary matchCount totalCount riskLevel
  in EvaluationReport
       { reportResults      = results
       , reportTotalRules   = totalCount
       , reportMatchedRules = matchCount
       , reportOverallRisk  = riskLevel
       , reportSummary      = summary
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
  , reportOverallRisk  :: RiskLevel
    -- ^ Aggregated risk assessment
  , reportSummary      :: Text
    -- ^ Human-readable summary
  } deriving (Show)

-- | Overall risk level for a claim based on matched rules.
data RiskLevel
  = LowRisk       -- ^ No significant risk indicators
  | MediumRisk    -- ^ Some elevated risk (1-2 high-risk rules)
  | HighRisk      -- ^ Significant risk (3+ high-risk rules)
  | CriticalRisk  -- ^ Fraud flag or rejection triggered
  deriving (Show, Eq, Ord)

-- ----------------------------------------------------------------------------
-- Risk Calculation
-- ----------------------------------------------------------------------------

-- | Determine overall risk level from rule evaluation results.
--
-- Logic:
--
-- 1. If any rule triggers 'FlagFraud' or 'RejectClaim' → 'CriticalRisk'
-- 2. If 3+ rules have risk score >= 70 → 'HighRisk'
-- 3. If 1-2 rules have risk score >= 70 → 'MediumRisk'
-- 4. Otherwise → 'LowRisk'
determineRiskLevel :: [RuleResult] -> RiskLevel
determineRiskLevel results =
  let matchedResults = filter resultMatched results
      hasReject      = any isRejectAction matchedResults
      hasFraud       = any isFraudFlag matchedResults
      highRiskCount  = length $ filter isHighRiskAction matchedResults
  in if hasReject || hasFraud
     then CriticalRisk
     else if highRiskCount > 2
          then HighRisk
          else if highRiskCount > 0
               then MediumRisk
               else LowRisk

-- | Check if a result contains a reject action.
isRejectAction :: RuleResult -> Bool
isRejectAction result = case resultAction result of
  Just (RejectClaim' _)         -> True
  Just (CompositeAction' actions) -> any isReject actions
  _                             -> False
  where
    isReject (RejectClaim' _) = True
    isReject _                = False

-- | Check if a result contains a fraud flag action.
isFraudFlag :: RuleResult -> Bool
isFraudFlag result = case resultAction result of
  Just (FlagFraud' _)           -> True
  Just (CompositeAction' actions) -> any isFraud actions
  _                             -> False
  where
    isFraud (FlagFraud' _) = True
    isFraud _              = False

-- | Check if a result contains a high risk score (>= 70).
isHighRiskAction :: RuleResult -> Bool
isHighRiskAction result = case resultAction result of
  Just (AssignRiskScore' score)   -> score >= 70
  Just (CompositeAction' actions) -> any isHighRisk actions
  _                               -> False
  where
    isHighRisk (AssignRiskScore' score) = score >= 70
    isHighRisk _                        = False

-- | Generate a human-readable summary of evaluation results.
generateSummary :: Int -> Int -> RiskLevel -> Text
generateSummary matched total risk = T.concat
  [ "Evaluated ", T.pack (show total), " rules, "
  , T.pack (show matched), " matched. "
  , "Overall risk: ", T.pack (show risk)
  ]
