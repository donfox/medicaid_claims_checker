{-# LANGUAGE DeriveGeneric #-}

module X12.DSL.Syntax where

import GHC.Generics
import Data.Aeson (ToJSON, FromJSON)
import Data.Text (Text)

-- | Core DSL syntax for fraud detection rules
data Rule = Rule
    { ruleName :: Text
    , ruleDescription :: Text
    , ruleCondition :: Predicate
    , ruleAction :: Action
    } deriving (Show, Eq, Generic)

instance ToJSON Rule
instance FromJSON Rule

-- | Predicate logic expressions
data Predicate
    = PTrue
    | PFalse
    | Equals FieldRef Value
    | NotEquals FieldRef Value
    | GreaterThan FieldRef Value
    | LessThan FieldRef Value
    | GreaterThanOrEqual FieldRef Value
    | LessThanOrEqual FieldRef Value
    | Contains FieldRef Value
    | Matches FieldRef Text  -- regex pattern
    | IsNull FieldRef
    | IsNotNull FieldRef
    | And Predicate Predicate
    | Or Predicate Predicate
    | Not Predicate
    | Exists SegmentPath Predicate
    | ForAll SegmentPath Predicate
    | Count SegmentPath CompOp Int
    deriving (Show, Eq, Generic)

instance ToJSON Predicate
instance FromJSON Predicate

-- | Field references in X12 documents
data FieldRef
    = Field Text                    -- Simple field name: "billing_amount"
    | SegmentField Text Text        -- Segment.Field: "CLM.claim_amount"
    | LoopField Text Text Text      -- Loop.Segment.Field: "2300.CLM.claim_amount"
    | ElementPosition Int Int Int   -- segment.element.subelement (e.g., CLM01-1)
    deriving (Show, Eq, Generic)

instance ToJSON FieldRef
instance FromJSON FieldRef

-- | Values in predicates
data Value
    = StringValue Text
    | NumberValue Double
    | DateValue Text
    | ListValue [Value]
    deriving (Show, Eq, Generic)

instance ToJSON Value
instance FromJSON Value

-- | Segment path for quantified predicates
data SegmentPath
    = SegmentPath Text [Text]  -- e.g., "2300" ["SV1"]
    deriving (Show, Eq, Generic)

instance ToJSON SegmentPath
instance FromJSON SegmentPath

-- | Comparison operators
data CompOp = EQ | NE | GT | LT | GTE | LTE
    deriving (Show, Eq, Generic)

instance ToJSON CompOp
instance FromJSON CompOp

-- | Actions to take when rule matches
data Action
    = FlagFraud Text              -- Flag with reason
    | AssignRiskScore Int         -- Assign risk score 0-100
    | RequireReview Text          -- Require manual review with note
    | RejectClaim Text            -- Reject claim with reason
    | CompositeAction [Action]    -- Multiple actions
    deriving (Show, Eq, Generic)

instance ToJSON Action
instance FromJSON Action
