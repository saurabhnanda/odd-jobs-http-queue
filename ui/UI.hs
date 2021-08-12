module UI where

import Types
import qualified OddJobs.Web as Web
import Network.Wai as Wai
import Network.Wai.Handler.Warp as Warp
import System.Log.FastLogger as FL
import OddJobs.Cli as Cli
import qualified OddJobs.ConfigBuilder as Cfg
import OddJobs.Types (UIConfig(..))
import Common (withPool, dbCredParser)
import OddJobs.Job (Job(..), eitherParsePayload)
import Lucid
import Lucid.Html5
import qualified Data.List as DL
import Database.PostgreSQL.Simple as PGS
import Database.PostgreSQL.Simple.Types as PGS
import Data.Pool
import Options.Applicative as Opts

data CliArgs = CliArgs
  { cliDbCreds :: !PGS.ConnectInfo
  , cliDbMaxConn :: !Int
  , cliUiStartArgs :: !Cli.UIStartArgs
  }

main :: IO ()
main = do
  let parserPrefs = prefs $ showHelpOnEmpty <> showHelpOnError
      parserInfo =  info (cliArgParser  <**> helper) fullDesc
  CliArgs{..} <- customExecParser parserPrefs parserInfo
  tcache <- FL.newTimeCache FL.simpleTimeFormat
  withTimedFastLogger tcache (LogStdout FL.defaultBufSize) $ \tlogger -> do
    let jobLogger = Cfg.defaultTimedLogger tlogger (Cfg.defaultLogStr Cfg.defaultJobType)
    withPool cliDbCreds cliDbMaxConn $ \dbPool -> do
      Cli.defaultWebUI cliUiStartArgs $ Cfg.mkUIConfig jobLogger jobTable dbPool $ \cfg ->
        cfg { uicfgJobToHtml = jobsToHtml dbPool }

jobsToHtml :: Pool Connection -> [Job] -> IO [Html ()]
jobsToHtml dbPool jobs = do
  let payloads :: [Either String JobPayload] = DL.map eitherParsePayload jobs
      (reqIds, sinkIds) = DL.foldl' extractIds ([], []) payloads
  withResource dbPool $ \conn -> do
    reqs :: [Req] <- PGS.query conn
                     ("SELECT " <> reqDbColumns <> " FROM ? WHERE id IN ?")
                     (PGS.Identifier "http_requests", PGS.In reqIds)
    sinks :: [Sink] <- PGS.query conn
                       ("SELECT " <> sinkDbColumns <> " FROM ? WHERE id IN ?")
                       (PGS.Identifier "http_sinks", PGS.In sinkIds)
    pure $ DL.zipWith (jobToHtml reqs sinks) payloads jobs
  where
    extractIds (reqIds, sinkIds) ePload = case ePload of
      Left _ -> (reqIds, sinkIds)
      Right pload -> case pload of
        JobReq rid sid -> (rid:reqIds, sid:sinkIds)

    jobToHtml :: [Req] -> [Sink] -> Either String JobPayload -> Job -> Html ()
    jobToHtml reqs sinks ePayload job =
      case ePayload of
        Right (JobReq rid sid) ->
          case (DL.find ((== rid) . reqId) reqs, DL.find ((== sid) . sinkId) sinks) of
            (Just req, Just sink) -> genHtml req sink job
            _ -> Cfg.defaultJobToHtml Cfg.defaultJobType job
        _ -> Cfg.defaultJobToHtml Cfg.defaultJobType job

    genHtml :: Req -> Sink -> Job -> Html ()
    genHtml Req{..} Sink{..} Job{..} = do
      div_ [ class_ "job" ] $ do
        div_ [ class_ "job-type" ] $ do
          span_ [ class_ "http-req-method", style_ "margin-right: 0.75em;" ] $ toHtml reqMethod
          span_ [ class_ "http-sink-url" ] $ toHtml sinkUrl
        div_ [ class_ "job-payload" ] $ do
          Cfg.defaultPayloadToHtml $ Cfg.defaultJobContent jobPayload
        case jobLastError of
          Nothing -> mempty
          Just e -> do
            div_ [ class_ "job-error collapsed" ] $ do
              a_ [ href_ "javascript: void(0);", onclick_ "toggleError(this)" ] $ do
                span_ [ class_ "badge badge-secondary error-expand" ] "+ Last error"
                span_ [ class_ "badge badge-secondary error-collapse d-none" ] "- Last error"
              " "
              Cfg.defaultErrorToHtml e

cliArgParser :: Parser CliArgs
cliArgParser = CliArgs
  <$> Common.dbCredParser
  <*> option auto (long "db-max-connections" <> metavar "MAXCONN" <> value 5 <> showDefault <> help "Maximum connections in DB pool")
  <*> Cli.uiStartArgsParser
