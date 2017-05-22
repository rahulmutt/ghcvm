{-# LANGUAGE NoImplicitPrelude, KindSignatures, TypeOperators, MagicHash, FlexibleContexts, TypeFamilies, ScopedTypeVariables, InstanceSigs #-}


import Prelude (const, Eq, Show, ($), (.))
import qualified Control.Monad as M (return)
import Unsafe.Coerce (unsafeCoerce)

import Java

data {-# CLASS "java.util.function.Function" #-} Function a b = Function (Object# (Function a b))
  deriving (Class, Eq, Show)

foreign import java unsafe "@wrapper apply"
  fun :: (t <: Object, r <: Object) => (t -> Java (Function t r) r) -> Function t r

foreign import java unsafe "apply" funApply :: (t <: Object, r <: Object) =>
  Function t r -> t -> r

-- Used purely for typeclass instance resolution
newtype Argument a = Argument a

-- Used purely for typeclass instance resolution
type family ToNewFunction a  where
  ToNewFunction (a -> b) = ToNewFunction a -> ToNewFunction b
  ToNewFunction a        = Argument a

type family ToJavaFunction a  where
  ToJavaFunction (a -> b) = Function (ToJavaFunction a) (ToJavaFunction b)
  ToJavaFunction a        = a

class ToFunction a where
  type JavaFunction a
  toFun :: a -> JavaFunction a
  fromFun :: JavaFunction a -> a

instance Class a => ToFunction (Argument a) where
  type JavaFunction (Argument a) = a
  toFun :: Argument a -> a
  toFun (Argument a) = a
  fromFun :: a -> Argument a
  fromFun = Argument

instance (ToFunction a, ToFunction b,
          Class (JavaFunction a), Class (JavaFunction b)) =>
           ToFunction (a -> b) where
  type JavaFunction (a -> b) = Function (JavaFunction a) (JavaFunction b)
  toFun :: (a -> b) -> JavaFunction (a -> b)
  toFun f = fun (\a -> M.return $ toFun (f (fromFun a)))
  fromFun :: Function (JavaFunction a) (JavaFunction b) -> (a -> b)
  fromFun f = \a -> fromFun (funApply f (toFun a))

toJavaFun :: forall a. ( ToFunction (ToNewFunction a)
                       , ToJavaFunction a ~ JavaFunction (ToNewFunction a) )
          => a -> ToJavaFunction a
toJavaFun f = toFun (unsafeCoerce f :: ToNewFunction a)
