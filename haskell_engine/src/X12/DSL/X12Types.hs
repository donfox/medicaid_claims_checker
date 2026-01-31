{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : X12.DSL.X12Types
Description : X12 document structure and evaluation result types
Stability   : experimental

This module defines types representing the hierarchical structure of X12 EDI
documents (specifically 837P professional claims) and the results of rule
evaluation.

== X12 Document Hierarchy

X12 documents have a nested structure:

@
X12Document
 └── Interchange (ISA/IEA envelope)
      └── FunctionalGroup (GS/GE envelope)
           └── Transaction (ST/SE transaction set)
                └── Loop (e.g., 2300 Claim, 2400 Service Line)
                     ├── Segment (e.g., CLM, SV1, DTP)
                     │    └── Element (field values)
                     └── Loop (nested child loops)
@

== Common X12 837P Loops

| Loop ID | Name | Description |
|---------|------|-------------|
| 1000A | Submitter | Claim submitter information |
| 1000B | Receiver | Claim receiver information |
| 2000A | Billing Provider | Provider submitting the claim |
| 2000B | Subscriber | Insurance subscriber |
| 2010AA | Billing Provider Name | Provider details |
| 2300 | Claim | Individual claim header |
| 2400 | Service Line | Individual service/procedure |

== Why Action' Exists

'Action'' is a duplicate of "X12.DSL.Syntax.Action" to avoid circular module
dependencies. The evaluator converts 'Action' to 'Action'' when producing
'RuleResult' values.
-}
module X12.DSL.X12Types
  ( -- * X12 Document Structure
    X12Document (..)
  , Interchange (..)
  , FunctionalGroup (..)
  , Transaction (..)
  , Loop (..)
  , Segment (..)
  , Element (..)
    -- * Evaluation Results
  , RuleResult (..)
  , Action' (..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Text (Text)
import GHC.Generics (Generic)

-- ----------------------------------------------------------------------------
-- X12 Document Structure
-- ----------------------------------------------------------------------------

-- | Top-level X12 document containing one or more interchanges.
--
-- In practice, most files contain a single interchange, but the X12 spec
-- allows multiple.
data X12Document = X12Document
  { docInterchanges :: [Interchange]
    -- ^ List of ISA/IEA interchange envelopes
  } deriving (Show, Eq, Generic)

instance ToJSON X12Document
instance FromJSON X12Document

-- | Interchange envelope (ISA/IEA segments).
--
-- The outermost wrapper in an X12 file, identifying sender and receiver.
data Interchange = Interchange
  { intControlNumber :: Text
    -- ^ Unique control number for this interchange (ISA13)
  , intSender        :: Text
    -- ^ Interchange sender ID (ISA06)
  , intReceiver      :: Text
    -- ^ Interchange receiver ID (ISA08)
  , intGroups        :: [FunctionalGroup]
    -- ^ Functional groups within this interchange
  } deriving (Show, Eq, Generic)

instance ToJSON Interchange
instance FromJSON Interchange

-- | Functional group envelope (GS/GE segments).
--
-- Groups related transactions together (e.g., all 837P claims).
data FunctionalGroup = FunctionalGroup
  { fgControlNumber :: Text
    -- ^ Group control number (GS06)
  , fgTransactions  :: [Transaction]
    -- ^ Transactions within this group
  } deriving (Show, Eq, Generic)

instance ToJSON FunctionalGroup
instance FromJSON FunctionalGroup

-- | Transaction set (ST/SE segments).
--
-- A single business document, e.g., one 837P claim submission which may
-- contain multiple individual claims.
data Transaction = Transaction
  { txControlNumber :: Text
    -- ^ Transaction set control number (ST02)
  , txType          :: Text
    -- ^ Transaction type code, e.g., "837" for professional claims
  , txLoops         :: Map Text [Loop]
    -- ^ Loops indexed by loop ID. Multiple loops with the same ID
    -- (e.g., multiple 2400 service lines) are stored as a list.
  } deriving (Show, Eq, Generic)

instance ToJSON Transaction
instance FromJSON Transaction

-- | Loop structure containing segments and nested loops.
--
-- Loops are repeating structures in X12. For example, loop 2400 (Service Line)
-- repeats once per service on a claim.
data Loop = Loop
  { loopId       :: Text
    -- ^ Loop identifier, e.g., "2300" (Claim), "2400" (Service Line)
  , loopSegments :: [Segment]
    -- ^ Segments directly within this loop
  , loopChildren :: [Loop]
    -- ^ Nested child loops
  } deriving (Show, Eq, Generic)

instance ToJSON Loop
instance FromJSON Loop

-- | Segment containing data elements.
--
-- Segments are the basic data containers in X12, identified by a 2-3 character
-- code (e.g., CLM for claim, SV1 for service line item).
data Segment = Segment
  { segmentId       :: Text
    -- ^ Segment identifier, e.g., "CLM", "SV1", "DTP", "NM1"
  , segmentElements :: [Element]
    -- ^ Data elements within this segment
  } deriving (Show, Eq, Generic)

instance ToJSON Segment
instance FromJSON Segment

-- | Data element, possibly with composite sub-elements.
--
-- Elements are the atomic data values. Some elements are composites containing
-- multiple sub-elements separated by a component separator.
data Element = Element
  { elementValue       :: Text
    -- ^ Primary element value
  , elementSubelements :: [Text]
    -- ^ Sub-elements for composite elements (empty for simple elements)
  } deriving (Show, Eq, Generic)

instance ToJSON Element
instance FromJSON Element

-- ----------------------------------------------------------------------------
-- Evaluation Results
-- ----------------------------------------------------------------------------

-- | Result of evaluating a single rule against a document.
--
-- Captures whether the rule matched and what action should be taken.
data RuleResult = RuleResult
  { resultRuleName :: Text
    -- ^ Name of the rule that was evaluated
  , resultMatched  :: Bool
    -- ^ Whether the rule's condition matched
  , resultAction   :: Maybe Action'
    -- ^ Action to take if matched ('Nothing' if not matched)
  , resultDetails  :: Text
    -- ^ Human-readable explanation of the result
  } deriving (Show, Eq, Generic)

instance ToJSON RuleResult
instance FromJSON RuleResult

-- | Mirror of "X12.DSL.Syntax.Action" for use in results.
--
-- This type exists to avoid circular module dependencies between
-- "X12.DSL.Syntax" and this module. The evaluator converts 'Action' to
-- 'Action'' when building 'RuleResult' values.
data Action'
  = FlagFraud' Text
    -- ^ Flag as potentially fraudulent
  | AssignRiskScore' Int
    -- ^ Assign risk score (0-100)
  | RequireReview' Text
    -- ^ Require manual review
  | RejectClaim' Text
    -- ^ Reject the claim
  | CompositeAction' [Action']
    -- ^ Multiple actions
  deriving (Show, Eq, Generic)

instance ToJSON Action'
instance FromJSON Action'
