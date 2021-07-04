module UI where

import Types
import qualified OddJobs.Web as Web
import Network.Wai as Wai
import Network.Wai.Handler.Warp as Warp
import System.Log.FastLogger as FL
import OddJobs.Cli as Cli
import qualified OddJobs.ConfigBuilder as Cfg
import Common (withPool)

main :: IO ()
main = runCli CliOnlyWebUi{..}
  where
    cliStartWebUI uiStartArgs configOverrideFn = do
      tcache <- FL.newTimeCache FL.simpleTimeFormat
      withTimedFastLogger tcache (LogStdout FL.defaultBufSize) $ \tlogger -> do
        let jobLogger = Cfg.defaultTimedLogger tlogger (Cfg.defaultLogStr Cfg.defaultJobType)
        withPool "dbname=http_queue user=b2b password=b2b host=localhost" $ \dbPool -> do
          Cli.defaultWebUI uiStartArgs $ Cfg.mkUIConfig jobLogger jobTable dbPool configOverrideFn
