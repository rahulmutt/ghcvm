{-# LANGUAGE OverloadedStrings #-}
module ETA.CodeGen.Prim where

import ETA.Main.DynFlags
import ETA.Types.TyCon
import ETA.Types.Type
import ETA.StgSyn.StgSyn
import ETA.Prelude.PrimOp
import ETA.Utils.Panic
import ETA.Utils.FastString

import Codec.JVM

import ETA.CodeGen.ArgRep
import ETA.CodeGen.Monad
import ETA.CodeGen.Foreign
import ETA.CodeGen.Env
import ETA.CodeGen.Layout
import ETA.CodeGen.Types
import ETA.CodeGen.Utils
import ETA.CodeGen.Rts
import ETA.CodeGen.Name

import ETA.Debug
import ETA.Util

import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Foldable (fold)
import Data.Maybe (fromJust, isJust)
import Data.Text (Text)
import Data.List (stripPrefix)
import qualified Data.Text as T

cgOpApp :: StgOp
        -> [StgArg]
        -> Type
        -> CodeGen ()
cgOpApp (StgFCallOp fcall _) args resType = cgForeignCall fcall args resType
-- TODO: Is this primop necessary like in GHC?
cgOpApp (StgPrimOp TagToEnumOp) args@[arg] resType = do
  dflags <- getDynFlags
  codes <- getNonVoidArgCodes args
  let code = case codes of
        [code'] -> code'
        _ -> panic "TagToEnumOp had void arg"
  emitReturn [mkLocDirect True $ tagToClosure dflags tyCon code]
  where tyCon = tyConAppTyCon resType

cgOpApp (StgPrimOp ObjectArrayNewOp) args resType = do
  [nCode] <- getNonVoidArgCodes args
  emitReturn [mkLocDirect False (arrayFt, nCode <> new arrayFt)]
  where arrayFt
          | arrayFt' == jobject = jarray jobject
          | otherwise =  arrayFt'
          where arrayFt' = fromJust
                         . repFieldType_maybe
                         . head . tail . snd
                         $ splitTyConApp resType

cgOpApp (StgPrimOp GetClassOp) [arg] resType = do
  -- TODO: Support array types
  emitReturn [mkLocDirect False
              ( clasFt
              , sconst objText
             <> invokestatic (mkMethodRef clas "forName" [jstring] (ret clasFt)))]
  where proxyTy  = stgArgType arg
        objTy    = maybe Nothing (Just . head . snd)
                 . splitTyConApp_maybe
                 . head . snd . splitTyConApp
                 $ resType
        objText  = maybe
                     "java.lang.Object"
                     ( T.map (\c -> if c == '/' then '.' else c)
                     . tagTypeToText)
                     objTy
        clas = "java/lang/Class"
        clasFt = obj clas

cgOpApp (StgPrimOp primOp) args resType = do
    dflags <- getDynFlags
    argCodes <- getNonVoidArgFtCodes args
    case shouldInlinePrimOp dflags primOp argCodes resType of
      Left primOpLoc -> do
        args' <- getRepFtCodes args
        withContinuation $ do
          emit $ mkCallExit True args'
              <> mkRtsFunCall primOpLoc

      -- TODO: Optimize: Remove the intermediate temp locations
      --       and allow direct code locations
      Right codes'
        | ReturnsPrim VoidRep <- resultInfo
        -> do
            codes <- codes'
            emit $ fold codes
            emitReturn []
        | ReturnsPrim rep <- resultInfo
              -- res <- newTemp rep'
              -- f [res]
              -- emitReturn [res]
        -> do -- Assumes Returns Prim is of Non-closure type
              codes <- codes'
              emitReturn [ mkLocDirect False (primRepFieldType rep, head codes) ]
        | ReturnsAlg tyCon <- resultInfo, isUnboxedTupleTyCon tyCon
        -> do -- locs <- newUnboxedTupleLocs resType
              -- f locs
              codes <- codes'
              let reps = getUnboxedResultReps resType
              emitReturn
                . map (\(rep, code) ->
                         mkLocDirect (isGcPtrRep rep) (primRepFieldType rep, code))
                $ zip reps codes
        | otherwise -> panic "cgPrimOp"
        where resultInfo = getPrimOpResultInfo primOp

cgOpApp (StgPrimCallOp (PrimCall label _)) args resType =
  withContinuation $ do
    argsFtCodes <- getNonVoidArgFtCodes args
    let (argFts, callArgs) = unzip argsFtCodes
    emit $ loadContext
        <> fold callArgs
        <> invokestatic (mkMethodRef clsName methodName (contextType:argFts) void)
  -- sequel <- getSequel
  -- case sequel of
  --   AssignTo targetLocs -> emit $ mkReturnEntry targetLocs
  --   _ -> return ()
  where (clsName, methodName) = labelToMethod (unpackFS label)

inlinePrimCall :: String -> [(FieldType, Code)] -> Code
inlinePrimCall name = error $ "inlinePrimCall: unimplemented = " ++ name

-- TODO: This is a hack to get around the bytecode verifier for array-related
--       primops that are used generically.
arrayFtCast :: FieldType -> (FieldType, Code)
arrayFtCast ft
  | ft == jobject = (objArray, gconv ft objArray)
  | otherwise = (ft, mempty)
  where objArray = jarray jobject

shouldInlinePrimOp :: DynFlags -> PrimOp -> [(FieldType, Code)] -> Type -> Either (Text, Text) (CodeGen [Code])
shouldInlinePrimOp dflags ObjectArrayAtOp ((origFt, arrayObj):args) _ =
  Right $ return [arrayObj <> maybeCast <> fold codes <> gaload elemFt]
  where (arrayFt, maybeCast) = arrayFtCast origFt
        (_, codes) = unzip args
        elemFt = fromJust $ getArrayElemFt arrayFt

shouldInlinePrimOp dflags ObjectArraySetOp ((origFt, arrayObj):args) _ =
  Right $ return [arrayObj <> maybeCast <> fold codes <> gastore elemFt]
  where (arrayFt, maybeCast) = arrayFtCast origFt
        (_, codes) = unzip args
        elemFt = fromJust $ getArrayElemFt arrayFt

shouldInlinePrimOp dflags ArrayLengthOp [(origFt, arrayObj)] _ =
  Right $ return [arrayObj <> maybeCast <> arraylength arrayFt]
  where (arrayFt, maybeCast) = arrayFtCast origFt

shouldInlinePrimOp dflags ClassCastOp args resType = Right $
  let (_, codes) = unzip args
      fromFt = fst (head args)
      toFt = fromJust . repFieldType_maybe $ resType
  in return [normalOp (gconv fromFt toFt) codes]

shouldInlinePrimOp dflags op args _ = shouldInlinePrimOp' dflags op $ snd (unzip args)

shouldInlinePrimOp' :: DynFlags -> PrimOp -> [Code] -> Either (Text, Text) (CodeGen [Code])
-- TODO: Inline array operations conditionally
shouldInlinePrimOp' dflags CopyArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "copyArray"
                              [closureType, jint, closureType, jint, jint]
                              (ret stgByteArrayType))
  ]

shouldInlinePrimOp' dflags CopyMutableArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "copyArray"
                              [closureType, jint, closureType, jint, jint]
                              (ret stgByteArrayType))
  ]

shouldInlinePrimOp' dflags CloneArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "cloneArray" [closureType, jint, jint]
                                                        (ret stgArrayType))
  ]
shouldInlinePrimOp' dflags CloneMutableArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "cloneArray" [closureType, jint, jint]
                                                        (ret stgArrayType))
  ]
shouldInlinePrimOp' dflags FreezeArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "cloneArray" [closureType, jint, jint]
                                                        (ret stgArrayType))
  ]
shouldInlinePrimOp' dflags ThawArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "cloneArray" [closureType, jint, jint]
                                                        (ret stgArrayType))
  ]
shouldInlinePrimOp' dflags CopySmallArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "copyArray"
                              [closureType, jint, closureType, jint, jint]
                              (ret stgByteArrayType))
  ]

shouldInlinePrimOp' dflags CopySmallMutableArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "copyArray"
                              [closureType, jint, closureType, jint, jint]
                              (ret stgByteArrayType))
  ]

shouldInlinePrimOp' dflags CloneSmallArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "cloneArray" [closureType, jint, jint]
                                                        (ret stgArrayType))
  ]
shouldInlinePrimOp' dflags CloneSmallMutableArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "cloneArray" [closureType, jint, jint]
                                                        (ret stgArrayType))
  ]
shouldInlinePrimOp' dflags FreezeSmallArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "cloneArray" [closureType, jint, jint]
                                                        (ret stgArrayType))
  ]
shouldInlinePrimOp' dflags ThawSmallArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "cloneArray" [closureType, jint, jint]
                                                        (ret stgArrayType))
  ]

shouldInlinePrimOp' dflags CopyArrayArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "copyArray"
                              [closureType, jint, closureType, jint, jint]
                              (ret stgByteArrayType))
  ]

shouldInlinePrimOp' dflags CopyMutableArrayArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "copyArray"
                              [closureType, jint, closureType, jint, jint]
                              (ret stgByteArrayType))
  ]


shouldInlinePrimOp' dflags NewByteArrayOp_Char args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgByteArray "create" [jint] (ret stgByteArrayType))
  ]

shouldInlinePrimOp' dflags NewPinnedByteArrayOp_Char args = Right $ return
  [
    fold args
 <> iconst jbool 1
 <> invokestatic (mkMethodRef stgByteArray "create" [jint, jbool] (ret stgByteArrayType))
  ]

shouldInlinePrimOp' dflags NewAlignedPinnedByteArrayOp_Char args = Right $ return
  [
    fold args
 <> iconst jbool 1
 <> invokestatic (mkMethodRef stgByteArray "create" [jint, jint, jbool] (ret stgByteArrayType))
  ]

shouldInlinePrimOp' dflags NewArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgArray "create" [jint, closureType] (ret stgArrayType))
  ]

shouldInlinePrimOp' dflags NewSmallArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgArray "create" [jint, closureType] (ret stgArrayType))
  ]

shouldInlinePrimOp' dflags NewArrayArrayOp args = Right $ return
  [
    fold args
 <> invokestatic (mkMethodRef stgArray "create" [jint, closureType] (ret stgArrayType))
  ]

shouldInlinePrimOp' dflags NewMutVarOp args = Right $ return
  [
    new stgMutVarType
 <> dup stgMutVarType
 <> fold args
 <> invokespecial (mkMethodRef stgMutVar "<init>" [closureType] void)
  ]

shouldInlinePrimOp' dflags NewTVarOp args = Right $ return
  [
    new stgTVarType
 <> dup stgTVarType
 <> fold args
 <> invokespecial (mkMethodRef stgTVar "<init>" [closureType] void)
  ]

shouldInlinePrimOp' dflags NewMVarOp args = Right $ return
  [
    new stgMVarType
 <> dup stgMVarType
 <> aconst_null closureType
 <> invokespecial (mkMethodRef stgMVar "<init>" [closureType] void)
  ]

shouldInlinePrimOp' dflags IsEmptyMVarOp [mvar] = Right $ return
  [ intCompOp ifnull [mvar <> mVarValue] ]

shouldInlinePrimOp' dflags MakeStableNameOp args = Right $ return
  [ normalOp (invokestatic (mkMethodRef "java/lang/System" "identityHashCode" [jobject] (ret jint))) args ]

shouldInlinePrimOp' dflags MakeStablePtrOp args = Right $ return
  [ normalOp (invokestatic (mkMethodRef "eta/runtime/stg/StablePtrTable" "makeStablePtr" [closureType] (ret jint))) args ]

shouldInlinePrimOp' dflags DeRefStablePtrOp args = Right $ return
  [ normalOp (invokestatic (mkMethodRef "eta/runtime/stg/StablePtrTable" "getClosure" [jint] (ret closureType))) args ]


shouldInlinePrimOp' dflags UnsafeThawArrayOp args = Right $ return [fold args]
shouldInlinePrimOp' dflags UnsafeThawSmallArrayOp args = Right $ return [fold args]

shouldInlinePrimOp' dflags primOp args
  | primOpOutOfLine primOp = Left $ mkRtsPrimOp primOp
  | otherwise = Right $ emitPrimOp primOp args

mkRtsPrimOp :: PrimOp -> (Text, Text)
mkRtsPrimOp RaiseOp                 = (stgExceptionGroup, "raise")
mkRtsPrimOp CatchOp                 = (stgExceptionGroup, "catch_")
mkRtsPrimOp RaiseIOOp               = (stgExceptionGroup, "raiseIO")
mkRtsPrimOp MaskAsyncExceptionsOp   = (stgExceptionGroup, "maskAsyncExceptions")
mkRtsPrimOp MaskUninterruptibleOp   = (stgExceptionGroup, "maskUninterruptible")
mkRtsPrimOp UnmaskAsyncExceptionsOp = (stgExceptionGroup, "unmaskAsyncExceptions")
mkRtsPrimOp MaskStatus              = (stgExceptionGroup, "getMaskingState")
mkRtsPrimOp FloatDecode_IntOp       = (ioGroup, "decodeFloat_Int")
mkRtsPrimOp AtomicallyOp            = (stmGroup, "atomically")
mkRtsPrimOp RetryOp                 = (stmGroup, "retry")
mkRtsPrimOp CatchRetryOp            = (stmGroup, "catchRetry")
mkRtsPrimOp CatchSTMOp              = (stmGroup, "catchSTM")
mkRtsPrimOp Check                   = (stmGroup, "check")
mkRtsPrimOp ReadTVarOp              = (stmGroup, "readTVar")
mkRtsPrimOp ReadTVarIOOp            = (stmGroup, "readTVarIO")
mkRtsPrimOp WriteTVarOp             = (stmGroup, "writeTVar")
mkRtsPrimOp TakeMVarOp              = (concGroup, "takeMVar")
mkRtsPrimOp TryTakeMVarOp           = (concGroup, "tryTakeMVar")
mkRtsPrimOp PutMVarOp               = (concGroup, "putMVar")
mkRtsPrimOp TryPutMVarOp            = (concGroup, "tryPutMVar")
mkRtsPrimOp ReadMVarOp              = (concGroup, "readMVar")
mkRtsPrimOp TryReadMVarOp           = (concGroup, "tryReadMVar")
mkRtsPrimOp ForkOp                  = (concGroup, "fork")
mkRtsPrimOp ForkOnOp                = (concGroup, "forkOn")
mkRtsPrimOp KillThreadOp            = (stgExceptionGroup, "killThread")
mkRtsPrimOp YieldOp                 = (concGroup, "yield")
mkRtsPrimOp LabelThreadOp           = (concGroup, "labelThread")
mkRtsPrimOp IsCurrentThreadBoundOp  = (concGroup, "isCurrentThreadBound")
mkRtsPrimOp NoDuplicateOp           = (stgGroup, "noDuplicate")
mkRtsPrimOp ThreadStatusOp          = (concGroup, "threadStatus")
mkRtsPrimOp MkWeakOp                = (stgGroup, "mkWeak")
mkRtsPrimOp MkWeakNoFinalizerOp     = (stgGroup, "mkWeakNoFinalizzer")
mkRtsPrimOp AddCFinalizerToWeakOp   = (stgGroup, "addJavaFinalizzerToWeak")
mkRtsPrimOp DeRefWeakOp             = (stgGroup, "deRefWeak")
mkRtsPrimOp FinalizeWeakOp          = (stgGroup, "finalizzeWeak")
mkRtsPrimOp AtomicModifyMutVarOp    = (ioGroup, "atomicModifyMutVar")
mkRtsPrimOp CasMutVarOp             = (ioGroup, "casMutVar")
mkRtsPrimOp GetSparkOp              = (parGroup, "getSpark")
mkRtsPrimOp NumSparks               = (parGroup, "numSparks")
mkRtsPrimOp primop = pprPanic "mkRtsPrimOp: unimplemented!" (ppr primop)

cgPrimOp   :: PrimOp            -- the op
           -> [StgArg]          -- arguments
           -> CodeGen [Code]
cgPrimOp op args = do
  argExprs <- getNonVoidArgCodes args
  emitPrimOp op argExprs

-- emitPrimOp :: [CgLoc]        -- where to put the results
--            -> PrimOp         -- the op
--            -> [Code]         -- arguments
--            -> CodeGen ()
emitPrimOp :: PrimOp -> [Code] -> CodeGen [Code]
emitPrimOp IndexOffAddrOp_Char [arg1, arg2]
  = return [ arg1
          <> arg2
          <> invokevirtual (mkMethodRef jstringC "charAt"
                                        [jint] (ret jchar))]
          -- TODO: You may have to cast to int or do some extra stuff here
          --       or maybe instead reference the direct byte array
emitPrimOp DataToTagOp [arg] = return [ getTagMethod arg <> iconst jint 1 <> isub ]

emitPrimOp IntQuotRemOp args = do
  codes1 <- emitPrimOp IntQuotOp args
  codes2 <- emitPrimOp IntRemOp args
  return $ codes1 ++ codes2

emitPrimOp WordQuotRemOp args = do
  codes1 <- emitPrimOp WordQuotOp args
  codes2 <- emitPrimOp WordRemOp args
  return $ codes1 ++ codes2

emitPrimOp IntAddCOp [arg1, arg2] = do
  tmp <- newTemp False jint
  emit $ storeLoc tmp (arg1 <> arg2 <> iadd)
  let sum = loadLoc tmp
  return $ [ sum
           , (arg1 <> sum <> ixor)
          <> (arg2 <> sum <> ixor)
          <> iand
          <> inot
           ]

emitPrimOp IntSubCOp [arg1, arg2] = do
  tmp <- newTemp False jint
  emit $ storeLoc tmp (arg1 <> arg2 <> isub)
  let diff = loadLoc tmp
  return $ [ diff
           , (arg1 <> arg2 <> ixor)
          <> (arg1 <> diff <> ixor)
          <> iand
          <> inot
           ]

emitPrimOp IntMulMayOfloOp [arg1, arg2] = do
  tmp <- newTemp False jlong
  emit $ storeLoc tmp ( (arg1 <> gconv jint jlong)
                     <> (arg2 <> gconv jint jlong)
                     <> lmul )
  let mul = loadLoc tmp
  return $ [ mul
          <> gconv jlong jint
          <> gconv jint  jlong
          <> mul
          <> lcmp
           ]

emitPrimOp op [arg]
  | nopOp op = return [arg]
emitPrimOp op args
  | Just execute <- simpleOp op
  = return [execute args]
emitPrimOp op _ = pprPanic "emitPrimOp: unimplemented" (ppr op)

nopOp :: PrimOp -> Bool
nopOp Int2WordOp   = True
nopOp Word2IntOp   = True
nopOp OrdOp        = True
nopOp ChrOp        = True
nopOp Int642Word64 = True
nopOp Word642Int64 = True
nopOp ChrOp        = True
nopOp ChrOp        = True
nopOp JBool2IntOp  = True
nopOp _            = False

normalOp :: Code -> [Code] -> Code
normalOp code args = fold args <> code

idOp :: [Code] -> Code
idOp = normalOp mempty

intCompOp :: (Code -> Code -> Code) -> [Code] -> Code
intCompOp op args = flip normalOp args $ op (iconst jint 1) (iconst jint 0)

simpleOp :: PrimOp -> Maybe ([Code] -> Code)

simpleOp MyThreadIdOp  = Just $ normalOp $ loadContext <> currentTSOField

-- Array# & MutableArray# ops
simpleOp UnsafeFreezeArrayOp  = Just idOp
simpleOp SameMutableArrayOp = Just $ intCompOp if_acmpeq
simpleOp SizeofArrayOp = Just $
  normalOp $ invokevirtual (mkMethodRef stgArray "size" [] (ret jint))
simpleOp SizeofMutableArrayOp = Just $
  normalOp $ invokevirtual (mkMethodRef stgArray "size" [] (ret jint))
-- TODO: Inline the get/set's
simpleOp WriteArrayOp = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "set" [jint, closureType] void
simpleOp ReadArrayOp = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "get" [jint] (ret closureType)
simpleOp IndexArrayOp = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "get" [jint] (ret closureType)

-- SmallArray# & SmallMutableArray# ops
simpleOp UnsafeFreezeSmallArrayOp  = Just idOp
simpleOp SameSmallMutableArrayOp = Just $ intCompOp if_acmpeq
simpleOp SizeofSmallArrayOp = Just $
  normalOp $ invokevirtual (mkMethodRef stgArray "size" [] (ret jint))
simpleOp SizeofSmallMutableArrayOp = Just $
  normalOp $ invokevirtual (mkMethodRef stgArray "size" [] (ret jint))
-- TODO: Inline the get/set's
simpleOp WriteSmallArrayOp = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "set" [jint, closureType] void
simpleOp ReadSmallArrayOp = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "get" [jint] (ret closureType)
simpleOp IndexSmallArrayOp = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "get" [jint] (ret closureType)

-- ArrayArray# & MutableArrayArray# ops
simpleOp UnsafeFreezeArrayArrayOp  = Just idOp
simpleOp SameMutableArrayArrayOp = Just $ intCompOp if_acmpeq
simpleOp SizeofArrayArrayOp = Just $
  normalOp $ invokevirtual (mkMethodRef stgArray "size" [] (ret jint))
simpleOp SizeofMutableArrayArrayOp = Just $
  normalOp $ invokevirtual (mkMethodRef stgArray "size" [] (ret jint))
-- TODO: Inline the get/set's
simpleOp IndexArrayArrayOp_ByteArray = Just $
  normalOp $ invokevirtual (mkMethodRef stgArray "get" [jint] (ret closureType))
          <> gconv closureType stgByteArrayType
simpleOp IndexArrayArrayOp_ArrayArray = Just $
  normalOp $ invokevirtual (mkMethodRef stgArray "get" [jint] (ret closureType))
          <> gconv closureType stgArrayType
simpleOp ReadArrayArrayOp_ByteArray = Just $
  normalOp $ invokevirtual (mkMethodRef stgArray "get" [jint] (ret closureType))
          <> gconv closureType stgByteArrayType
simpleOp ReadArrayArrayOp_MutableByteArray = Just $
  normalOp $ invokevirtual (mkMethodRef stgArray "get" [jint] (ret closureType))
          <> gconv closureType stgByteArrayType
simpleOp ReadArrayArrayOp_ArrayArray = Just $
  normalOp $ invokevirtual (mkMethodRef stgArray "get" [jint] (ret closureType))
          <> gconv closureType stgArrayType
simpleOp ReadArrayArrayOp_MutableArrayArray = Just $
  normalOp $ invokevirtual (mkMethodRef stgArray "get" [jint] (ret closureType))
          <> gconv closureType stgArrayType
simpleOp WriteArrayArrayOp_ByteArray = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "set" [jint, closureType] void
simpleOp WriteArrayArrayOp_MutableByteArray = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "set" [jint, closureType] void
simpleOp WriteArrayArrayOp_ArrayArray = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "set" [jint, closureType] void
simpleOp WriteArrayArrayOp_MutableArrayArray = Just $
  normalOp $ invokevirtual
    $ mkMethodRef stgArray "set" [jint, closureType] void

-- ByteArray# & MutableByteArray# ops
simpleOp ByteArrayContents_Char = Just $ normalOp byteArrayBuf
simpleOp SameMutableArrayOp = Just $ intCompOp if_acmpeq
simpleOp UnsafeFreezeByteArrayOp = Just idOp
simpleOp IndexByteArrayOp_Char = Just $ byteArrayIndexOp jbyte preserveByte
simpleOp IndexByteArrayOp_WideChar = Just $ byteArrayIndexOp jint mempty
simpleOp IndexByteArrayOp_Int = Just $ byteArrayIndexOp jint mempty
simpleOp IndexByteArrayOp_Word = Just $ byteArrayIndexOp jint mempty
simpleOp IndexByteArrayOp_Addr = Just $ byteArrayIndexOp jint
  (invokestatic $
    mkMethodRef memoryManager "getBuffer" [jint] (ret byteBufferType))
simpleOp IndexByteArrayOp_Float = Just $ byteArrayIndexOp jfloat mempty
simpleOp IndexByteArrayOp_Double = Just $ byteArrayIndexOp jdouble mempty
simpleOp IndexByteArrayOp_StablePtr = Just $ byteArrayIndexOp jint mempty
simpleOp IndexByteArrayOp_Int8 = Just $ byteArrayIndexOp jbyte preserveByte
simpleOp IndexByteArrayOp_Int16 = Just $ byteArrayIndexOp jshort preserveShort
simpleOp IndexByteArrayOp_Int32 = Just $ byteArrayIndexOp jint mempty
simpleOp IndexByteArrayOp_Int64 = Just $ byteArrayIndexOp jlong mempty
simpleOp IndexByteArrayOp_Word8 = Just $ byteArrayIndexOp jbyte preserveByte
simpleOp IndexByteArrayOp_Word16 = Just $ byteArrayIndexOp jshort preserveShort
simpleOp IndexByteArrayOp_Word32 = Just $ byteArrayIndexOp jint mempty
simpleOp IndexByteArrayOp_Word64 = Just $ byteArrayIndexOp jlong mempty

simpleOp ReadByteArrayOp_Char = Just $ byteArrayIndexOp jbyte preserveByte
simpleOp ReadByteArrayOp_WideChar = Just $ byteArrayIndexOp jint mempty
simpleOp ReadByteArrayOp_Int = Just $ byteArrayIndexOp jint mempty
simpleOp ReadByteArrayOp_Word = Just $ byteArrayIndexOp jint mempty
simpleOp ReadByteArrayOp_Addr = Just $ byteArrayIndexOp jint
  (invokestatic $
    mkMethodRef memoryManager "getBuffer" [jint] (ret byteBufferType))
simpleOp ReadByteArrayOp_Float = Just $ byteArrayIndexOp jfloat mempty
simpleOp ReadByteArrayOp_Double = Just $ byteArrayIndexOp jdouble mempty
simpleOp ReadByteArrayOp_StablePtr = Just $ byteArrayIndexOp jint mempty
simpleOp ReadByteArrayOp_Int8 = Just $ byteArrayIndexOp jbyte preserveByte
simpleOp ReadByteArrayOp_Int16 = Just $ byteArrayIndexOp jshort preserveShort
simpleOp ReadByteArrayOp_Int32 = Just $ byteArrayIndexOp jint mempty
simpleOp ReadByteArrayOp_Int64 = Just $ byteArrayIndexOp jlong mempty
simpleOp ReadByteArrayOp_Word8 = Just $ byteArrayIndexOp jbyte preserveByte
simpleOp ReadByteArrayOp_Word16 = Just $ byteArrayIndexOp jshort preserveShort
simpleOp ReadByteArrayOp_Word32 = Just $ byteArrayIndexOp jint mempty
simpleOp ReadByteArrayOp_Word64 = Just $ byteArrayIndexOp jlong mempty

simpleOp WriteByteArrayOp_Char = Just $ byteArrayWriteOp jbyte mempty
simpleOp WriteByteArrayOp_WideChar = Just $ byteArrayWriteOp jint mempty
simpleOp WriteByteArrayOp_Int = Just $ byteArrayWriteOp jint mempty
simpleOp WriteByteArrayOp_Word = Just $ byteArrayWriteOp jint mempty
simpleOp WriteByteArrayOp_Addr = Just $ byteArrayWriteOp jint
  (invokestatic $
     mkMethodRef memoryManager "getAddress" [byteBufferType] (ret jint))
simpleOp WriteByteArrayOp_Float = Just $ byteArrayWriteOp jfloat mempty
simpleOp WriteByteArrayOp_Double = Just $ byteArrayWriteOp jdouble mempty
-- TODO: Verify writes for Word/Int 8/16 - add additional casts?
simpleOp WriteByteArrayOp_StablePtr = Just $ byteArrayWriteOp jint mempty
simpleOp WriteByteArrayOp_Int8 = Just $ byteArrayWriteOp jbyte preserveByte
simpleOp WriteByteArrayOp_Int16 = Just $ byteArrayWriteOp jshort preserveShort
simpleOp WriteByteArrayOp_Int32 = Just $ byteArrayWriteOp jint mempty
simpleOp WriteByteArrayOp_Int64 = Just $ byteArrayWriteOp jlong mempty
simpleOp WriteByteArrayOp_Word8 = Just $ byteArrayWriteOp jbyte preserveByte
simpleOp WriteByteArrayOp_Word16 = Just $ byteArrayWriteOp jshort preserveShort
simpleOp WriteByteArrayOp_Word32 = Just $ byteArrayWriteOp jint mempty
simpleOp WriteByteArrayOp_Word64 = Just $ byteArrayWriteOp jlong mempty

-- Int# ops
simpleOp IntAddOp = Just $ normalOp iadd
simpleOp IntSubOp = Just $ normalOp isub
simpleOp IntMulOp = Just $ normalOp imul
simpleOp IntQuotOp = Just $ normalOp idiv
simpleOp IntRemOp = Just $ normalOp irem

simpleOp AndIOp = Just $ normalOp iand
simpleOp OrIOp = Just $ normalOp ior
simpleOp XorIOp = Just $ normalOp ixor
simpleOp NotIOp = Just $ normalOp inot
simpleOp ISllOp = Just $ normalOp ishl
simpleOp ISraOp = Just $ normalOp ishr
simpleOp ISrlOp = Just $ normalOp iushr

simpleOp IntNegOp = Just $ normalOp ineg
simpleOp IntEqOp = Just $ intCompOp if_icmpeq
simpleOp IntNeOp = Just $ intCompOp if_icmpne
simpleOp IntLeOp = Just $ intCompOp if_icmple
simpleOp IntLtOp = Just $ intCompOp if_icmplt
simpleOp IntGeOp = Just $ intCompOp if_icmpge
simpleOp IntGtOp = Just $ intCompOp if_icmpgt

-- Word# ops
-- TODO: Take a look at compareUnsigned in JDK 8
--       and see if that's more efficient
simpleOp WordEqOp   = Just $ intCompOp if_icmpeq
simpleOp WordNeOp   = Just $ intCompOp if_icmpeq
simpleOp WordAddOp  = Just $ normalOp iadd
simpleOp WordSubOp  = Just $ normalOp isub
simpleOp WordMulOp  = Just $ normalOp imul
simpleOp WordQuotOp = Just $ unsignedOp ldiv
simpleOp WordRemOp  = Just $ unsignedOp lrem
simpleOp WordGtOp   = Just $ unsignedCmp ifgt
simpleOp WordGeOp   = Just $ unsignedCmp ifge
simpleOp WordLeOp   = Just $ unsignedCmp ifle
simpleOp WordLtOp   = Just $ unsignedCmp iflt
--Verify true for unsigned operations
simpleOp AndOp = Just $ normalOp iand
simpleOp OrOp = Just $ normalOp ior
simpleOp XorOp = Just $ normalOp ixor
simpleOp NotOp = Just $ normalOp inot
simpleOp SllOp = Just $ normalOp ishl
simpleOp SrlOp = Just $ normalOp iushr

-- Char# ops
simpleOp CharEqOp = Just $ intCompOp if_icmpeq
simpleOp CharNeOp = Just $ intCompOp if_icmpne
simpleOp CharGtOp = Just $ unsignedCmp ifgt
simpleOp CharGeOp = Just $ unsignedCmp ifge
simpleOp CharLeOp = Just $ unsignedCmp ifle
simpleOp CharLtOp = Just $ unsignedCmp iflt

-- Double# ops
simpleOp DoubleEqOp = Just $ typedCmp jdouble ifeq
simpleOp DoubleNeOp = Just $ typedCmp jdouble ifne
simpleOp DoubleGeOp = Just $ typedCmp jdouble ifge
simpleOp DoubleLeOp = Just $ typedCmp jdouble ifle
simpleOp DoubleGtOp = Just $ typedCmp jdouble ifgt
simpleOp DoubleLtOp = Just $ typedCmp jdouble iflt

simpleOp DoubleAddOp = Just $ normalOp dadd
simpleOp DoubleSubOp = Just $ normalOp dsub
simpleOp DoubleMulOp = Just $ normalOp dmul
simpleOp DoubleDivOp = Just $ normalOp ddiv
simpleOp DoubleNegOp = Just $ normalOp dneg

simpleOp DoubleExpOp = Just $ normalOp $ doubleMathEndoOp "exp"
simpleOp DoubleLogOp = Just $ normalOp $ doubleMathEndoOp "log"
simpleOp DoubleSqrtOp = Just $ normalOp $ doubleMathEndoOp "sqrt"
simpleOp DoubleSinOp = Just $ normalOp $ doubleMathEndoOp "sin"
simpleOp DoubleCosOp = Just $ normalOp $ doubleMathEndoOp "cos"
simpleOp DoubleTanOp = Just $ normalOp $ doubleMathEndoOp "tan"
simpleOp DoubleAsinOp = Just $ normalOp $ doubleMathEndoOp "asin"
simpleOp DoubleAcosOp = Just $ normalOp $ doubleMathEndoOp "acos"
simpleOp DoubleAtanOp = Just $ normalOp $ doubleMathEndoOp "atan"
simpleOp DoubleSinhOp = Just $ normalOp $ doubleMathEndoOp "sinh"
simpleOp DoubleCoshOp = Just $ normalOp $ doubleMathEndoOp "cosh"
simpleOp DoubleTanhOp = Just $ normalOp $ doubleMathEndoOp "tanh"
simpleOp DoublePowerOp = Just $ normalOp $ doubleMathOp "pow" [jdouble, jdouble] jdouble

-- Float# ops
simpleOp FloatEqOp = Just $ typedCmp jfloat ifeq
simpleOp FloatNeOp = Just $ typedCmp jfloat ifne
simpleOp FloatGeOp = Just $ typedCmp jfloat ifge
simpleOp FloatLeOp = Just $ typedCmp jfloat ifle
simpleOp FloatGtOp = Just $ typedCmp jfloat ifgt
simpleOp FloatLtOp = Just $ typedCmp jfloat iflt

simpleOp FloatAddOp = Just $ normalOp fadd
simpleOp FloatSubOp = Just $ normalOp fsub
simpleOp FloatMulOp = Just $ normalOp fmul
simpleOp FloatDivOp = Just $ normalOp fdiv
simpleOp FloatNegOp = Just $ normalOp fneg

simpleOp FloatExpOp = Just $ normalOp $ floatMathEndoOp "exp"
simpleOp FloatLogOp = Just $ normalOp $ floatMathEndoOp "log"
simpleOp FloatSqrtOp = Just $ normalOp $ floatMathEndoOp "sqrt"
simpleOp FloatSinOp = Just $ normalOp $ floatMathEndoOp "sin"
simpleOp FloatCosOp = Just $ normalOp $ floatMathEndoOp "cos"
simpleOp FloatTanOp = Just $ normalOp $ floatMathEndoOp "tan"
simpleOp FloatAsinOp = Just $ normalOp $ floatMathEndoOp "asin"
simpleOp FloatAcosOp = Just $ normalOp $ floatMathEndoOp "acos"
simpleOp FloatAtanOp = Just $ normalOp $ floatMathEndoOp "atan"
simpleOp FloatSinhOp = Just $ normalOp $ floatMathEndoOp "sinh"
simpleOp FloatCoshOp = Just $ normalOp $ floatMathEndoOp "cosh"
simpleOp FloatTanhOp = Just $ normalOp $ floatMathEndoOp "tanh"
simpleOp FloatPowerOp = Just $ \[arg1, arg2] ->
     (arg1 <> gconv jfloat jdouble)
  <> (arg2 <> floatMathOp "pow" [jdouble, jdouble] jdouble)

-- Conversions
simpleOp Int2DoubleOp   = Just $ normalOp $ gconv jint    jdouble
simpleOp Double2IntOp   = Just $ normalOp $ gconv jdouble jint
simpleOp Int2FloatOp    = Just $ normalOp $ gconv jint    jfloat
simpleOp Float2IntOp    = Just $ normalOp $ gconv jfloat  jint
simpleOp Float2DoubleOp = Just $ normalOp $ gconv jfloat  jdouble
simpleOp Double2FloatOp = Just $ normalOp $ gconv jdouble jfloat
simpleOp Word2FloatOp   = Just $ normalOp $ unsignedExtend mempty <> gconv jlong jfloat
simpleOp Word2DoubleOp  = Just $ normalOp $ unsignedExtend mempty <> gconv jlong jdouble
simpleOp Word64Eq = Just $ typedCmp jlong ifeq
simpleOp Word64Ne = Just $ typedCmp jlong ifne
simpleOp Word64Lt = Just $ unsignedLongCmp iflt
simpleOp Word64Le = Just $ unsignedLongCmp ifle
simpleOp Word64Gt = Just $ unsignedLongCmp ifgt
simpleOp Word64Ge = Just $ unsignedLongCmp ifge
simpleOp Word64Quot = Just $
  normalOp $ invokestatic $ mkMethodRef rtsUnsigned "divideUnsigned" [jlong, jlong] (ret jlong)
simpleOp Word64Rem = Just $
  normalOp $ invokestatic $ mkMethodRef rtsUnsigned "remainderUnsigned" [jlong, jlong] (ret jlong)
simpleOp Word64And = Just $ normalOp land
simpleOp Word64Or = Just $ normalOp lor
simpleOp Word64Xor = Just $ normalOp lxor
simpleOp Word64Not = Just $ normalOp lnot
simpleOp Word64SllOp = Just $ normalOp lshl
simpleOp Word64SrlOp = Just $ normalOp lushr
-- TODO: Check if these operations are optimal
simpleOp PopCntOp = Just $ normalOp $ popCntOp
simpleOp PopCnt8Op = Just $ normalOp $ preserveByte <> popCntOp
simpleOp PopCnt16Op = Just $ normalOp $ preserveShort <> popCntOp
simpleOp PopCnt32Op = Just $ normalOp $ popCntOp
simpleOp PopCnt64Op = Just $ normalOp $
  invokestatic $ mkMethodRef "java/lang/Long" "bitCount" [jlong] (ret jint)
simpleOp ClzOp = Just $ normalOp $ clzOp
simpleOp Clz8Op = Just $ normalOp $ preserveByte <> clzOp <> iconst jint 24 <> isub
simpleOp Clz16Op = Just $ normalOp $ preserveShort <> clzOp <> iconst jint 16 <> isub
simpleOp Clz32Op = Just $ normalOp $ clzOp
simpleOp Clz64Op = Just $ normalOp $
  invokestatic $ mkMethodRef "java/lang/Long" "numberOfLeadingZeros" [jlong] (ret jint)
simpleOp CtzOp = Just $ normalOp $ ctzOp
simpleOp Ctz8Op = Just $ normalOp $ iconst jint 0x100 <> ior <> ctzOp
simpleOp Ctz16Op = Just $ normalOp $ iconst jint 0x10000 <> ior <> ctzOp
simpleOp Ctz32Op = Just $ normalOp $ ctzOp
simpleOp Ctz64Op = Just $ normalOp $
  invokestatic $ mkMethodRef "java/lang/Long" "numberOfTrailingZeros" [jlong] (ret jint)

-- TODO: Verify all the BSwap operations
-- TODO: Is this correct?
simpleOp BSwap16Op = Just $ normalOp $
     gconv jint jshort
  <> invokestatic (mkMethodRef "java/lang/Short" "reverseBytes" [jshort] (ret jshort))
  <> gconv jshort jint
simpleOp BSwap32Op = Just $ normalOp $
  invokestatic (mkMethodRef "java/lang/Integer" "reverseBytes" [jint] (ret jint))
simpleOp BSwap64Op = Just $ normalOp $
  invokestatic (mkMethodRef "java/lang/Long" "reverseBytes" [jlong] (ret jlong))
simpleOp BSwapOp = Just $ normalOp $
  invokestatic (mkMethodRef "java/lang/Integer" "reverseBytes" [jint] (ret jint))

simpleOp Int64Eq = Just $ typedCmp jlong ifeq
simpleOp Int64Ne = Just $ typedCmp jlong ifne
simpleOp Int64Lt = Just $ typedCmp jlong iflt
simpleOp Int64Le = Just $ typedCmp jlong ifle
simpleOp Int64Gt = Just $ typedCmp jlong ifgt
simpleOp Int64Ge = Just $ typedCmp jlong ifge
simpleOp Int64Quot = Just $ normalOp ldiv
simpleOp Int64Rem = Just $ normalOp lrem
simpleOp Int64Add = Just $ normalOp ladd
simpleOp Int64Sub = Just $ normalOp lsub
simpleOp Int64Mul = Just $ normalOp lmul
simpleOp Int64Neg = Just $ normalOp lneg
simpleOp Int64SllOp = Just $ normalOp lshl
simpleOp Int64SraOp = Just $ normalOp lshr
simpleOp Int64SrlOp = Just $ normalOp lushr
simpleOp Int2Int64 = Just $ normalOp $ gconv jint  jlong
simpleOp Int642Int = Just $ normalOp $ gconv jlong jint
simpleOp Word2Word64 = Just $ unsignedExtend . head
-- TODO: Right conversion?
simpleOp Word64ToWord = Just $ normalOp $ gconv jlong jint
simpleOp DecodeDoubleInteger = Just $ normalOp $ gconv jlong jint
simpleOp IndexJByteArrayOp = Just $ normalOp $ gaload jbyte
simpleOp ReadJByteArrayOp  = Just $ normalOp $ gaload jbyte
simpleOp WriteJByteArrayOp = Just $ normalOp $ gastore jbyte
simpleOp JByte2CharOp = Just $ normalOp preserveByte
simpleOp JByte2IntOp = Just idOp
simpleOp Int2JBoolOp = Just idOp

-- StgMutVar ops
simpleOp ReadMutVarOp = Just $ normalOp mutVarValue
simpleOp WriteMutVarOp = Just $ normalOp mutVarSetValue
simpleOp SameMutVarOp = Just $ intCompOp if_acmpeq

-- Addr# ops
-- TODO: Inline these primops
simpleOp Addr2IntOp = Just $ normalOp
  $ invokestatic $ mkMethodRef memoryManager "getAddress" [byteBufferType] (ret jint)
simpleOp Int2AddrOp = Just $ normalOp
  $ invokestatic $ mkMethodRef memoryManager "getBuffer" [jint] (ret byteBufferType)
simpleOp AddrAddOp = Just $ \[addr, dx] ->
     addr
  <> byteBufferDup
  <> addr
  <> byteBufferPosGet
  <> dx
  <> iadd
  <> byteBufferPosSet
  <> gconv bufferType byteBufferType
simpleOp AddrSubOp = Just $ \[addr1, addr2] ->
  addr1 <> byteBufferPosGet <> addr2 <> byteBufferPosGet <> isub
simpleOp AddrRemOp = Just $ \[addr, n] ->
  addr <> byteBufferPosGet <> n <> irem
simpleOp AddrGtOp = Just $ addrCmpOp if_icmpgt
simpleOp AddrGeOp = Just $ addrCmpOp if_icmpge
simpleOp AddrEqOp = Just $ addrCmpOp if_icmpeq
simpleOp AddrNeOp = Just $ addrCmpOp if_icmpne
simpleOp AddrLtOp = Just $ addrCmpOp if_icmplt
simpleOp AddrLeOp = Just $ addrCmpOp if_icmple

simpleOp IndexOffAddrOp_Char = Just $ addrIndexOp jbyte preserveByte
simpleOp IndexOffAddrOp_WideChar = Just $ addrIndexOp jint mempty
simpleOp IndexOffAddrOp_Int = Just $ addrIndexOp jint mempty
simpleOp IndexOffAddrOp_Word = Just $ addrIndexOp jint mempty
simpleOp IndexOffAddrOp_Addr = Just $ addrIndexOp jint
  (invokestatic $
    mkMethodRef memoryManager "getBuffer" [jint] (ret byteBufferType))
simpleOp IndexOffAddrOp_Float = Just $ addrIndexOp jfloat mempty
simpleOp IndexOffAddrOp_Double = Just $ addrIndexOp jdouble mempty
simpleOp IndexOffAddrOp_StablePtr = Just $ addrIndexOp jint mempty
simpleOp IndexOffAddrOp_Int8 = Just $ addrIndexOp jbyte preserveByte
simpleOp IndexOffAddrOp_Int16 = Just $ addrIndexOp jshort preserveShort
simpleOp IndexOffAddrOp_Int32 = Just $ addrIndexOp jint mempty
simpleOp IndexOffAddrOp_Int64 = Just $ addrIndexOp jlong mempty
simpleOp IndexOffAddrOp_Word8 = Just $ addrIndexOp jbyte preserveByte
simpleOp IndexOffAddrOp_Word16 = Just $ addrIndexOp jshort preserveShort
simpleOp IndexOffAddrOp_Word32 = Just $ addrIndexOp jint mempty
simpleOp IndexOffAddrOp_Word64 = Just $ addrIndexOp jlong mempty

simpleOp ReadOffAddrOp_Char = Just $ addrIndexOp jbyte preserveByte
simpleOp ReadOffAddrOp_WideChar = Just $ addrIndexOp jint mempty
simpleOp ReadOffAddrOp_Int = Just $ addrIndexOp jint mempty
simpleOp ReadOffAddrOp_Word = Just $ addrIndexOp jint mempty
simpleOp ReadOffAddrOp_Addr = Just $ addrIndexOp jint
  (invokestatic $
    mkMethodRef memoryManager "getBuffer" [jint] (ret byteBufferType))
simpleOp ReadOffAddrOp_Float = Just $ addrIndexOp jfloat mempty
simpleOp ReadOffAddrOp_Double = Just $ addrIndexOp jdouble mempty
simpleOp ReadOffAddrOp_StablePtr = Just $ addrIndexOp jint mempty
simpleOp ReadOffAddrOp_Int8 = Just $ addrIndexOp jbyte preserveByte
simpleOp ReadOffAddrOp_Int16 = Just $ addrIndexOp jshort preserveShort
simpleOp ReadOffAddrOp_Int32 = Just $ addrIndexOp jint mempty
simpleOp ReadOffAddrOp_Int64 = Just $ addrIndexOp jlong mempty
simpleOp ReadOffAddrOp_Word8 = Just $ addrIndexOp jbyte preserveByte
simpleOp ReadOffAddrOp_Word16 = Just $ addrIndexOp jshort preserveShort
simpleOp ReadOffAddrOp_Word32 = Just $ addrIndexOp jint mempty
simpleOp ReadOffAddrOp_Word64 = Just $ addrIndexOp jlong mempty

simpleOp WriteOffAddrOp_Char = Just $ addrWriteOp jbyte mempty
simpleOp WriteOffAddrOp_WideChar = Just $ addrWriteOp jint mempty
simpleOp WriteOffAddrOp_Int = Just $ addrWriteOp jint mempty
simpleOp WriteOffAddrOp_Word = Just $ addrWriteOp jint mempty
simpleOp WriteOffAddrOp_Addr = Just $ addrWriteOp jint
  (invokestatic $
     mkMethodRef memoryManager "getAddress" [byteBufferType] (ret jint))
simpleOp WriteOffAddrOp_Float = Just $ addrWriteOp jfloat mempty
simpleOp WriteOffAddrOp_Double = Just $ addrWriteOp jdouble mempty
-- TODO: Verify writes for Word/Int 8/16 - add additional casts?
simpleOp WriteOffAddrOp_StablePtr = Just $ addrWriteOp jint mempty
simpleOp WriteOffAddrOp_Int8 = Just $ addrWriteOp jbyte preserveByte
simpleOp WriteOffAddrOp_Int16 = Just $ addrWriteOp jshort preserveShort
simpleOp WriteOffAddrOp_Int32 = Just $ addrWriteOp jint mempty
simpleOp WriteOffAddrOp_Int64 = Just $ addrWriteOp jlong mempty
simpleOp WriteOffAddrOp_Word8 = Just $ addrWriteOp jbyte preserveByte
simpleOp WriteOffAddrOp_Word16 = Just $ addrWriteOp jshort preserveShort
simpleOp WriteOffAddrOp_Word32 = Just $ addrWriteOp jint mempty
simpleOp WriteOffAddrOp_Word64 = Just $ addrWriteOp jlong mempty

-- TODO: Verify that narrowing / preserving are compatible with GHC
-- Narrowing ops
simpleOp Narrow8IntOp   = Just $ normalOp $ preserveByte
simpleOp Narrow16IntOp  = Just $ normalOp $ preserveShort
simpleOp Narrow32IntOp  = Just idOp
simpleOp Narrow8WordOp  = Just $ normalOp $ preserveByte
simpleOp Narrow16WordOp = Just $ normalOp $ preserveShort
simpleOp Narrow32WordOp = Just idOp

-- Misc
simpleOp SameTVarOp             = Just $ intCompOp if_acmpeq
simpleOp SameMVarOp             = Just $ intCompOp if_acmpeq
simpleOp EqStablePtrOp          = Just $ intCompOp if_icmpeq
simpleOp EqStableNameOp         = Just $ intCompOp if_icmpeq
simpleOp SameMutableByteArrayOp = Just $ intCompOp if_acmpeq
simpleOp ReallyUnsafePtrEqualityOp = Just $ intCompOp if_acmpeq
simpleOp StableNameToIntOp      = Just idOp
simpleOp TouchOp                = Just $ const mempty
simpleOp CopyAddrToByteArrayOp = Just $ normalOp $
  invokestatic $ mkMethodRef stgByteArray "copyAddrToByteArray"
                   [byteBufferType, closureType, jint, jint] void
simpleOp CopyMutableByteArrayToAddrOp = Just $ normalOp $
  invokestatic $ mkMethodRef stgByteArray "copyByteArrayToAddr"
                   [closureType, jint, byteBufferType, jint] void
simpleOp CopyByteArrayToAddrOp = Just $ normalOp $
  invokestatic $ mkMethodRef stgByteArray "copyByteArrayToAddr"
                   [closureType, jint, byteBufferType, jint] void
simpleOp CopyByteArrayOp = Just $ normalOp $
  invokestatic $ mkMethodRef stgByteArray "copyByteArray"
                   [closureType, jint, closureType, jint, jint] void
simpleOp CopyMutableByteArrayOp = Just $ normalOp $
  invokestatic $ mkMethodRef stgByteArray "copyByteArray"
                   [closureType, jint, closureType, jint, jint] void
simpleOp StablePtr2AddrOp = Just $ normalOp $
  invokestatic $ mkMethodRef "eta/runtime/stg/StablePtrTable" "stablePtr2Addr"
                   [jint] (ret byteBufferType)
simpleOp Addr2StablePtrOp = Just $ normalOp $
  invokevirtual $ mkMethodRef byteBuffer "getInt" [] (ret jint)
simpleOp SizeofMutableByteArrayOp = Just $ normalOp $
  invokevirtual $ mkMethodRef stgByteArray "remaining" [] (ret jint)
simpleOp SizeofByteArrayOp = Just $ normalOp $
  invokevirtual $ mkMethodRef stgByteArray "remaining" [] (ret jint)

-- Sparks
-- TODO: Implement
simpleOp ParOp = Just $ \_ -> iconst jint 0

simpleOp ObjectIsNull = Just $ \[o] -> o <> ifnull (iconst jint 1) (iconst jint 0)

simpleOp _             = Nothing

popCntOp, clzOp, ctzOp :: Code
popCntOp = invokestatic $ mkMethodRef "java/lang/Integer" "bitCount" [jint] (ret jint)
clzOp = invokestatic $ mkMethodRef "java/lang/Integer" "numberOfLeadingZeros" [jint] (ret jint)
ctzOp = invokestatic $ mkMethodRef "java/lang/Integer" "numberOfTrailingZeros" [jint] (ret jint)

addrCmpOp :: (Code -> Code -> Code) -> [Code] -> Code
addrCmpOp op args = intCompOp op (map (<> byteBufferAddrGet) args)

floatMathEndoOp :: Text -> Code
floatMathEndoOp f = gconv jfloat jdouble <> doubleMathEndoOp f <> gconv jdouble jfloat

floatMathOp :: Text -> [FieldType] -> FieldType -> Code
floatMathOp f args ret = gconv jfloat jdouble <> doubleMathOp f args ret <> gconv jdouble jfloat

doubleMathOp :: Text -> [FieldType] -> FieldType -> Code
doubleMathOp f args ret = invokestatic $ mkMethodRef "java/lang/Math" f args (Just ret)

doubleMathEndoOp :: Text -> Code
doubleMathEndoOp f = doubleMathOp f [jdouble] jdouble

addrIndexOp :: FieldType -> Code -> [Code] -> Code
addrIndexOp ft resCode = \[this, ix] ->
     this
  <> dup byteBufferType
  <> byteBufferPosGet
  <> ix
  <> iconst jint (fromIntegral (fieldByteSize ft))
  <> imul
  <> iadd
  <> byteBufferGet ft
  <> resCode

addrWriteOp :: FieldType -> Code -> [Code] -> Code
addrWriteOp ft argCode = \[this, ix, val] ->
    this
 <> dup byteBufferType
 <> byteBufferPosGet
 <> ix
 <> iconst jint (fromIntegral (fieldByteSize ft))
 <> imul
 <> iadd
 <> val
 <> argCode
 <> byteBufferPut ft
 <> pop byteBufferType

byteArrayIndexOp :: FieldType -> Code -> [Code] -> Code
byteArrayIndexOp ft resCode = \[this, ix] ->
  addrIndexOp ft resCode [this <> byteArrayBuf, ix]

byteArrayWriteOp :: FieldType -> Code -> [Code] -> Code
byteArrayWriteOp ft argCode = \[this, ix, val] ->
  addrWriteOp ft argCode [this <> byteArrayBuf, ix, val]

preserveByte :: Code
preserveByte = iconst jint 0xFF <> iand

preserveShort :: Code
preserveShort = iconst jint 0xFFFF <> iand

unsignedOp :: Code -> [Code] -> Code
unsignedOp op [arg1, arg2]
  = unsignedExtend arg1
 <> unsignedExtend arg2
 <> op
 <> gconv jlong jint

typedCmp :: FieldType -> (Code -> Code -> Code) -> [Code] -> Code
typedCmp ft ifop [arg1, arg2]
  = gcmp ft arg1 arg2
 <> ifop (iconst jint 1) (iconst jint 0)

unsignedCmp :: (Code -> Code -> Code) -> [Code] -> Code
unsignedCmp ifop args
  = typedCmp jlong ifop $ map unsignedExtend args

unsignedExtend :: Code -> Code
unsignedExtend i = i <> gconv jint jlong <> lconst 0xFFFFFFFF <> land

lONG_MIN_VALUE :: Code
lONG_MIN_VALUE = lconst 0x8000000000000000

unsignedLongCmp :: (Code -> Code -> Code) -> [Code] -> Code
unsignedLongCmp ifop args
  = typedCmp jlong ifop $ map addMin args
  where addMin x = x <> lONG_MIN_VALUE <> ladd
