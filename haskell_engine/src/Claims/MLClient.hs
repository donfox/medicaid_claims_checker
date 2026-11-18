{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | HTTP client for an external ML fraud-scoring service.
--
-- Sends a claim payload as JSON to the configured endpoint and parses the
-- response into an 'MLResult'.  The expected contract version is @1.0@;
-- responses with a different version are rejected.
--
-- On any network or decoding failure the caller receives @Left errorMsg@,
-- which the 'Claims.PolicyCombiner' translates into an @ML:error_fallback@
-- decision path.
--
-- == Response contract (v1.0)
--
-- @
-- { "contract_version": "1.0",
--   "status": "ok",
--   "model":  { "model_id": "…", "model_version": "…" },
--   "scores": { "risk_score": 0.72, "confidence": 0.88 },
--   "top_factors": [ { "feature": "…", "direction": "up", "contribution": 0.19 } ]
-- }
-- @
module Claims.MLClient
  ( -- * ML result types
    MLModelInfo (..),
    MLTopFactor (..),
    MLResult (..),
    mlStubResult,
    mlErrorResult,

    -- * Calling the scorer
    MLClientConfig (..),
    getMlClientConfig,
    validateMlScorerUrl,
    scoreClaimWithMl,
    parseMlResultFromValue,
  )
where

import Control.Exception (SomeException, try)
import Data.List (isInfixOf, isPrefixOf)
import Data.Aeson (ToJSON, Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString.Lazy qualified as BL
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Network.HTTP.Client qualified as HC
import Network.HTTP.Simple
  ( Request,
    getResponseBody,
    httpLBS,
    parseRequest,
    setRequestBodyJSON,
    setRequestHeader,
    setRequestMethod,
    setRequestResponseTimeout,
  )
import Network.HTTP.Types (hContentType)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

-- | Identity metadata returned by the ML service for audit trails.
data MLModelInfo = MLModelInfo
  { modelId :: Text,
    modelVersion :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON MLModelInfo

-- | A single SHAP-style feature attribution from the ML model.
data MLTopFactor = MLTopFactor
  { feature :: Text,
    direction :: Text,
    contribution :: Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON MLTopFactor

-- | Normalised ML scoring result.  Constructed either from a live ML response
-- ('parseMlResultFromValue'), a stub ('mlStubResult'), or an
-- error sentinel ('mlErrorResult').
data MLResult = MLResult
  { mlStatus :: Text,
    mlRiskScore :: Maybe Double,
    mlConfidence :: Maybe Double,
    mlModelInfo :: Maybe MLModelInfo,
    mlTopFactors :: [MLTopFactor]
  }
  deriving (Show, Eq, Generic)

instance ToJSON MLResult

-- | Deterministic stub for testing without a live ML service.
mlStubResult :: MLResult
mlStubResult =
  MLResult
    { mlStatus = "ok",
      mlRiskScore = Just 0.42,
      mlConfidence = Just 0.74,
      mlModelInfo = Just (MLModelInfo "fraud_stub_v1" "1.0.0"),
      mlTopFactors =
        [ MLTopFactor "provider_30d_outlier_rate" "up" 0.19,
          MLTopFactor "cpt_mix_divergence" "up" 0.12
        ]
    }

-- | Sentinel value used when the ML service call fails.  All score fields
-- are 'Nothing' and 'mlStatus' is @"error"@.
mlErrorResult :: Text -> MLResult
mlErrorResult _errMsg =
  MLResult
    { mlStatus = "error",
      mlRiskScore = Nothing,
      mlConfidence = Nothing,
      mlModelInfo = Nothing,
      mlTopFactors = []
    }

-- | Connection settings for the ML scoring service.
data MLClientConfig = MLClientConfig
  { mlEndpointUrl :: String,   -- ^ Full URL — must begin with @https://@
    mlTimeoutMs :: Int          -- ^ Request timeout in milliseconds
  }
  deriving (Show, Eq)

-- | The scorer settings from @ML_SCORER_URL@ and @ML_TIMEOUT_MS@, or
-- 'Nothing' when no URL is set or the URL is refused.
getMlClientConfig :: IO (Maybe MLClientConfig)
getMlClientConfig = do
  mUrl <- lookupEnv "ML_SCORER_URL"
  mTimeout <- lookupEnv "ML_TIMEOUT_MS"
  let timeoutMs = fromMaybe 120 (mTimeout >>= readMaybe)
  case mUrl of
    Nothing -> pure Nothing
    Just url -> case validateMlScorerUrl url of
      Left err -> do
        hPutStrLn stderr $ "WARNING: ML_SCORER_URL rejected — " ++ err
        pure Nothing
      Right () -> pure $ Just $ MLClientConfig url timeoutMs

-- | Validate that an ML scorer URL does not target a private or cloud-metadata
-- hostname, preventing SSRF when ML_SCORER_URL is influenced by a misconfigured
-- secrets manager or CI pipeline. Blocks RFC-1918 ranges, loopback, link-local,
-- and known cloud metadata hostnames.
validateMlScorerUrl :: String -> Either String ()
validateMlScorerUrl url
  | not ("https://" `isPrefixOf` url) =
      Left "ML_SCORER_URL must begin with https://"
  | otherwise =
      let host = takeWhile (\c -> c /= '/' && c /= ':') (drop 8 url)
      in if any (`isPrefixOf` host) blockedPrefixes || any (`isInfixOf` host) blockedSubstrings
           then Left $ "ML_SCORER_URL hostname is blocked (SSRF prevention): " ++ host
           else Right ()
  where
    blockedPrefixes   = ["127.", "10.", "192.168.", "169.254.", "0.", "::1", "fc00:", "fd"]
    blockedSubstrings = ["localhost", "internal", "metadata", ".local"]

-- | POST a claim to the ML service and return the parsed result.  Returns
-- @Left msg@ on network errors, decode failures, or contract mismatches.
-- Rejects non-HTTPS endpoints immediately to prevent PHI from travelling in
-- cleartext.
scoreClaimWithMl :: MLClientConfig -> Text -> Value -> IO (Either Text MLResult)
scoreClaimWithMl cfg claimId document
  | not ("https://" `isPrefixOf` mlEndpointUrl cfg) =
      pure $ Left "ML_SCORER_URL must use https:// — refusing to transmit PHI over plaintext"
  | otherwise = do
  reqEither <- try (mkRequest cfg claimId document) :: IO (Either SomeException Request)
  case reqEither of
    Left err -> pure $ Left $ T.pack $ "request_build_failed: " <> show err
    Right req -> do
      respEither <- try (httpLBS req) :: IO (Either SomeException (HC.Response BL.ByteString))
      case respEither of
        Left err -> pure $ Left $ T.pack $ "ml_http_error: " <> show err
        Right resp ->
          case Aeson.eitherDecode (getResponseBody resp) of
            Left decodeErr -> pure $ Left $ T.pack $ "ml_decode_error: " <> decodeErr
            Right val ->
              case parseMlResultFromValue val of
                Left parseErr -> pure $ Left parseErr
                Right ml -> pure $ Right ml

-- | Strip patient-identifying fields before forwarding a claim to the ML
-- scorer. Removes subscriber/patient objects (name, DOB, address) and scrubs
-- name/address sub-fields from provider objects, retaining only the
-- statistical features the model needs for fraud scoring.
projectForMl :: Value -> Value
projectForMl (Aeson.Object obj) =
  Aeson.Object $ KM.fromList $ map scrubEntry $ KM.toList stripped
  where
    piiTopKeys = map Key.fromText ["subscriber", "patient", "member", "insured", "guarantor"]
    stripped = foldr KM.delete obj piiTopKeys
    providerKeys = ["provider", "billing_provider", "rendering_provider",
                    "referring_provider", "attending_provider"]
    piiSubKeys = map Key.fromText ["name", "address", "city", "state", "zip", "phone"]
    scrubEntry (k, v)
      | Key.toText k `elem` providerKeys = (k, scrubProviderPii v)
      | otherwise = (k, v)
    scrubProviderPii (Aeson.Object po) = Aeson.Object $ foldr KM.delete po piiSubKeys
    scrubProviderPii v = v
projectForMl v = v

-- | Build the outbound HTTP request with the v1.0 contract payload.
-- The claim document is projected through 'projectForMl' before transmission
-- so patient-identifying fields are never sent to the ML service.
mkRequest :: MLClientConfig -> Text -> Value -> IO Request
mkRequest cfg claimId document = do
  base <- parseRequest (mlEndpointUrl cfg)
  let payload =
        Aeson.object
          [ "contract_version" Aeson..= ("1.0" :: Text),
            "request_id" Aeson..= claimId,
            "claim_id" Aeson..= claimId,
            "claim" Aeson..= Aeson.object ["source_format" Aeson..= ("json" :: Text), "payload" Aeson..= projectForMl document]
          ]
  pure $
    setRequestResponseTimeout (HC.responseTimeoutMicro (mlTimeoutMs cfg * 1000)) $
      setRequestMethod "POST" $
        setRequestHeader hContentType ["application/json"] $
          setRequestBodyJSON payload $
            base

-- | Pure parser: decode an already-parsed JSON 'Value' into an 'MLResult'.
-- Useful for unit testing without network I/O.
parseMlResultFromValue :: Value -> Either Text MLResult
parseMlResultFromValue val =
  case AesonTypes.parseEither parseMl val of
    Left err -> Left (T.pack err)
    Right parsed -> Right parsed

-- | Internal Aeson parser.  Validates contract version, extracts model info,
-- scores, and top contributing factors.  Falls back to @"ml_probability"@ if
-- @"risk_score"@ is missing.
parseMl :: Value -> AesonTypes.Parser MLResult
parseMl = Aeson.withObject "MLResponse" $ \obj -> do
  contractVersion <- obj Aeson..: "contract_version"
  if (contractVersion :: Text) /= "1.0"
    then fail "Unsupported contract_version; expected 1.0"
    else pure ()

  status <- obj Aeson..:? "status" Aeson..!= ("ok" :: Text)
  if T.toLower status /= "ok"
    then pure (mlErrorResult "ml_status_not_ok")
    else do
      modelObj <- obj Aeson..: "model"
      scoresObj <- obj Aeson..: "scores"
      factors <- obj Aeson..:? "top_factors" Aeson..!= []

      modelIdV <- parseModelRequiredField "model_id" modelObj
      modelVersionV <- parseModelRequiredField "model_version" modelObj
      let modelInfo = Just (MLModelInfo modelIdV modelVersionV)

      risk <- parseRiskScoreRequired scoresObj
      conf <- parseNumericField "confidence" scoresObj
      parsedFactors <- mapM parseFactor factors

      pure
        MLResult
          { mlStatus = "ok",
            mlRiskScore = Just risk,
            mlConfidence = conf,
            mlModelInfo = modelInfo,
            mlTopFactors = parsedFactors
          }

parseModelRequiredField :: Text -> Value -> AesonTypes.Parser Text
parseModelRequiredField key = Aeson.withObject "ModelObject" $ \obj -> obj Aeson..: Key.fromText key

parseNumericField :: Text -> Value -> AesonTypes.Parser (Maybe Double)
parseNumericField key =
  Aeson.withObject "NumericObject" $ \obj ->
    case KM.lookup (Key.fromText key) obj of
      Nothing -> pure Nothing
      Just (Aeson.Number n) -> pure $ Just (toRealFloat n)
      Just (Aeson.String t) -> pure $ readMaybeDouble t
      _ -> pure Nothing

-- | Extract risk score, trying @"risk_score"@ first, then @"ml_probability"@
-- as a fallback.  Fails if neither field is present.
parseRiskScoreRequired :: Value -> AesonTypes.Parser Double
parseRiskScoreRequired scoresObj = do
  direct <- parseNumericField "risk_score" scoresObj
  case direct of
    Just v -> pure v
    Nothing -> do
      fallback <- parseNumericField "ml_probability" scoresObj
      case fallback of
        Just v -> pure v
        Nothing -> fail "Missing required score field: risk_score or ml_probability"

parseFactor :: Value -> AesonTypes.Parser MLTopFactor
parseFactor = Aeson.withObject "MLTopFactor" $ \obj -> do
  factorFeature <- obj Aeson..:? "feature" Aeson..!= "unknown_feature"
  factorDirection <- obj Aeson..:? "direction" Aeson..!= "up"
  factorContribution <- obj Aeson..:? "contribution" Aeson..!= 0.0
  pure (MLTopFactor factorFeature factorDirection factorContribution)

readMaybeDouble :: Text -> Maybe Double
readMaybeDouble txt =
  case reads (T.unpack txt) of
    [(d, "")] -> Just d
    _ -> Nothing
