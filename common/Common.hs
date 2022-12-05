module Common where

import Types
import Data.Pool as Pool
import Database.PostgreSQL.Simple as PGS
import Database.PostgreSQL.Simple.FromRow as PGS
import qualified Data.ByteString as BS
import qualified Data.HashMap.Strict as HM
import qualified Data.List as DL
import Network.HTTP.Client as Http
import qualified Data.ByteString.Char8 as C8
import UnliftIO (bracket)
import Control.Monad (forM, forever, void)
import Database.PostgreSQL.Simple.Notification as PGS
import Debug.Trace
import Options.Applicative as Opts
-- import Network.Wai (Middleware, responseLBS)
import qualified Network.Wai as Wai
import Network.HTTP.Types (status200, status202)
import Control.Concurrent.Async (race)
import Control.Concurrent (threadDelay)

withPool :: PGS.ConnectInfo
         -> Int
         -> (Pool PGS.Connection -> IO a)
         -> IO a
withPool connInfo maxConn action = bracket poolcreator Pool.destroyAllResources action
  where
    poolcreator = Pool.createPool (PGS.connect connInfo) PGS.close 1 5 maxConn

loadActiveSinks :: Connection -> IO [Sink]
loadActiveSinks conn = PGS.queryWith_ parser conn qry
  where
    qry = "SELECT id, active, source_path, sink_url from http_sinks where active"
    parser = Sink
      <$> field
      <*> field
      <*> field
      <*> field

prepareSinkPathMap :: [Sink] -> SinkPathMap
prepareSinkPathMap sinks =
  HM.fromListWith (++) $ DL.map (\s -> (sinkSourcePath s, [s])) sinks

prepareSinkIdMap :: [Sink] -> IO SinkIdMap
prepareSinkIdMap sinks = do
  x <- forM sinks $ \s -> (,) <$> (pure $ sinkId s) <*> (Http.parseUrlThrow $ C8.unpack $ sinkUrl s)
  pure $ HM.fromList x

withSinkCfgListener :: Connection -> ([Sink] -> IO ()) -> IO ()
withSinkCfgListener conn action = do
  void $ PGS.execute conn "LISTEN ?" (Only sinkChangedChannel)
  forever $ do
    void $ PGS.getNotification conn
    sinks <- loadActiveSinks conn
    void $ action sinks

dbCredParser :: Parser PGS.ConnectInfo
dbCredParser = ConnectInfo
  <$> strOption ( long "pg-host" <> metavar "PGHOST" <> help "Postgres host")
  <*> option auto ( long "pg-port" <> metavar "PGPORT" <> value 5432 <> showDefault <> help "Postgres port")
  <*> strOption ( long "pg-user" <> metavar "PGUSER" <> help "Postgres user")
  <*> strOption ( long "pg-password" <> metavar "PGPASSWORD" <> help "Postgres password")
  <*> strOption ( long "pg-database" <> metavar "PGDATABASE" <> help "Postgres database")

healthCheckMiddleware :: BS.ByteString -> Pool PGS.Connection -> Int -> Wai.Middleware
healthCheckMiddleware healthPath dbPool delay originalApp req respond =
  case Wai.rawPathInfo req == healthPath of
    False -> originalApp req respond
    True -> do
      (race (threadDelay delay) tryDbConn) >>= \case
        Left _ -> respond $ Wai.responseLBS status202 mempty "degraded"
        Right _ -> respond $ Wai.responseLBS status200 mempty "ok"
  where
    tryDbConn = withResource dbPool (const $ pure ())