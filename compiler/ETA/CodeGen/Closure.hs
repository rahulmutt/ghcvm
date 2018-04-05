{-# LANGUAGE OverloadedStrings #-}
module ETA.CodeGen.Closure where

import ETA.Main.DynFlags
import ETA.BasicTypes.Id
import ETA.StgSyn.StgSyn
import ETA.Types.Type
import ETA.Types.TyCon
import ETA.BasicTypes.BasicTypes
import ETA.BasicTypes.DataCon
import ETA.Utils.Panic
import ETA.BasicTypes.Name
import ETA.CodeGen.Rts
import ETA.CodeGen.Types
import ETA.CodeGen.ArgRep
import Codec.JVM
import Data.Monoid((<>))
import Data.Text (Text)
import qualified Data.Text as T

mkClosureLFInfo :: Id           -- The binder
                -> TopLevelFlag -- True of top level
                -> [NonVoid Id] -- Free vars
                -> UpdateFlag   -- Update flag
                -> [Id]         -- Args
                -> LambdaFormInfo
mkClosureLFInfo binder topLevelFlag freeVars updateFlag args
  | null args =
        mkLFThunk (idType binder) topLevelFlag nvFreeVars updateFlag
  | otherwise =
        mkLFReEntrant topLevelFlag nvFreeVars args (mkArgDescr args)
  where nvFreeVars = map unsafeStripNV freeVars

mkConLFInfo :: DataCon -> LambdaFormInfo
mkConLFInfo = LFCon

mkLFReEntrant :: TopLevelFlag -> [Id] -> [Id] -> ArgFVDescr -> LambdaFormInfo
mkLFReEntrant topLevelFlag freeVars args argDescriptor =
  LFReEntrant {
    lfTopLevelFlag = topLevelFlag,
    lfArity = length args,
    lfNoFreeVars = null freeVars,
    lfArgDescriptor = argDescriptor }

mkLFThunk :: Type -> TopLevelFlag -> [Id] -> UpdateFlag -> LambdaFormInfo
mkLFThunk thunkType topLevelFlag freeVars updateFlag
  = -- Invariant: not updatable or lifted type
    LFThunk {
      lfTopLevelFlag = topLevelFlag,
      lfNoFreeVars = null freeVars,
      lfUpdatable = isUpdatable updateFlag,
      lfStandardFormInfo = NonStandardThunk,
      lfMaybeFunction = maybeFunction thunkType }

lfStandardForm :: Int -> Int -> Bool
lfStandardForm args fvs
  | args == 0 = fvs <= 6
  | args <= 4 = fvs <= 4
  | args <= 6 = fvs <= 1
  | otherwise = False

lfClass :: Bool -> Int -> Int -> LambdaFormInfo -> Text
lfClass hasStdLayout _arity fvs (LFThunk {..}) =
  "eta/" <> thunkBase <> thunkExt
  where thunkBase
          | isTopLevel lfTopLevelFlag = "runtime/thunk/CAF"
          | lfUpdatable               = "UpdatableThunk"
          | otherwise                 = "runtime/thunk/SingleEntryThunk"
        thunkExt
          | isTopLevel lfTopLevelFlag = mempty
          | hasStdLayout = T.pack ((++) (show fvs) "runtime/thunk/")
          | otherwise = mempty

lfClass hasStdLayout args fvs (LFReEntrant {..})
  = "eta/runtime/apply/Function" <> funExt
  where funExt
          | hasStdLayout = T.pack (show args) <> fvsText
          | args <= 6    = T.pack ((show args))
          | otherwise    = mempty
        fvsText
          | fvs > 0   = "_" <> T.pack (show fvs)
          | otherwise = mempty
lfClass _ _ _ _ = panic "lfClass: Not a Function or a Thunk"

lfCallPattern :: LambdaFormInfo -> Maybe CallPattern
lfCallPattern (LFReEntrant {..})
  | ArgFVSpec afts <- lfArgDescriptor = afts
lfCallPattern _ = Nothing

maybeFunction :: Type -> Bool
maybeFunction ty
  | UnaryRep rep <- repType ty
  , Just tc <- tyConAppTyCon_maybe rep
  , isDataTyCon tc
  = False
  | otherwise
  = True

mkArgDescr :: [Id] -> ArgFVDescr
mkArgDescr args = ArgFVSpec callPattern
  where callPattern = stdPattern argReps
        argReps = map idArgRep args

stdPattern :: [ArgRep] -> Maybe CallPattern
stdPattern argReps
  | length argReps == arity = Just (arity, fts)
  | otherwise = Nothing
  where (arity, fts) = slowCallPattern argReps

mkLFImported :: Id -> LambdaFormInfo
mkLFImported id
  | Just con <- isDataConWorkId_maybe id
  , isNullaryRepDataCon con
  = LFCon { lfDataCon = con }
  | arity > 0
  = LFReEntrant {
      lfTopLevelFlag = TopLevel,
      lfArity = arity,
      lfNoFreeVars = True,
      lfArgDescriptor = panic "mkLFImported: lfArgDescriptor" }
  | otherwise
  = mkLFArgument id
  where arity = idRepArity id

mkLFArgument :: Id -> LambdaFormInfo
mkLFArgument id
  | isUnLiftedType ty      = LFUnLifted
  | maybeFunction ty       = LFUnknown True
  | otherwise              = LFUnknown False
  where
    ty = idType id

argPrimRep :: StgArg -> PrimRep
argPrimRep = typePrimRep . stgArgType

data CallMethod
  = EnterIt
  | JumpToIt Label [CgLoc] (Maybe (Int, CgLoc))
  | ReturnIt
  | SlowCall
  | DirectEntry CgLoc RepArity

getCallMethod
  :: DynFlags
  -> Name           -- Function being applied
  -> Id             -- Function Id used to chech if it can refer to
                    -- CAF's and whether the function is tail-calling
                    -- itself
  -> LambdaFormInfo -- Its info
  -> RepArity       -- Number of available arguments
  -> RepArity       -- Number of void arguments
  -> CgLoc          -- Passed in from cgIdApp so that we can
                    -- handle let-no-escape bindings and self-recursive
                    -- tail calls using the same data constructor,
                    -- JumpToIt. This saves us one case branch in
                    -- cgIdApp
  -> Maybe SelfLoopInfo -- can we perform a self-recursive tail call?
  -> Maybe CgLoc        -- Scoped location of function
  -> CallMethod

getCallMethod _ _ _ _ _ _ _ _ (Just (LocLne label target targetLoc cgLocs))
  = JumpToIt label cgLocs (Just (target, targetLoc))

getCallMethod dflags _ id _ nArgs vArgs _ (Just (selfLoopId, label, cgLocs)) _
  | gopt Opt_Loopification dflags, id == selfLoopId, nArgs - vArgs == length cgLocs
  = JumpToIt label cgLocs Nothing


-- TODO: Enter via node when in parallel
getCallMethod _ _ _ (LFReEntrant _ arity _ _) n _ cgLoc _ _
  | n == 0         = ReturnIt        -- No args at all
  | n < arity      = SlowCall        -- Not enough args
  | otherwise      = DirectEntry cgLoc arity

getCallMethod _ _ _ LFUnLifted _ _ _ _ _
  = ReturnIt

getCallMethod _ _ _ (LFCon _) _ _ _ _ _
  = ReturnIt

getCallMethod _ _ _
              (LFThunk _ _ updatable stdFormInfo isFun) _ _ cgLoc _ _
  | isFun      -- it *might* be a function, so we must "call" it (which is always safe)
  = SlowCall
  -- Since isFun is False, we are *definitely* looking at a data value
  | updatable
  = EnterIt
  -- TODO: Is the below necessary?
  -- even a non-updatable selector thunk can be updated by the garbage
  -- collector.
  | SelectorThunk {} <- stdFormInfo
  = EnterIt
  | otherwise        -- Jump direct to code for single-entry thunks
  = DirectEntry cgLoc 0

getCallMethod _ _ _ (LFUnknown True) _ _ _ _ _
  = SlowCall -- might be a function

getCallMethod _ _ _ (LFUnknown False) _ _ _ _ _
  = EnterIt -- Not a function

getCallMethod _ _ _ LFLetNoEscape _ _ (LocLne label target targetLoc cgLocs) _ _
  = JumpToIt label cgLocs (Just (target, targetLoc))

getCallMethod _ _ _ _ _ _ _ _ _ = panic "Unknown call method"

mkApLFInfo :: Id -> UpdateFlag -> Int -> LambdaFormInfo
mkApLFInfo id updateFlag arity
  = LFThunk NotTopLevel (arity == 0)
           (isUpdatable updateFlag) (ApThunk arity) (maybeFunction (idType id))

mkSelectorLFInfo :: Id -> Int -> ArgRep -> Bool -> LambdaFormInfo
mkSelectorLFInfo id pos rep updatable
  = LFThunk NotTopLevel False updatable (SelectorThunk pos rep)
        (maybeFunction (idType id))

lneIdInfo :: Id -> Label -> Int -> CgLoc -> [CgLoc] -> CgIdInfo
lneIdInfo id label target targetLoc cgLocs =
  CgIdInfo
  { cgId = id
  , cgLambdaForm =  mkLFLetNoEscape
  , cgLocation = LocLne label target targetLoc cgLocs }

getDataConTag :: DataCon -> Int
getDataConTag = dataConTag

mkLFLetNoEscape :: LambdaFormInfo
mkLFLetNoEscape = LFLetNoEscape

genStdThunk :: LambdaFormInfo -> (FieldType, Code -> Code)
genStdThunk (LFThunk _ _ updatable stdForm _)
  | SelectorThunk pos rep <- stdForm
  = let selClass = selectThunkName updatable $ T.pack (show rep)
        ft = obj selClass
    in ( ft
       , \loads ->
           new ft
        <> dup ft
        <> iconst jint (fromIntegral pos)
        <> loads
        <> invokespecial (mkMethodRef selClass "<init>" [jint, closureType] void) )
  | ApThunk n <- stdForm
  = let ft = obj apUpdClass
        fields = replicate n closureType
        apUpdClass = apUpdName n
    in ( ft
       , \loads ->
           new ft
        <> dup ft
        <> loads
        <> invokespecial (mkMethodRef apUpdClass "<init>" fields void) )
  | otherwise = panic "genStdThunk: Thunk is not in standard form!"
genStdThunk _ = error $ "genStdThunk: bad genStdThunk"
