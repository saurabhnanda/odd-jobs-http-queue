module Test where

import Test.Tasty as Tasty hiding (withResource)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty.Hedgehog
import Network.HTTP.Client as Http
import qualified Network.HTTP.Types as HT
import qualified Network.HTTP.Types.Header as HT
import qualified Data.ByteString as BS
import Network.Wai.Test as WaiTest (setPath, runSession)
import Network.Wai as Wai
import Data.Functor.Identity (Identity)
import Data.Pool
import Database.PostgreSQL.Simple as PGS
import UnliftIO.Async
import Network.Wai.Handler.Warp as Warp
import Network.HTTP.Client.TLS (getGlobalManager)
import qualified Data.ByteString.Lazy.Char8 as LC8
import qualified Main as Q
import UnliftIO (liftIO)
import Types (ReqId(..))
import Data.String (fromString)
import qualified Data.ByteString.Lazy as BSL
import Debug.Trace
import qualified Data.List as DL
import qualified Data.CaseInsensitive as CI

main :: IO ()
main = do
  Q.withPool "dbname=http_queue user=b2b password=b2b host=localhost" $ \dbPool -> do
    withAsync (Warp.run 9009 $ waiApp dbPool) $ \_ -> do
      defaultMain $
        testGroup "All tests"
        [ testReqRoundtrip dbPool ]

waiApp :: Pool Connection -> Wai.Application
waiApp dbPool req respondFn = withResource dbPool $ \conn -> do
  rid <- Q.saveReq conn req
  respondFn $ Wai.responseLBS HT.status200 [] $ fromString $ show rid

testReqRoundtrip dbPool = testProperty "" $ property $ do
  originalReq <- forAll genHttpReq
  test $ do
    res <- liftIO $ getGlobalManager >>= Http.httpLbs originalReq
    let rid = read $ LC8.unpack $ Http.responseBody res
    dbReq <- liftIO $ withResource dbPool $ \conn -> Q.loadReq conn rid
    let recreatedReq = Q.prepareHttpReq dbReq
    (Http.method originalReq) === (Http.method recreatedReq)
    (Http.path originalReq) === (Http.path recreatedReq)
    (Http.queryString originalReq) === (Http.queryString recreatedReq)
    (filteredHeaders $ Http.requestHeaders originalReq) === (filteredHeaders $ Http.requestHeaders recreatedReq)
    case (Http.requestBody originalReq, Http.requestBody recreatedReq) of
      (Http.RequestBodyBS x, Http.RequestBodyBS y) -> x===y
      (Http.RequestBodyLBS x, Http.RequestBodyLBS y) -> x===y
      (Http.RequestBodyBS x, Http.RequestBodyLBS y) -> BSL.fromStrict x===y
      (Http.RequestBodyLBS x, Http.RequestBodyBS y) -> x===BSL.fromStrict y
      z -> error "Unsupported"
  -- Create HTTP.Request =>
  -- Post to throwaway Wai server via WaiTest.runSession =>
  -- Get resultant Wai.Request =>
  -- Convert to Req =>
  -- Save to DB =>
  -- Load from DB =>
  -- Construct HTTP.Request =>
  -- Roundtrip completed

filteredHeaders :: HT.RequestHeaders -> HT.RequestHeaders
filteredHeaders = DL.filter $ \(h, _) -> h `DL.notElem` ignoredRequestHeaders

ignoredRequestHeaders :: [HT.HeaderName]
ignoredRequestHeaders =
  [ HT.hAcceptEncoding, HT.hHost, HT.hTransferEncoding, HT.hContentLength, HT.hContentEncoding ]


genMethod :: MonadGen m => m HT.Method
genMethod = fmap HT.renderStdMethod $
            Gen.element [HT.GET, HT.POST, HT.PUT, HT.DELETE, HT.PATCH]

genPath :: MonadGen m => m BS.ByteString
genPath = fmap (("/" <>) . (BS.intercalate "/")) $
          Gen.list (Range.linear 0 10) $
          Gen.utf8 (Range.linear 0 10) Gen.unicode

genUrlEncodedString :: MonadGen m => m BS.ByteString
genUrlEncodedString = do
  flag <- Gen.bool
  s <- Gen.bytes (Range.linear 0 10)
  pure $ HT.urlEncode flag s

genUrlEncodedKvp :: (MonadGen m, GenBase m ~ Identity)
                 => m BS.ByteString
genUrlEncodedKvp = do
  k <- Gen.filter (not . BS.null) genUrlEncodedString
  v <- genUrlEncodedString
  pure $ k <> "=" <> v

genQuery :: (MonadGen m, GenBase m ~ Identity)
         => m BS.ByteString
genQuery = do
  kvps <- Gen.list (Range.linear 0 10) genUrlEncodedKvp
  pure $ if kvps == []
         then ""
         else "?" <> BS.intercalate "&" kvps

genWaiReq :: (MonadGen m, GenBase m ~ Identity)
          => m Wai.Request
genWaiReq = do
  method <- genMethod
  path <- genPath
  qry <- genQuery
  pure $ (flip WaiTest.setPath) (path <> "?" <> qry) $
    Wai.defaultRequest { requestMethod = method, httpVersion = HT.http11 }

genRequestHeader :: (MonadGen m, GenBase m ~ Identity)
                 => m (HT.HeaderName, BS.ByteString)
genRequestHeader = (,)
  <$> (fmap CI.mk $ Gen.utf8 (Range.linear 1 10) Gen.unicode)
  <*> (Gen.utf8 (Range.linear 1 10) Gen.unicode)

genReqHeaders :: (MonadGen m, GenBase m ~ Identity)
              => m HT.RequestHeaders
genReqHeaders = Gen.list (Range.linear 1 10) genRequestHeader

genHttpReq :: (MonadGen m, GenBase m ~ Identity)
           => m Http.Request
genHttpReq = do
  method <- genMethod
  path <- genPath
  qry <- genQuery
  headers <- genReqHeaders
  body <- Http.RequestBodyBS <$> Gen.bytes (Range.linear 1 1000)
  pure $ Http.defaultRequest { Http.method = method
                             , Http.host = "localhost"
                             , Http.port = 9009
                             , Http.path = path
                             , Http.queryString = qry
                             , Http.requestHeaders  = headers
                             , Http.requestBody = body
                             }
