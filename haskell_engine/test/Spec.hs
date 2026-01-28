module Main (main) where

import Test.Hspec
import X12.DSL.Parser
import X12.DSL.Syntax

main :: IO ()
main = hspec $ do
  describe "DSL Parser" $ do
    it "parses simple equality predicate" $ do
      let input = "RULE test \"Test rule\" WHEN field = \"value\" THEN FLAG_FRAUD \"test\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          ruleName rule `shouldBe` "test"
          ruleDescription rule `shouldBe` "Test rule"

    it "parses numeric comparison" $ do
      let input = "RULE test \"Test\" WHEN amount > 100.0 THEN RISK_SCORE 50;"
      parseRule input `shouldSatisfy` isRight

    it "parses complex AND expression" $ do
      let input = "RULE test \"Test\" WHEN field1 = \"a\" AND field2 > 10.0 THEN REJECT \"fail\";"
      parseRule input `shouldSatisfy` isRight

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _ = False
