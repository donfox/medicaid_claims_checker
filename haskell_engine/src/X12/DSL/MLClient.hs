{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module X12.DSL.MLClient
  ( MLClientConfig (..),
    scoreClaimWithMl,
    parseMlResultFromValue,
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString.Lazy qualified as BL
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
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
import X12.DSL.PolicyCombiner
  ( MLModelInfo (..),
    MLResult (..),
    MLTopFactor (..),
    mlErrorResult,
  )

data MLClientConfig = MLClientConfig
  { mlEndpointUrl :: String,
    mlTimeoutMs :: Int
  }
  deriving (Show, Eq)

scoreClaimWithMl :: MLClientConfig -> Text -> Value -> IO (Either Text MLResult)
scoreClaimWithMl cfg claimId document = do
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

mkRequest :: MLClientConfig -> Text -> Value -> IO Request
mkRequest cfg claimId document = do
  base <- parseRequest (mlEndpointUrl cfg)
  let payload =
        Aeson.object
          [ "contract_version" Aeson..= ("1.0" :: Text),
            "request_id" Aeson..= claimId,
            "claim_id" Aeson..= claimId,
            "claim" Aeson..= Aeson.object ["source_format" Aeson..= ("json" :: Text), "payload" Aeson..= document]
          ]
  pure $
    setRequestResponseTimeout (HC.responseTimeoutMicro (mlTimeoutMs cfg * 1000)) $
      setRequestMethod "POST" $
        setRequestHeader hContentType ["application/json"] $
          setRequestBodyJSON payload $
            base

parseMlResultFromValue :: Value -> Either Text MLResult
parseMlResultFromValue val =
  case AesonTypes.parseEither parseMl val of
    Left err -> Left (T.pack err)
    Right parsed -> Right parsed

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
