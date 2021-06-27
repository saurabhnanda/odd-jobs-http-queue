module Main where

import Network.Wai as Wai
import Network.Wai.Handler.Warp as Warp
import OddJobs.Job as Job
import OddJobs.Web as Web
import Network.HTTP.Types as HTTP
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString as BS
import Network.Wai.Middleware.Vhost (vhost)
import Debug.Trace
import OddJobs.Cli (defaultMain)
import qualified OddJobs.Job as Job
import Data.Pool as Pool
import UnliftIO (bracket)
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
import Control.Monad (forM)
import Data.String (fromString)

type SinkMap = HM.HashMap BS.ByteString [Sink]

withPool :: BS.ByteString
         -> (Pool PGS.Connection -> IO a)
         -> IO a
withPool connString action = bracket poolcreator Pool.destroyAllResources action
  where
    poolcreator = Pool.createPool (PGS.connectPostgreSQL connString) PGS.close 1 5 8

main :: IO ()
main = do
  withPool "dbname=http_queue user=b2b password=b2b host=localhost" $ \dbPool -> do
    withResource dbPool runMigrations

    putStrLn "Creating sink map"
    sinkMapRef <- withResource dbPool $ \conn -> do
      loadActiveSinks conn >>= newIORef

    putStrLn "starting on port 9000"
    Warp.run 9000 $
      vhost [(isAdminUiHost, adminApp)] (coreApp dbPool sinkMapRef)
  where
    isAdminUiHost req =
      let h = requestHeaderHost req
      in h == (Just "http-queue-admin") || (fmap (BS.isPrefixOf "http-queue-admin:") h == Just True)

coreApp :: Pool PGS.Connection -> IORef SinkMap -> Wai.Application
coreApp dbPool sinkMapRef req responseFn = withResource dbPool $ \conn -> do
  activeSinks <- readIORef sinkMapRef
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
    (Only x):_ -> pure x
    y -> error $ "Unexpected result from SQL query: " <> show y
  where
    qry = "INSERT INTO http_requests(method, path, query, headers, body) VALUES(?, ?, ?, ?, ?) RETURNING id"

-- jobRunner :: Job -> IO ()
-- jobRunner j = do
--   (Job.throwParsePayload j) >>= \case
--     JobReq rid -> _todo

loadActiveSinks :: Connection -> IO SinkMap
loadActiveSinks conn = do
  xs <- PGS.queryWith_ parser conn qry
  pure $ HM.fromListWith (++) $ DL.map (\s -> (sinkSourcePath s, [s])) xs
  where
    qry = "SELECT id, active, source_path, sink_host, sink_path from http_sinks where active"
    parser = Sink
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
