{-# LANGUAGE OverloadedStrings #-}

module X12.DSL.EvaluationContract
  ( EvaluationRequest (..),
  )
where

import Data.Aeson (FromJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.Text (Text)
import Data.Text qualified as T

data EvaluationRequest = EvaluationRequest
  { evalContractVersion :: Text,
    evalRequestId :: Text,
    evalClaimId :: Text,
    evalTenantId :: Text,
    evalRulesText :: Text,
    evalDocument :: Aeson.Value,
    evalContext :: Maybe Aeson.Value
  }
  deriving (Show)

instance FromJSON EvaluationRequest where
  parseJSON = Aeson.withObject "EvaluationRequest" $ \v -> do
    contractVersion <- v Aeson..: "contract_version"
    requestId <- v Aeson..: "request_id"
    claimId <- v Aeson..: "claim_id"
    tenantId <- v Aeson..: "tenant_id"
    rulesText <- v Aeson..: "rulesText"
    document <- v Aeson..: "document"
    context <- v Aeson..:? "context"

    if contractVersion /= ("1.0" :: Text)
      then fail "Unsupported contract_version; expected 1.0"
      else pure ()

    ensureNonEmpty "request_id" requestId
    ensureNonEmpty "claim_id" claimId
    ensureNonEmpty "tenant_id" tenantId

    pure
      EvaluationRequest
        { evalContractVersion = contractVersion,
          evalRequestId = requestId,
          evalClaimId = claimId,
          evalTenantId = tenantId,
          evalRulesText = rulesText,
          evalDocument = document,
          evalContext = context
        }

ensureNonEmpty :: Text -> Text -> AesonTypes.Parser ()
ensureNonEmpty fieldName value =
  if T.strip value == ""
    then fail (T.unpack fieldName <> " must not be empty")
    else pure ()
