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

  describe "Values that could never be compared are parse errors" $ do
    let parseError cond = either show (const "") (parseRule ("RULE t \"T\" WHEN " <> cond <> " THEN FLAG_FRAUD \"x\";"))

    it "an unquoted code in claim.has_procedure / claim.has_diagnosis" $ do
      parseError "claim.has_procedure 99285" `shouldContain` "claim.has_procedure needs a quoted code"
      parseError "claim.has_diagnosis E11" `shouldContain` "claim.has_diagnosis needs a quoted code"
    it "a quoted number with >, <, >= or <=" $
      mapM_
        (\op -> parseError ("amount " <> op <> " \"10000\"") `shouldContain` "A quoted value cannot be compared with")
        [">", "<", ">=", "<="]
    it "BETWEEN with text or field bounds" $ do
      parseError "amount BETWEEN \"1\" AND \"9\"" `shouldContain` "BETWEEN needs number bounds"
      parseError "amount BETWEEN low AND high" `shouldContain` "BETWEEN needs number bounds"
    it "= or != with a list" $ do
      parseError "code = [\"A\", \"B\"]" `shouldContain` "use in_list"
      parseError "code != [1, 2]" `shouldContain` "use in_list"
    it "still accepts the forms that work" $
      mapM_
        (\cond -> (cond, parseError cond) `shouldBe` (cond, ""))
        [ "claim.has_procedure \"99285\""
        , "amount > 10000"
        , "amount > other.amount"
        , "code = \"A\""
        , "code != 99213"
        , "amount BETWEEN 100 AND 500.5"
        , "amount BETWEEN -5 AND 5"
        ]

  describe "Numbers too large to use are parse errors" $ do
    let parseError input = either show (const "") (parseRule input)
    it "a COUNT number that would wrap around" $
      parseError "RULE t \"T\" WHEN COUNT(service_lines) > 18446744073709551615 THEN REJECT \"x\";"
        `shouldContain` "COUNT is compared with a number from 0 to 1000000"
    it "a RISK_SCORE that would wrap around into 0-100" $
      parseError "RULE t \"T\" WHEN TRUE THEN RISK_SCORE 18446744073709551666;"
        `shouldContain` "RISK_SCORE must be in range 0-100"
    it "a number too large for a Double" $
      parseError ("RULE t \"T\" WHEN amount > 1" <> T.replicate 400 "0" <> " THEN REJECT \"x\";")
        `shouldContain` "Number is too large"

  describe "Comments and line breaks anywhere between words" $ do
    let parses input = parseRule input `shouldSatisfy` isRight
    it "after WHERE and IN" $
      parses "RULE t \"T\" WHEN EXISTS l IN -- the lines\n service_lines WHERE -- note\n l.code = \"A\" THEN REJECT \"x\";"
    it "inside parentheses" $
      parses "RULE t \"T\" WHEN ( -- note\n amount > 5 -- why\n ) THEN REJECT \"x\";"
    it "inside helper arguments and lists" $
      parses "RULE t \"T\" WHEN in_list(code, -- codes\n [\"A\", -- first\n \"B\"]) THEN REJECT \"x\";"
    it "inside COUNT(...) and before its number" $
      parses "RULE t \"T\" WHEN COUNT( -- lines\n service_lines ) -- how many\n > 3 THEN REJECT \"x\";"
    it "inside IS NOT NULL, with extra spaces or a line break" $ do
      parses "RULE t \"T\" WHEN npi IS NOT  NULL THEN REJECT \"x\";"
      parses "RULE t \"T\" WHEN npi IS\n NOT\n NULL THEN REJECT \"x\";"
    it "inside a composite action" $
      parses "RULE t \"T\" WHEN TRUE THEN [ -- both\n REJECT \"a\", -- and\n RISK_SCORE 90 ];"

  describe "Nesting" $ do
    let deepQuantifiers n = T.concat ["RULE d \"d\" WHEN ", T.replicate n "EXISTS service_lines WHERE ", "TRUE THEN REJECT \"x\";"]
    it "nested quantifiers count towards the depth limit" $ do
      parseRule (deepQuantifiers 50) `shouldSatisfy` isRight
      either show (const "") (parseRule (deepQuantifiers 51)) `shouldContain` "Predicate nesting exceeds the maximum depth"
    it "NOT may be repeated" $
      parseRule "RULE t \"T\" WHEN NOT NOT amount > 5 THEN REJECT \"x\";"
        `shouldBe` parseRule "RULE t \"T\" WHEN NOT (NOT amount > 5) THEN REJECT \"x\";"

  describe "A WHERE runs to the end of the condition" $ do
    let condOf input = either (error . show) ruleCondition (parseRule input)
        lines' = Path ["service_lines"]
        code = Compare EQ (Path ["procedure_code"]) (StringValue "99285")
        amount = Compare GT (Path ["financial", "claim_amount"]) (NumberValue 10000)
    it "an AND after WHERE is inside the quantifier" $
      condOf "RULE t \"T\" WHEN EXISTS service_lines WHERE procedure_code = \"99285\" AND financial.claim_amount > 10000 THEN REJECT \"x\";"
        `shouldBe` Exists Nothing lines' (And code amount)
    it "parentheses end the quantifier" $
      condOf "RULE t \"T\" WHEN (EXISTS service_lines WHERE procedure_code = \"99285\") AND financial.claim_amount > 10000 THEN REJECT \"x\";"
        `shouldBe` And (Exists Nothing lines' code) amount

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
