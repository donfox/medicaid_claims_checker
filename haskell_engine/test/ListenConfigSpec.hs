-- | Startup rules for where the engine listens and whether it uses TLS.
module ListenConfigSpec (listenConfigSpec) where

import Data.Either (isLeft)
import Data.List (isInfixOf)
import Test.Hspec
import Claims.ListenConfig

-- | resolveListen with only some variables set; arguments are
-- ENGINE_HOST, ENGINE_PORT, RULE_ENGINE_TLS_CERT, RULE_ENGINE_TLS_KEY.
resolve :: Maybe String -> Maybe String -> Maybe String -> Maybe String -> Either String ListenConfig
resolve = resolveListen

failsWith :: String -> Either String ListenConfig -> Expectation
failsWith needle result = case result of
  Left msg -> msg `shouldSatisfy` (needle `isInfixOf`)
  Right c -> expectationFailure ("expected a refusal, got " ++ show c)

listenConfigSpec :: Spec
listenConfigSpec = describe "Claims.ListenConfig.resolveListen" $ do
  describe "plain HTTP" $ do
    it "defaults to 127.0.0.1:8080 without TLS" $
      resolve Nothing Nothing Nothing Nothing
        `shouldBe` Right (ListenConfig "127.0.0.1" 8080 Nothing)

    it "treats empty variables as unset" $
      resolve (Just "") (Just "") (Just "") (Just "")
        `shouldBe` Right (ListenConfig "127.0.0.1" 8080 Nothing)

    it "accepts every loopback spelling" $
      mapM_
        (\h -> resolve (Just h) Nothing Nothing Nothing `shouldBe` Right (ListenConfig h 8080 Nothing))
        ["127.0.0.1", "localhost", "::1"]

    it "uses ENGINE_PORT" $
      resolve Nothing (Just "18080") Nothing Nothing
        `shouldBe` Right (ListenConfig "127.0.0.1" 18080 Nothing)

    it "refuses a network address" $
      mapM_
        (\h -> failsWith "not a loopback address" (resolve (Just h) Nothing Nothing Nothing))
        ["0.0.0.0", "::", "10.0.0.5", "engine.internal", "127.0.0.2"]

  describe "TLS" $ do
    it "serves any host when both cert and key are set" $
      resolve (Just "0.0.0.0") (Just "8443") (Just "cert.pem") (Just "key.pem")
        `shouldBe` Right (ListenConfig "0.0.0.0" 8443 (Just ("cert.pem", "key.pem")))

    it "keeps the loopback default when only TLS is set" $
      resolve Nothing Nothing (Just "cert.pem") (Just "key.pem")
        `shouldBe` Right (ListenConfig "127.0.0.1" 8080 (Just ("cert.pem", "key.pem")))

    it "refuses a cert without a key, or a key without a cert" $ do
      failsWith "set both" (resolve Nothing Nothing (Just "cert.pem") Nothing)
      failsWith "set both" (resolve Nothing Nothing Nothing (Just "key.pem"))
      failsWith "set both" (resolve Nothing Nothing (Just "cert.pem") (Just ""))

    it "does not let half a TLS pair open a network address" $
      resolve (Just "0.0.0.0") Nothing (Just "cert.pem") Nothing `shouldSatisfy` isLeft

  describe "ENGINE_PORT" $ do
    it "refuses values that are not a port" $
      mapM_
        (\p -> failsWith "ENGINE_PORT must be a port number" (resolve Nothing (Just p) Nothing Nothing))
        ["abc", "0", "-1", "65536", "80.5", "8080x"]

    it "accepts the ends of the range" $ do
      resolve Nothing (Just "1") Nothing Nothing `shouldBe` Right (ListenConfig "127.0.0.1" 1 Nothing)
      resolve Nothing (Just "65535") Nothing Nothing `shouldBe` Right (ListenConfig "127.0.0.1" 65535 Nothing)
