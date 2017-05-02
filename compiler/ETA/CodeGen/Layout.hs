{-# LANGUAGE OverloadedStrings #-}
module ETA.CodeGen.Layout where

import ETA.Types.Type
import ETA.Types.TyCon
import ETA.Main.DynFlags
import ETA.StgSyn.StgSyn
import ETA.BasicTypes.Id
import Codec.JVM
import ETA.Util
import ETA.CodeGen.Monad
import ETA.CodeGen.Types
import ETA.CodeGen.ArgRep
import ETA.CodeGen.Rts
import ETA.CodeGen.Name (qualifiedName)
import ETA.CodeGen.Env


import Data.Maybe (mapMaybe)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Foldable (fold)

emitReturn :: [CgLoc] -> CodeGen ()
emitReturn results = do
  sequel <- getSequel
  emit $
    case sequel of
      Return         -> mkReturnExit results
      AssignTo slots -> multiAssign slots (map loadLoc results)

emitAssign :: CgLoc -> Code -> CodeGen ()
emitAssign cgLoc code = emit $ storeLoc cgLoc code

-- TODO: Verify that this is valid in all cases,
--       otherwise fall back on the strongly connected components
--       algorithm a la GHC
multiAssign :: [CgLoc] -> [Code] -> Code
multiAssign locs codes = fold $ zipWith storeLoc locs codes
-- multiAssign [] []       = mempty
-- multiAssign [loc] [rhs] = storeLoc loc rhs
-- multiAssign _ _         = error "multiAssign for more than one location"

-- TODO: Beautify this code
-- TODO: There are a lot of bangs in this function. Verify that they do
--       indeed help.
mkCallEntry :: Int -> [NonVoid Id] -> ([(NonVoid Id, CgLoc)], Code, Int)
mkCallEntry nStart nvArgs = (zip nvArgs locs, loadContext <> code, n)
  where (!code, !locs, !n) = loadArgs nStart mempty [] (map mkLayoutArg nvArgs) 2 1 1 1 1 1
        loadArgs !n !code !locs ((_arg, argRep, ft):args)
                 !r !i !l !f !d !o =
          case argRep of
            P -> loadRec (context r) (r + 1) i l f d o
            N -> loadRec (context i <> gconv jint ft) r (i + 1) l f d o
            L -> loadRec (context l) r i (l + 1) f d o
            F -> loadRec (context f) r i l (f + 1) d o
            D -> loadRec (context d) r i l f (d + 1) o
            O -> loadRec (context o <> gconv jobject ft) r i l f d (o + 1)
            _ -> error "contextLoad: V"
          where context = contextLoad ft argRep
                loadRec nextCode =
                  loadArgs (n + ftSize) (code <> nextCode)
                           (loc:locs) args
                ftSize = fieldSize ft
                loc = LocLocal (argRep == P) ft n
        loadArgs !n !code !locs _ _ _ _ _ _ _ = (code, reverse locs, n)

mkLayoutArg :: NonVoid Id -> (Id, ArgRep, FieldType)
mkLayoutArg arg = (arg', argRep, ft)
  where arg' = unsafeStripNV arg
        argRep = idArgRep arg'
        ft = expectJust "mkLayoutArg" . repFieldType_maybe $ idType arg'

mkCallExit :: Bool -> [(ArgRep, Maybe FieldType, Maybe Code)] -> Code
mkCallExit slow args' = storeArgs mempty args' rStart 1 1 1 1 1
  where rStart = if slow then 1 else 2
        storeArgs !code ((argRep, ft', code'):args) !r !i !l !f !d !o =
          case argRep of
            P -> storeRec (context r) (r + 1) i l f d o
            N -> storeRec (context i) r (i + 1) l f d o
            L -> storeRec (context l) r i (l + 1) f d o
            F -> storeRec (context f) r i l (f + 1) d o
            D -> storeRec (context d) r i l f (d + 1) o
            O -> storeRec (context o) r i l f d (o + 1)
            V -> storeArgs code args r i l f d o
          where ft = expectJust "mkCallExit:ft" ft'
                loadCode = expectJust "mkCallExit:loadCode" code'
                context = contextStore ft argRep loadCode
                storeRec nextCode =
                  storeArgs (code <> nextCode) args
        storeArgs !code _ _ _ _ _ _ _ = code

mkReturnEntry :: [CgLoc] -> Code
mkReturnEntry cgLocs' = loadVals mempty cgLocs' 1 1 1 1 1 1
  where loadVals !code (cgLoc:cgLocs) !r !i !l !f !d !o =
          case argRep of
            P -> loadRec (context r) (r + 1) i l f d o
            N -> loadRec (context i <> gconv jint ft) r (i + 1) l f d o
            L -> loadRec (context l) r i (l + 1) f d o
            F -> loadRec (context f) r i l (f + 1) d o
            D -> loadRec (context d) r i l f (d + 1) o
            O -> loadRec (context o <> gconv jobject ft) r i l f d (o + 1)
            _ -> error "contextLoad: V"
          where ft = locFt cgLoc
                argRep = locArgRep cgLoc
                context = contextLoad ft argRep
                loadRec nextCode =
                  loadVals (code <> storeLoc cgLoc nextCode) cgLocs
        loadVals !code _ _ _ _ _ _ _ = code

mkReturnExit :: [CgLoc] -> Code
mkReturnExit cgLocs' = storeVals mempty cgLocs' 1 1 1 1 1 1
  where storeVals !code (cgLoc:cgLocs) !r !i !l !f !d !o =
          case argRep of
            P -> storeRec (context r) (r + 1) i l f d o
            N -> storeRec (context i) r (i + 1) l f d o
            L -> storeRec (context l) r i (l + 1) f d o
            F -> storeRec (context f) r i l (f + 1) d o
            D -> storeRec (context d) r i l f (d + 1) o
            O -> storeRec (context o) r i l f d (o + 1)
            _ -> error "contextLoad: V"
          where ft = locFt cgLoc
                loadCode = loadLoc cgLoc
                argRep = locArgRep cgLoc
                context = contextStore ft argRep loadCode
                storeRec nextCode =
                  storeVals (code <> nextCode) cgLocs
        storeVals !code _ _ _ _ _ _ _ = code

slowCall :: CgLoc -> [StgArg] -> CodeGen ()
slowCall fun args = do
  dflags <- getDynFlags
  argFtCodes <- getRepFtCodes args
  let (apPat, arity, _fts) = slowCallPattern $ map (\(a,_,_) -> a) argFtCodes
      slowCode = directCall' True (mkApFast apPat) arity
                             ((P, Just ft, Just code):argFtCodes)
  if n > arity && optLevel dflags >= 2 then do
    -- TODO: Implement optimization
    --       effectively an evaluation test + fast call
    emit slowCode
  else
    emit slowCode
  where n = length args
        ft = locFt fun
        code = loadLoc fun

directCall :: Bool -> CgLoc -> RepArity -> [StgArg] -> CodeGen ()
directCall slow (LocStatic _ modClass clName) arity args = do
  argFtCodes <- getRepFtCodes args
  emit $ directStaticCall slow modClass' arity argFtCodes
  where modClass' = qualifiedName modClass clName
directCall slow cgLoc arity args = do
  argFtCodes <- getRepFtCodes args
  emit $ directCall' slow (enterMethod cgLoc) arity argFtCodes

directStaticCall :: Bool -> Text -> RepArity -> [(ArgRep, Maybe FieldType, Maybe Code)] -> Code
directStaticCall slow modClass arity args =
     stackLoadCode restArgs
  <> aconst_null closureType
  <> loadContext
  <> fold (mapMaybe argCode callArgs)
  <> enterBody modClass (mapMaybe argFt callArgs)
  where (callArgs, restArgs) = splitAt realArity args
        realArity = if slow then arity + 1 else arity
        argFt (_, ft', _) = ft'
        argCode (_, _, code') = code'

directCall' :: Bool -> Code -> RepArity -> [(ArgRep, Maybe FieldType, Maybe Code)] -> Code
directCall' slow entryCode arity args =
     stackLoadCode restArgs
  <> mkCallExit slow callArgs
  <> entryCode
  where (callArgs, restArgs) = splitAt realArity args
        realArity = if slow then arity + 1 else arity

stackLoadCode :: [(ArgRep, Maybe FieldType, Maybe Code)] -> Code
stackLoadCode args =
  if null stackFrames then mempty
  else    loadContext
       <> currentTSOField
       <> fold stackFramesLoad
       <> pop tsoType
  where stackFramesLoad = map (\code -> dup tsoType
                                     <> code
                                     <> spPushMethod)
                          stackFrames
        stackFrames = slowArgFrames args

slowArgFrames :: [(ArgRep, Maybe FieldType, Maybe Code)] -> [Code]
slowArgFrames [] = []
slowArgFrames args = thisFrame : slowArgFrames restArgs
  where (argPat, n, fts) = slowCallPattern $ map (\(a,_,_) -> a) args
        (callArgs, restArgs) = splitAt n args
        thisFrame = genSlowFrame argPat fts callArgs

genSlowFrame :: Text -> [FieldType] -> [(ArgRep, Maybe FieldType, Maybe Code)] -> Code
genSlowFrame patText fts args =
     new ft
  <> dup ft
  <> fold loadCodes
  <> invokespecial (mkMethodRef patClass "<init>" fts void)
  where patClass = apply $ argPatToFrame patText
        loadCodes = mapMaybe (\(_, _, a) -> a) args
        ft = obj patClass

getRepFtCodes :: [StgArg] -> CodeGen [(ArgRep, Maybe FieldType, Maybe Code)]
getRepFtCodes = mapM getFtAmode
  where getFtAmode arg
          | Nothing <- ft = return (V, Nothing, Nothing)
          | otherwise = do code <- getArgLoadCode (NonVoid arg)
                           return (rep, ft, Just code)
          where ty = stgArgType arg
                ft = repFieldType_maybe ty
                rep = typeArgRep ty

newUnboxedTupleLocs :: Type -> CodeGen [CgLoc]
newUnboxedTupleLocs resType = getSequel >>= chooseLocs
  where chooseLocs (AssignTo regs) = return regs
        chooseLocs _               = mapM (\rep -> newTemp (isGcPtrRep rep)
                                                           (primRepFieldType rep))
                                   $ getUnboxedResultReps resType

getUnboxedResultReps :: Type -> [PrimRep]
getUnboxedResultReps resType = [ rep
                               | ty <- tyArgs
                               , let rep = typePrimRep ty
                               , not (isVoidRep rep) ]
  where tyArgs = case repType resType of
          UbxTupleRep tys -> tys
          UnaryRep    ty  -> [ty]

withContinuation :: CodeGen () -> CodeGen ()
withContinuation call = do
  sequel <- getSequel
  case sequel of
    AssignTo cgLocs -> do
      wrapStackCheck call
      emit $ mkReturnEntry cgLocs
    _               -> do
      call
      return ()

wrapStackCheck :: CodeGen () -> CodeGen ()
wrapStackCheck call = do
    -- TODO: Replace the local variable with an internal variable in context?
    --stackTop <- newTemp False frameType
    emit $ loadContext <> spTopIndexMethod
    emit $ loadContext <> spTopMethod
    call
    emit $ loadContext
        <> dup_x2 jint frameType contextType
        <> pop contextType
        <> checkForStackFramesMethod
        <> ifeq mempty vreturn
