{-# LANGUAGE PolyKinds, DataKinds, MagicHash, ScopedTypeVariables, MultiParamTypeClasses #-}
module Eta.Overloadable(Overloadable(..)) where

import GHC.Base
import GHC.TypeLits

class Overloadable (a :: k) (s :: Symbol) r where
  overloaded :: Proxy# a -> Proxy# s -> r
