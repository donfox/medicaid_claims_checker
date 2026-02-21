{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module      : X12.DSL.Syntax
-- Description : Abstract syntax tree for the X12 fraud detection DSL
-- Stability   : experimental
--
-- This module defines the core abstract syntax tree (AST) types for the fraud
-- detection domain-specific language. These types represent the structure of
-- parsed rules and are used by both the parser ("X12.DSL.Parser") and evaluators
-- ("X12.DSL.Evaluator", "X12.DSL.SimpleEvaluator").
--
-- == Type Hierarchy
--
-- @
-- Rule
--  ├── ruleName        :: Text
--  ├── ruleDescription :: Text
--  ├── ruleBindings    :: [Binding]
--  ├── ruleCondition   :: Predicate
--  └── ruleAction      :: Action
--
-- Predicate (boolean expressions)
--  ├── Comparisons: Equals, NotEquals, GreaterThan, LessThan, ...
--  ├── Null checks: IsNull, IsNotNull
--  ├── String ops:  Contains, Matches
--  ├── Logic:       And, Or, Not
--  └── Quantifiers: Exists, ForAll, Count
--
-- FieldRef (document field references)
--  ├── Field         "amount"           (simple)
--  ├── SegmentField  "CLM" "amount"     (segment.field)
--  └── LoopField     "2300" "CLM" "01"  (loop.segment.field)
--
-- Action (responses to matched rules)
--  ├── FlagFraud, AssignRiskScore, RequireReview, RejectClaim
--  └── CompositeAction [Action]
-- @
--
-- == JSON Serialization
--
-- All types derive 'ToJSON' and 'FromJSON' instances via "GHC.Generics",
-- allowing rules to be stored as JSON configuration files.
module X12.DSL.Syntax
  ( -- * Core Types
    Rule (..),
    Binding (..),
    Predicate (..),
    Action (..),

    -- * Field References
    FieldRef (..),
    SegmentPath (..),

    -- * Values and Operators
    Value (..),
    CompOp (..),
  )
where

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
  { -- | Unique identifier for the rule
    ruleName :: Text,
    -- | Human-readable description
    ruleDescription :: Text,
    -- | Local LET bindings available in rule condition
    ruleBindings :: [Binding],
    -- | Boolean condition to evaluate
    ruleCondition :: Predicate,
    -- | Action to take when condition is true
    ruleAction :: Action
  }
  deriving (Show, Eq, Generic)

instance ToJSON Rule

instance FromJSON Rule

-- | Local variable binding within a rule.
--
-- Example: @LET amount = 2300.CLM.claim_amount@
data Binding = Binding
  { bindingName :: Text,
    bindingField :: FieldRef
  }
  deriving (Show, Eq, Generic)

instance ToJSON Binding

instance FromJSON Binding

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
  = -- | Always true (useful for testing)
    PTrue
  | -- | Always false (useful for disabling rules)
    PFalse
  | -- | Field equals value: @field = "value"@
    Equals FieldRef Value
  | -- | Field not equals: @field != "value"@
    NotEquals FieldRef Value
  | -- | Numeric greater than: @field > 100@
    GreaterThan FieldRef Value
  | -- | Numeric less than: @field < 100@
    LessThan FieldRef Value
  | -- | Numeric greater or equal: @field >= 100@
    GreaterThanOrEqual FieldRef Value
  | -- | Numeric less or equal: @field <= 100@
    LessThanOrEqual FieldRef Value
  | -- | String contains substring: @field CONTAINS "text"@
    Contains FieldRef Value
  | -- | Regex pattern match: @field MATCHES "pattern"@ (not yet implemented)
    Matches FieldRef Text
  | -- | Field is missing or null: @field IS NULL@
    IsNull FieldRef
  | -- | Field exists and is not null: @field IS NOT NULL@
    IsNotNull FieldRef
  | -- | Logical conjunction: @pred1 AND pred2@
    And Predicate Predicate
  | -- | Logical disjunction: @pred1 OR pred2@
    Or Predicate Predicate
  | -- | Logical negation: @NOT pred@
    Not Predicate
  | -- | Existential quantifier: true if any element in path satisfies predicate
    --
    -- @EXISTS 2400 WHERE SV1.amount > 1000@
    Exists SegmentPath Predicate
  | -- | Universal quantifier: true if all elements in path satisfy predicate
    --
    -- @FORALL 2400 WHERE SV1.amount < 5000@
    ForAll SegmentPath Predicate
  | -- | Count elements in path and compare: @COUNT(2400) > 10@
    Count SegmentPath CompOp Int
  | -- | Built-in helper function call returning boolean.
    --
    -- @is_weekend(claim.service_date)@
    -- @is_high_amount(claim.amount, 50000)@
    HelperCall Text [Value]
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
  = -- | Simple field name, looked up directly in the document.
    --
    -- Example: @"billing_amount"@
    Field Text
  | -- | Segment-qualified field: @segment.field@
    --
    -- Example: @SegmentField "CLM" "amount"@ for @CLM.amount@
    SegmentField Text Text
  | -- | Loop-qualified field: @loop.segment.field@
    --
    -- Example: @LoopField "2300" "CLM" "01"@ for @2300.CLM.01@
    LoopField Text Text Text
  | -- | Direct element position reference (segment index, element, subelement).
    --
    -- For advanced X12 access like @CLM01-1@ (not commonly used with JSON).
    ElementPosition Int Int Int
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
  = -- | Loop ID and optional segment path within the loop
    SegmentPath Text [Text]
  deriving (Show, Eq, Generic)

instance ToJSON SegmentPath

instance FromJSON SegmentPath

-- ----------------------------------------------------------------------------
-- Values
-- ----------------------------------------------------------------------------

-- | Literal values used in predicates for comparisons.
data Value
  = -- | Text value: @"pending"@
    StringValue Text
  | -- | Numeric value: @10000.50@
    NumberValue Double
  | -- | Date value as text: @"2024-01-15"@ (format depends on document)
    DateValue Text
  | -- | List of values for IN-style comparisons (future use)
    ListValue [Value]
  | -- | Field reference for field-to-field comparisons: @field1 > field2@
    FieldRefValue FieldRef
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
  = -- | Equal to
    EQ
  | -- | Not equal to
    NE
  | -- | Greater than
    GT
  | -- | Less than
    LT
  | -- | Greater than or equal
    GTE
  | -- | Less than or equal
    LTE
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
  = -- | Flag the claim as potentially fraudulent with a reason.
    --
    -- @FlagFraud "Billing code mismatch"@
    FlagFraud Text
  | -- | Assign a risk score from 0 (safe) to 100 (high risk).
    --
    -- @AssignRiskScore 75@
    AssignRiskScore Int
  | -- | Flag for manual review with a note explaining why.
    --
    -- @RequireReview "Provider under investigation"@
    RequireReview Text
  | -- | Reject the claim outright with a reason.
    --
    -- @RejectClaim "Duplicate submission"@
    RejectClaim Text
  | -- | Execute multiple actions together.
    --
    -- @CompositeAction [FlagFraud "reason", AssignRiskScore 80]@
    CompositeAction [Action]
  deriving (Show, Eq, Generic)

instance ToJSON Action

instance FromJSON Action
