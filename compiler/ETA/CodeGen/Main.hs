{-# LANGUAGE OverloadedStrings, LambdaCase #-}
module ETA.CodeGen.Main where

import ETA.BasicTypes.Module
import ETA.BasicTypes.VarEnv
import ETA.BasicTypes.VarSet
import ETA.Main.HscTypes
import ETA.Types.TyCon
import ETA.StgSyn.StgSyn
import ETA.Main.DynFlags
import ETA.BasicTypes.Id
import ETA.BasicTypes.Name
import ETA.BasicTypes.DataCon
import ETA.Utils.Util (unzipWith)
import ETA.Utils.Digraph
import ETA.Prelude.PrelNames (rOOT_MAIN)

import ETA.Util

import ETA.Debug
import ETA.CodeGen.Types
import ETA.CodeGen.Closure
import ETA.CodeGen.Layout
import ETA.CodeGen.Constr
import ETA.CodeGen.Expr
import ETA.CodeGen.Monad
import ETA.CodeGen.Bind
import ETA.CodeGen.Name
import ETA.CodeGen.Rts
import ETA.CodeGen.ArgRep
import ETA.CodeGen.Env
import ETA.CodeGen.Utils

import Codec.JVM

import Data.Foldable
import Data.Monoid
import Data.Maybe
import Control.Monad hiding (void)

import Data.Text (Text, pack, append)

codeGen :: HscEnv -> Module -> ModLocation
        -> [TyCon] -> [StgBinding] -> HpcInfo
        -> Maybe ([MethodDef], [FieldDef]) -> IO [ClassFile]
codeGen hscEnv thisMod thisModLoc dataTyCons stgBinds _hpcInfo mMFs = do
  runCodeGen mMFs env state $ do
    mapM_ (cgTopBinding dflags) stgBinds
    mapM_ cgTyCon dataTyCons
  where
    (env, state) = initCg dflags thisMod thisModLoc
    dflags = hsc_dflags hscEnv

cgTopBinding :: DynFlags -> StgBinding -> CodeGen ()
cgTopBinding dflags (StgNonRec id rhs) = do
  traceCg $ str "generating " <+> ppr id
  id' <- externaliseId dflags id
  let (info, code) = cgTopRhs dflags NonRecursive [id'] Nothing id' rhs
  mRecInfo <- code
  genRecInitCode $ maybeToList $ fmap (id',) mRecInfo
  addBinding info

cgTopBinding dflags (StgRec pairs) = do
  _mod <- getModule
  let (binders, rhss) = unzip pairs
  traceCg $ str "generating (rec)" <+> ppr binders
  binders' <- mapM (externaliseId dflags) binders
  let pairs'         = zip binders' rhss
      conRecIds      = map fst
                     $ filter (\(_, expr) -> case expr of
                                  StgRhsCon _ _ _ -> True
                                  _               -> False)
                     $ pairs'
      -- Only grab functions, not thunks
      funRecBinds = findFunCycles
                  $ filter (\(_, expr) -> case expr of
                             StgRhsClosure _ _ _ _ _ args _
                               | length args > 0 -> True
                             _ -> False)
                  $ pairs'

  (mFunRecIds, genRecFunCode) <-
    if length funRecBinds > 1
    then do
      genFunRecBinds funRecBinds
    else return (Nothing, return ())
  let (infos, codes) = unzip $
        unzipWith (cgTopRhs dflags Recursive conRecIds mFunRecIds) pairs'
  addBindings infos
  recInfos <- fmap catMaybes
            $ forM (zip binders' codes)
            $ \(id, code) -> do
              mRecInfo <- code
              return $ fmap (id,) mRecInfo
  genRecInitCode recInfos
  genRecFunCode
  -- NOTE: We do addBindings again to restore the bindings. genRecFunCode temporarily
  --       adds lneInfos for the ids.
  addBindings infos
  where genFunRecBinds funRecBinds = do
          n <- newRecursiveInitNumber
          traceCg $ str "Found mutually recursive group [" <+> int n <+> str "]:"
                <+> ppr (map fst funRecBinds)
          let genCode = do
                _ <- withMethod [Public, Static] (mkRecBindingMethodName n)
                  [closureType, contextType, jint] (ret closureType) $ do
                  label <- newLabel
                  let targetLoc = mkLocLocal False jint 2
                  ((_,loadCode):loadCodes, codes')
                    <- fmap unzip $ forM (zip [0..] funRecBinds) $
                        \(target, (funId, StgRhsClosure _ _ _ _ _ args' body)) -> do
                        let args = nonVoidIds args'
                        argLocs <- mapM newIdLoc args
                        emit $ fold (map storeDefault argLocs)
                        let code = fmap (target,) $ forkLneBody $ do
                              traceCg $ str "Generating (mutually recursive)"
                                    <+> ppr funId
                              bindArgs $ zip args argLocs
                              cgExpr body
                        addScopedBinding $
                          lneIdInfo funId label target targetLoc argLocs
                        return ((target, mkCallEntry argLocs), code)
                  ((_,code):codes) <- sequence codes'
                  emit $ intSwitch (loadLoc targetLoc) loadCodes (Just loadCode)
                      <> startLabel label
                      <> intSwitch (loadLoc targetLoc) codes (Just code)
                return ()
          let funRecIdsMap = mkVarEnv $ zip (map fst funRecBinds) [0..]
          return (Just (n, funRecIdsMap), genCode)

        findFunCycles :: [(Id, StgRhs)] -> [(Id, StgRhs)]
        findFunCycles idExprs = concat
                              . map findCyclicNodes
                              . stronglyConnCompG
                              $ graphFromEdgedVertices nodes
          where nodes = map (\(id, expr) ->
                               ((expr, id, findRecCalls (recIds `delVarSet` id) expr)))
                        idExprs
                recIds = mkVarSet $ map fst idExprs
                findCyclicNodes (CyclicSCC nodes)
                  = map (\(expr, id, _) -> (id, expr)) nodes
                findCyclicNodes _ = []
                findRecCalls recIds (StgRhsClosure _ _ _ _ _ _ expr) = go expr
                  where go (StgApp occ _) | occ `elemVarSet` recIds = [occ]
                        go (StgTick _ expr) = go expr
                        go (StgCase _ _ _ _ _ _ alts)
                          = concat $ map (\(_, _, _, expr) -> go expr) alts
                        go (StgLetNoEscape _ _ binding expr) =
                          go expr
                          ++ (case binding of
                                StgNonRec _ (StgRhsClosure _ _ _ _ _ _ body) -> go body
                                StgRec pairs -> concat $
                                  map (\case
                                          (_, StgRhsClosure _ _ _ _ _ _ body)
                                            -> go body
                                          _ -> []) pairs)
                        go (StgLet _ expr) = go expr
                        go _ = []

cgTopRhs :: DynFlags -> RecFlag -> [Id] -> Maybe (Int, VarEnv Int) -> Id -> StgRhs -> (CgIdInfo, CodeGen (Maybe RecInfo))
cgTopRhs dflags _ conRecIds _ binder (StgRhsCon _ con args) =
  cgTopRhsCon dflags binder conRecIds con args

cgTopRhs dflags recflag _ mFunRecIds binder
   (StgRhsClosure _ binderInfo _freeVars updateFlag _ args body) =
  -- fvs should be empty
  cgTopRhsClosure dflags recflag mFunRecIds binder binderInfo updateFlag args body

cgTopRhsClosure :: DynFlags
                -> RecFlag              -- member of a recursive group?
                -> Maybe (Int, VarEnv Int)
                -> Id
                -> StgBinderInfo
                -> UpdateFlag
                -> [Id]                 -- Args
                -> StgExpr
                -> (CgIdInfo, CodeGen (Maybe RecInfo))
cgTopRhsClosure dflags recflag mFunRecIds id _binderInfo updateFlag args body
  = (cgIdInfo, genCode)
  where cgIdInfo = mkCgIdInfo dflags id lfInfo
        lfInfo = mkClosureLFInfo id TopLevel [] updateFlag args
        (modClass, clName, _clClass) = getJavaInfo dflags cgIdInfo
        qClName = closure clName
        genCode
          | StgApp f [] <- body, null args, isNonRec recflag
          = do cgInfo <- getCgIdInfo f
               defineField $ mkFieldDef [Private, Static] qClName closureType
               let field = mkFieldRef modClass qClName closureType
                   loadCode = idInfoLoadCode cgInfo
                   initField =
                       [
                         new indStaticType
                       , dup indStaticType
                       , loadCode
                       , invokespecial $ mkMethodRef stgIndStatic "<init>" [closureType] void
                       , putstatic field
                       ]
               defineMethod $ initCodeTemplate True modClass qClName field
                              (fold initField)
               return Nothing
          | otherwise = do
            let arity = length args
            (_, CgState { cgClassName }) <- forkClosureBody $
              closureCodeBody True id lfInfo
                              (nonVoidIds args) mFunRecIds arity body [] False []

            let ft        = obj cgClassName
                flags     = [Private, Static]
                isThunk   = arity == 0
                field     = mkFieldRef modClass qClName closureType
                initField =
                    [
                      new ft
                    , dup ft
                    , invokespecial $ mkMethodRef cgClassName "<init>" [] void
                    , putstatic field
                    ]
            defineField $ mkFieldDef flags qClName closureType
            -- Only thunk init codes should be synchronized since they are stateful.
            defineMethod $ initCodeTemplate isThunk modClass qClName field
                          (fold initField)
            return Nothing

-- Simplifies the code if the mod is associated to the Id
externaliseId :: DynFlags -> Id -> CodeGen Id
externaliseId _dflags id = do
  mod <- getModule
  return $
    if isInternalName name then
      setIdName id $ externalise mod
    else if isExternalName name && nameModule name == rOOT_MAIN then
      setIdName id $ internalise mod
    else id
  where
    internalise mod = mkExternalName uniq mod occ' loc
      where occ' = mkOccName ns $ ":" ++ occNameString occ
    externalise mod = mkExternalName uniq mod occ' loc
      where occ' = mkLocalOcc uniq occ
    name = idName id
    uniq = nameUnique name
    occ  = nameOccName name
    loc  = nameSrcSpan name
    ns   = occNameSpace occ

cgTyCon :: TyCon -> CodeGen ()
cgTyCon tyCon = unless (null dataCons) $ do
    dflags <- getDynFlags
    let tyConClass = nameTypeText dflags . tyConName $ tyCon
    (_, CgState {..}) <- newTypeClosure tyConClass stgConstr
    mapM_ (cgDataCon cgClassName) dataCons
    when (isEnumerationTyCon tyCon) $
      cgEnumerationTyCon cgClassName tyCon
  where dataCons = tyConDataCons tyCon

cgEnumerationTyCon :: Text -> TyCon -> CodeGen ()
cgEnumerationTyCon _tyConCl tyCon = do
  dflags <- getDynFlags
  thisClass <- getClass
  let fieldName = nameTypeTable dflags $ tyConName tyCon
      loadCodes = [    dup arrayFt
                    <> iconst jint i
                    <> new dataFt
                    <> dup dataFt
                    <> invokespecial (mkMethodRef dataClass "<init>" [] void)
                    <> gastore closureType
                    | (i, con) <- zip [0..] $ tyConDataCons tyCon
                    , let dataFt    = obj dataClass
                          dataClass = dataConClass dflags con ]
      field = mkFieldRef thisClass fieldName arrayFt
      initField = [ iconst jint $ fromIntegral familySize
                  , new arrayFt
                  , fold loadCodes
                  , putstatic field
                  ]
  defineField $ mkFieldDef [Private, Static] fieldName arrayFt
  modClass <- getModClass
  defineMethod $ initCodeTemplate' arrayFt False modClass fieldName field $ fold initField
  where
        arrayFt = jarray closureType
        familySize = tyConFamilySize tyCon

cgDataCon :: Text -> DataCon -> CodeGen ()
cgDataCon typeClass dataCon = do
  dflags <- getDynFlags
  modClass <- getModClass
  let dataConClassName = nameDataText dflags . dataConName $ dataCon
      thisClass = qualifiedName modClass dataConClassName
      thisFt = obj thisClass
      defineTagMethod =
          defineMethod . mkMethodDef thisClass [Public] "getTag" [] (ret jint) $
                         iconst jint conTag
                      <> greturn jint
  -- TODO: Reduce duplication
  if isNullaryRepDataCon dataCon then do
      _ <- newExportedClosure dataConClassName typeClass $ do
        defineMethod $ mkDefaultConstructor thisClass typeClass
        defineTagMethod
      return ()
  else
    do let initCode :: Code
           initCode = go 1 indexedFields
             where go _ [] = mempty
                   go n ((i, ft): xs) = code <> go (n + fieldSize ft) xs
                    where maybeDup = if i /= numFields then dup thisFt else mempty
                          code     = maybeDup
                                  <> gload ft (fromIntegral n)
                                  <> putfield (mkFieldRef thisClass (constrField i) ft)

           fieldDefs :: [FieldDef]
           fieldDefs = map (\(i, ft) ->
                        -- TODO: Find a better way to handle recursion
                        --       that allows us to use 'final' in most cases.
                         mkFieldDef [Public] (constrField i) ft)
                       indexedFields


           (ps, os, ns, fs, ls, ds) = go indexedFields [] [] [] [] [] []

           go [] ps os ns fs ls ds = (ps, os, ns, fs, ls, ds)
           go ((i, ft):ifs) ps os ns fs ls ds =
             case ftArgRep ft of
               P -> go ifs ((i, code):ps) os ns fs ls ds
               O -> go ifs ps ((i, code):os) ns fs ls ds
               N -> go ifs ps os ((i, code):ns) fs ls ds
               F -> go ifs ps os ns ((i, code):fs) ls ds
               L -> go ifs ps os ns fs ((i, code):ls) ds
               D -> go ifs ps os ns fs ls ((i, code):ds)
               _ -> panic "cgDataCon: V argrep!"
              where code = gload thisFt 0
                        <> getfield (mkFieldRef thisClass (constrField i) ft)

           defineGetRep :: ArgRep -> [(Int, Code)] -> CodeGen ()
           defineGetRep _rep [] = return ()
           defineGetRep rep branches =
             defineMethod $
               mkMethodDef thisClass [Public] method [jint] (ret ft) $
                 gswitch (gload jint 1) branches
                   (Just $ barf (append method ": invalid field index!")
                        <> defaultValue ft)
              <> greturn ft
             where ft = argRepFt rep
                   method = append "get" (pack $ show rep)

           indexedFields :: [(Int, FieldType)]
           indexedFields = indexList fields

           numFields :: Int
           numFields = length fields

           fields :: [FieldType]
           fields = repFieldTypes $ dataConRepArgTys dataCon

       _ <- newExportedClosure dataConClassName typeClass $ do
         defineFields fieldDefs
         defineTagMethod
         defineGetRep P ps
         defineGetRep O os
         defineGetRep N ns
         defineGetRep F fs
         defineGetRep L ls
         defineGetRep D ds
         defineMethod $ mkConstructorDef thisClass typeClass fields initCode
       return ()
  where conTag = fromIntegral $ getDataConTag dataCon

genRecInitCode :: [(Id, RecInfo)] -> CodeGen ()
genRecInitCode []       = return ()
-- Extremely common case
genRecInitCode [(_ , (modClass, qClName, dataClass, field, code, recIndexes))] = do
  let postCode = map (\(i, _) ->
                        dup dataFt
                     <> dup dataFt
                     <> putfield (mkFieldRef dataClass (constrField i) closureType))
                 recIndexes
      dataFt   = obj dataClass
  defineMethod $ initCodeTemplate True modClass qClName field $
    code <> fold postCode <> putstatic field
-- Rare case
genRecInitCode recIdInfos = do
  let localsEnv = mkVarEnv $ zip recIds [0..]
  moduleClass <- getModClass
  recInitNo <- newRecursiveInitNumber
  let recInitMethod = mkMethodRef moduleClass recMethodName [] void
      recMethodName = mkRecInitMethodName recInitNo
  loadStoreCodes <- forM recIdInfos $
    \(id, (modClass, qClName, dataClass, field, code, recIndexes)) -> do
      let dataFt     = obj dataClass
          recIdLocal = lookupVarEnv_NF localsEnv id
          genRecStoreCode (i, recId)
            = dup dataFt
           <> gload closureType (lookupVarEnv_NF localsEnv recId)
           <> putfield (mkFieldRef dataClass (constrField i) closureType)
      defineMethod $ initCodeTemplate True modClass qClName field
                     (invokestatic recInitMethod)
      return ( code <> gstore dataFt recIdLocal
             , gload dataFt recIdLocal
            <> fold (map genRecStoreCode recIndexes)
            <> putstatic field)
  let (loadCodes, storeCodes) = unzip loadStoreCodes
      initCodeBody = fold loadCodes <> fold storeCodes <> vreturn
  defineMethod $
    mkMethodDef moduleClass [Public, Static] recMethodName [] void initCodeBody
  where (recIds, _recInfos) = unzip recIdInfos

