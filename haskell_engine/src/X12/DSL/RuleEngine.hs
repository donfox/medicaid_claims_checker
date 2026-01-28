{-# LANGUAGE OverloadedStrings #-}

module X12.DSL.RuleEngine
    ( RuleEngine
    , newRuleEngine
    , loadRules
    , evaluateDocument
    , evaluateSimpleJson
    , EvaluationReport(..)
    ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Aeson as Aeson
import X12.DSL.Syntax
import X12.DSL.Parser
import X12.DSL.Evaluator
import X12.DSL.SimpleEvaluator (evaluateRuleSimple)
import X12.DSL.X12Types

-- | Rule engine that holds loaded rules
data RuleEngine = RuleEngine
    { engineRules :: [Rule]
    } deriving (Show)

-- | Comprehensive evaluation report
data EvaluationReport = EvaluationReport
    { reportResults :: [RuleResult]
    , reportTotalRules :: Int
    , reportMatchedRules :: Int
    , reportOverallRisk :: RiskLevel
    , reportSummary :: Text
    } deriving (Show)

data RiskLevel = LowRisk | MediumRisk | HighRisk | CriticalRisk
    deriving (Show, Eq, Ord)

-- | Create a new rule engine
newRuleEngine :: RuleEngine
newRuleEngine = RuleEngine []

-- | Load rules from text into the engine
loadRules :: Text -> Either String RuleEngine
loadRules rulesText = case parseRules rulesText of
    Left err -> Left $ "Parse error: " ++ show err
    Right rules -> Right $ RuleEngine rules

-- | Evaluate an X12 document against all loaded rules
evaluateDocument :: RuleEngine -> X12Document -> EvaluationReport
evaluateDocument engine doc =
    let results = map (evaluateRule doc) (engineRules engine)
        matched = filter resultMatched results
        matchCount = length matched
        totalCount = length results
        riskLevel = determineRiskLevel results
        summary = generateSummary matchCount totalCount riskLevel
    in EvaluationReport results totalCount matchCount riskLevel summary

-- | Evaluate any JSON document against all loaded rules (simple mode)
evaluateSimpleJson :: RuleEngine -> Aeson.Value -> EvaluationReport
evaluateSimpleJson engine doc =
    let results = map (evaluateRuleSimple doc) (engineRules engine)
        matched = filter resultMatched results
        matchCount = length matched
        totalCount = length results
        riskLevel = determineRiskLevel results
        summary = generateSummary matchCount totalCount riskLevel
    in EvaluationReport results totalCount matchCount riskLevel summary

-- | Determine overall risk level from rule results
determineRiskLevel :: [RuleResult] -> RiskLevel
determineRiskLevel results =
    let matchedResults = filter resultMatched results
        hasReject = any isRejectAction matchedResults
        hasFraud = any isFraudFlag matchedResults
        highRiskCount = length $ filter isHighRiskAction matchedResults
    in if hasReject || hasFraud
       then CriticalRisk
       else if highRiskCount > 2
            then HighRisk
            else if highRiskCount > 0
                 then MediumRisk
                 else LowRisk

isRejectAction :: RuleResult -> Bool
isRejectAction result = case resultAction result of
    Just (RejectClaim' _) -> True
    Just (CompositeAction' actions) -> any isRejectAction' actions
    _ -> False
  where
    isRejectAction' (RejectClaim' _) = True
    isRejectAction' _ = False

isFraudFlag :: RuleResult -> Bool
isFraudFlag result = case resultAction result of
    Just (FlagFraud' _) -> True
    Just (CompositeAction' actions) -> any isFraudFlag' actions
    _ -> False
  where
    isFraudFlag' (FlagFraud' _) = True
    isFraudFlag' _ = False

isHighRiskAction :: RuleResult -> Bool
isHighRiskAction result = case resultAction result of
    Just (AssignRiskScore' score) -> score >= 70
    Just (CompositeAction' actions) -> any isHighRiskAction' actions
    _ -> False
  where
    isHighRiskAction' (AssignRiskScore' score) = score >= 70
    isHighRiskAction' _ = False

generateSummary :: Int -> Int -> RiskLevel -> Text
generateSummary matched total risk =
    T.concat
        [ "Evaluated ", T.pack (show total), " rules, "
        , T.pack (show matched), " matched. "
        , "Overall risk: ", T.pack (show risk)
        ]
