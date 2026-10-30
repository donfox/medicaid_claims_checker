{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Claims.Parser".
module Claims.ParserSpec (parserSpec) where

import Control.Applicative ((<|>))
import Data.Aeson (object, (.=))
import Data.Either (isLeft, isRight)
import Data.List (isPrefixOf, stripPrefix)
import Data.Text qualified as T
import Data.Time (Day, fromGregorian)
import Test.Hspec
import Claims.Evaluator (evaluateRuleSimple)
import Claims.Parser
import Claims.Syntax
import Prelude hiding (EQ, GT, LT)

-- | Fixed test date: 2026-02-28 (Saturday)
testDay :: Day
testDay = fromGregorian 2026 2 28

parserSpec :: Spec
parserSpec = do
  describe "Rule fixture files" $ do
    validRules <- runIO (fixtureRules <$> readFile "test/fixtures/valid_rules.dsl")
    faultyRules <- runIO (fixtureRules <$> readFile "test/fixtures/faulty_rules.dsl")

    it "finds every rule in both files" $ do
      length validRules `shouldBe` 10
      length faultyRules `shouldBe` 9

    describe "valid_rules.dsl: each rule parses" $
      mapM_ (\(label, text) -> it label $ parseRules text `shouldSatisfy` isRight) validRules

    describe "faulty_rules.dsl: each rule is rejected" $
      mapM_ (\(label, text) -> it label $ parseRules text `shouldSatisfy` isLeft) faultyRules

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

    it "parses OR expression" $ do
      let input = "RULE test \"Test\" WHEN a = \"x\" OR b = \"y\" THEN RISK_SCORE 30;"
      parseRule input `shouldSatisfy` isRight

    it "parses NOT expression" $ do
      let input = "RULE test \"Test\" WHEN NOT field = \"bad\" THEN FLAG_FRAUD \"negation test\";"
      parseRule input `shouldSatisfy` isRight

    it "parses nested boolean expressions" $ do
      let input = "RULE test \"Test\" WHEN (a = \"1\" OR b = \"2\") AND c > 10.0 THEN RISK_SCORE 50;"
      parseRule input `shouldSatisfy` isRight

    it "parses composite actions" $ do
      let input = "RULE test \"Test\" WHEN x = \"y\" THEN [FLAG_FRAUD \"reason\", RISK_SCORE 75];"
      parseRule input `shouldSatisfy` isRight

    it "parses segment-qualified field references" $ do
      let input = "RULE test \"Test\" WHEN CLM.amount > 1000.0 THEN FLAG_FRAUD \"high claim\";"
      parseRule input `shouldSatisfy` isRight

    it "parses loop-qualified field references" $ do
      let input = "RULE test \"Test\" WHEN 2300.CLM.amount > 5000.0 THEN REQUIRE_REVIEW \"review\";"
      parseRule input `shouldSatisfy` isRight

    it "parses multiple rules" $ do
      let input = "RULE r1 \"First\" WHEN TRUE THEN RISK_SCORE 10; RULE r2 \"Second\" WHEN FALSE THEN RISK_SCORE 20;"
      case parseRules input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rules -> length rules `shouldBe` 2

    it "parses LET bindings before WHEN" $ do
      let input =
            "RULE with_let \"Uses LET\" LET amount = claim.amount WHEN amount > 1000 THEN FLAG_FRAUD \"high\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          length (ruleBindings rule) `shouldBe` 1
          bindingName (head (ruleBindings rule)) `shouldBe` "amount"

    it "rejects duplicate LET binding names" $ do
      let input =
            "RULE with_let \"Uses LET\" LET amount = claim.amount LET amount = claim.other WHEN amount > 1000 THEN FLAG_FRAUD \"high\";"
      parseRule input `shouldSatisfy` isLeft

    it "evaluates predicates using LET bindings" $ do
      let input =
            "RULE with_let \"Uses LET\" LET amount = claim.amount WHEN amount > 1000 THEN FLAG_FRAUD \"high\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["amount" .= (1500 :: Int)]]
              result = evaluateRuleSimple testDay doc rule
          resultMatched result `shouldBe` True

    it "parses helper-call predicates" $ do
      let input =
            "RULE helper_rule \"Helper call\" WHEN is_weekend(claim.service_date) THEN REQUIRE_REVIEW \"weekend\";"
      parseRule input `shouldSatisfy` isRight

    it "evaluates is_weekend helper" $ do
      let input =
            "RULE helper_rule \"Helper call\" WHEN is_weekend(claim.service_date) THEN REQUIRE_REVIEW \"weekend\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["service_date" .= ("2026-02-22" :: String)]]
              result = evaluateRuleSimple testDay doc rule
          resultMatched result `shouldBe` True

    it "evaluates is_high_amount helper" $ do
      let input =
            "RULE helper_rule \"Helper call\" WHEN is_high_amount(claim.amount, 50000) THEN FLAG_FRAUD \"high amount\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["amount" .= (75000 :: Int)]]
              result = evaluateRuleSimple testDay doc rule
          resultMatched result `shouldBe` True

    it "evaluates in_list helper" $ do
      let input =
            "RULE helper_rule \"Helper call\" WHEN in_list(claim.state, [\"NY\", \"CA\"]) THEN REQUIRE_REVIEW \"state\";"
      case parseRule input of
        Left err -> expectationFailure $ "Parse failed: " ++ show err
        Right rule -> do
          let doc = object ["claim" .= object ["state" .= ("CA" :: String)]]
              result = evaluateRuleSimple testDay doc rule
          resultMatched result `shouldBe` True

  describe "Helper validation" $ do
    let parseError input = either show (const "") (parseRule input)

    it "rejects an unknown helper name" $
      parseError "RULE t \"T\" WHEN is_weekand(code) THEN FLAG_FRAUD \"x\";"
        `shouldContain` "Unknown helper function: is_weekand"

    it "rejects a known helper called with too few arguments" $
      parseError "RULE t \"T\" WHEN is_date_before(dos) THEN FLAG_FRAUD \"x\";"
        `shouldContain` "is_date_before takes 2 arguments, got 1"

    it "rejects a known helper called with too many arguments" $
      parseError "RULE t \"T\" WHEN is_weekend(dos, other) THEN FLAG_FRAUD \"x\";"
        `shouldContain` "is_weekend takes 1 argument, got 2"

    it "accepts helper names in any letter case, as the evaluator does" $
      parseRule "RULE t \"T\" WHEN IS_WEEKEND(dos) THEN FLAG_FRAUD \"x\";" `shouldSatisfy` isRight

    it "accepts every documented helper with its argument count" $
      mapM_
        (\call -> (call, parseRule ("RULE t \"T\" WHEN " <> call <> " THEN FLAG_FRAUD \"x\";")) `shouldSatisfy` (isRight . snd))
        [ "is_weekend(dos)"
        , "is_high_amount(amount, 500)"
        , "starts_with(code, \"99\")"
        , "in_list(code, [\"A\", \"B\"])"
        , "is_future_date(dos)"
        , "is_date_before(dos, \"1900-01-01\")"
        , "is_valid_npi(npi)"
        , "is_npi_format(npi)"
        , "is_age_valid(dob, 0, 130)"
        ]

-- | The rules in a .dsl fixture file, each with a test label. A rule starts
-- at a line beginning @RULE @ and runs to the next one; @--@ comment lines
-- are left out. A @-- FAULT n: why@ comment adds its reason to the label of
-- the rule after it.
fixtureRules :: String -> [(String, T.Text)]
fixtureRules = go Nothing . lines
  where
    go _ [] = []
    go fault (l : ls)
      | isRule l =
          let (body, rest) = break isRule ls
              label = takeWhile (/= ' ') (drop 5 l) <> maybe "" (\why -> " (" <> why <> ")") fault
              text = T.pack (unlines (l : filter (not . isComment) body))
           in (label, text) : go (lastFault body) rest
      | otherwise = go (faultReason l <|> fault) ls

    isRule = ("RULE " `isPrefixOf`)
    isComment = ("--" `isPrefixOf`)
    lastFault body = foldr (\l acc -> acc <|> faultReason l) Nothing body
    faultReason l = drop 2 . dropWhile (/= ':') <$> stripPrefix "-- FAULT" l
