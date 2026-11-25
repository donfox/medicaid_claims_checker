{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the HTTP layer in app/: "Middleware" and the routing in
-- "Routes", run on WAI requests without starting a server.
module AppSpec (appSpec) where

import Control.Concurrent.QSem (newQSem)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Network.HTTP.Types (Method, Status, methodGet, methodPost, status200, status401, status404, status405)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Network.Socket (Family (AF_INET), SockAddr (..), SocketType (Stream), close, connect, defaultProtocol, socket, tupleToHostAddress)
import Network.Socket.ByteString (recv, sendAll)
import Network.Wai.Handler.Warp (testWithApplicationSettings)
import Network.Wai (Application, Request (..), Response, defaultRequest, responseHeaders, responseLBS, responseStatus)
import Network.Wai.Internal (ResponseReceived (..))
import Test.Hspec
import Middleware
import Claims.Pipeline (EngineConfig (..))
import Routes (app)
import ServerSettings (baseSettings)

-- | Run an application on a request and return its response.
run :: Application -> Request -> IO Response
run application req = do
  ref <- newIORef Nothing
  _ <- application req (\r -> writeIORef ref (Just r) >> pure ResponseReceived)
  maybe (error "the application gave no response") pure =<< readIORef ref

request :: Method -> [Text] -> Request
request method path = defaultRequest {requestMethod = method, pathInfo = path}

withToken :: Request -> Request
withToken r = r {requestHeaders = [("Authorization", "Bearer s3cret")]}

-- | An inner application that always answers 200.
alwaysOk :: Application
alwaysOk _ respond = respond (responseLBS status200 [] "ok")

-- | No scorer and no test override.
testConfig :: EngineConfig
testConfig = EngineConfig Nothing False

statusOf :: Application -> Request -> IO Status
statusOf application r = responseStatus <$> run application r

appSpec :: Spec
appSpec = describe "HTTP layer (app/)" $ do
  describe "constantTimeEq" $
    it "is True only for equal strings" $ do
      constantTimeEq "Bearer abc" "Bearer abc" `shouldBe` True
      constantTimeEq "Bearer abd" "Bearer abc" `shouldBe` False
      constantTimeEq "Bearer ab" "Bearer abc" `shouldBe` False
      constantTimeEq "" "" `shouldBe` True

  describe "authMiddleware" $ do
    let guarded = authMiddleware "s3cret" alwaysOk
    it "lets the right token through" $
      statusOf guarded (withToken (request methodPost ["api", "parse-rule"])) `shouldReturn` status200
    it "refuses a wrong token of the same length" $
      statusOf guarded ((request methodPost ["api", "parse-rule"]) {requestHeaders = [("Authorization", "Bearer s3creX")]})
        `shouldReturn` status401
    it "refuses a missing token" $
      statusOf guarded (request methodPost ["api", "parse-rule"]) `shouldReturn` status401
    it "lets /api/health through without a token" $
      statusOf guarded (request methodGet ["api", "health"]) `shouldReturn` status200
    it "refuses everything but health when no secret is set" $
      statusOf (authMiddleware "" alwaysOk) (withToken (request methodPost ["api", "parse-rule"])) `shouldReturn` status401

  describe "parseRateLimit" $ do
    it "defaults to 1000 when unset" $
      parseRateLimit Nothing `shouldBe` Right 1000
    it "accepts 1 to 10,000,000" $ do
      parseRateLimit (Just "1") `shouldBe` Right 1
      parseRateLimit (Just "10000000") `shouldBe` Right 10000000
    it "refuses anything else, including a huge number that would wrap into range" $
      mapM_
        (\s -> parseRateLimit (Just s) `shouldSatisfy` either (const True) (const False))
        ["0", "-5", "abc", "10000001", "18446744073709552616"]

  describe "pruneRateMap" $
    it "drops timestamps older than the window, and addresses left with none" $ do
      now <- getCurrentTime
      let old = addUTCTime (-120) now
          recent = addUTCTime (-5) now
          addr n = SockAddrInet 0 (tupleToHostAddress (10, 0, 0, n))
          m = Map.fromList [(addr 1, [recent, old]), (addr 2, [old])]
      pruneRateMap now m `shouldBe` Map.fromList [(addr 1, [recent])]

  describe "Routing" $ do
    let routed method path = do
          sem <- newQSem 1
          run (app testConfig sem) (request method path)
    it "an unknown path is 404" $
      responseStatus <$> routed methodGet ["api", "nope"] `shouldReturn` status404
    it "the wrong method is 405, with Allow naming the right one" $ do
      batch <- routed methodGet ["api", "batch-evaluate"]
      responseStatus batch `shouldBe` status405
      lookup "Allow" (responseHeaders batch) `shouldBe` Just "POST"
      health <- routed methodPost ["api", "health"]
      responseStatus health `shouldBe` status405
      lookup "Allow" (responseHeaders health) `shouldBe` Just "GET"
    it "the right method reaches the handler" $
      responseStatus <$> routed methodGet ["api", "health"] `shouldReturn` status200

  describe "Server settings" $
    it "send no Server header naming Warp and its version, even on a refused request" $ do
      let guarded = authMiddleware "s3cret" alwaysOk
      response <- testWithApplicationSettings baseSettings (pure guarded) $ \port ->
        rawRequest port "GET /api/evaluate HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
      BS8.unpack (BS.take 12 response) `shouldBe` "HTTP/1.1 401"
      let headerNames = map (BS8.map toLowerAscii . BS8.takeWhile (/= ':')) (BS8.lines response)
      headerNames `shouldNotContain` ["server"]

-- | Send raw bytes to a local port and read the whole reply (the request
-- asks the server to close the connection after answering).
rawRequest :: Int -> BS.ByteString -> IO BS.ByteString
rawRequest port req = do
  sock <- socket AF_INET Stream defaultProtocol
  connect sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1)))
  sendAll sock req
  let readAll acc = do
        chunk <- recv sock 4096
        if BS.null chunk then pure (BS.concat (reverse acc)) else readAll (chunk : acc)
  reply <- readAll []
  close sock
  pure reply

toLowerAscii :: Char -> Char
toLowerAscii c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c
