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
import Control.Concurrent.Async.Lifted
import Network.Wai.Handler.Warp as Warp
import Network.HTTP.Client.TLS (getGlobalManager)
import qualified Data.ByteString.Lazy.Char8 as LC8
import UnliftIO (liftIO, MonadIO, MonadUnliftIO)
import Types (ReqId(..), SinkId(..))
import Data.String (fromString)
import qualified Data.ByteString.Lazy as BSL
import Debug.Trace
import qualified Data.List as DL
import qualified Data.CaseInsensitive as CI
import qualified Common
import qualified Source
import qualified Sink
import Control.Monad (forM, zipWithM_, forM_, void)
import OddJobs.Types (delaySeconds, Seconds(..))
import UnliftIO.IORef
import qualified Data.ByteString.Char8 as C8
import Data.Maybe (fromJust)
import Control.Monad.Trans.Control (MonadBaseControl)
import qualified Migrations
import Network.Socket.Wait as W(wait)
import UnliftIO.Exception

main :: IO ()
main = do
  Common.withPool "dbname=http_queue user=b2b password=b2b host=localhost" $ \dbPool -> do
    withResource dbPool recreateDb
    withAsync (logAllErrors "Sink" Sink.main) $ \_ -> do
      withAsync (logAllErrors "Source" Source.main) $ \_ -> do
        runRandomPort (roundtripSourceApp dbPool) $ \roundtripPort -> do
          W.wait "127.0.0.1" roundtripPort
          defaultMain $ testGroup "All tests"
            [ testReqRoundtrip dbPool roundtripPort
            , testCoreLogic dbPool
            ]
          putStrLn "======> AFTER defaultMain <===== "
  --   putStrLn "======> EXITED outer withAsync <===== "
  -- putStrLn "=====> ABOUT TO EXIT MAIN <====="

-- runRandomPort :: (MonadIO m) => Wai.Application -> (Warp.Port -> m ()) -> m ()
runRandomPort :: ( MonadIO m
                 , MonadBaseControl IO m )
              => Application
              -> (Port -> m b)
              -> m b
runRandomPort app action = do
  (port, socket) <- liftIO Warp.openFreePort
  traceM $ "Starting at port " <> show port
  withAsync (liftIO $ Warp.runSettingsSocket (Warp.setPort port Warp.defaultSettings) socket app) (const $ action port)


logAllErrors :: (MonadIO m, MonadUnliftIO m) => String -> m () -> m ()
logAllErrors msg action = withException action $ \(e :: SomeException) -> do
  liftIO $ putStrLn $ "******* " <> msg <> ": " <> show e

recreateDb :: Connection -> IO ()
recreateDb conn = do
  void $ PGS.execute_ conn "drop table if exists jobs; drop table if exists http_requests; drop table if exists http_sinks;"
  Migrations.runMigrations conn

roundtripSourceApp :: Pool Connection -> Wai.Application
roundtripSourceApp dbPool req respondFn = withResource dbPool $ \conn -> do
  rid <- Source.saveReq conn req 1
  respondFn $ Wai.responseLBS HT.status200 [] $ fromString $ show rid

-- TODO: Maintain an IORef [(SinkUrl, Int)]] to track number of times SinkUrl
-- has been called
coreLogicSinkApp :: IORef [(ReqId, SinkId)] -> Wai.Application
coreLogicSinkApp logRef req respondFn = do
  let hs = Wai.requestHeaders req
      rid = ReqId $ read $ C8.unpack $ fromJust $ DL.lookup Sink.hReqId hs
      sid = SinkId $ read $ C8.unpack $ fromJust $ DL.lookup Sink.hSinkId hs
  atomicModifyIORef' logRef (\x -> ((rid, sid):x, ()))
  putStrLn $ "received " <> show rid <> " " <> show sid
  respondFn $ Wai.responseLBS HT.status200 [] $ "Ok"

testReqRoundtrip dbPool port = testProperty "http-request round-trip" $ property $ do
  originalReq <- forAll $ genHttpReq Http.defaultRequest{Http.port=port} genPath
  sinkPath <- forAll genPath
  test $ do
    res <- liftIO $ getGlobalManager >>= Http.httpLbs originalReq
    let rid = read $ LC8.unpack $ Http.responseBody res
    dbReq <- liftIO $ withResource dbPool $ \conn -> Sink.loadReq conn rid
    let recreatedReq = Sink.prepareHttpReq Http.defaultRequest{Http.path=sinkPath} dbReq
    (Http.method originalReq) === (Http.method recreatedReq)
    sinkPath === (Http.path recreatedReq)
    (Http.queryString originalReq) === (Http.queryString recreatedReq)
    (filteredHeaders $ Http.requestHeaders originalReq) === (filteredHeaders $ Http.requestHeaders recreatedReq)
    case (Http.requestBody originalReq, Http.requestBody recreatedReq) of
      (Http.RequestBodyBS x, Http.RequestBodyBS y) -> x===y
      (Http.RequestBodyLBS x, Http.RequestBodyLBS y) -> x===y
      (Http.RequestBodyBS x, Http.RequestBodyLBS y) -> BSL.fromStrict x===y
      (Http.RequestBodyLBS x, Http.RequestBodyBS y) -> x===BSL.fromStrict y
      z -> error "Unsupported"

testCoreLogic dbPool = testProperty "core source-sink logic" $ withTests 1 $ property $ do

  testData :: [(BS.ByteString, Int, [Http.Request])] <- forAll $ Gen.list (Range.constant 1 30) $ do
    sourcePath <- Gen.filter (\x -> BS.length x > 5) genPath
    sinkCount <- Gen.int (Range.constant 1 30)
    httpReqs <- Gen.list (Range.constant 1 10) $
                genHttpReq Http.defaultRequest{Http.port=9000} $ pure sourcePath
    pure (sourcePath, sinkCount, httpReqs)

  let jobCount = DL.foldl' (\memo (_, sinkCount, httpReqs) -> memo + (sinkCount * DL.length httpReqs)) 0 testData

  let setupSource sinkPort = do
        mgr <- getGlobalManager
        withResource dbPool $ \conn -> forM_ testData (createSinks conn sinkPort)
        forConcurrently_ testData $ \(_, _, httpReqs) ->
          forConcurrently_ httpReqs $ \req -> Http.httpLbs req mgr

  let pollTest :: IORef [(ReqId, SinkId)] -> Int -> TestT IO ()
      pollTest logRef logCnt = do
        logs <- liftIO $ readIORef logRef
        let newLogCnt = DL.length logs
        liftIO $ putStrLn $ ">>>>>>> " <> show newLogCnt <> " of " <> show jobCount
        if newLogCnt < logCnt
          then failure
          else if newLogCnt == jobCount
               then liftIO $ putStrLn ">>>>>>>>>>> All jobs completed"
               else do nonPositiveRemaining <- liftIO getNonPositiveRemaining
                       nonPositiveRemaining === 0
                       delaySeconds $ Seconds 1
                       pollTest logRef newLogCnt

  test $ do
    liftIO $ putStrLn "$$$$$$$$$$ I WAS RUN $$$$$$$$$$"
    logRef <- newIORef []
    runRandomPort (coreLogicSinkApp logRef) $ \sinkPort -> do
      liftIO $ do
        putStrLn "==== WAITING ===="
        liftIO $ W.wait "127.0.0.1" 9000
        liftIO $ W.wait "127.0.0.1" sinkPort
        putStrLn "==== WAIT COMPLETE ===="
        setupSource sinkPort
      race_ (delaySeconds $ Seconds 60) (pollTest logRef 0)
      observedJobCount <- DL.length <$> readIORef logRef
      jobCount === observedJobCount

  where
    createSinks conn (sinkPort :: Int) (p, c, _) =
      forM_ [1..c] $ \_ -> Sink.createSink conn (True, p, "http://localhost:" <> (C8.pack $ show sinkPort) <> "/test")

    getJobCount :: IO Int
    getJobCount = withResource dbPool $ \conn -> fromOnly . head <$> PGS.query_ conn "SELECT count(*) FROM jobs"

    getNonPositiveRemaining :: IO Int
    getNonPositiveRemaining = withResource dbPool $ \conn -> fromOnly . head <$> PGS.query_ conn "SELECT count(*) FROM http_requests where remaining < 1"


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
           => Http.Request
           -> m BS.ByteString
           -> m Http.Request
genHttpReq defReq pathGenerator = do
  method <- genMethod
  path <- pathGenerator
  qry <- genQuery
  headers <- genReqHeaders
  body <- Http.RequestBodyBS <$> Gen.bytes (Range.linear 1 1000)
  pure $ defReq { Http.method = method
                , Http.host = "localhost"
                , Http.path = path
                , Http.queryString = qry
                , Http.requestHeaders  = headers
                , Http.requestBody = body
                }
