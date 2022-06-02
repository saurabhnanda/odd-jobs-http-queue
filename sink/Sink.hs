module Sink where

import Types
import Common
import Data.Pool as Pool
import Database.PostgreSQL.Simple as PGS
import Database.PostgreSQL.Simple as PGS
import Database.PostgreSQL.Simple.Transaction as PGS
import Database.PostgreSQL.Simple.FromRow as PGS
import Database.PostgreSQL.Simple.Types as PGS (PGArray(..))
import Data.Functor (void)
import Control.Monad (when)
import qualified Data.List as DL
import Network.HTTP.Client as Http
import OddJobs.Job as Job
import UnliftIO.IORef
import UnliftIO (throwIO)
import qualified Data.HashMap.Strict as HM
import qualified Data.CaseInsensitive as CI
import OddJobs.ConfigBuilder as Job
import Network.HTTP.Client.TLS (newTlsManagerWith, tlsManagerSettings)
import System.Log.FastLogger as FL
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import UnliftIO.Async
import Options.Applicative as Opts

data Env = Env
  { envPool :: !(Pool Connection)
  , envSinkIdMapRef :: !(IORef SinkIdMap)
  , envManager :: !Http.Manager
  , envLogger :: LogLevel -> LogStr -> IO ()
  }

data CliArgs = CliArgs
  { cliDbCreds :: !PGS.ConnectInfo
  , cliDbMaxConn :: !Int
  }

main :: IO ()
main = do
  let parserPrefs = prefs $ showHelpOnEmpty <> showHelpOnError
      parserInfo =  info (cliArgParser  <**> helper) fullDesc
  CliArgs{..} <- customExecParser parserPrefs parserInfo
  -- TODO: hard-coding the default timeout to 10 mins - this should be configurable
  envManager <- newTlsManagerWith tlsManagerSettings{managerResponseTimeout=(responseTimeoutMicro $ 1000000 * 60 * 10)}
  tcache <- FL.newTimeCache FL.simpleTimeFormat
  putStrLn "### [Sink] before withTimedFastLogger..."
  withTimedFastLogger tcache (LogStdout FL.defaultBufSize) $ \tlogger -> do
    let jobLogFn = Job.defaultTimedLogger tlogger (Job.defaultLogStr Job.defaultJobType)
        envLogger = loggingFn tlogger
    putStrLn "### [Sink] before runPool..."
    withPool cliDbCreds cliDbMaxConn $ \envPool -> do
      putStrLn "### [Sink] before prepraeSinkIdMap..."
      envSinkIdMapRef <- (withResource envPool loadActiveSinks) >>= prepareSinkIdMap >>= newIORef

      let jobCfg = Job.mkConfig
            jobLogFn
            jobTable
            envPool
            (MaxConcurrentJobs 1000)
            (runJob Env{..}) $
            \cfg -> cfg { cfgDefaultMaxAttempts = 17 }

      let sinkCfgListener = withResource envPool $ \conn ->
            Common.withSinkCfgListener conn $ \sinks -> do
            envLogger LevelInfo "[Sink] About to reload sink map"
            prepareSinkIdMap sinks >>= writeIORef envSinkIdMapRef
            envLogger LevelInfo "[Sink] Reloaded sink map"

      putStrLn "### [Sink] before sinkCfgListener..."
      withAsync sinkCfgListener $ \_ -> do
        putStrLn "### Starting job runner..."
        startJobRunner jobCfg

-- TODO: Handle LogLevel properly
loggingFn :: TimedFastLogger -> LogLevel -> LogStr -> IO ()
loggingFn tlogger _ lstr = tlogger $ \t -> toLogStr t <> " | " <> lstr <> "\n"

callSink :: Env -> ReqId -> SinkId -> IO ()
callSink Env{..} rid sid = do
  dbReq <- withResource envPool $ \conn -> loadReq conn rid
  sinkReq <- readIORef envSinkIdMapRef >>= pure . (HM.lookup sid) >>= \case
    Nothing -> throwIO $ SinkNotFoundException sid
    -- TODO: make the actual HTTP call and analyze the results
    -- if the call is successful, decide whether to delete the dbReq, or not.
    Just r ->
      let reqIdHdr = (hReqId, C8.pack $ show $ rawReqId rid)
          sinkIdHdr  = (hSinkId, C8.pack $ show $ rawSinkId sid)
      in pure $ prepareHttpReq r $ dbReq { reqHeaders = reqIdHdr:sinkIdHdr:(reqHeaders dbReq) }

  void $ Http.httpLbs sinkReq envManager
  withResource envPool $ \conn -> updateOrDeleteReq conn rid

hReqId = CI.mk "X-Queue-Request-Id"
hSinkId = CI.mk "X-Queue-Sink-Id"

jobRunner :: Env -> Job -> IO ()
jobRunner env j = do
  (Job.throwParsePayload j) >>= \case
    JobReq rid sid -> void $ callSink env rid sid

prepareHttpReq :: Http.Request -> Req -> Http.Request
prepareHttpReq r Req{..} = r
  { Http.method = reqMethod
  , Http.queryString = reqQueryString
  , Http.requestHeaders = reqHeaders
  , Http.requestBody = Http.RequestBodyLBS reqBody
  }

loadReq :: Connection -> ReqId -> IO Req
loadReq conn rid = head <$> PGS.queryWith parser conn qry (Only rid)
  where
    qry = "SELECT id, method, path, query, headers, body, remaining from http_requests where id = ?"
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
      <*> field

updateOrDeleteReq :: Connection -> ReqId -> IO ()
updateOrDeleteReq conn rid = withTransaction conn $ do
  remaining :: Int <- fromOnly . head <$> PGS.query conn qry (Only rid)
  when (remaining==0) $ void $ PGS.execute conn delQry (Only rid)
  where
    qry = "UPDATE http_requests SET remaining = remaining - 1 WHERE id = ? RETURNING remaining"
    delQry = "DELETE FROM http_requests where id = ?"

createSink :: Connection -> (Bool, BS.ByteString, BS.ByteString) -> IO Sink
createSink conn args = head <$> PGS.query conn qry args
  where
    qry = "INSERT INTO http_sinks(active, source_path, sink_url) VALUES(?, ?, ?) RETURNING id, active, source_path, sink_url"

runJob :: Env -> Job -> IO ()
runJob env j = (throwParsePayload j) >>= \case
  JobReq rid sid -> void $ callSink env rid sid

cliArgParser :: Parser CliArgs
cliArgParser = CliArgs
  <$> Common.dbCredParser
  <*> option auto (long "db-max-connections" <> metavar "MAXCONN" <> value 20 <> showDefault <> help "Maximum connections in DB pool")
