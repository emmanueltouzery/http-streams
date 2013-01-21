--
-- HTTP client for use with io-streams
--
-- Copyright © 2012-2013 Operational Dynamics Consulting, Pty Ltd
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the BSD licence.
--

{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE MagicHash         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS -fno-warn-orphans  #-}

module Network.Http.Inconvenience (
    URL,
    get,
    post,
    postForm,
    put
) where

import Blaze.ByteString.Builder (Builder)
import qualified Blaze.ByteString.Builder as Builder (flush, fromByteString,
                                                      fromWord8, toByteString)
import Control.Exception (bracket)
import Data.Bits (Bits (..))
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as S
import Data.ByteString.Internal (c2w, w2c)
import Data.Char (intToDigit, isAlphaNum)
import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.Monoid (Monoid (..))
import GHC.Exts
import GHC.Word (Word8 (..))
import Network.URI (URI (..), URIAuth (..), nullURI, parseURI)
import System.IO.Streams (InputStream, OutputStream)
import qualified System.IO.Streams as Streams

import Network.Http.Connection
import Network.Http.RequestBuilder
import Network.Http.Types


instance IsString URI where
    fromString str = case parseURI str of
        Just uri    -> uri
        Nothing     -> nullURI

type URL = ByteString

------------------------------------------------------------------------------

--
-- | URL-escapes a string (see
-- <http://tools.ietf.org/html/rfc2396.html#section-2.4>)
--
urlEncode :: ByteString -> URL
urlEncode = Builder.toByteString . urlEncodeBuilder
{-# INLINE urlEncode #-}


--
-- | URL-escapes a string (see
-- <http://tools.ietf.org/html/rfc2396.html#section-2.4>) into a 'Builder'.
--
urlEncodeBuilder :: ByteString -> Builder
urlEncodeBuilder = go mempty
  where
    go !b !s = maybe b' esc (S.uncons y)
      where
        (x,y)     = S.span (flip HashSet.member urlEncodeTable) s
        b'        = b `mappend` Builder.fromByteString x
        esc (c,r) = let b'' = if c == ' '
                                then b' `mappend` Builder.fromWord8 (c2w '+')
                                else b' `mappend` hexd c
                    in go b'' r


hexd :: Char -> Builder
hexd c0 = Builder.fromWord8 (c2w '%') `mappend` Builder.fromWord8 hi `mappend` Builder.fromWord8 low
  where
    !c        = c2w c0
    toDigit   = c2w . intToDigit
    !low      = toDigit $ fromEnum $ c .&. 0xf
    !hi       = toDigit $ (c .&. 0xf0) `shiftr` 4

    shiftr (W8# a#) (I# b#) = I# (word2Int# (uncheckedShiftRL# a# b#))


urlEncodeTable :: HashSet Char
urlEncodeTable = HashSet.fromList $! filter f $! map w2c [0..255]
  where
    f c = isAlphaNum c || elem c "$-.!*'(),"


------------------------------------------------------------------------------


establish :: URI -> IO (Connection)
establish u =
    case scheme of
        "http:" -> openConnection host port
        "https:"-> error ("SSL support not yet implemented")
        _       -> error ("Unknown URI scheme " ++ scheme)
  where
    scheme = uriScheme u

    auth = case uriAuthority u of
        Just x  -> x
        Nothing -> URIAuth "" "localhost" ""

    host = uriRegName auth
    port = case uriPort auth of
        ""  -> 80
        _   -> read $ tail $ uriPort auth :: Int



parseURL :: URL -> URI
parseURL r' =
    case parseURI r of
        Just u  -> u
        Nothing -> error ("Can't parse URI " ++ r)
  where
    r = S.unpack r'

------------------------------------------------------------------------------

path :: URI -> ByteString
path u = S.pack $ concat [uriPath u, uriQuery u, uriFragment u]


------------------------------------------------------------------------------

--
-- | Issue an HTTP GET request and pass the resultant response to the
-- supplied handler function.
--
-- The handler function is as for 'receiveResponse', so you can use one
-- of the supplied convenience handlers if you're in a hurry:
--
-- > x' <- get "http://www.bbc.co.uk/news/" concatHandler
--
-- But as ever the disadvantage of doing this is you are not doing
-- anything intelligent with the HTTP response status code. Better
-- to write your own handler function.
--
get :: URL
    -- ^ Resource to GET from.
    -> (Response -> InputStream ByteString -> IO β)
    -- ^ Handler function to receive the response from the server.
    -> IO β
get r' handler = bracket
    (establish u)
    (teardown)
    (process)

  where
    teardown = closeConnection

    u = parseURL r'

    process c = do
        q <- buildRequest c $ do
            http GET (path u)
            setAccept "*/*"

        sendRequest c q emptyBody

        receiveResponse c handler

--
-- | Send content to a server via an HTTP POST request. Use this
-- function if you have an 'OutputStream' with the body content.
-- See the note in 'put' about @Content-Length@ and the request
-- body needing to fit into memory. If that is inconvenient, just use
-- the underlying "Network.Http.Client" API directly.
--
post :: URL
    -- ^ Resource to POST to.
    -> ContentType
    -- ^ MIME type of the request body being sent.
    -> (OutputStream Builder -> IO α)
    -- ^ Handler function to write content to server.
    -> (Response -> InputStream ByteString -> IO β)
    -- ^ Handler function to receive the response from the server.
    -> IO β
post r' t body handler = bracket
    (establish u)
    (teardown)
    (process)
  where
    teardown = closeConnection

    u = parseURL r'

    process c = do
        (e,n) <- runBody body

        q <- buildRequest c $ do
            http POST (path u)
            setAccept "*/*"
            setContentType t
            setContentLength n

        sendRequest c q e

        receiveResponse c handler


runBody
    :: (OutputStream Builder -> IO α)
    -> IO ((OutputStream Builder -> IO ()), Int)
runBody body = do
    (o1, getList) <- Streams.listOutputStream
        :: IO (OutputStream ByteString, IO [ByteString])
    (o2, getCount) <- Streams.countOutput o1
    o3 <- Streams.builderStream o2

    _ <- body o3
    Streams.write (Just Builder.flush) o3

    n <- getCount
    l <- getList
    i1 <- Streams.fromList l
        :: IO (InputStream ByteString)

    return (inputStreamBody i1, fromIntegral n)


--
-- | Send form data to a server via an HTTP POST request. This is the
-- usual use case; most services expect the body to be MIME type
-- @application/x-www-form-urlencoded@ as this is what conventional
-- web browsers send on form submission. If you want to POST to a URL
-- with an arbitrary Content-Type, use 'post'.
--
postForm
    :: URL
    -- ^ Resource to POST to.
    -> [(ByteString, ByteString)]
    -- ^ List of name=value pairs. Will be sent URL-encoded.
    -> (Response -> InputStream ByteString -> IO β)
    -- ^ Handler function to receive the response from the server.
    -> IO β
postForm r' nvs handler = bracket
    (establish u)
    (teardown)
    (process)
  where
    teardown = closeConnection

    u = parseURL r'

    b' = S.intercalate "&" $ map combine nvs

    combine :: (ByteString,ByteString) -> ByteString
    combine (n',v') = S.concat [urlEncode n', "=", urlEncode v']

    parameters :: OutputStream Builder -> IO ()
    parameters o = do
        Streams.write (Just (Builder.fromByteString b')) o

    process c = do
        (e,n) <- runBody parameters

        q <- buildRequest c $ do
            http POST (path u)
            setAccept "*/*"
            setContentType "application/x-www-form-urlencoded"
            setContentLength n

        sendRequest c q e

        receiveResponse c handler


--
-- | Place content on the server at the given URL via an HTTP PUT
-- request, specifying the content type and a function to write the
-- content to the supplied 'OutputStream'. You might see:
--
-- > put "http://s3.example.com/bucket42/object149" "text/plain" $
-- >     fileBody "hello.txt" $ \p i -> do
-- >         putStr $ show p
-- >         Streams.connect i stdout
--
-- RFC 2616 requires that we send a @Content-Length@ header, but we
-- can't figure that out unless we've run through the outbound stream,
-- which means the entity body being sent must fit entirely into memory.
-- If you need to send something large and already know the size, use
-- the underlying API directly and you can actually stream the body
-- instead. For example:
--
-- > n <- getSize "hello.txt"
-- >
-- > c <- openConnection "s3.example.com" 80
-- >
-- > q <- buildRequest c $ do
-- >     http PUT "/bucket42/object149"
-- >     setContentType "text/plain"
-- >     setContentLength n
-- >
-- > _ <- sendRequest c q (fileBody "hello.txt")
-- > p <- receiveResponse c (\p _ -> return p)
-- >
-- > closeConnection c
-- > assert (getStatusCode p == 201)
--
-- or something to that effect; the key being that you can set the
-- @Content-Length@ header correctly, and then write the content using
-- (in this example) 'fileBody' which will let @io-streams@ stream
-- the content in more-or-less constant space.
--
put :: URL
    -- ^ Resource to PUT to.
    -> ContentType
    -- ^ MIME type of the request body being sent.
    -> (OutputStream Builder -> IO α)
    -- ^ Handler function to write content to server.
    -> (Response -> InputStream ByteString -> IO β)
    -- ^ Handler function to receive the response from the server.
    -> IO β
put r' t body handler = bracket
    (establish u)
    (teardown)
    (process)
  where
    teardown = closeConnection

    u = parseURL r'

    process c = do
        (e,n) <- runBody body

        let len = S.pack $ show (n :: Int)

        q <- buildRequest c $ do
            http PUT (path u)
            setAccept "*/*"
            setHeader "Content-Type" t
            setHeader "Content-Length" len

        sendRequest c q e

        receiveResponse c handler
