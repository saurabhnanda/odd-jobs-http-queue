{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Types where

import Data.Aeson as Aeson
import Data.Aeson.Types as Aeson (listParser, Parser)
import Network.HTTP.Types as HT
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text.Encoding as Text
import qualified Data.Text as Text
import qualified Data.List as DL
import qualified Data.Vector as V
import Data.String (fromString)
import OddJobs.Types (TableName)
import GHC.Generics
import Database.PostgreSQL.Simple.FromField as PGS (FromField(..))
import Database.PostgreSQL.Simple.Types as PGS
import Database.PostgreSQL.Simple.ToField as PGS (ToField(..))
import Database.PostgreSQL.Simple.FromRow as PGS (FromRow(..), field)
import qualified Data.HashMap.Strict as HM
import qualified Network.HTTP.Client as Http
import UnliftIO (Exception)
import Data.Pool (Pool)
import Database.PostgreSQL.Simple as PGS (Connection)
import UnliftIO (IORef)
import Data.Hashable (Hashable)
import qualified Data.CaseInsensitive as CI


jobTable :: TableName
jobTable = "jobs"

sinkChangedChannel :: PGS.Identifier
sinkChangedChannel = "sink_changed"

data ReqId = ReqId { rawReqId :: Int } deriving (Eq, Show, Generic, Read)
instance ToJSON ReqId where toJSON = genericToJSON Aeson.defaultOptions{unwrapUnaryRecords=True}
instance FromJSON ReqId where parseJSON = genericParseJSON Aeson.defaultOptions{unwrapUnaryRecords=True}

instance FromField ReqId where
  fromField fld mBS = ReqId <$> (fromField fld mBS)

instance ToField ReqId where
  toField = toField . rawReqId

data Req = Req
  { reqId :: !ReqId
  , reqMethod :: !HT.Method
  , reqPathInfo :: !BS.ByteString
  , reqQueryString :: !BS.ByteString
  , reqHeaders :: !HT.RequestHeaders
  , reqBody :: !BSL.ByteString
  , reqRemaining :: !Int
  }

instance FromRow Req where
  fromRow = Req
    <$> field
    <*> field
    <*> field
    <*> field
    <*> fmap (DL.map toHeader . fromPGArray) field
    <*> field
    <*> field
    where
      toHeader x = case fromPGArray x of
        [k, v] -> (CI.mk k, v)
        z -> Prelude.error $ "Unexpected values in headers: " <> show z


reqDbColumns :: PGS.Query
reqDbColumns = "id, method, path, query, headers, body, remaining"

-- instance FromRow Req where
--   fromRow = Req
--     <$> fromField
--     <*> fromField
--     <*> fromField
--     <*> fromField
--     <*> fromField
--     <*> fromField

-- instance ToRow Req where


-- instance ToJSON Req where
--   toJSON Req{..} =
--     let hs = (flip DL.concatMap) reqHeaders $ \(k, v) -> [ (Text.pack $ show k, Text.decodeUtf8 v) ]
--     in Aeson.object [ "method" .= (Text.decodeUtf8 reqMethod)
--                     , "pathInfo" .= (Text.decodeUtf8 reqPathInfo)
--                     , "queryString" .= (Text.decodeUtf8 reqQueryString)
--                     , "headers" .= hs
--                     ]

-- instance FromJSON Req where
--   parseJSON = withObject "Need an Object to parse to Req" $ \o -> do
--     reqMethod <- Text.encodeUtf8 <$> o .: "method"
--     reqPathInfo <- Text.encodeUtf8 <$> o .: "pathInfo"
--     reqQueryString <- Text.encodeUtf8 <$> o .: "queryString"
--     reqHeaders <- (o .: "headers") >>= (Aeson.listParser headerParser)
--     pure Req{..}
--     where
--       headerParser :: Value -> Aeson.Parser HT.Header
--       headerParser = withArray "Expecting Array to parse into RequestHeaders" $ \a -> do
--         let [k, v] = V.toList a
--         (,)
--           <$> withText "Expecting Text to parse into header-name" (pure . fromString . Text.unpack) k
--           <*> withText "Expecting Text to parse into header-value" (pure . Text.encodeUtf8) v

data JobPayload = JobReq ReqId SinkId
  deriving (Generic)

instance FromJSON JobPayload where
  -- TODO: This can cause a serious bug, I think!
  parseJSON = genericParseJSON Aeson.defaultOptions {tagSingleConstructors=True}

instance ToJSON JobPayload where
  -- TODO: This can cause a serious bug, I think!
  toJSON = genericToJSON Aeson.defaultOptions {tagSingleConstructors=True}


data SinkId = SinkId { rawSinkId :: Int } deriving (Eq, Show, Generic, Hashable)

instance ToJSON SinkId where toJSON = genericToJSON Aeson.defaultOptions{unwrapUnaryRecords=True}
instance FromJSON SinkId where parseJSON = genericParseJSON Aeson.defaultOptions{unwrapUnaryRecords=True}

instance FromField SinkId where
  fromField fld mBS = SinkId <$> (fromField fld mBS)

instance ToField SinkId where
  toField = toField . rawSinkId

data Sink = Sink
  { sinkId :: !SinkId
  , sinkActive :: !Bool
  , sinkSourcePath :: !BS.ByteString
  , sinkUrl :: !BS.ByteString
  } deriving (Eq, Show)

instance FromRow Sink where
  fromRow = Sink
    <$> field
    <*> field
    <*> field
    <*> field

sinkDbColumns :: PGS.Query
sinkDbColumns = "id, active, source_path, sink_url"

type SinkPathMap = HM.HashMap BS.ByteString [Sink]
type SinkIdMap = HM.HashMap SinkId Http.Request

data SinkNotFoundException = SinkNotFoundException SinkId deriving (Eq, Show)
instance Exception SinkNotFoundException
