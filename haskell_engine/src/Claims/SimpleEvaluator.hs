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
import Data.List (nub)
import Data.Maybe (isJust, isNothing)
import Data.Int (Int64)
import Data.Scientific (Scientific, toBoundedInteger, toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (Day, DayOfWeek (Saturday, Sunday), dayOfWeek, defaultTimeLocale, parseTimeM, toGregorian)
import Data.Vector qualified as V
import Prelude hiding (EQ, GT, LT)
import Claims.Syntax qualified as Syntax
import Claims.Syntax (CompOp (..), Path (..), RuleResult (..), compileRegex)
import Text.Regex.TDFA (matchTest)
import Text.Regex.TDFA.Text ()

-- ----------------------------------------------------------------------------
-- Evaluation Environment
-- ----------------------------------------------------------------------------

-- | Environment for predicate evaluation.
--
-- Carries LET bindings (text aliases), quantifier-scoped variables (JSON
-- objects from @EXISTS x IN …@), and the current document context.
-- The two prefix fields only affect how field names are written in
-- "not checked" reasons: inside @EXISTS line IN service_lines@ the field
-- @line.date_of_service@ is reported as @service_lines[].date_of_service@.
data EvalEnv = EvalEnv
  { envLetBindings :: Map Text Text
  , envScopeVars   :: Map Text Aeson.Value
  , envScopeNames  :: Map Text [Text]  -- ^ quantifier variable → display prefix
  , envDocPrefix   :: [Text]           -- ^ display prefix of 'envDoc'
  , envDoc         :: Aeson.Value
  , envToday       :: Day
  }

-- | Build an initial environment from a document.
mkEnv :: Day -> Map Text Text -> Aeson.Value -> EvalEnv
mkEnv today lets doc = EvalEnv lets Map.empty Map.empty [] doc today

-- ----------------------------------------------------------------------------
-- Three-valued logic
-- ----------------------------------------------------------------------------

-- | The result of a predicate. 'Unknown' means the predicate depends on data
-- that is missing or unusable (an absent field, text where a number was
-- expected, an unreadable date, an empty or absent collection). It carries
-- the reasons, e.g. @"financial.claim_amount missing"@, so the result can
-- name what was missing.
--
-- The connectives follow SQL: @NOT Unknown@ is 'Unknown', @Unknown OR Yes@ is
-- 'Yes', @Unknown AND No@ is 'No'. A rule fires only on 'Yes', so missing data
-- never makes a rule match by itself; analysts test for it explicitly with
-- @IS NULL@ or @COUNT(...) = 0@.
data Truth = Yes | No | Unknown [Text]
  deriving (Eq, Show)

-- | A definite result.
known :: Bool -> Truth
known b = if b then Yes else No

-- | A failed lookup (with its reasons) becomes 'Unknown'.
fromCheck :: Check Bool -> Truth
fromCheck = either Unknown known

tNot :: Truth -> Truth
tNot = \case
  Yes -> No
  No -> Yes
  Unknown rs -> Unknown rs

-- | Kleene AND; does not evaluate the second argument when the first is 'No'.
-- When both sides are unknown, the reasons of both are kept.
tAnd :: Truth -> Truth -> Truth
tAnd No _ = No
tAnd a b = case (a, b) of
  (_, No) -> No
  (_, Yes) -> a
  (Unknown ra, Unknown rb) -> Unknown (ra ++ rb)
  (_, Unknown rb) -> Unknown rb

-- | Kleene OR; does not evaluate the second argument when the first is 'Yes'.
-- When both sides are unknown, the reasons of both are kept.
tOr :: Truth -> Truth -> Truth
tOr Yes _ = Yes
tOr a b = case (a, b) of
  (_, Yes) -> Yes
  (_, No) -> a
  (Unknown ra, Unknown rb) -> Unknown (ra ++ rb)
  (_, Unknown rb) -> Unknown rb

-- | EXISTS over a collection: 'Unknown' (with the given reason) when there
-- is nothing to examine.
tAny :: Text -> [Truth] -> Truth
tAny reason [] = Unknown [reason]
tAny _ ts = foldr tOr No ts

-- | FORALL over a collection: 'Unknown' (with the given reason) when there
-- is nothing to examine.
tAll :: Text -> [Truth] -> Truth
tAll reason [] = Unknown [reason]
tAll _ ts = foldr tAnd Yes ts

-- | A value read from the claim, or the reasons it could not be.
type Check a = Either [Text] a

-- | Combine two checks, keeping the reasons of both when both fail.
check2 :: Check a -> Check b -> Check (a, b)
check2 (Right a) (Right b) = Right (a, b)
check2 a b = Left (reasons a ++ reasons b)
  where
    reasons = either id (const [])

-- | A check that fails with one reason when the value is 'Nothing'.
orElse :: Maybe a -> Text -> Check a
orElse m reason = maybe (Left [reason]) Right m

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
  Syntax.Exists var path p -> tAny (emptyReason path) (quantify var path p)
  Syntax.ForAll var path p -> tAll (emptyReason path) (quantify var path p)
  -- COUNT is definite: a missing collection counts as zero
  Syntax.Count path op n ->
    known $ applyOp op (length $ findArrayItems path (envDoc env)) n
  Syntax.HelperCall helperName args ->
    fromCheck $ evaluateHelperCall env helperName args
  -- String operations
  Syntax.Contains fieldRef val ->
    fromCheck $ do
      fieldVal <- lookupText env fieldRef
      case val of
        Syntax.StringValue searchStr -> Right (T.isInfixOf searchStr fieldVal)
        _ -> Left ["CONTAINS needs a text value"]
  Syntax.Matches fieldRef pattern ->
    fromCheck $ do
      regex <- compileRegex pattern `orElse` "invalid MATCHES pattern"
      matchTest regex <$> lookupText env fieldRef
  where
    isNumber (Syntax.NumberValue _) = True
    isNumber _ = False
    -- Evaluate the body once per item. Without a variable the item becomes
    -- the document; with one, the item is bound to it and the document stays.
    quantify var path p =
      [ evaluateWithEnv (enter var path item) p | item <- findArrayItems path (envDoc env) ]
    enter Nothing path item =
      env {envDoc = item, envDocPrefix = itemPrefix path}
    enter (Just name) path item =
      env
        { envScopeVars = Map.insert name item (envScopeVars env),
          envScopeNames = Map.insert name (itemPrefix path) (envScopeNames env)
        }
    itemPrefix (Path ps) = envDocPrefix env ++ markLast ps
    markLast ps = case reverse ps of
      (lastPart : before) -> reverse ((lastPart <> "[]") : before)
      [] -> []
    emptyReason path = displayPath env path <> " missing or empty"

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
            Unknown reasons ->
              "Rule did not match: missing or unusable data ("
                <> T.intercalate "; " (nub reasons)
                <> ")"
       in RuleResult
            { resultRuleName = Syntax.ruleName rule,
              resultMatched = matched,
              resultAction = action,
              resultDetails = details,
              resultUndecided = isUnknown truth
            }
  where
    isUnknown (Unknown _) = True
    isUnknown _ = False

buildBindingContext :: Day -> Aeson.Value -> [Syntax.Binding] -> Either Text (Map Text Text)
buildBindingContext today doc = foldM step Map.empty
  where
    step ctx binding =
      let env = mkEnv today ctx doc
       in case lookupFieldWithEnv env (Syntax.bindingField binding) of
            Just value -> Right $ Map.insert (Syntax.bindingName binding) value ctx
            Nothing -> Left $ "Could not resolve LET binding '" <> Syntax.bindingName binding <> "'"

-- | Run a built-in helper. A failed check (an argument missing or
-- unusable, or an unknown call) is treated by the caller as 'Unknown'.
evaluateHelperCall :: EvalEnv -> Text -> [Syntax.Value] -> Check Bool
evaluateHelperCall env helperName args =
  case (T.toLower helperName, args) of
    ("is_weekend", [arg]) ->
      isWeekend <$> date arg
    ("is_high_amount", [actualArg, thresholdArg]) ->
      uncurry (>) <$> check2 (number actualArg) (number thresholdArg)
    ("starts_with", [textArg, prefixArg]) ->
      uncurry (flip T.isPrefixOf) <$> check2 (text textArg) (text prefixArg)
    ("in_list", [textArg, listArg]) ->
      uncurry elem <$> check2 (text textArg) (resolveArgTextList env listArg)
    ("is_future_date", [arg]) ->
      (> envToday env) <$> date arg
    ("is_date_before", [dateArg, cutoffArg]) ->
      uncurry (<) <$> check2 (date dateArg) (date cutoffArg)
    ("is_valid_npi", [arg]) ->
      isValidNpi <$> text arg
    ("is_npi_format", [arg]) ->
      isNpiFormat <$> text arg
    ("is_age_valid", [dobArg, minArg, maxArg]) -> do
      (dob, (minAge, maxAge)) <- check2 (date dobArg) (check2 (number minArg) (number maxArg))
      let age = fromIntegral (yearsBetween dob (envToday env))
      pure (age >= minAge && age <= maxAge)
    _ -> Left ["unknown helper " <> helperName]
  where
    text = resolveArgText env
    number = resolveArgNumber env
    date arg = resolveArgText env arg >>= \t -> parseDate t `orElse` (argLabel env arg <> " is not a valid date")

resolveArgText :: EvalEnv -> Syntax.Value -> Check Text
resolveArgText env arg =
  case arg of
    Syntax.StringValue t -> Right t
    Syntax.NumberValue d -> Right (doubleToText d)
    Syntax.FieldValue fieldRef -> lookupText env fieldRef
    Syntax.ListValue _ -> Left ["a list is not a single value"]

resolveArgNumber :: EvalEnv -> Syntax.Value -> Check Double
resolveArgNumber env arg =
  case arg of
    Syntax.NumberValue d -> Right d
    _ -> resolveArgText env arg >>= \t -> textToDouble t `orElse` (argLabel env arg <> " is not a number")

resolveArgTextList :: EvalEnv -> Syntax.Value -> Check [Text]
resolveArgTextList env arg =
  case arg of
    Syntax.ListValue values -> traverse (resolveArgText env) values
    _ -> Left ["IN_LIST needs a list"]

-- | How an argument is named in a reason: a field by its path, a literal
-- as written.
argLabel :: EvalEnv -> Syntax.Value -> Text
argLabel env = \case
  Syntax.FieldValue fieldRef -> displayPath env fieldRef
  Syntax.StringValue t -> "\"" <> t <> "\""
  Syntax.NumberValue d -> doubleToText d
  Syntax.ListValue _ -> "list"

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
  fromCheck $ uncurry cmp <$> check2 (lookupText env fieldRef) expected
  where
    expected = case val of
      Syntax.StringValue t -> Right t
      Syntax.FieldValue otherRef -> lookupText env otherRef
      _ -> Left ["unsupported comparison value"]

-- | Compare a field's number with a number literal or another field.
-- 'Unknown' if either side is missing or not a number.
compareNumber :: EvalEnv -> Path -> Syntax.Value -> (Double -> Double -> Bool) -> Truth
compareNumber env fieldRef val cmp =
  fromCheck $ uncurry cmp <$> check2 (lookupNumber env fieldRef) expected
  where
    expected = case val of
      Syntax.NumberValue n -> Right n
      Syntax.FieldValue otherRef -> lookupNumber env otherRef
      _ -> Left ["unsupported comparison value"]

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
lookupFieldWithEnv env ref = either (const Nothing) Just (lookupText env ref)

-- | Look up a field as text, or say why it cannot be used: missing (absent
-- or null) or not a single value (an object or array).
lookupText :: EvalEnv -> Path -> Check Text
lookupText env ref@(Path parts) = case parts of
  (first : rest)
    | Just scopeVal <- Map.lookup first (envScopeVars env) -> fromRaw (lookupPathRaw rest scopeVal)
  [single]
    | Just val <- Map.lookup single (envLetBindings env) -> Right val
  _ -> fromRaw (lookupPathRaw parts (envDoc env))
  where
    fromRaw = \case
      Nothing -> Left [displayPath env ref <> " missing"]
      Just Aeson.Null -> Left [displayPath env ref <> " missing"]
      Just v -> valueToText v `orElse` (displayPath env ref <> " is not a single value")

-- | Look up a field as a number, or say why it cannot be used.
lookupNumber :: EvalEnv -> Path -> Check Double
lookupNumber env ref =
  lookupText env ref >>= \t -> textToDouble t `orElse` (displayPath env ref <> " is not a number")

-- | A field path as an analyst would recognise it in the claim, with
-- quantifier variables replaced by their collection (see 'EvalEnv').
displayPath :: EvalEnv -> Path -> Text
displayPath env (Path parts) = T.intercalate "." $ case parts of
  (first : rest)
    | Just prefix <- Map.lookup first (envScopeNames env) -> prefix ++ rest
  _ -> envDocPrefix env ++ parts

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
  fromCheck $ do
    actual <- lookupNumber env fieldRef
    case (loVal, hiVal) of
      (Syntax.NumberValue lo, Syntax.NumberValue hi) -> Right (actual >= lo && actual <= hi)
      _ -> Left ["BETWEEN needs numbers"]

-- | Evaluate @claim.has_diagnosis "code"@ by searching
-- @diagnosis_codes[*].code@.
--
-- 'Unknown' when the claim has no diagnosis codes to search.
evaluateHasDiagnosis :: EvalEnv -> Syntax.Value -> Truth
evaluateHasDiagnosis env val =
  case val of
    Syntax.StringValue searchCode ->
      searchSources
        (displayPath env (Path ["diagnosis_codes"]) <> " missing or empty")
        [anyCodeInArray (envDoc env) ["diagnosis_codes"] "code" searchCode]
    _ -> Unknown ["has_diagnosis needs a text code"]

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
            "no procedure_codes, service_lines or procedure_code on the claim"
            [ anyCodeInArray doc ["procedure_codes"] "code" searchCode,
              anyCodeInArray doc ["service_lines"] "procedure_code" searchCode,
              (== searchCode) <$> lookupPath ["procedure_code"] doc
            ]
    _ -> Unknown ["has_procedure needs a text code"]

-- | Combine searches of several places a code may appear. 'Nothing' means
-- that place is absent from the claim. Found anywhere → 'Yes'; some place
-- searched without finding it → 'No'; nowhere to search → 'Unknown' with
-- the given reason.
searchSources :: Text -> [Maybe Bool] -> Truth
searchSources reason results
  | Just True `elem` results = Yes
  | any isJust results = No
  | otherwise = Unknown [reason]

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

