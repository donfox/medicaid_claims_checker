{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Claims.Pipeline".
module Claims.PipelineSpec (pipelineSpec) where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Either (isRight)
import Data.Maybe (isJust, isNothing)
import Data.Time (fromGregorian)
import Network.HTTP.Types (status400, status503)
import Test.Hspec
import Claims.Parser (loadRules)
import Claims.Pipeline

pipelineSpec :: Spec
pipelineSpec = do
  describe "Single-claim evaluation errors" $ do
    let request rules =
          EvaluationRequest "1.0" "req_1" "claim_1" "payer_a" rules (object ["amount" .= (100 :: Int)]) Nothing
        isRulesError (Left (RulesError _)) = True
        isRulesError _ = False

    it "rules that do not parse are a RulesError, answered with 400" $ do
      result <- processEvaluation (request "RULE broken")
      result `shouldSatisfy` isRulesError
      fst (evaluationErrorJSON (RulesError "x")) `shouldBe` status400

    it "a timeout is answered with 503 and reason \"timeout\", as the batch endpoint reports it" $
      evaluationErrorJSON TimedOut
        `shouldBe` ( status503,
                     object
                       [ "error" .= ("evaluation timed out after 30 s" :: String),
                         "reason" .= ("timeout" :: String)
                       ]
                   )

    it "valid rules give a report" $ do
      result <- processEvaluation (request "RULE r \"d\" WHEN amount > 5 THEN REQUIRE_REVIEW \"x\";")
      result `shouldSatisfy` isRight

  describe "The per-claim time limit" $ do
    let rules = either error id (loadRules "RULE f \"d\" WHEN FORALL l IN service_lines WHERE l.amount > 0 THEN REJECT \"x\";")
        bigClaim = object ["service_lines" .= replicate 200000 (object [])]
        today = fromGregorian 2026 2 28

    it "gives up when the claim takes longer than the limit" $ do
      result <- evaluateClaimWithin 1000 rules today bigClaim
      result `shouldSatisfy` isNothing

    it "returns the report when there is time" $ do
      result <- evaluateClaimWithin 30000000 rules today (object ["service_lines" .= [object ["amount" .= (5 :: Int)]]])
      result `shouldSatisfy` isJust

  describe "Evaluation request contract" $ do
    it "accepts valid evaluate request contract payload" $ do
      let payload =
            object
              [ "contract_version" .= ("1.0" :: String),
                "request_id" .= ("req_1" :: String),
                "claim_id" .= ("claim_1" :: String),
                "tenant_id" .= ("payer_a" :: String),
                "rulesText" .= ("RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;" :: String),
                "document" .= object ["amount" .= (100 :: Int)]
              ]
      (Aeson.fromJSON payload :: Aeson.Result EvaluationRequest) `shouldSatisfy` isAesonSuccess

    it "rejects missing request_id" $ do
      let payload =
            object
              [ "contract_version" .= ("1.0" :: String),
                "claim_id" .= ("claim_1" :: String),
                "tenant_id" .= ("payer_a" :: String),
                "rulesText" .= ("RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;" :: String),
                "document" .= object ["amount" .= (100 :: Int)]
              ]
      (Aeson.fromJSON payload :: Aeson.Result EvaluationRequest) `shouldSatisfy` isAesonError

    it "rejects unsupported request contract_version" $ do
      let payload =
            object
              [ "contract_version" .= ("2.0" :: String),
                "request_id" .= ("req_1" :: String),
                "claim_id" .= ("claim_1" :: String),
                "tenant_id" .= ("payer_a" :: String),
                "rulesText" .= ("RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;" :: String),
                "document" .= object ["amount" .= (100 :: Int)]
              ]
      (Aeson.fromJSON payload :: Aeson.Result EvaluationRequest) `shouldSatisfy` isAesonError

    it "rejects empty tenant_id" $ do
      let payload =
            object
              [ "contract_version" .= ("1.0" :: String),
                "request_id" .= ("req_1" :: String),
                "claim_id" .= ("claim_1" :: String),
                "tenant_id" .= ("   " :: String),
                "rulesText" .= ("RULE r \"d\" WHEN TRUE THEN RISK_SCORE 10;" :: String),
                "document" .= object ["amount" .= (100 :: Int)]
              ]
      (Aeson.fromJSON payload :: Aeson.Result EvaluationRequest) `shouldSatisfy` isAesonError

isAesonSuccess :: Aeson.Result a -> Bool
isAesonSuccess (Aeson.Success _) = True
isAesonSuccess _ = False

isAesonError :: Aeson.Result a -> Bool
isAesonError (Aeson.Error _) = True
isAesonError _ = False
