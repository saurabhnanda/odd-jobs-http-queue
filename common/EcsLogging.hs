module EcsLogging where

import Data.Aeson as Aeson
import Data.Aeson.Encoding as Aeson
import Network.Wai as Wai
import Data.Time
import Data.List as DL
import Network.HTTP.Types (HttpVersion(..), statusCode)
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as Builder
import System.Log.FastLogger (FormattedTime)
import Data.Maybe
import UnliftIO.IORef
import UnliftIO.Exception
import qualified Data.Text as T
import Data.Text.Lazy.Encoding (decodeUtf8)
import Debug.Trace
import Network.Wai.Internal

newtype ServiceName = ServiceName { rawServiceName :: String }
newtype ServiceId = ServiceId { rawServiceId :: String }

iso8601Format :: BS.ByteString
iso8601Format = "%Y-%m-%dT%H:%M:%S%z"

waiReqToEcsLog :: ServiceName
               -> FormattedTime
               -> Wai.Request
               -> Maybe BSL.ByteString
               -> Wai.Response
               -> BSL.ByteString
waiReqToEcsLog serviceName t req mBody res =
  encodingToLazyByteString $
  pairs $ "@timestamp" .= (C8.unpack t)
  <> "service.name" .= (rawServiceName serviceName)
  -- <> "service.id" .= TODO
  <> "service.type" .= ("http-queue" :: String)
  -- <> ("labels" .= )
  -- <> ("message" .= )
  -- <> ("tags" .= )
  <> reqId
  <> reqBodyLength
  <> maybe mempty (\x -> "http.request.body.content" .= decodeUtf8 x) mBody
  <> "http.request.method" .= (C8.unpack $ requestMethod req)
  <> "http.version" .= (let HttpVersion{..} = httpVersion req in (show httpMajor) <> "." <> (show httpMinor))
  <> maybe mempty (\x -> "url.domain" .= C8.unpack x) (requestHeaderHost req)
  <> "url.path" .= (C8.unpack $ rawPathInfo req)
  <> "url.query" .= (C8.unpack $ rawQueryString req)
  <> "url.scheme" .= (if isSecure req then "https" else "http" :: String)
  -- <> "http.response.body.bytes" .= traceShow (responseHeaders)
  <> "http.response.status_code" .= (show $ statusCode $ responseStatus res)
  <> pair' (text "http.response.body.content") respBody
  where
    respBody = case res of
      ResponseFile _ _ filepath _ -> string $ "< file served: " <> filepath <> " >"
      ResponseBuilder _ _ builder -> lazyText $ decodeUtf8 $ Builder.toLazyByteString builder
      ResponseStream _ _ _ -> string "< response stream >"
      ResponseRaw _ _ -> string "< raw response >"
    reqBodyLength = case requestBodyLength req of
      KnownLength x -> "http.request.body.bytes" .= x
      ChunkedBody -> mempty

    reqId = case DL.lookup "X-Request-Id" (requestHeaders req) of
      Just x -> "http.request.id" .= (C8.unpack x)
      Nothing -> mempty

--
-- Copied from Network.Wai.Middleware.RequestLogger
--
getRequestBody :: Request -> IO (Request, [C8.ByteString])
getRequestBody req = do
  let loop front = do
         bs <- requestBody req
         if C8.null bs
             then return $ front []
             else loop $ front . (bs:)
  body <- loop id
  -- logging the body here consumes it, so fill it back up
  -- obviously not efficient, but this is the development logger
  --
  -- Note: previously, we simply used CL.sourceList. However,
  -- that meant that you could read the request body in twice.
  -- While that in itself is not a problem, the issue is that,
  -- in production, you wouldn't be able to do this, and
  -- therefore some bugs wouldn't show up during testing. This
  -- implementation ensures that each chunk is only returned
  -- once.
  ichunks <- newIORef body
  let rbody = atomicModifyIORef ichunks $ \chunks ->
         case chunks of
             [] -> ([], C8.empty)
             x:y -> (y, x)
  let req' = req { requestBody = rbody }
  return (req', body)
