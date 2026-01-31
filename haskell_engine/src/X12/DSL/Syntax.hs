{-# LANGUAGE DeriveGeneric #-}

{- |
Module      : X12.DSL.Syntax
Description : Abstract syntax tree for the X12 fraud detection DSL
Stability   : experimental

This module defines the core abstract syntax tree (AST) types for the fraud
detection domain-specific language. These types represent the structure of
parsed rules and are used by both the parser ("X12.DSL.Parser") and evaluators
("X12.DSL.Evaluator", "X12.DSL.SimpleEvaluator").

== Type Hierarchy

@
Rule
 ├── ruleName        :: Text
 ├── ruleDescription :: Text
 ├── ruleCondition   :: Predicate
 └── ruleAction      :: Action

Predicate (boolean expressions)
 ├── Comparisons: Equals, NotEquals, GreaterThan, LessThan, ...
 ├── Null checks: IsNull, IsNotNull
 ├── String ops:  Contains, Matches
 ├── Logic:       And, Or, Not
 └── Quantifiers: Exists, ForAll, Count

FieldRef (document field references)
 ├── Field         "amount"           (simple)
 ├── SegmentField  "CLM" "amount"     (segment.field)
 └── LoopField     "2300" "CLM" "01"  (loop.segment.field)

Action (responses to matched rules)
 ├── FlagFraud, AssignRiskScore, RequireReview, RejectClaim
 └── CompositeAction [Action]
@

== JSON Serialization

All types derive 'ToJSON' and 'FromJSON' instances via "GHC.Generics",
allowing rules to be stored as JSON configuration files.
-}
module X12.DSL.Syntax
  ( -- * Core Types
    Rule (..)
  , Predicate (..)
  , Action (..)
    -- * Field References
  , FieldRef (..)
  , SegmentPath (..)
    -- * Values and Operators
  , Value (..)
  , CompOp (..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- ----------------------------------------------------------------------------
-- Rules
-- ----------------------------------------------------------------------------

-- | A fraud detection rule consisting of a condition and action.
--
-- When the 'ruleCondition' evaluates to 'True' against a claim document,
-- the 'ruleAction' is triggered.
--
-- ==== Example
--
-- @
-- Rule
--   { ruleName = "high_amount"
--   , ruleDescription = "Flag claims over $10,000"
--   , ruleCondition = GreaterThan (SegmentField "CLM" "amount") (NumberValue 10000)
--   , ruleAction = FlagFraud "Unusually high claim amount"
--   }
-- @
data Rule = Rule
  { ruleName        :: Text       -- ^ Unique identifier for the rule
  , ruleDescription :: Text       -- ^ Human-readable description
  , ruleCondition   :: Predicate  -- ^ Boolean condition to evaluate
  , ruleAction      :: Action     -- ^ Action to take when condition is true
  } deriving (Show, Eq, Generic)

instance ToJSON Rule
instance FromJSON Rule

-- ----------------------------------------------------------------------------
-- Predicates
-- ----------------------------------------------------------------------------

-- | Boolean expressions that can be evaluated against a claim document.
--
-- Predicates form a tree structure supporting:
--
-- * __Comparisons__: equality, inequality, numeric comparisons
-- * __String operations__: contains, regex matching
-- * __Null checks__: test for missing fields
-- * __Boolean logic__: and, or, not
-- * __Quantifiers__: exists, forall, count over collections
data Predicate
  = PTrue
    -- ^ Always true (useful for testing)
  | PFalse
    -- ^ Always false (useful for disabling rules)
  | Equals FieldRef Value
    -- ^ Field equals value: @field = "value"@
  | NotEquals FieldRef Value
    -- ^ Field not equals: @field != "value"@
  | GreaterThan FieldRef Value
    -- ^ Numeric greater than: @field > 100@
  | LessThan FieldRef Value
    -- ^ Numeric less than: @field < 100@
  | GreaterThanOrEqual FieldRef Value
    -- ^ Numeric greater or equal: @field >= 100@
  | LessThanOrEqual FieldRef Value
    -- ^ Numeric less or equal: @field <= 100@
  | Contains FieldRef Value
    -- ^ String contains substring: @field CONTAINS "text"@
  | Matches FieldRef Text
    -- ^ Regex pattern match: @field MATCHES "pattern"@ (not yet implemented)
  | IsNull FieldRef
    -- ^ Field is missing or null: @field IS NULL@
  | IsNotNull FieldRef
    -- ^ Field exists and is not null: @field IS NOT NULL@
  | And Predicate Predicate
    -- ^ Logical conjunction: @pred1 AND pred2@
  | Or Predicate Predicate
    -- ^ Logical disjunction: @pred1 OR pred2@
  | Not Predicate
    -- ^ Logical negation: @NOT pred@
  | Exists SegmentPath Predicate
    -- ^ Existential quantifier: true if any element in path satisfies predicate
    --
    -- @EXISTS 2400 WHERE SV1.amount > 1000@
  | ForAll SegmentPath Predicate
    -- ^ Universal quantifier: true if all elements in path satisfy predicate
    --
    -- @FORALL 2400 WHERE SV1.amount < 5000@
  | Count SegmentPath CompOp Int
    -- ^ Count elements in path and compare: @COUNT(2400) > 10@
  deriving (Show, Eq, Generic)

instance ToJSON Predicate
instance FromJSON Predicate

-- ----------------------------------------------------------------------------
-- Field References
-- ----------------------------------------------------------------------------

-- | References to fields within an X12/JSON document.
--
-- X12 documents have a hierarchical structure: loops contain segments,
-- segments contain elements. Field references can target different levels
-- of this hierarchy.
data FieldRef
  = Field Text
    -- ^ Simple field name, looked up directly in the document.
    --
    -- Example: @"billing_amount"@
  | SegmentField Text Text
    -- ^ Segment-qualified field: @segment.field@
    --
    -- Example: @SegmentField "CLM" "amount"@ for @CLM.amount@
  | LoopField Text Text Text
    -- ^ Loop-qualified field: @loop.segment.field@
    --
    -- Example: @LoopField "2300" "CLM" "01"@ for @2300.CLM.01@
  | ElementPosition Int Int Int
    -- ^ Direct element position reference (segment index, element, subelement).
    --
    -- For advanced X12 access like @CLM01-1@ (not commonly used with JSON).
  deriving (Show, Eq, Generic)

instance ToJSON FieldRef
instance FromJSON FieldRef

-- | Path to a collection of segments/loops for quantified predicates.
--
-- Used with 'Exists', 'ForAll', and 'Count' to identify which collection
-- to iterate over.
--
-- ==== Examples
--
-- @
-- SegmentPath "2400" []         -- All loops with ID "2400"
-- SegmentPath "2400" ["SV1"]    -- SV1 segments within 2400 loops
-- @
data SegmentPath
  = SegmentPath Text [Text]
    -- ^ Loop ID and optional segment path within the loop
  deriving (Show, Eq, Generic)

instance ToJSON SegmentPath
instance FromJSON SegmentPath

-- ----------------------------------------------------------------------------
-- Values
-- ----------------------------------------------------------------------------

-- | Literal values used in predicates for comparisons.
data Value
  = StringValue Text
    -- ^ Text value: @"pending"@
  | NumberValue Double
    -- ^ Numeric value: @10000.50@
  | DateValue Text
    -- ^ Date value as text: @"2024-01-15"@ (format depends on document)
  | ListValue [Value]
    -- ^ List of values for IN-style comparisons (future use)
  deriving (Show, Eq, Generic)

instance ToJSON Value
instance FromJSON Value

-- ----------------------------------------------------------------------------
-- Operators
-- ----------------------------------------------------------------------------

-- | Comparison operators for numeric predicates.
--
-- Note: These shadow Prelude's 'Prelude.EQ', 'Prelude.LT', 'Prelude.GT',
-- but are used only within the DSL context.
data CompOp
  = EQ   -- ^ Equal to
  | NE   -- ^ Not equal to
  | GT   -- ^ Greater than
  | LT   -- ^ Less than
  | GTE  -- ^ Greater than or equal
  | LTE  -- ^ Less than or equal
  deriving (Show, Eq, Generic)

instance ToJSON CompOp
instance FromJSON CompOp

-- ----------------------------------------------------------------------------
-- Actions
-- ----------------------------------------------------------------------------

-- | Actions to execute when a rule's condition matches.
--
-- Actions represent the business response to detected fraud patterns.
-- Multiple actions can be combined using 'CompositeAction'.
data Action
  = FlagFraud Text
    -- ^ Flag the claim as potentially fraudulent with a reason.
    --
    -- @FlagFraud "Billing code mismatch"@
  | AssignRiskScore Int
    -- ^ Assign a risk score from 0 (safe) to 100 (high risk).
    --
    -- @AssignRiskScore 75@
  | RequireReview Text
    -- ^ Flag for manual review with a note explaining why.
    --
    -- @RequireReview "Provider under investigation"@
  | RejectClaim Text
    -- ^ Reject the claim outright with a reason.
    --
    -- @RejectClaim "Duplicate submission"@
  | CompositeAction [Action]
    -- ^ Execute multiple actions together.
    --
    -- @CompositeAction [FlagFraud "reason", AssignRiskScore 80]@
  deriving (Show, Eq, Generic)

instance ToJSON Action
instance FromJSON Action
