{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Claims.SimpleEvaluator
-- Description : Evaluate DSL predicates against generic JSON documents
-- Stability   : experimental
--
-- This module evaluates fraud detection rules against generic JSON documents
-- (Aeson 'Aeson.Value'). This is the recommended evaluator for production use
-- with JSON claim data.
--
-- Unlike "Claims.Evaluator" which requires a fully parsed 'X12Document'
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
-- import Claims.SimpleEvaluator
-- import Claims.Parser (parseRule)
--
-- main :: IO ()
-- main = do
--   let Just claim = decode "{\"amount\": 15000, \"status\": \"pending\"}"
--       Right rule = parseRule "RULE test \"\" WHEN amount > 10000 THEN FLAG_FRAUD \"high\";"
--   print $ evaluateRuleSimple claim rule
-- @
module Claims.SimpleEvaluator
  ( -- * Evaluation Functions
    evaluatePredicateSimple,
    evaluateRuleSimple,

    -- * Field Lookup (exported for testing)
    lookupJsonField,

    -- * Helper Functions
    helperArity,

    -- * Regular Expressions
    compileRegex,
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
import Data.Int (Int64)
import Data.Scientific (Scientific, toBoundedInteger, toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day, DayOfWeek (Saturday, Sunday), dayOfWeek, defaultTimeLocale, parseTimeM, toGregorian)
import Data.Vector qualified as V
import Claims.Syntax qualified as Syntax
import Claims.Syntax (RuleResult (..))
import Text.Regex.TDFA (CompOption (multiline), ExecOption, Regex, defaultCompOpt, defaultExecOpt, makeRegexOptsM, matchTest)
import Text.Regex.TDFA.Text ()

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
-- Returns 'True' only if the predicate is definitely true for the document.
-- A predicate that depends on missing or unusable data is not a match.
--
-- ==== Example
--
-- @
-- let doc = Aeson.object ["amount" .= (15000 :: Int)]
--     pred = Syntax.GreaterThan (Syntax.Field "amount") (Syntax.NumberValue 10000)
-- evaluatePredicateSimple doc pred  -- Returns True
-- @
evaluatePredicateSimple :: Day -> Aeson.Value -> Syntax.Predicate -> Bool
evaluatePredicateSimple today doc = (== Yes) . evaluateWithEnv (mkEnv today Map.empty doc)

-- ----------------------------------------------------------------------------
-- Three-valued logic
-- ----------------------------------------------------------------------------

-- | The result of a predicate. 'Unknown' means the predicate depends on data
-- that is missing or unusable (an absent field, text where a number was
-- expected, an unreadable date, an empty or absent collection).
--
-- The connectives follow SQL: @NOT Unknown@ is 'Unknown', @Unknown OR Yes@ is
-- 'Yes', @Unknown AND No@ is 'No'. A rule fires only on 'Yes', so missing data
-- never makes a rule match by itself; analysts test for it explicitly with
-- @IS NULL@ or @COUNT(...) = 0@.
data Truth = Yes | No | Unknown
  deriving (Eq, Show)

-- | A definite result.
known :: Bool -> Truth
known b = if b then Yes else No

-- | 'Nothing' (data missing or unusable) becomes 'Unknown'.
fromMaybeBool :: Maybe Bool -> Truth
fromMaybeBool = maybe Unknown known

tNot :: Truth -> Truth
tNot = \case
  Yes -> No
  No -> Yes
  Unknown -> Unknown

-- | Kleene AND; does not evaluate the second argument when the first is 'No'.
tAnd :: Truth -> Truth -> Truth
tAnd No _ = No
tAnd a b = case b of
  No -> No
  Yes -> a
  Unknown -> Unknown

-- | Kleene OR; does not evaluate the second argument when the first is 'Yes'.
tOr :: Truth -> Truth -> Truth
tOr Yes _ = Yes
tOr a b = case b of
  Yes -> Yes
  No -> a
  Unknown -> Unknown

-- | EXISTS over a collection: 'Unknown' when there is nothing to examine.
tAny :: [Truth] -> Truth
tAny [] = Unknown
tAny ts = foldr tOr No ts

-- | FORALL over a collection: 'Unknown' when there is nothing to examine.
tAll :: [Truth] -> Truth
tAll [] = Unknown
tAll ts = foldr tAnd Yes ts

-- | Internal evaluator carrying the full environment.
evaluateWithEnv :: EvalEnv -> Syntax.Predicate -> Truth
evaluateWithEnv env = \case
  -- Boolean literals
  Syntax.PTrue -> Yes
  Syntax.PFalse -> No
  -- Equality comparisons (numeric when the literal is a number)
  Syntax.Equals fieldRef val@(Syntax.NumberValue _) ->
    compareNumericField env fieldRef val (==)
  Syntax.NotEquals fieldRef val@(Syntax.NumberValue _) ->
    compareNumericField env fieldRef val (/=)
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
  -- Null checks are always definite
  Syntax.IsNull fieldRef ->
    known $ isNothing $ lookupFieldWithEnv env fieldRef
  Syntax.IsNotNull fieldRef ->
    known $ isJust $ lookupFieldWithEnv env fieldRef
  -- Boolean logic (recursive)
  Syntax.And p1 p2 ->
    evaluateWithEnv env p1 `tAnd` evaluateWithEnv env p2
  Syntax.Or p1 p2 ->
    evaluateWithEnv env p1 `tOr` evaluateWithEnv env p2
  Syntax.Not p ->
    tNot $ evaluateWithEnv env p
  -- Quantifiers over arrays — unnamed: shift doc (backward compatible)
  Syntax.Exists Nothing path innerPred ->
    tAny [evaluateWithEnv (env { envDoc = item }) innerPred | item <- findArrayItems path (envDoc env)]
  Syntax.ForAll Nothing path innerPred ->
    tAll [evaluateWithEnv (env { envDoc = item }) innerPred | item <- findArrayItems path (envDoc env)]
  -- Quantifiers over arrays — named: bind variable, doc stays unchanged
  Syntax.Exists (Just varName) path innerPred ->
    tAny [evaluateWithEnv (bindScope varName item env) innerPred | item <- findArrayItems path (envDoc env)]
  Syntax.ForAll (Just varName) path innerPred ->
    tAll [evaluateWithEnv (bindScope varName item env) innerPred | item <- findArrayItems path (envDoc env)]
  -- COUNT is definite: a missing collection counts as zero
  Syntax.Count path op n ->
    known $ compareInt (length $ findArrayItems path (envDoc env)) op n
  Syntax.HelperCall helperName args ->
    fromMaybeBool $ evaluateHelperCall env helperName args
  -- String operations
  Syntax.Contains fieldRef val ->
    fromMaybeBool $ do
      fieldVal <- lookupFieldWithEnv env fieldRef
      case val of
        Syntax.StringValue searchStr -> Just (T.isInfixOf searchStr fieldVal)
        _ -> Nothing
  Syntax.Matches fieldRef pattern ->
    fromMaybeBool $ matchTest <$> compileRegex pattern <*> lookupFieldWithEnv env fieldRef

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
          resultDetails = "Rule binding error: " <> err,
          resultUndecided = True
        }
    Right bindings ->
      let env = mkEnv today bindings doc
          truth = evaluateWithEnv env (Syntax.ruleCondition rule)
          matched = truth == Yes
          action =
            if matched
              then Just (Syntax.ruleAction rule)
              else Nothing
          details = case truth of
            Yes -> "Rule matched: " <> Syntax.ruleDescription rule
            No -> "Rule did not match"
            Unknown -> "Rule did not match: missing or unusable data"
       in RuleResult
            { resultRuleName = Syntax.ruleName rule,
              resultMatched = matched,
              resultAction = action,
              resultDetails = details,
              resultUndecided = truth == Unknown
            }

buildBindingContext :: Day -> Aeson.Value -> [Syntax.Binding] -> Either Text (Map Text Text)
buildBindingContext today doc = foldM step Map.empty
  where
    step ctx binding =
      let env = mkEnv today ctx doc
       in case lookupFieldWithEnv env (Syntax.bindingField binding) of
            Just value -> Right $ Map.insert (Syntax.bindingName binding) value ctx
            Nothing -> Left $ "Could not resolve LET binding '" <> Syntax.bindingName binding <> "'"

-- | Argument count of each built-in helper, keyed by lower-case name.
-- The parser checks calls against this table, so a misspelled helper or a
-- wrong argument count is a parse error instead of a rule that never fires.
-- Keep it in step with 'evaluateHelperCall'.
helperArities :: Map Text Int
helperArities =
  Map.fromList
    [ ("is_weekend", 1),
      ("is_high_amount", 2),
      ("starts_with", 2),
      ("in_list", 2),
      ("is_future_date", 1),
      ("is_date_before", 2),
      ("is_valid_npi", 1),
      ("is_npi_format", 1),
      ("is_age_valid", 3)
    ]

-- | Argument count of a built-in helper (any letter case), or 'Nothing'
-- if no helper has that name.
helperArity :: Text -> Maybe Int
helperArity name = Map.lookup (T.toLower name) helperArities

-- | Run a built-in helper. 'Nothing' means an argument was missing or
-- unusable (or the call is unknown), which the caller treats as 'Unknown'.
evaluateHelperCall :: EvalEnv -> Text -> [Syntax.Value] -> Maybe Bool
evaluateHelperCall env helperName args =
  case (T.toLower helperName, args) of
    ("is_weekend", [arg]) ->
      isWeekend <$> date arg
    ("is_high_amount", [actualArg, thresholdArg]) ->
      (>) <$> number actualArg <*> number thresholdArg
    ("starts_with", [textArg, prefixArg]) ->
      flip T.isPrefixOf <$> text textArg <*> text prefixArg
    ("in_list", [textArg, listArg]) ->
      elem <$> text textArg <*> resolveArgTextList env listArg
    ("is_future_date", [arg]) ->
      (> envToday env) <$> date arg
    ("is_date_before", [dateArg, cutoffArg]) ->
      (<) <$> date dateArg <*> date cutoffArg
    ("is_valid_npi", [arg]) ->
      isValidNpi <$> text arg
    ("is_npi_format", [arg]) ->
      isNpiFormat <$> text arg
    ("is_age_valid", [dobArg, minArg, maxArg]) -> do
      dob <- date dobArg
      minAge <- number minArg
      maxAge <- number maxArg
      let age = fromIntegral (yearsBetween dob (envToday env))
      pure (age >= minAge && age <= maxAge)
    _ -> Nothing
  where
    text = resolveArgText env
    number = resolveArgNumber env
    date arg = resolveArgText env arg >>= parseDate

resolveArgText :: EvalEnv -> Syntax.Value -> Maybe Text
resolveArgText env arg =
  case arg of
    Syntax.StringValue t -> Just t
    Syntax.NumberValue d -> Just (doubleToText d)
    Syntax.DateValue t -> Just t
    Syntax.FieldRefValue fieldRef -> lookupFieldWithEnv env fieldRef
    Syntax.ListValue _ -> Nothing

resolveArgNumber :: EvalEnv -> Syntax.Value -> Maybe Double
resolveArgNumber env arg =
  case arg of
    Syntax.NumberValue d -> Just d
    Syntax.StringValue t -> textToDouble t
    Syntax.DateValue _ -> Nothing
    Syntax.FieldRefValue fieldRef -> lookupFieldWithEnv env fieldRef >>= textToDouble
    Syntax.ListValue _ -> Nothing

resolveArgTextList :: EvalEnv -> Syntax.Value -> Maybe [Text]
resolveArgTextList env arg =
  case arg of
    Syntax.ListValue values -> mapM (resolveArgText env) values
    _ -> Nothing

isWeekend :: Day -> Bool
isWeekend day = dayOfWeek day == Saturday || dayOfWeek day == Sunday

parseDate :: Text -> Maybe Day
parseDate dateText =
  parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack dateText)
    <|> parseTimeM True defaultTimeLocale "%Y%m%d" (T.unpack dateText)
    <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S" (T.unpack dateText)

-- ----------------------------------------------------------------------------
-- Field Comparison Helpers
-- ----------------------------------------------------------------------------

-- | Compare a field's string value against an expected value or another field.
-- 'Unknown' if either side is missing.
compareField ::
  EvalEnv ->
  Syntax.FieldRef ->
  Syntax.Value ->
  (Text -> Text -> Bool) ->
  Truth
compareField env fieldRef val cmp =
  fromMaybeBool $ do
    fieldVal <- lookupFieldWithEnv env fieldRef
    expectedVal <- case val of
      Syntax.StringValue t -> Just t
      Syntax.FieldRefValue otherFieldRef -> lookupFieldWithEnv env otherFieldRef
      _ -> Nothing
    pure (cmp fieldVal expectedVal)

-- | Compare a field's numeric value against an expected value or another field.
-- 'Unknown' if either side is missing or not a number.
compareNumericField ::
  EvalEnv ->
  Syntax.FieldRef ->
  Syntax.Value ->
  (Double -> Double -> Bool) ->
  Truth
compareNumericField env fieldRef val cmp =
  fromMaybeBool $ do
    actualVal <- lookupFieldWithEnv env fieldRef >>= textToDouble
    expectedVal <- case val of
      Syntax.NumberValue n -> Just n
      Syntax.FieldRefValue otherFieldRef -> lookupFieldWithEnv env otherFieldRef >>= textToDouble
      _ -> Nothing
    pure (cmp actualVal expectedVal)

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
  Aeson.Number n -> Just $ scientificToText n
  Aeson.Bool True -> Just "true"
  Aeson.Bool False -> Just "false"
  Aeson.Null -> Nothing
  _ -> Nothing -- Arrays and objects can't be compared as text

-- | Render a JSON number the way it would be written in a claim.
--
-- Whole numbers keep every digit (@1234567893@, not @1.234567893e9@), so
-- numeric NPIs, codes and IDs compare correctly as text. Values outside
-- the 'Int64' range fall back to 'Double' rather than expanding a huge
-- exponent into a giant 'Integer'.
scientificToText :: Scientific -> Text
scientificToText n =
  case toBoundedInteger n :: Maybe Int64 of
    Just i -> T.pack (show i)
    Nothing -> doubleToText (toRealFloat n)

-- | Render a 'Double', dropping the @.0@ from whole numbers so a DSL
-- literal like @99213@ reads the same as the JSON number @99213@.
doubleToText :: Double -> Text
doubleToText d
  | d == fromIntegral i && abs d < 1e15 = T.pack (show i)
  | otherwise = T.pack (show d)
  where
    i = round d :: Integer

-- ----------------------------------------------------------------------------
-- Array Navigation for Quantifiers
-- ----------------------------------------------------------------------------

-- | Find array items at a path for EXISTS/FORALL/COUNT predicates.
--
-- If the path points to an array, returns its elements.
-- If the path points to an object, returns it as a single-element list.
-- Otherwise returns an empty list.
findArrayItems :: Syntax.SegmentPath -> Aeson.Value -> [Aeson.Value]
findArrayItems (Syntax.SegmentPath pathStr pathParts) doc =
  case lookupPathRaw (pathStr : pathParts) doc of
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
evaluateBetween :: EvalEnv -> Syntax.FieldRef -> Syntax.Value -> Syntax.Value -> Truth
evaluateBetween env fieldRef loVal hiVal =
  fromMaybeBool $ do
    actual <- lookupFieldWithEnv env fieldRef >>= textToDouble
    lo <- valueToDouble loVal
    hi <- valueToDouble hiVal
    pure (actual >= lo && actual <= hi)
  where
    valueToDouble (Syntax.NumberValue n) = Just n
    valueToDouble _ = Nothing

-- | Evaluate @claim.has_diagnosis "code"@ by searching
-- @diagnosis_codes[*].code@.
--
-- 'Unknown' when the claim has no diagnosis codes to search.
evaluateHasDiagnosis :: EvalEnv -> Syntax.Value -> Truth
evaluateHasDiagnosis env val =
  case val of
    Syntax.StringValue searchCode ->
      searchSources [anyCodeInArray (envDoc env) ["diagnosis_codes"] "code" searchCode]
    _ -> Unknown

-- | Evaluate @claim.has_procedure "code"@.
--
-- Searches @procedure_codes[*].code@, @service_lines[*].procedure_code@,
-- and the top-level @procedure_code@ field. 'Unknown' when none of those
-- is present.
evaluateHasProcedure :: EvalEnv -> Syntax.Value -> Truth
evaluateHasProcedure env val =
  case val of
    Syntax.StringValue searchCode ->
      let doc = envDoc env
       in searchSources
            [ anyCodeInArray doc ["procedure_codes"] "code" searchCode,
              anyFieldInArray doc ["service_lines"] "procedure_code" searchCode,
              (== searchCode) <$> lookupPath ["procedure_code"] doc
            ]
    _ -> Unknown

-- | Combine searches of several places a code may appear. 'Nothing' means
-- that place is absent from the claim. Found anywhere → 'Yes'; some place
-- searched without finding it → 'No'; nowhere to search → 'Unknown'.
searchSources :: [Maybe Bool] -> Truth
searchSources results
  | Just True `elem` results = Yes
  | any isJust results = No
  | otherwise = Unknown

-- | Check if any element in a non-empty array at @rootPath@ has a sub-field
-- matching the target. E.g. @diagnosis_codes[*].code == "E11.9"@.
-- 'Nothing' if there is no such array or it is empty.
anyCodeInArray :: Aeson.Value -> [Text] -> Text -> Text -> Maybe Bool
anyCodeInArray doc rootPath fieldName target =
  case lookupPathRaw rootPath doc of
    Just (Aeson.Array arr)
      | not (V.null arr) -> Just (V.any (matchField fieldName target) arr)
    _ -> Nothing

-- | Check if any element in an array at @rootPath@ has a direct field matching
-- the target.  E.g. @service_lines[*].procedure_code == "99213"@.
anyFieldInArray :: Aeson.Value -> [Text] -> Text -> Text -> Maybe Bool
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
-- Regular Expressions
-- ----------------------------------------------------------------------------

-- | Compile a @MATCHES@ pattern (POSIX extended syntax, via regex-tdfa).
--
-- regex-tdfa runs in time linear in the input, so analyst-written patterns
-- cannot cause catastrophic backtracking. Multiline mode is off, so @^@ and
-- @$@ anchor to the whole field value. Returns 'Nothing' for an invalid
-- pattern; the parser rejects those, so this only matters for rules loaded
-- from JSON.
compileRegex :: Text -> Maybe Regex
compileRegex pattern =
  makeRegexOptsM (defaultCompOpt {multiline = False}) (defaultExecOpt :: ExecOption) (T.unpack pattern)
