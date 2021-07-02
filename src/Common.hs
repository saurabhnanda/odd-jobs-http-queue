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

withPool :: BS.ByteString
         -> (Pool PGS.Connection -> IO a)
         -> IO a
withPool connString action = bracket poolcreator Pool.destroyAllResources action
  where
    poolcreator = Pool.createPool (PGS.connectPostgreSQL connString) PGS.close 1 5 10

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
