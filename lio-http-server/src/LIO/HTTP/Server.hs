{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-|
This module exposes a general interface for writing web apps. It's
slightly simpler than Wai, but also more general in allowing code to run in
an arbitrary monad (vs. IO). For example, this module exports an HTTP server
implementation in lio's 'DC' monad. Here is a simple example using this directly:

@
{-# LANGUAGE OverloadedStrings #-}
import LIO.HTTP.Server

main :: IO ()
main = server 3000 "127.0.0.1" app

app :: DCApplication
app _ = do
  return $ Response status200 [] "Hello World!"
@

The current 'Request' interface is deliberately simple in making all but the
request body pure. This may change since we may wish to label certain
headers (e.g., because they are sensitive) in the future and labeling a
whole request object may be too coarse grained.

Similarly, the 'Response' data type is deliberately simple. This may be
extended to make it easy to securely stream data in the future.
-}
module LIO.HTTP.Server (
  -- * Handle requests in the WebMonad
  WebMonad(..), Request(..), Response(..),
  Application, Middleware,
  -- * General networking types 
  Port, HostPreference,
  module Network.HTTP.Types,
  -- * DC Label specific
  DCApplication, DCMiddleware
  ) where
import Network.HTTP.Types
import Data.Text (Text)
import LIO.DCLabel
import LIO.TCB (ioTCB)
import Network.Wai.Handler.Warp (Port, HostPreference)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Wai
import qualified Data.ByteString.Lazy as Lazy


-- | This type class is used to describe a general, simple Wai-like interface
-- for manipulating HTTP requests and running a web app server.
class Monad m => WebMonad m where
  -- | Data type representing the request.
  data Request m :: * 
  -- | HTTP request method.
  reqMethod      :: Request m -> Method            
  -- | HTTP version.
  reqHttpVersion :: Request m -> HttpVersion
  -- | Path info, i.e., the URL pieces after the scheme, host, port, not including the query string.
  reqPathInfo    :: Request m -> [Text]
  -- | Parsed query string.
  reqQueryString :: Request m -> Query
  -- | HTTP request headers.
  reqHeaders     :: Request m -> [Header]
  -- | HTTP request body.
  reqBody        :: Request m -> m Lazy.ByteString
  -- | Function for running the application on specified port and host info.
  server         :: Port -> HostPreference -> Application m -> IO ()

-- | This data type encapsulates HTTP responses. For now, we only support lazy
-- ByteString bodies. In the future this data type may be extended to
-- efficiently support streams and file serving.
data Response = Response {
   rspStatus  :: Status          -- ^ HTTP response status.
 , rspHeaders :: [Header]        -- ^ HTTP response headers.
 , rspBody    :: Lazy.ByteString -- ^ HTTP response body
 }


-- header :: Header
-- header  (hAccept, "12")
-- test :: Response
-- test  Response status200 (header:[]) "hello"

instance Show Response where

  show (Response status headers body) = 
    show status ++ " " ++ show headers ++ " " ++ show body

-- | An application is a function that takes an HTTP request and produces an
-- HTTP response, potentially performing side-effects.
type Application m = Request m -> m Response

-- | A middleware is simply code that transforms the request or response.
type Middleware m  = Application m -> Application m

--  LIO specific code:

-- | Instace for the DC monad, wrapping the Wai interface and using the warp
-- server to serve requests. Note that the initial current label and clearance
-- are those provided by `evalDC`. Middleware should be used to change the
-- current label or clearance. Middleware should also be used to label the
-- request if secrecy/integrity is a concern.
instance WebMonad DC where
  data Request DC = RequestTCB { unRequestTCB :: Wai.Request }
  reqMethod      = Wai.requestMethod . unRequestTCB
  reqHttpVersion = Wai.httpVersion . unRequestTCB
  reqPathInfo    = Wai.pathInfo . unRequestTCB
  reqQueryString = Wai.queryString . unRequestTCB
  reqHeaders     = Wai.requestHeaders . unRequestTCB
  reqBody        = ioTCB . Wai.strictRequestBody . unRequestTCB
  server port hostPref app = 
    let settings = Wai.setHost hostPref $ Wai.setPort port $ 
                   Wai.setServerName "lio-http-server" $ Wai.defaultSettings
    in Wai.runSettings settings $ toWaiApplication app

-- test :: Request DC
-- test = RequestTCB Wai.defaultRequest

instance Show (Request DC) where
  show (RequestTCB request) = show request

-- | Type alias for DC-labeled applications
type DCApplication = Application DC

-- | Type alias for DC-labeled middleware
type DCMiddleware = Middleware DC
 
-- | Internal function for converting a DCApplication to a Wai Application
toWaiApplication :: DCApplication -> Wai.Application
toWaiApplication dcApp wReq wRespond = do
  resp <- evalDC $ dcApp $ fromWaiRequest wReq
  wRespond $ toWaiResponse resp
    where fromWaiRequest :: Wai.Request -> Request DC
          fromWaiRequest = RequestTCB
          toWaiResponse :: Response -> Wai.Response
          toWaiResponse (Response status headers body) = Wai.responseLBS status headers body
