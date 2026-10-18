{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Claims.SimpleEvaluator
-- Description : Evaluate rules against JSON claims
--
-- Fields are looked up by dotted path (@claim.amount@, @items.0.price@) and
-- compared as text or numbers. Predicates use three-valued logic so that
-- missing data never makes a rule match by itself (see 'Truth').
module Claims.SimpleEvaluator
  ( evaluateRuleSimple,
    helperArity,
    compileRegex,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (foldM, (>=>))
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
import Prelude hiding (EQ, GT, LT)
import Claims.Syntax qualified as Syntax
import Claims.Syntax (CompOp (..), Path (..), RuleResult (..))
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
  -- = and != compare text unless the literal is a number; the rest are numeric
  Syntax.Compare op ref val
    | op `elem` [EQ, NE], not (isNumber val) -> compareText env ref val (applyOp op)
    | otherwise -> compareNumber env ref val (applyOp op)
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
  Syntax.Exists var path p -> tAny (quantify var path p)
  Syntax.ForAll var path p -> tAll (quantify var path p)
  -- COUNT is definite: a missing collection counts as zero
  Syntax.Count path op n ->
    known $ applyOp op (length $ findArrayItems path (envDoc env)) n
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
  where
    isNumber (Syntax.NumberValue _) = True
    isNumber _ = False
    -- Evaluate the body once per item. Without a variable the item becomes
    -- the document; with one, the item is bound to it and the document stays.
    quantify var path p =
      [ evaluateWithEnv (enter var item) p | item <- findArrayItems path (envDoc env) ]
    enter Nothing item = env {envDoc = item}
    enter (Just name) item = env {envScopeVars = Map.insert name item (envScopeVars env)}

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
    Syntax.FieldValue fieldRef -> lookupFieldWithEnv env fieldRef
    Syntax.ListValue _ -> Nothing

resolveArgNumber :: EvalEnv -> Syntax.Value -> Maybe Double
resolveArgNumber env arg =
  case arg of
    Syntax.NumberValue d -> Just d
    Syntax.StringValue t -> textToDouble t
    Syntax.FieldValue fieldRef -> lookupFieldWithEnv env fieldRef >>= textToDouble
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

-- | Compare a field's text with a string literal or another field.
-- 'Unknown' if either side is missing.
compareText :: EvalEnv -> Path -> Syntax.Value -> (Text -> Text -> Bool) -> Truth
compareText env fieldRef val cmp =
  fromMaybeBool $ do
    fieldVal <- lookupFieldWithEnv env fieldRef
    expectedVal <- case val of
      Syntax.StringValue t -> Just t
      Syntax.FieldValue otherRef -> lookupFieldWithEnv env otherRef
      _ -> Nothing
    pure (cmp fieldVal expectedVal)

-- | Compare a field's number with a number literal or another field.
-- 'Unknown' if either side is missing or not a number.
compareNumber :: EvalEnv -> Path -> Syntax.Value -> (Double -> Double -> Bool) -> Truth
compareNumber env fieldRef val cmp =
  fromMaybeBool $ do
    actualVal <- lookupFieldWithEnv env fieldRef >>= textToDouble
    expectedVal <- case val of
      Syntax.NumberValue n -> Just n
      Syntax.FieldValue otherRef -> lookupFieldWithEnv env otherRef >>= textToDouble
      _ -> Nothing
    pure (cmp actualVal expectedVal)

applyOp :: Ord a => CompOp -> a -> a -> Bool
applyOp = \case
  EQ -> (==)
  NE -> (/=)
  GT -> (>)
  LT -> (<)
  GTE -> (>=)
  LTE -> (<=)

-- | Parse a Text value as a Double.
textToDouble :: Text -> Maybe Double
textToDouble t = case reads (T.unpack t) of
  [(d, "")] -> Just d
  _ -> Nothing

-- ----------------------------------------------------------------------------
-- JSON Field Lookup
-- ----------------------------------------------------------------------------

-- | Look up a field. Resolution order:
--
-- 1. If the first part names a quantifier variable (@EXISTS x IN ...@),
--    look up the rest inside that item.
-- 2. If the path is a single name bound by @LET@, use the bound value.
-- 3. Otherwise look the path up in the document.
lookupFieldWithEnv :: EvalEnv -> Path -> Maybe Text
lookupFieldWithEnv env (Path parts) = case parts of
  (first : rest)
    | Just scopeVal <- Map.lookup first (envScopeVars env) -> lookupPath rest scopeVal
  [single]
    | Just val <- Map.lookup single (envLetBindings env) -> Just val
  _ -> lookupPath parts (envDoc env)

-- | Follow a path through objects (by key) and arrays (by index) and render
-- the value found as text.
lookupPath :: [Text] -> Aeson.Value -> Maybe Text
lookupPath path = lookupPathRaw path >=> valueToText

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

-- | The items of the collection at a path: an array's elements, or a single
-- object as a one-item list. Anything else, or nothing, gives no items.
findArrayItems :: Path -> Aeson.Value -> [Aeson.Value]
findArrayItems (Path parts) doc =
  case lookupPathRaw parts doc of
    Just (Aeson.Array arr) -> V.toList arr
    Just obj@(Aeson.Object _) -> [obj] -- Single object as list of one
    _ -> []

-- | Follow a path through objects (by key) and arrays (by index).
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
evaluateBetween :: EvalEnv -> Path -> Syntax.Value -> Syntax.Value -> Truth
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
              anyCodeInArray doc ["service_lines"] "procedure_code" searchCode,
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
