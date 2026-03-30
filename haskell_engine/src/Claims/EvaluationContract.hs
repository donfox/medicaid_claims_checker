{-# LANGUAGE OverloadedStrings #-}

-- | Inbound request contract for the @\/api\/batch-evaluate@ endpoint.
--
-- Defines the 'EvaluationRequest' type that is deserialised from incoming
-- JSON.  The 'FromJSON' instance enforces:
--
--   * @contract_version@ must be @"1.0"@
--   * @request_id@, @claim_id@, and @tenant_id@ must be non-empty strings
--
-- == Expected JSON shape
--
-- @
-- { "contract_version": "1.0",
--   "request_id":  "req-001",
--   "claim_id":    "CLM-12345",
--   "tenant_id":   "tenant-a",
--   "rulesText":   "RULE ImDates …",
--   "document":    { … claim fields … },
--   "context":     null
-- }
-- @
module Claims.EvaluationContract
  ( EvaluationRequest (..),
  )
where

import Data.Aeson (FromJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.Text (Text)
import Data.Text qualified as T

-- | A validated evaluation request.  All fields have passed contract and
-- non-empty checks by the time this value is constructed.
data EvaluationRequest = EvaluationRequest
  { evalContractVersion :: Text,        -- ^ Must be @"1.0"@
    evalRequestId :: Text,              -- ^ Caller-supplied correlation ID
    evalClaimId :: Text,                -- ^ Claim identifier to evaluate
    evalTenantId :: Text,               -- ^ Tenant / organisation scope
    evalRulesText :: Text,              -- ^ Raw DSL rule text to compile
    evalDocument :: Aeson.Value,        -- ^ Claim payload (arbitrary JSON)
    evalContext :: Maybe Aeson.Value     -- ^ Optional evaluation context
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

-- | Fail the parse if the given field value is blank (empty or whitespace-only).
ensureNonEmpty :: Text -> Text -> AesonTypes.Parser ()
ensureNonEmpty fieldName value =
  if T.strip value == ""
    then fail (T.unpack fieldName <> " must not be empty")
    else pure ()
