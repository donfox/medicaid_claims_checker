{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module X12.DSL.X12Types where

import GHC.Generics
import Data.Aeson (ToJSON, FromJSON)
import Data.Text (Text)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)

-- | Represents a parsed X12 837P claim document
data X12Document = X12Document
    { docInterchanges :: [Interchange]
    } deriving (Show, Eq, Generic)

instance ToJSON X12Document
instance FromJSON X12Document

data Interchange = Interchange
    { intControlNumber :: Text
    , intSender :: Text
    , intReceiver :: Text
    , intGroups :: [FunctionalGroup]
    } deriving (Show, Eq, Generic)

instance ToJSON Interchange
instance FromJSON Interchange

data FunctionalGroup = FunctionalGroup
    { fgControlNumber :: Text
    , fgTransactions :: [Transaction]
    } deriving (Show, Eq, Generic)

instance ToJSON FunctionalGroup
instance FromJSON FunctionalGroup

data Transaction = Transaction
    { txControlNumber :: Text
    , txType :: Text  -- "837" for professional claims
    , txLoops :: Map Text [Loop]  -- Loop ID -> Loop instances
    } deriving (Show, Eq, Generic)

instance ToJSON Transaction
instance FromJSON Transaction

data Loop = Loop
    { loopId :: Text  -- e.g., "2300" (Claim), "2400" (Service Line)
    , loopSegments :: [Segment]
    , loopChildren :: [Loop]  -- Nested loops
    } deriving (Show, Eq, Generic)

instance ToJSON Loop
instance FromJSON Loop

data Segment = Segment
    { segmentId :: Text  -- e.g., "CLM", "SV1", "DTP"
    , segmentElements :: [Element]
    } deriving (Show, Eq, Generic)

instance ToJSON Segment
instance FromJSON Segment

data Element = Element
    { elementValue :: Text
    , elementSubelements :: [Text]  -- Composite elements
    } deriving (Show, Eq, Generic)

instance ToJSON Element
instance FromJSON Element

-- | Result of rule evaluation
data RuleResult = RuleResult
    { resultRuleName :: Text
    , resultMatched :: Bool
    , resultAction :: Maybe Action'
    , resultDetails :: Text
    } deriving (Show, Eq, Generic)

instance ToJSON RuleResult
instance FromJSON RuleResult

-- Action' mirrors X12.DSL.Syntax.Action but avoids circular imports
data Action'
    = FlagFraud' Text
    | AssignRiskScore' Int
    | RequireReview' Text
    | RejectClaim' Text
    | CompositeAction' [Action']
    deriving (Show, Eq, Generic)

instance ToJSON Action'
instance FromJSON Action'
