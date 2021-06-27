module Main where

import Network.Wai as Wai
import Network.Wai.Handler.Warp as Warp
import OddJobs.Job as Job
import OddJobs.Web as Web
import Network.HTTP.Types as HT
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString as BS
import Network.Wai.Middleware.Vhost (vhost)
import Debug.Trace
import OddJobs.Cli (defaultMain)
import qualified OddJobs.Job as Job
import Data.Pool as Pool
import UnliftIO (bracket, throwIO)
import UnliftIO.IORef
import Database.PostgreSQL.Simple as PGS
import Database.PostgreSQL.Simple.Transaction as PGS
import Database.PostgreSQL.Simple.ToField as PGS (toField)
import Database.PostgreSQL.Simple.FromRow as PGS (field)
import Database.PostgreSQL.Simple.FromField as PGS (fromField)
import Database.PostgreSQL.Simple.Types as PGS (PGArray(..), Binary(..))
import Types
import Migrations (runMigrations)
import Data.Aeson as Aeson
import qualified Data.List as DL
import qualified Data.CaseInsensitive as CI
import qualified Data.HashMap.Strict as HM
import Control.Monad (forM, void)
import Data.String (fromString)
import Data.Maybe (fromJust)
import qualified Network.HTTP.Client as Http
import qualified Data.ByteString.Char8 as C8


withPool :: BS.ByteString
         -> (Pool PGS.Connection -> IO a)
         -> IO a
withPool connString action = bracket poolcreator Pool.destroyAllResources action
  where
    poolcreator = Pool.createPool (PGS.connectPostgreSQL connString) PGS.close 1 5 8

main :: IO ()
main = do
  withPool "dbname=http_queue user=b2b password=b2b host=localhost" $ \envPool -> do
    withResource envPool runMigrations

    putStrLn "Creating sink map"
    (envSinkPathMapRef, envSinkIdMapRef) <- withResource envPool $ \conn -> do
      (x, y) <- loadActiveSinks conn
      (,) <$> newIORef x <*> newIORef y

    putStrLn "starting on port 9000"
    Warp.run 9000 $
      vhost [(isAdminUiHost, adminApp)] (coreApp Env{..})
  where
    isAdminUiHost req =
      let h = requestHeaderHost req
      in h == (Just "http-queue-admin") || (fmap (BS.isPrefixOf "http-queue-admin:") h == Just True)

coreApp :: Env -> Wai.Application
coreApp Env{..} req responseFn = withResource envPool $ \conn -> do
  activeSinks <- readIORef envSinkPathMapRef
  case HM.lookup (rawPathInfo req) activeSinks of
    Nothing -> responseFn $ Wai.responseLBS status400 [] "Incoming path does not have even a single corresponding HTTP sink"
    Just sinks -> PGS.withTransaction conn $ do
      rid <- saveReq conn req
      jobs <- forM sinks $ \Sink{sinkId} -> Job.createJob conn jobTable $ JobReq rid sinkId
      let jids = DL.map Job.jobId jobs
      responseFn $ Wai.responseLBS status200 [] $ "Queued: " <> (fromString $ show jids)

adminApp :: Wai.Application
adminApp req responseFn =
  responseFn $ Wai.responseLBS status200 [] "admin-app"

saveReq :: Connection -> Wai.Request -> IO ReqId
saveReq conn req = do
  b <- Wai.lazyRequestBody req
  let args = ( requestMethod req
             , rawPathInfo req
             , rawQueryString req
             , PGArray $ DL.map (\(k, v) -> PGArray [toField $ CI.original k, toField v]) $ requestHeaders req
             , Binary b
             )
  (PGS.query conn qry args) >>= \case
    (Only x):[] -> pure x
    y -> error $ "Unexpected result from SQL query: " <> show y
  where
    qry = "INSERT INTO http_requests(method, path, query, headers, body) VALUES(?, ?, ?, ?, ?) RETURNING id"

loadReq :: Connection -> ReqId  -> IO Req
loadReq conn rid = head <$> PGS.queryWith parser conn qry (Only rid)
  where
    qry = "SELECT id, method, path, query, headers, body from http_requests where id = ?"
    toHeader x = case fromPGArray x of
      [k, v] -> (CI.mk k, v)
      z -> Prelude.error $ "Unexpected values in headers: " <> show z
    parser = Req
      <$> field
      <*> field
      <*> field
      <*> field
      <*> fmap (DL.map toHeader . fromPGArray) field
      <*> field

prepareHttpReq :: Req -> Http.Request
prepareHttpReq Req{..} = Http.defaultRequest
  { Http.method = reqMethod
  , Http.path = reqPathInfo
  , Http.queryString = reqQueryString
  , Http.requestHeaders = reqHeaders
  , Http.requestBody = Http.RequestBodyLBS reqBody
  }

loadActiveSinks :: Connection -> IO (SinkPathMap, SinkIdMap)
loadActiveSinks conn = do
  sinks <- PGS.queryWith_ parser conn qry
  let sinkPathMap = HM.fromListWith (++) $ DL.map (\s -> (sinkSourcePath s, [s])) sinks
  sinkIdMap <- forM sinks $ \s -> (,) <$> (pure $ sinkId s) <*> (Http.parseUrlThrow $ C8.unpack $ sinkUrl s)
  pure (sinkPathMap, HM.fromList sinkIdMap)
  where
    qry = "SELECT id, active, source_path, sink_url from http_sinks where active"
    parser = Sink
      <$> field
      <*> field
      <*> field
      <*> field

-- TODO: Req needs to be deleted when there are no more jobs against it
callSink :: Env -> ReqId -> SinkId -> IO ()
callSink Env{..} rid sid = do
  Req{..} <- withResource envPool $ \conn -> loadReq conn rid
  sinkReq <- readIORef envSinkIdMapRef >>= pure . (HM.lookup sid) >>= \case
    Nothing -> throwIO $ SinkNotFoundException sid
    Just r -> pure r { Http.method = reqMethod
                     , Http.path = reqPathInfo
                     , Http.queryString = reqQueryString
                     , Http.requestHeaders = reqHeaders
                     , Http.requestBody = Http.RequestBodyLBS reqBody
                     }
  pure ()

jobRunner :: Env -> Job -> IO ()
jobRunner env j = do
  (Job.throwParsePayload j) >>= \case
    JobReq rid sid -> void $ callSink env rid sid

