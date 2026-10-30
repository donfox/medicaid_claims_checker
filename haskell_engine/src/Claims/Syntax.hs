{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Claims.Syntax
-- Description : Abstract syntax tree for the claims rule DSL
--
-- The AST produced by "Claims.Parser" and evaluated by
-- "Claims.SimpleEvaluator". The DSL itself is described in
-- @docs/SYNTAX_GUIDE.md@.
--
-- The AST's JSON encoding (returned by @/api/parse-rule@) is not read by any
-- client. 'Action' and 'RuleResult' are different: their encoding is part of
-- the evaluation reports Phoenix stores, so it must not change.
module Claims.Syntax
  ( Rule (..),
    Binding (..),
    Predicate (..),
    Action (..),
    Path (..),
    Value (..),
    CompOp (..),
    RuleResult (..),
    helperArity,
    compileRegex,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Text.Regex.TDFA (CompOption (multiline), ExecOption, Regex, defaultCompOpt, defaultExecOpt, makeRegexOptsM)
import Text.Regex.TDFA.Text ()

data Rule = Rule
  { ruleName :: Text,
    ruleDescription :: Text,
    ruleBindings :: [Binding],
    ruleCondition :: Predicate,
    ruleAction :: Action
  }
  deriving (Show, Eq, Ord, Generic)

instance ToJSON Rule

-- | @LET name = path@
data Binding = Binding
  { bindingName :: Text,
    bindingField :: Path
  }
  deriving (Show, Eq, Ord, Generic)

instance ToJSON Binding

data Predicate
  = PTrue
  | PFalse
  | -- | @field op value@. Numeric for @>@, @<@, @>=@, @<=@, and for @=@ / @!=@
    -- when the value is a number; otherwise @=@ / @!=@ compare text.
    Compare CompOp Path Value
  | -- | Inclusive: @field BETWEEN lo AND hi@
    Between Path Value Value
  | Contains Path Value
  | -- | POSIX extended regex search; @^@ / @$@ anchor to the whole value.
    Matches Path Text
  | IsNull Path
  | IsNotNull Path
  | HasDiagnosis Value
  | HasProcedure Value
  | And Predicate Predicate
  | Or Predicate Predicate
  | Not Predicate
  | -- | @EXISTS [var IN] path WHERE p@. Without a variable, @p@ is evaluated
    -- with each item as the document.
    Exists (Maybe Text) Path Predicate
  | ForAll (Maybe Text) Path Predicate
  | -- | @COUNT(path) op n@
    Count Path CompOp Int
  | HelperCall Text [Value]
  deriving (Show, Eq, Ord, Generic)

instance ToJSON Predicate

-- | A dotted path into the claim JSON, such as @2300.CLM.claim_amount@ or
-- @service_lines.0.procedure_code@. Names a field, or in EXISTS, FORALL and
-- COUNT a collection.
newtype Path = Path [Text]
  deriving (Show, Eq, Ord, Generic)

instance ToJSON Path

data Value
  = StringValue Text
  | NumberValue Double
  | -- | @[a, b, ...]@, for helpers such as @in_list@
    ListValue [Value]
  | -- | A field on the right-hand side: @field1 > field2@
    FieldValue Path
  deriving (Show, Eq, Ord, Generic)

instance ToJSON Value

-- | Comparison operators. They shadow Prelude's 'Prelude.EQ', 'Prelude.LT'
-- and 'Prelude.GT'.
data CompOp = EQ | NE | GT | LT | GTE | LTE
  deriving (Show, Eq, Ord, Generic)

instance ToJSON CompOp

data Action
  = FlagFraud Text
  | -- | 0 (safe) to 100 (high risk)
    AssignRiskScore Int
  | RequireReview Text
  | RejectClaim Text
  | ApproveClaim Text
  | CompositeAction [Action]
  deriving (Show, Eq, Ord, Generic)

instance ToJSON Action

instance FromJSON Action

-- | The result of evaluating one rule against one claim.
data RuleResult = RuleResult
  { resultRuleName :: Text
  , resultMatched  :: Bool
  , resultAction   :: Maybe Action
  , resultDetails  :: Text
  , resultUndecided :: Bool
    -- ^ The rule could not be decided because data it needs is missing or
    -- unusable. Always 'False' when 'resultMatched' is 'True'.
  } deriving (Show, Eq, Generic)

-- | The JSON encoding is a wire contract with the Phoenix app and with
-- evaluation reports already stored in its database: action tags carry a
-- trailing prime (@{"tag": "RejectClaim'", ...}@), a leftover from when
-- results used a separate primed copy of 'Action'. The type is gone; the
-- format stays.
instance ToJSON RuleResult where
  toJSON r =
    object
      [ "resultRuleName" .= resultRuleName r
      , "resultMatched"  .= resultMatched r
      , "resultAction"   .= fmap (retagActions (<> "'") . toJSON) (resultAction r)
      , "resultDetails"  .= resultDetails r
      , "resultUndecided" .= resultUndecided r
      ]

instance FromJSON RuleResult where
  parseJSON = withObject "RuleResult" $ \o ->
    RuleResult
      <$> o .: "resultRuleName"
      <*> o .: "resultMatched"
      <*> (traverse (parseJSON . retagActions unprime) =<< o .:? "resultAction")
      <*> o .: "resultDetails"
      -- Reports stored before this field existed omit it.
      <*> o .:? "resultUndecided" .!= False
    where
      unprime t = fromMaybe t (T.stripSuffix "'" t)

-- | Rewrite the constructor tag of an encoded 'Action', recursing into
-- 'CompositeAction' contents.
retagActions :: (Text -> Text) -> Aeson.Value -> Aeson.Value
retagActions f (Aeson.Object o) =
  Aeson.Object (KeyMap.fromList [(k, step k v) | (k, v) <- KeyMap.toList o])
  where
    step "tag" (Aeson.String t) = Aeson.String (f t)
    step "contents" v           = retagActions f v
    step _ v                    = v
retagActions f (Aeson.Array a) = Aeson.Array (fmap (retagActions f) a)
retagActions _ v = v

-- ----------------------------------------------------------------------------
-- Built-in helpers and patterns
-- ----------------------------------------------------------------------------
-- Shared by the parser, which rejects bad helper calls and patterns when a
-- rule is written, and the evaluator, which runs them.

-- | Argument count of each built-in helper, keyed by lower-case name.
-- The parser checks calls against this table, so a misspelled helper or a
-- wrong argument count is a parse error instead of a rule that never fires.
-- Keep it in step with 'Claims.SimpleEvaluator.evaluateHelperCall'.
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
