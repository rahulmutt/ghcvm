{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE NoImplicitPrelude, MagicHash, UnboxedTuples, BangPatterns #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  ETA.JString
-- Copyright   :  (c) Rahul Muttineni 2016
-- License     :  BSD-style (see the file libraries/base/LICENSE)
--
-- Maintainer  :  rahulmutt@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- The @JString@ type and associated operations.
--
-----------------------------------------------------------------------------

module ETA.JString (
   JString
 , mkJString
 -- , withJString
 -- , withJStringLen
 ) where

import GHC.Base
import GHC.Num
import GHC.Real
import Data.String
import Data.Char
import Foreign
import GHC.Show (Show(..))
import GHC.Pack (unpackCString)

-- TODO: Add rules to simplify
-- fromString (unpackCString# "Hello world!"#) :: JString = JString "Hello world"#
instance IsString JString where
  fromString = mkJString

instance Show JString where
    show = show . unpackCString

-- TODO: Move this to a more appropriate place
{-# INLINE inlinePerformIO #-}
inlinePerformIO :: IO a -> a
inlinePerformIO (IO m) = case m realWorld# of (# _, r #)   -> r

-- TODO: All the following is taken from ETA.Utils.FastString
mkJString :: String -> JString
mkJString str =
  inlinePerformIO $ do
    let l = utf8EncodedLength str
    buf <- mallocForeignPtrBytes l
    withForeignPtr buf $ \ptr -> do
      utf8EncodeString ptr str
      byteBufferToJavaString ptr

utf8EncodedLength :: String -> Int
utf8EncodedLength str = go 0 str
  where go !n [] = n
        go n (c:cs)
          | ord c > 0 && ord c <= 0x007f = go (n+1) cs
          | ord c <= 0x07ff = go (n+2) cs
          | ord c <= 0xffff = go (n+3) cs
          | otherwise       = go (n+4) cs

utf8EncodeChar :: Char -> Ptr Word8 -> IO (Ptr Word8)
utf8EncodeChar c ptr =
  let x = ord c in
  case () of
    _ | x > 0 && x <= 0x007f -> do
          poke ptr (fromIntegral x)
          return (ptr `plusPtr` 1)
        -- NB. '\0' is encoded as '\xC0\x80', not '\0'.  This is so that we
        -- can have 0-terminated UTF-8 strings (see GHC.Base.unpackCStringUtf8).
      | x <= 0x07ff -> do
          poke ptr (fromIntegral (0xC0 .|. ((x `shiftR` 6) .&. 0x1F)))
          pokeElemOff ptr 1 (fromIntegral (0x80 .|. (x .&. 0x3F)))
          return (ptr `plusPtr` 2)
      | x <= 0xffff -> do
          poke ptr (fromIntegral (0xE0 .|. (x `shiftR` 12) .&. 0x0F))
          pokeElemOff ptr 1 (fromIntegral (0x80 .|. (x `shiftR` 6) .&. 0x3F))
          pokeElemOff ptr 2 (fromIntegral (0x80 .|. (x .&. 0x3F)))
          return (ptr `plusPtr` 3)
      | otherwise -> do
          poke ptr (fromIntegral (0xF0 .|. (x `shiftR` 18)))
          pokeElemOff ptr 1 (fromIntegral (0x80 .|. ((x `shiftR` 12) .&. 0x3F)))
          pokeElemOff ptr 2 (fromIntegral (0x80 .|. ((x `shiftR` 6) .&. 0x3F)))
          pokeElemOff ptr 3 (fromIntegral (0x80 .|. (x .&. 0x3F)))
          return (ptr `plusPtr` 4)

utf8EncodeString :: Ptr Word8 -> String -> IO ()
utf8EncodeString ptr str = go ptr str
  where go !_   []     = return ()
        go ptr (c:cs) = do
          ptr' <- utf8EncodeChar c ptr
          go ptr' cs

foreign import java unsafe "@static eta.base.Utils.byteBufferToStr"
  byteBufferToJavaString :: Ptr a -> IO JString
