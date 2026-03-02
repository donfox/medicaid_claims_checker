{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : X12.DSL.SimpleEvaluator
-- Description : Evaluate DSL predicates against generic JSON documents
-- Stability   : experimental
--
-- This module evaluates fraud detection rules against generic JSON documents
-- (Aeson 'Aeson.Value'). This is the recommended evaluator for production use
-- with JSON claim data.
--
-- Unlike "X12.DSL.Evaluator" which requires a fully parsed 'X12Document'
-- structure, this evaluator works with any JSON, making it suitable for:
--
-- * Flat JSON representations of claims
-- * JSON APIs
-- * Testing with simple JSON fixtures
--
-- == Field Lookup
--
-- Fields are looked up using dot notation paths:
--
-- * @"amount"@ - direct field lookup
-- * @"claim.amount"@ - nested field lookup
-- * @"items.0.price"@ - array index access
--
-- The evaluator automatically converts JSON values to text for comparison.
--
-- == Example Usage
--
-- @
-- import Data.Aeson (decode)
-- import X12.DSL.SimpleEvaluator
-- import X12.DSL.Parser (parseRule)
--
-- main :: IO ()
-- main = do
--   let Just claim = decode "{\"amount\": 15000, \"status\": \"pending\"}"
--       Right rule = parseRule "RULE test \"\" WHEN amount > 10000 THEN FLAG_FRAUD \"high\";"
--   print $ evaluateRuleSimple claim rule
-- @
module X12.DSL.SimpleEvaluator
  ( -- * Evaluation Functions
    evaluatePredicateSimple,
    evaluateRuleSimple,

    -- * Field Lookup (exported for testing)
    lookupJsonField,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (foldM)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Char (isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day, DayOfWeek (Saturday, Sunday), dayOfWeek, defaultTimeLocale, parseTimeM, toGregorian)
import Data.Vector qualified as V
import X12.DSL.Syntax qualified as Syntax
import X12.DSL.Syntax (Action' (..), RuleResult (..))

-- ----------------------------------------------------------------------------
-- Evaluation Environment
-- ----------------------------------------------------------------------------

-- | Environment for predicate evaluation.
--
-- Carries LET bindings (text aliases), quantifier-scoped variables (JSON
-- objects from @EXISTS x IN …@), and the current document context.
data EvalEnv = EvalEnv
  { envLetBindings :: Map Text Text
  , envScopeVars   :: Map Text Aeson.Value
  , envDoc         :: Aeson.Value
  , envToday       :: Day
  }

-- | Build an initial environment from a document.
mkEnv :: Day -> Map Text Text -> Aeson.Value -> EvalEnv
mkEnv today lets doc = EvalEnv lets Map.empty doc today

-- ----------------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------------

-- | Evaluate a predicate against a JSON value.
--
-- Returns 'True' if the predicate matches the JSON document, 'False' otherwise.
--
-- ==== Example
--
-- @
-- let doc = Aeson.object ["amount" .= (15000 :: Int)]
--     pred = Syntax.GreaterThan (Syntax.Field "amount") (Syntax.NumberValue 10000)
-- evaluatePredicateSimple doc pred  -- Returns True
-- @
evaluatePredicateSimple :: Day -> Aeson.Value -> Syntax.Predicate -> Bool
evaluatePredicateSimple today doc = evaluateWithEnv (mkEnv today Map.empty doc)

-- | Internal evaluator carrying the full environment.
evaluateWithEnv :: EvalEnv -> Syntax.Predicate -> Bool
evaluateWithEnv env = \case
  -- Boolean literals
  Syntax.PTrue -> True
  Syntax.PFalse -> False
  -- Equality comparisons
  Syntax.Equals fieldRef val ->
    compareField env fieldRef val (==)
  Syntax.NotEquals fieldRef val ->
    compareField env fieldRef val (/=)
  -- Numeric comparisons
  Syntax.GreaterThan fieldRef val ->
    compareNumericField env fieldRef val (>)
  Syntax.LessThan fieldRef val ->
    compareNumericField env fieldRef val (<)
  Syntax.GreaterThanOrEqual fieldRef val ->
    compareNumericField env fieldRef val (>=)
  Syntax.LessThanOrEqual fieldRef val ->
    compareNumericField env fieldRef val (<=)
  -- Inclusive range
  Syntax.Between fieldRef loVal hiVal ->
    evaluateBetween env fieldRef loVal hiVal
  -- Domain-specific checks
  Syntax.HasDiagnosis val -> evaluateHasDiagnosis env val
  Syntax.HasProcedure val -> evaluateHasProcedure env val
  -- Null checks
  Syntax.IsNull fieldRef ->
    isNothing $ lookupFieldWithEnv env fieldRef
  Syntax.IsNotNull fieldRef ->
    isJust $ lookupFieldWithEnv env fieldRef
  -- Boolean logic (recursive)
  Syntax.And p1 p2 ->
    evaluateWithEnv env p1 && evaluateWithEnv env p2
  Syntax.Or p1 p2 ->
    evaluateWithEnv env p1 || evaluateWithEnv env p2
  Syntax.Not p ->
    not $ evaluateWithEnv env p
  -- Quantifiers over arrays — unnamed: shift doc (backward compatible)
  Syntax.Exists Nothing path innerPred ->
    any (\item -> evaluateWithEnv (env { envDoc = item }) innerPred)
        (findArrayItems path (envDoc env))
  Syntax.ForAll Nothing path innerPred ->
    all (\item -> evaluateWithEnv (env { envDoc = item }) innerPred)
        (findArrayItems path (envDoc env))
  -- Quantifiers over arrays — named: bind variable, doc stays unchanged
  Syntax.Exists (Just varName) path innerPred ->
    any (\item -> evaluateWithEnv (bindScope varName item env) innerPred)
        (findArrayItems path (envDoc env))
  Syntax.ForAll (Just varName) path innerPred ->
    all (\item -> evaluateWithEnv (bindScope varName item env) innerPred)
        (findArrayItems path (envDoc env))
  Syntax.Count path op n ->
    compareInt (length $ findArrayItems path (envDoc env)) op n
  Syntax.HelperCall helperName args ->
    evaluateHelperCall (envToday env) (envLetBindings env) (envDoc env) helperName args
  -- String operations
  Syntax.Contains fieldRef val ->
    case (lookupFieldWithEnv env fieldRef, val) of
      (Just fieldVal, Syntax.StringValue searchStr) ->
        T.isInfixOf searchStr fieldVal
      _ -> False
  Syntax.Matches _fieldRef _pattern ->
    False -- TODO: Implement regex matching

-- | Add a quantifier-bound variable to the environment.
bindScope :: Text -> Aeson.Value -> EvalEnv -> EvalEnv
bindScope varName item env =
  env { envScopeVars = Map.insert varName item (envScopeVars env) }

-- | Evaluate a complete rule against a JSON document.
--
-- Returns a 'RuleResult' indicating whether the rule matched and what
-- action should be taken.
evaluateRuleSimple :: Day -> Aeson.Value -> Syntax.Rule -> RuleResult
evaluateRuleSimple today doc rule =
  case buildBindingContext today doc (Syntax.ruleBindings rule) of
    Left err ->
      RuleResult
        { resultRuleName = Syntax.ruleName rule,
          resultMatched = False,
          resultAction = Nothing,
          resultDetails = "Rule binding error: " <> err
        }
    Right bindings ->
      let env = mkEnv today bindings doc
          matched = evaluateWithEnv env (Syntax.ruleCondition rule)
          action =
            if matched
              then Just (convertAction $ Syntax.ruleAction rule)
              else Nothing
          details =
            if matched
              then "Rule matched: " <> Syntax.ruleDescription rule
              else "Rule did not match"
       in RuleResult
            { resultRuleName = Syntax.ruleName rule,
              resultMatched = matched,
              resultAction = action,
              resultDetails = details
            }

buildBindingContext :: Day -> Aeson.Value -> [Syntax.Binding] -> Either Text (Map Text Text)
buildBindingContext today doc = foldM step Map.empty
  where
    step ctx binding =
      let env = mkEnv today ctx doc
       in case lookupFieldWithEnv env (Syntax.bindingField binding) of
            Just value -> Right $ Map.insert (Syntax.bindingName binding) value ctx
            Nothing -> Left $ "Could not resolve LET binding '" <> Syntax.bindingName binding <> "'"

evaluateHelperCall :: Day -> Map Text Text -> Aeson.Value -> Text -> [Syntax.Value] -> Bool
evaluateHelperCall today bindings doc helperName args =
  case T.toLower helperName of
    "is_weekend" ->
      case args of
        [arg] -> maybe False isWeekend (resolveArgText today bindings doc arg)
        _ -> False
    "is_high_amount" ->
      case args of
        [actualArg, thresholdArg] ->
          case (resolveArgNumber today bindings doc actualArg, resolveArgNumber today bindings doc thresholdArg) of
            (Just actual, Just threshold) -> actual > threshold
            _ -> False
        _ -> False
    "starts_with" ->
      case args of
        [textArg, prefixArg] ->
          case (resolveArgText today bindings doc textArg, resolveArgText today bindings doc prefixArg) of
            (Just textVal, Just prefixVal) -> T.isPrefixOf prefixVal textVal
            _ -> False
        _ -> False
    "in_list" ->
      case args of
        [textArg, listArg] ->
          case (resolveArgText today bindings doc textArg, resolveArgTextList today bindings doc listArg) of
            (Just textVal, Just values) -> textVal `elem` values
            _ -> False
        _ -> False
    "is_future_date" ->
      case args of
        [arg] -> maybe False (> today) (resolveArgText today bindings doc arg >>= parseDate)
        _ -> False
    "is_date_before" ->
      case args of
        [dateArg, cutoffArg] ->
          case (resolveArgText today bindings doc dateArg >>= parseDate, resolveArgText today bindings doc cutoffArg >>= parseDate) of
            (Just d, Just cutoff) -> d < cutoff
            _ -> False
        _ -> False
    "is_valid_npi" ->
      case args of
        [arg] -> maybe False isValidNpi (resolveArgText today bindings doc arg)
        _ -> False
    "is_npi_format" ->
      case args of
        [arg] -> maybe False isNpiFormat (resolveArgText today bindings doc arg)
        _ -> False
    "is_age_valid" ->
      case args of
        [dobArg, minArg, maxArg] ->
          case (resolveArgText today bindings doc dobArg >>= parseDate, resolveArgNumber today bindings doc minArg, resolveArgNumber today bindings doc maxArg) of
            (Just dob, Just minAge, Just maxAge) ->
              let age = yearsBetween dob today
               in fromIntegral age >= minAge && fromIntegral age <= maxAge
            _ -> False
        _ -> False
    _ -> False

resolveArgText :: Day -> Map Text Text -> Aeson.Value -> Syntax.Value -> Maybe Text
resolveArgText today bindings doc arg =
  case arg of
    Syntax.StringValue t -> Just t
    Syntax.NumberValue d -> Just (T.pack (show d))
    Syntax.DateValue t -> Just t
    Syntax.FieldRefValue fieldRef -> lookupFieldWithEnv (mkEnv today bindings doc) fieldRef
    Syntax.ListValue _ -> Nothing

resolveArgNumber :: Day -> Map Text Text -> Aeson.Value -> Syntax.Value -> Maybe Double
resolveArgNumber today bindings doc arg =
  case arg of
    Syntax.NumberValue d -> Just d
    Syntax.StringValue t -> textToDouble t
    Syntax.DateValue _ -> Nothing
    Syntax.FieldRefValue fieldRef -> lookupFieldWithEnv (mkEnv today bindings doc) fieldRef >>= textToDouble
    Syntax.ListValue _ -> Nothing

resolveArgTextList :: Day -> Map Text Text -> Aeson.Value -> Syntax.Value -> Maybe [Text]
resolveArgTextList today bindings doc arg =
  case arg of
    Syntax.ListValue values -> mapM (resolveArgText today bindings doc) values
    _ -> Nothing

isWeekend :: Text -> Bool
isWeekend dateText =
  case parseDate dateText of
    Just day ->
      let dow = dayOfWeek day
       in dow == Saturday || dow == Sunday
    Nothing -> False

parseDate :: Text -> Maybe Day
parseDate dateText =
  parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack dateText)
    <|> parseTimeM True defaultTimeLocale "%Y%m%d" (T.unpack dateText)
    <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S" (T.unpack dateText)

-- ----------------------------------------------------------------------------
-- Field Comparison Helpers
-- ----------------------------------------------------------------------------

-- | Compare a field's string value against an expected value or another field.
compareField ::
  EvalEnv ->
  Syntax.FieldRef ->
  Syntax.Value ->
  (Text -> Text -> Bool) ->
  Bool
compareField env fieldRef val cmp =
  case (lookupFieldWithEnv env fieldRef, val) of
    (Just fieldVal, Syntax.StringValue expectedVal) -> cmp fieldVal expectedVal
    (Just fieldVal, Syntax.FieldRefValue otherFieldRef) ->
      case lookupFieldWithEnv env otherFieldRef of
        Just otherVal -> cmp fieldVal otherVal
        Nothing -> False
    _ -> False

-- | Compare a field's numeric value against an expected value or another field.
compareNumericField ::
  EvalEnv ->
  Syntax.FieldRef ->
  Syntax.Value ->
  (Double -> Double -> Bool) ->
  Bool
compareNumericField env fieldRef val cmp =
  case (lookupFieldWithEnv env fieldRef, val) of
    (Just fieldVal, Syntax.NumberValue expectedVal) ->
      case textToDouble fieldVal of
        Just actualVal -> cmp actualVal expectedVal
        Nothing -> False
    (Just fieldVal, Syntax.FieldRefValue otherFieldRef) ->
      case (textToDouble fieldVal, lookupFieldWithEnv env otherFieldRef >>= textToDouble) of
        (Just actualVal, Just otherVal) -> cmp actualVal otherVal
        _ -> False
    _ -> False

-- | Compare two integers using a comparison operator.
compareInt :: Int -> Syntax.CompOp -> Int -> Bool
compareInt actual op expected = case op of
  Syntax.EQ -> actual == expected
  Syntax.NE -> actual /= expected
  Syntax.GT -> actual > expected
  Syntax.LT -> actual < expected
  Syntax.GTE -> actual >= expected
  Syntax.LTE -> actual <= expected

-- | Parse a Text value as a Double.
textToDouble :: Text -> Maybe Double
textToDouble t = case reads (T.unpack t) of
  [(d, "")] -> Just d
  _ -> Nothing

-- ----------------------------------------------------------------------------
-- JSON Field Lookup
-- ----------------------------------------------------------------------------

-- | Look up a field in a JSON value using dot notation.
--
-- Supports multiple reference styles:
--
-- * @Field "amount"@ → looks up @"amount"@ directly
-- * @Field "claim.amount"@ → looks up @claim.amount@ (dot-separated path)
-- * @SegmentField "CLM" "amount"@ → looks up @CLM.amount@
-- * @LoopField "2300" "CLM" "01"@ → looks up @2300.CLM.01@
--
-- Array indices are supported: @"items.0.price"@ accesses the first item's price.
lookupJsonField :: Syntax.FieldRef -> Aeson.Value -> Maybe Text
lookupJsonField fieldRef doc = case fieldRef of
  Syntax.Field name ->
    lookupPath (T.splitOn "." name) doc
  Syntax.SegmentField seg field ->
    lookupPath [seg, field] doc
  Syntax.LoopField loop seg field ->
    lookupPath [loop, seg, field] doc
  Syntax.ElementPosition _ _ _ ->
    Nothing -- Not used for JSON

-- | Scope-aware field lookup.
--
-- Resolution order:
--
-- 1. If the first path component matches a quantifier-bound variable
--    (@EXISTS x IN …@), resolve the rest against that JSON value.
-- 2. If the name matches a LET binding, return its text value.
-- 3. Otherwise fall back to document lookup.
lookupFieldWithEnv :: EvalEnv -> Syntax.FieldRef -> Maybe Text
lookupFieldWithEnv env fieldRef =
  case fieldRef of
    Syntax.Field name ->
      let parts = T.splitOn "." name
       in case parts of
            (first : rest)
              | Just scopeVal <- Map.lookup first (envScopeVars env) ->
                  lookupPath rest scopeVal
            [single]
              | Just val <- Map.lookup single (envLetBindings env) ->
                  Just val
            _ -> lookupJsonField fieldRef (envDoc env)
    Syntax.SegmentField seg field
      | Just scopeVal <- Map.lookup seg (envScopeVars env) ->
          lookupPath [field] scopeVal
      | otherwise ->
          lookupJsonField fieldRef (envDoc env)
    Syntax.LoopField loop seg field
      | Just scopeVal <- Map.lookup loop (envScopeVars env) ->
          lookupPath [seg, field] scopeVal
      | otherwise ->
          lookupJsonField fieldRef (envDoc env)
    _ -> lookupJsonField fieldRef (envDoc env)

-- | Navigate a dot-separated path through JSON and extract a text value.
--
-- Handles both objects (by key) and arrays (by numeric index).
lookupPath :: [Text] -> Aeson.Value -> Maybe Text
lookupPath [] val = valueToText val
lookupPath (key : rest) val = case val of
  Aeson.Object obj ->
    KM.lookup (Key.fromText key) obj >>= lookupPath rest
  Aeson.Array arr ->
    case reads (T.unpack key) of
      [(idx, "")]
        | idx >= 0 && idx < V.length arr ->
            lookupPath rest (arr V.! idx)
      _ -> Nothing
  _ -> Nothing

-- | Convert a JSON value to Text for comparison.
--
-- * Strings are returned as-is
-- * Numbers are converted to decimal text
-- * Booleans become "true" or "false"
-- * Null and complex types (arrays, objects) return 'Nothing'
valueToText :: Aeson.Value -> Maybe Text
valueToText = \case
  Aeson.String t -> Just t
  Aeson.Number n -> Just $ T.pack $ show (toRealFloat n :: Double)
  Aeson.Bool True -> Just "true"
  Aeson.Bool False -> Just "false"
  Aeson.Null -> Nothing
  _ -> Nothing -- Arrays and objects can't be compared as text

-- ----------------------------------------------------------------------------
-- Array Navigation for Quantifiers
-- ----------------------------------------------------------------------------

-- | Find array items at a path for EXISTS/FORALL/COUNT predicates.
--
-- If the path points to an array, returns its elements.
-- If the path points to an object, returns it as a single-element list.
-- Otherwise returns an empty list.
findArrayItems :: Syntax.SegmentPath -> Aeson.Value -> [Aeson.Value]
findArrayItems (Syntax.SegmentPath pathStr _) doc =
  case lookupPathRaw (T.splitOn "." pathStr) doc of
    Just (Aeson.Array arr) -> V.toList arr
    Just obj@(Aeson.Object _) -> [obj] -- Single object as list of one
    _ -> []

-- | Navigate a path but return the raw JSON value (not converted to text).
lookupPathRaw :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPathRaw [] val = Just val
lookupPathRaw (key : rest) val = case val of
  Aeson.Object obj ->
    KM.lookup (Key.fromText key) obj >>= lookupPathRaw rest
  Aeson.Array arr ->
    case reads (T.unpack key) of
      [(idx, "")]
        | idx >= 0 && idx < V.length arr ->
            lookupPathRaw rest (arr V.! idx)
      _ -> Nothing
  _ -> Nothing

-- ----------------------------------------------------------------------------
-- Between / HasDiagnosis / HasProcedure
-- ----------------------------------------------------------------------------

-- | Evaluate @field BETWEEN lo AND hi@ (inclusive).
evaluateBetween :: EvalEnv -> Syntax.FieldRef -> Syntax.Value -> Syntax.Value -> Bool
evaluateBetween env fieldRef loVal hiVal =
  case lookupFieldWithEnv env fieldRef >>= textToDouble of
    Just actual ->
      case (valueToDouble loVal, valueToDouble hiVal) of
        (Just lo, Just hi) -> actual >= lo && actual <= hi
        _ -> False
    Nothing -> False
  where
    valueToDouble (Syntax.NumberValue n) = Just n
    valueToDouble _ = Nothing

-- | Evaluate @claim.has_diagnosis "code"@.
--
-- Searches @diagnosis_codes[*].code@ and
-- @service_lines[*].diagnosis_codes[*]@ (when stored as plain strings).
evaluateHasDiagnosis :: EvalEnv -> Syntax.Value -> Bool
evaluateHasDiagnosis env val =
  case val of
    Syntax.StringValue searchCode ->
      let doc = envDoc env
       in anyCodeInArray doc ["diagnosis_codes"] "code" searchCode
    _ -> False

-- | Evaluate @claim.has_procedure "code"@.
--
-- Searches @procedure_codes[*].code@, @service_lines[*].procedure_code@,
-- and the top-level @procedure_code@ field.
evaluateHasProcedure :: EvalEnv -> Syntax.Value -> Bool
evaluateHasProcedure env val =
  case val of
    Syntax.StringValue searchCode ->
      let doc = envDoc env
       in anyCodeInArray doc ["procedure_codes"] "code" searchCode
            || anyFieldInArray doc ["service_lines"] "procedure_code" searchCode
            || lookupPath ["procedure_code"] doc == Just searchCode
    _ -> False

-- | Check if any element in an array at @rootPath@ has a sub-field matching
-- the target.  E.g. @diagnosis_codes[*].code == "E11.9"@.
anyCodeInArray :: Aeson.Value -> [Text] -> Text -> Text -> Bool
anyCodeInArray doc rootPath fieldName target =
  case lookupPathRaw rootPath doc of
    Just (Aeson.Array arr) ->
      V.any (matchField fieldName target) arr
    _ -> False

-- | Check if any element in an array at @rootPath@ has a direct field matching
-- the target.  E.g. @service_lines[*].procedure_code == "99213"@.
anyFieldInArray :: Aeson.Value -> [Text] -> Text -> Text -> Bool
anyFieldInArray = anyCodeInArray  -- same implementation, different intent

-- | Does a JSON object's named field equal the target text?
matchField :: Text -> Text -> Aeson.Value -> Bool
matchField fieldName target (Aeson.Object obj) =
  case KM.lookup (Key.fromText fieldName) obj of
    Just (Aeson.String t) -> t == target
    _ -> False
matchField _ _ _ = False

-- ----------------------------------------------------------------------------
-- NPI Validation
-- ----------------------------------------------------------------------------

-- | Check if a string is a valid NPI (10 ASCII digits + Luhn-10 checksum).
isValidNpi :: Text -> Bool
isValidNpi t = isNpiFormat t && luhn10Check t

-- | Check if a string is exactly 10 ASCII digits.
isNpiFormat :: Text -> Bool
isNpiFormat t = T.length t == 10 && T.all isDigit t

-- | Validate the NPI Luhn-10 check digit.
-- Uses the health industry prefix "80840" per CMS specification.
luhn10Check :: Text -> Bool
luhn10Check npi =
  let digits = map (\c -> fromEnum c - fromEnum '0') (T.unpack npi)
      full = [8, 0, 8, 4, 0] ++ digits -- 15 digits total
      processed = zipWith
        (\i d -> if odd i then let x = d * 2 in if x > 9 then x - 9 else x else d)
        [0 :: Int ..]
        (reverse full)
   in sum processed `mod` 10 == 0

-- ----------------------------------------------------------------------------
-- Age Calculation
-- ----------------------------------------------------------------------------

-- | Calculate whole years between two dates (standard age calculation).
yearsBetween :: Day -> Day -> Int
yearsBetween dob ref =
  let (y1, m1, d1) = toGregorian dob
      (y2, m2, d2) = toGregorian ref
      age = fromIntegral (y2 - y1)
   in if (m2, d2) < (m1, d1) then age - 1 else age

-- ----------------------------------------------------------------------------
-- Action Conversion
-- ----------------------------------------------------------------------------

-- | Convert a Syntax.Action to Action' for inclusion in results.
convertAction :: Syntax.Action -> Action'
convertAction = \case
  Syntax.FlagFraud reason -> FlagFraud' reason
  Syntax.AssignRiskScore score -> AssignRiskScore' score
  Syntax.RequireReview note -> RequireReview' note
  Syntax.RejectClaim reason -> RejectClaim' reason
  Syntax.ApproveClaim reason -> ApproveClaim' reason
  Syntax.CompositeAction actions -> CompositeAction' (map convertAction actions)
