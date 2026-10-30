{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Claims.MLClient".
module Claims.MLClientSpec (mlClientSpec) where

import Data.Aeson (object, (.=))
import Data.Either (isLeft)
import Test.Hspec
import Claims.MLClient

mlClientSpec :: Spec
mlClientSpec = do
  describe "MLClient parser" $ do
    it "parses contract-style risk_score" $ do
      let payload =
            object
              [ "status" .= ("ok" :: String),
                "contract_version" .= ("1.0" :: String),
                "model" .= object ["model_id" .= ("m1" :: String), "model_version" .= ("1.2" :: String)],
                "scores" .= object ["risk_score" .= (0.83 :: Double), "confidence" .= (0.77 :: Double)],
                "top_factors" .= [object ["feature" .= ("f1" :: String), "direction" .= ("up" :: String), "contribution" .= (0.2 :: Double)]]
              ]
      case parseMlResultFromValue payload of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right res -> do
          mlRiskScore res `shouldBe` Just 0.83
          mlStatus res `shouldBe` "ok"

    it "parses fallback ml_probability when risk_score missing" $ do
      let payload =
            object
              [ "status" .= ("ok" :: String),
                "contract_version" .= ("1.0" :: String),
                "model" .= object ["model_id" .= ("m1" :: String), "model_version" .= ("1.2" :: String)],
                "scores" .= object ["ml_probability" .= (0.61 :: Double)]
              ]
      case parseMlResultFromValue payload of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right res -> mlRiskScore res `shouldBe` Just 0.61

    it "rejects missing contract_version" $ do
      let payload =
            object
              [ "status" .= ("ok" :: String),
                "model" .= object ["model_id" .= ("m1" :: String), "model_version" .= ("1.2" :: String)],
                "scores" .= object ["risk_score" .= (0.83 :: Double)]
              ]
      parseMlResultFromValue payload `shouldSatisfy` isLeft

    it "rejects unsupported contract_version" $ do
      let payload =
            object
              [ "status" .= ("ok" :: String),
                "contract_version" .= ("2.0" :: String),
                "model" .= object ["model_id" .= ("m1" :: String), "model_version" .= ("1.2" :: String)],
                "scores" .= object ["risk_score" .= (0.83 :: Double)]
              ]
      parseMlResultFromValue payload `shouldSatisfy` isLeft

    it "rejects missing required scores block for ok status" $ do
      let payload =
            object
              [ "status" .= ("ok" :: String),
                "contract_version" .= ("1.0" :: String),
                "model" .= object ["model_id" .= ("m1" :: String), "model_version" .= ("1.2" :: String)]
              ]
      parseMlResultFromValue payload `shouldSatisfy` isLeft

    it "rejects missing required model fields for ok status" $ do
      let payload =
            object
              [ "status" .= ("ok" :: String),
                "contract_version" .= ("1.0" :: String),
                "model" .= object ["model_id" .= ("m1" :: String)],
                "scores" .= object ["risk_score" .= (0.83 :: Double)]
              ]
      parseMlResultFromValue payload `shouldSatisfy` isLeft
