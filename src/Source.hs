module Source where

import Network.Wai as Wai
import Network.Wai.Handler.Warp as Warp
import OddJobs.Job as Job
-- import OddJobs.Web as Web
import OddJobs.ConfigBuilder as Job
import Network.HTTP.Types as HT
import Network.HTTP.Types.Header as HT
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString as BS
import Network.Wai.Middleware.Vhost (vhost)
import Debug.Trace
-- import OddJobs.Cli (defaultMain)
import qualified OddJobs.Job as Job
import Data.Pool as Pool
import UnliftIO (bracket, throwIO, try)
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
import Network.HTTP.Client.TLS (getGlobalManager)
import Common

data Env = Env
  { envPool :: !(Pool Connection)
  , envSinkPathMapRef :: !(IORef SinkPathMap)
  , envManager :: !Http.Manager
  }



main :: IO ()
main = do
  envManager <- getGlobalManager
  withPool "dbname=http_queue user=b2b password=b2b host=localhost" $ \envPool -> do
    withResource envPool runMigrations

    putStrLn "Creating sink map"
    envSinkPathMapRef <- withResource envPool $ \conn ->
      (loadActiveSinks conn) >>= (newIORef . prepareSinkPathMap)

    putStrLn "starting on port 9000"
    Warp.run 9000 $ coreApp Env{..}
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
      rid <- saveReq conn req (DL.length sinks)
      jobs <- forM sinks $ \Sink{sinkId} -> Job.createJob conn jobTable $ JobReq rid sinkId
      let jids = DL.map Job.jobId jobs
      responseFn $ Wai.responseLBS status200 [] $ "Queued: " <> (fromString $ show jids)

-- adminApp :: Wai.Application
-- adminApp req responseFn =
--   responseFn $ Wai.responseLBS status200 [] "admin-app"

saveReq :: Connection -> Wai.Request -> Int -> IO ReqId
saveReq conn req sinkCnt = do
  b <- Wai.lazyRequestBody req
  let args = ( requestMethod req
             , rawPathInfo req
             , rawQueryString req
             , PGArray $ DL.map (\(k, v) -> PGArray [toField $ CI.original k, toField v]) $
               removeHostHeader $
               requestHeaders req
             , Binary b
             , sinkCnt
             )
  (PGS.query conn qry args) >>= \case
    (Only x):[] -> pure x
    y -> error $ "Unexpected result from SQL query: " <> show y
  where
    removeHostHeader = DL.filter (\(k, _) -> k /= HT.hHost)
    qry = "INSERT INTO http_requests(method, path, query, headers, body, remaining) VALUES(?, ?, ?, ?, ?, ?) RETURNING id"




