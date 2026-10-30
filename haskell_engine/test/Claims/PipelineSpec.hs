{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Claims.Pipeline".
module Claims.PipelineSpec (pipelineSpec) where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Test.Hspec
import Claims.Pipeline (EvaluationRequest (..))

pipelineSpec :: Spec
pipelineSpec = do
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
