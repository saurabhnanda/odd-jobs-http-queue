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
import System.Log.FastLogger as FL
import UnliftIO.Async
import Options.Applicative as Opts

data Env = Env
  { envPool :: !(Pool Connection)
  , envSinkPathMapRef :: !(IORef SinkPathMap)
  , envManager :: !Http.Manager
  , envLogger :: LogLevel -> LogStr -> IO ()
  }

data CliArgs = CliArgs
  { cliDbCreds :: !PGS.ConnectInfo
  , cliDbMaxConn :: !Int
  , cliListenPort :: !Port
  }


main :: IO ()
main = do
  let parserPrefs = prefs $ showHelpOnEmpty <> showHelpOnError
      parserInfo =  info (cliArgParser  <**> helper) fullDesc
  CliArgs{..} <- customExecParser parserPrefs parserInfo
  envManager <- getGlobalManager
  tcache <- FL.newTimeCache FL.simpleTimeFormat
  withTimedFastLogger tcache (LogStdout FL.defaultBufSize) $ \tlogger -> do
    let envLogger = loggingFn tlogger
    envLogger LevelDebug "--- [Source] before withPool"
    withPool cliDbCreds cliDbMaxConn $ \envPool -> do

      envLogger LevelDebug "--- [Source] before createsinkMap"
      envSinkPathMapRef <- withResource envPool $ \conn ->
        (loadActiveSinks conn) >>= (newIORef . prepareSinkPathMap)

      let sinkCfgListener = withResource envPool $ \conn ->
            Common.withSinkCfgListener conn $ \sinks -> do
            envLogger LevelInfo "[Source] About to reload sink map"
            writeIORef envSinkPathMapRef $ prepareSinkPathMap sinks
            envLogger LevelInfo "[Source] Reloaded sink map"

      envLogger LevelDebug "--- [Source] before withAsync sinkCfgListener"
      withAsync sinkCfgListener $ \_ -> do
        envLogger LevelInfo $ toLogStr $ "--- [Source] Starting on port " <> (show cliListenPort)
        Warp.run cliListenPort $ coreApp Env{..}

-- TODO: Handle LogLevel properly
loggingFn :: TimedFastLogger -> LogLevel -> LogStr -> IO ()
loggingFn tlogger _ lstr = tlogger $ \t -> toLogStr t <> " | " <> lstr <> "\n"


coreApp :: Env -> Wai.Application
coreApp Env{..} req responseFn = withResource envPool $ \conn -> do
  activeSinks <- readIORef envSinkPathMapRef
  let rpath = (rawPathInfo req)
  case HM.lookup rpath activeSinks of
    Nothing -> do
      envLogger LevelError $ "Sink not found for incoming path: " <> toLogStr rpath
      responseFn $ Wai.responseLBS status400 [] "Incoming path does not have even a single corresponding HTTP sink"
    Just sinks -> PGS.withTransaction conn $ do
      rid <- saveReq conn req (DL.length sinks)
      jobs <- forM sinks $ \Sink{sinkId} -> Job.createJob conn jobTable $ JobReq rid sinkId
      let jids = DL.map Job.jobId jobs
          respBody = Aeson.encode $ Aeson.object [ "job_ids" Aeson..= jids ]
      envLogger LevelDebug $ "Queued: " <> (toLogStr respBody)
      responseFn $ Wai.responseLBS status200 [(HT.hContentType, "application/json")] respBody

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
               removeHeaders $
               requestHeaders req
             , Binary b
             , sinkCnt
             )
  (PGS.query conn qry args) >>= \case
    (Only x):[] -> pure x
    y -> error $ "Unexpected result from SQL query: " <> show y
  where
    removeHeaders = DL.filter (\(k, _) -> k /= HT.hHost && k /= HT.hContentLength && k /= HT.hTransferEncoding)
    qry = "INSERT INTO http_requests(method, path, query, headers, body, remaining) VALUES(?, ?, ?, ?, ?, ?) RETURNING id"

cliArgParser :: Parser CliArgs
cliArgParser = CliArgs
  <$> Common.dbCredParser
  <*> option auto (long "db-max-connections" <> metavar "MAXCONN" <> value 20 <> showDefault <> help "Maximum connections in DB pool")
  <*> option auto (long "listen-port" <> metavar "PORT" <> value 8080 <> showDefault <> help "Port for incoming HTTP connections")
