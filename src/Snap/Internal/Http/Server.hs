{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Snap.Internal.Http.Server where

------------------------------------------------------------------------------
import           Control.Arrow (first, second)
import           Control.Monad.State.Strict
import           Control.Exception
import           Data.Char
import           Data.CIByteString
import           Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import           Data.ByteString.Internal (c2w, w2c)
import qualified Data.ByteString.Nums.Careless.Int as Cvt
import           Data.List (foldl')
import qualified Data.Map as Map
import           Data.Maybe (catMaybes, fromMaybe)
import           Data.Monoid
import           Prelude hiding (catch)

-- FIXME: indentation
import GHC.Conc
import System.Exit
import System.IO
import System.IO.Error hiding (catch)
import GHC.IOBase (IOErrorType(..))
------------------------------------------------------------------------------
import           Snap.Internal.Http.Types hiding (Enumerator)
import           Snap.Internal.Http.Parser
import           Snap.Iteratee hiding (foldl', head, take)
import qualified Snap.Iteratee as I

-- guard this by an ifdef later
#ifdef LIBEV
import qualified Snap.Internal.Http.Server.LibevBackend as Backend
import           Snap.Internal.Http.Server.LibevBackend (debug)
#else
import qualified Snap.Internal.Http.Server.SimpleBackend as Backend
import           Snap.Internal.Http.Server.SimpleBackend (debug)
#endif

import           Snap.Internal.Http.Server.Date

-- | The handler has to return the request object because we have to clear the
-- HTTP request body before we send the response. If the handler consumes the
-- request body, it is responsible for setting @rqBody=return@ in the returned
-- request (otherwise we will mess up reading the input stream).
--
-- Note that we won't be bothering end users with this -- the details will be
-- hidden inside the Snap monad
type ServerHandler = Request -> Iteratee IO (Request,Response)

type ServerMonad = StateT ServerState (Iteratee IO)

data ServerState = ServerState
    { _forceConnectionClose  :: Bool
    , _localHostname         :: ByteString
    , _localAddress          :: ByteString
    , _localPort             :: Int
    , _remoteAddr            :: ByteString
    , _remotePort            :: Int
    }


runServerMonad :: ByteString      -- ^ local host name
               -> ByteString      -- ^ local ip address
               -> Int             -- ^ local port
               -> ByteString      -- ^ remote ip address
               -> Int             -- ^ remote port
               -> ServerMonad a   -- ^ monadic action to run
               -> Iteratee IO a
runServerMonad lh lip lp rip rp m = evalStateT m st
  where
    st = ServerState False lh lip lp rip rp



------------------------------------------------------------------------------
-- input/output


-- FIXME: exception handling

httpServe :: ByteString         -- ^ bind address, or \"*\" for all
          -> Int                -- ^ port to bind to
          -> ByteString         -- ^ local hostname (server name)
          -> ServerHandler      -- ^ handler procedure
          -> IO ()
httpServe bindAddress bindPort localHostname handler = do
    bracket (spawn numCapabilities)
            (\xs -> do
                 debug "Server.httpServe: SHUTDOWN"
                 mapM_ (Backend.stop . fst) xs)
            (runAll)

  where
    runAll xs = do
        mapM_ f $ xs `zip` [0..]
        mapM_ (takeMVar . snd) xs
      where
        f ((backend,mvar),cpu) =
            forkOnIO cpu $ do
                labelMe $ "accThread " ++ show cpu
                forever $ go backend cpu
                putMVar mvar ()


    labelMe :: String -> IO ()
    labelMe s = do
        tid <- myThreadId
        labelThread tid s

    spawn n = do
        sock <- Backend.bindIt bindAddress bindPort
        backends <- mapM (Backend.new sock) $ [0..(n-1)]
        mvars <- replicateM n newEmptyMVar

        return (backends `zip` mvars)


    runOne backend cpu = Backend.withConnection backend cpu $ \conn -> do
        debug "Server.httpServe.runOne: entered"
        let readEnd = Backend.getReadEnd conn
        let writeEnd = I.bufferIteratee $ Backend.getWriteEnd conn

        let raddr = Backend.getRemoteAddr conn
        let rport = Backend.getRemotePort conn
        let laddr = Backend.getLocalAddr conn
        let lport = Backend.getLocalPort conn

        runHTTP localHostname laddr lport raddr rport readEnd writeEnd handler
        debug "Server.httpServe.runHTTP: finished"


    go backend cpu = runOne backend cpu
                   `catches`
                   [ Handler $ \(e :: AsyncException) -> do
                         debug $
                           "Server.httpServe.go: got async exception, " ++
                             "terminating:\n" ++ show e
                         exitFailure

                   , Handler $ \(_ :: Backend.BackendTerminatedException) -> do
                         debug $ "Server.httpServe.go: got backend terminated, waiting for cleanup"
                         let delay = 10 * ((10::Int)^(6::Int))
                         threadDelay delay
                         exitSuccess

                   , Handler $ \(e :: IOException) -> do
                         debug $
                           "Server.httpServe.go: got io exception: " ++ show e

                         let et = ioeGetErrorType e

                         when (et == Interrupted) exitFailure

                   , Handler $ \(e :: SomeException) -> do
                         debug $
                           "Server.httpServe.go: got exception: " ++ show e
                         return () ]


runHTTP :: ByteString         -- ^ local host name
        -> ByteString         -- ^ local ip address
        -> Int                -- ^ local port
        -> ByteString         -- ^ remote ip address
        -> Int                -- ^ remote port
        -> Enumerator IO ()   -- ^ read end of socket
        -> Iteratee IO ()     -- ^ write end of socket
        -> ServerHandler      -- ^ handler procedure
        -> IO ()
runHTTP lh lip lp rip rp readEnd writeEnd handler =
    go `catch` (\(e::SomeException) -> logError $ show e)
  where
    -- FIXME: log error here
    logError s = debug $ "Server.runHTTP: " ++ s

    go = do
        let iter = runServerMonad lh lip lp rip rp $
                                  httpSession writeEnd handler
        readEnd iter >>= run


sERVER_HEADER :: [ByteString]
sERVER_HEADER = ["Snap/0.pre-1"]



-- | Run an HTTP session.
httpSession :: Iteratee IO ()      -- ^ write end of socket
            -> ServerHandler       -- ^ handler procedure
            -> ServerMonad ()
httpSession writeEnd handler = do
    liftIO $ debug "Server.httpSession: entered"
    req        <- receiveRequest
    (req',rsp) <- lift $ handler req

    liftIO $ debug "Server.httpSession: handled, skipping request body"
    lift $ joinIM $ rqBody req' skipToEof

    date <- liftIO getDateString

    let ins = (Map.insert "Date" [date] . Map.insert "Server" sERVER_HEADER)
    let rsp' = updateHeaders ins rsp
    liftIO $ debug "Server.httpSession: request body skipped, sending response"
    sendResponse rsp' writeEnd

    checkConnectionClose (rspHeaders rsp)

    cc <- gets _forceConnectionClose

    if cc
       then return ()
       else httpSession writeEnd handler


receiveRequest :: ServerMonad Request
receiveRequest = do
    ireq <- lift parseRequest
    req  <- toRequest ireq >>= setEnumerator >>= parseForm

    checkConnectionClose $ rqHeaders req
    return req


  where
    -- check: did the client specify "transfer-encoding: chunked"? then we have
    -- to honor that.
    --
    -- otherwise: check content-length header. if set: only take N bytes from
    -- the read end of the socket
    --
    -- if no content-length and no chunked encoding, enumerate the entire
    -- socket and close afterwards
    setEnumerator :: Request -> ServerMonad Request
    setEnumerator req =
        if isChunked
          then return req { rqBody = readChunkedTransferEncoding }
          else maybe noContentLength hasContentLength mbCL

      where
        isChunked = maybe False
                          ((== ["chunked"]) . map toCI)
                          (Map.lookup "transfer-encoding" hdrs)

        hasContentLength :: Int -> ServerMonad Request
        hasContentLength l = do
            return $ req { rqBody = e }
          where
            e :: Enumerator IO a
            e = return . joinI . I.take l

        noContentLength :: ServerMonad Request
        noContentLength = do
            return $ req { rqBody = return . joinI . I.take 0 }


        hdrs = rqHeaders req
        mbCL = Map.lookup "content-length" hdrs >>= return . Cvt.int . head


    parseForm :: Request -> ServerMonad Request
    parseForm req = if doIt then getIt else return req
      where
        doIt = mbCT == Just "application/x-www-form-urlencoded"
        mbCT = liftM head $ Map.lookup "content-type" (rqHeaders req)

        getIt :: ServerMonad Request
        getIt = do
            iter <- liftIO $ rqBody req stream2stream
            body <- lift iter
            let newParams = parseUrlEncoded $ strictize $ fromWrap body
            return $ req { rqBody = return
                         , rqParams = rqParams req `mappend` newParams }


    toRequest (IRequest method uri version kvps) = do
        localAddr     <- gets _localAddress
        localPort     <- gets _localPort
        remoteAddr    <- gets _remoteAddr
        remotePort    <- gets _remotePort
        localHostname <- gets _localHostname

        let (serverName, serverPort) = fromMaybe
                                         (localHostname, localPort)
                                         (liftM (parseHost . head)
                                                (Map.lookup "host" hdrs))


        return $ Request serverName
                         serverPort
                         remoteAddr
                         remotePort
                         localAddr
                         localPort
                         localHostname
                         isSecure
                         hdrs
                         enum
                         mbContentLength
                         method
                         version
                         cookies
                         pathInfo
                         contextPath
                         uri
                         queryString
                         params

      where
        dropLeadingSlash s = maybe s f mbS
          where
            f (a,s') = if a == c2w '/' then s' else s
            mbS = S.uncons s

        isSecure        = False

        hdrs            = toHeaders kvps

        mbContentLength = liftM (Cvt.int . head) $
                          Map.lookup "content-length" hdrs

        cookies         = maybe []
                                (catMaybes . map parseCookie)
                                (Map.lookup "set-cookie" hdrs)

        contextPath     = "/"

        parseHost h = (a, Cvt.int (S.drop 1 b))
          where
            (a,b) = S.break (== (c2w ':')) h

        enum            = return    -- will override in "setEnumerator"
        params          = parseUrlEncoded queryString

        (pathInfo, queryString) = first dropLeadingSlash . second (S.drop 1) $
                                  S.break (== (c2w '?')) uri


sendResponse :: Response
             -> Iteratee IO a
             -> ServerMonad a
sendResponse rsp writeEnd = do
    (hdrs, bodyEnum) <- maybe noCL hasCL (rspContentLength rsp)

    let headerline = S.concat [ "HTTP/"
                              , bshow major
                              , "."
                              , bshow minor
                              , " "
                              , bshow $ rspStatus rsp
                              , " "
                              , rspStatusReason rsp
                              , "\r\n" ]

    let enum = enumBS headerline >.
               enumLBS (fmtHdrs hdrs) >.
               enumBS "\r\n" >.
               bodyEnum (rspBody rsp)

    -- send the data out. run throws an exception on error that we will catch
    -- in the toplevel handler.
    liftIO $ enum writeEnd >>= run

  where
    (major,minor) = rspHttpVersion rsp
    fmtHdrs hdrs = L.fromChunks $ concat xs
      where
        xs = map f $ Map.toList hdrs

        f (k, ys) = map (g k) ys

        g k y = S.concat [ unCI k, ": ", y, "\r\n" ]

    stHdrs = Map.delete "Content-Length" $ rspHeaders rsp

    noCL :: ServerMonad (Headers, Enumerator IO a -> Enumerator IO a)
    noCL = do
        -- are we in HTTP/1.1?
        let sendChunked = (rspHttpVersion rsp) == (1,1)
        if sendChunked
          then do
              return ( Map.insert "Transfer-Encoding" ["chunked"] stHdrs
                     , writeChunkedTransferEncoding )
          else do
              -- HTTP/1.0 and no content-length? We'll have to close the
              -- socket.
              modify $! \s -> s { _forceConnectionClose = True }
              return (stHdrs, id)

    hasCL :: Int -> ServerMonad (Headers, Enumerator IO a -> Enumerator IO a)
    hasCL cl = do
        -- set the content-length header
        return (Map.insert "Content-Length" [fromStr $ show cl] stHdrs, i)
      where
        i :: Enumerator IO a -> Enumerator IO a
        i enum iter = enum (joinI $ takeExactly cl iter)


------------------------------------------------------------------------------
checkConnectionClose :: Headers -> ServerMonad ()
checkConnectionClose hdrs =
    if l == Just ["close"]
       then modify $ \s -> s { _forceConnectionClose = True }
       else return ()
  where
    l  = liftM (map tl) $ Map.lookup "Connection" hdrs
    tl = S.map (c2w . toLower . w2c)

bshow :: (Show a) => a -> ByteString
bshow = S.pack . map c2w . show

-- FIXME: whitespace-trim the values here.
toHeaders :: [(ByteString,ByteString)] -> Headers
toHeaders kvps = foldl' f Map.empty kvps'
  where
    kvps'     = map (first toCI . second (:[])) kvps
    f m (k,v) = Map.insertWith' (flip (++)) k v m
