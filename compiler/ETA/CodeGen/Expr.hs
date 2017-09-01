module ETA.CodeGen.Expr where

import ETA.Core.CoreSyn
import ETA.Types.Type
import ETA.Types.TyCon
import ETA.BasicTypes.Id
import ETA.BasicTypes.VarEnv
import ETA.BasicTypes.SrcLoc
import ETA.Prelude.PrimOp
import ETA.StgSyn.StgSyn
import ETA.BasicTypes.DataCon
import ETA.Utils.Panic
import ETA.Util
import ETA.Debug
import ETA.CodeGen.Utils
import ETA.CodeGen.Monad
import ETA.CodeGen.Name
import ETA.CodeGen.Layout
import ETA.CodeGen.Types
import ETA.CodeGen.Closure
import ETA.CodeGen.Env
import ETA.CodeGen.Rts
import ETA.CodeGen.Constr
import ETA.CodeGen.Prim
import ETA.CodeGen.ArgRep
import {-# SOURCE #-} ETA.CodeGen.Bind (cgBind)
import Codec.JVM

import Data.Monoid((<>))
import Data.Foldable(fold)
import Data.Maybe(mapMaybe,maybe)
import Control.Monad(when, forM_, unless)

cgExpr :: StgExpr -> CodeGen ()
cgExpr expr = do
  expr' <- preCgExpr expr
  doCgExpr expr' 

preCgExpr :: StgExpr -> CodeGen StgExpr
preCgExpr e@(StgTick _ _) = return e 
preCgExpr expr = do
  mbLn <- getInnermostLineNumber
  case mbLn of
    Just ln -> do
      traceCg (str $ "StgExpr emitting line number: " ++ show ln)
      emit $ emitLineNumber $ mkLineNumber ln
      resetLineNumbers
    Nothing -> return ()
  return expr
  
doCgExpr :: StgExpr -> CodeGen ()
doCgExpr (StgApp fun args) = traceCg (str "StgApp" <+> ppr fun <+> ppr args) >>
                           cgIdApp fun args
doCgExpr (StgOpApp (StgPrimOp SeqOp) [StgVarArg a, _] _) = cgIdApp a []
doCgExpr (StgOpApp op args ty) = traceCg (str "StgOpApp" <+> ppr op <+> ppr args <+> ppr ty) >>
                               cgOpApp op args ty
doCgExpr (StgConApp con args) = traceCg (str "StgConApp" <+> ppr con <+> ppr args) >>
                              cgConApp con args

doCgExpr (StgTick t e) = do
  traceCg (str "StgTick, tickish:" <+> ppr t)
  cgTick t
  cgExpr e
  
doCgExpr (StgLit lit) = emitReturn [mkLocDirect False $ cgLit lit]
doCgExpr (StgLet binds expr) = do
  forbidScoping (cgBind binds)
  cgExpr expr
doCgExpr (StgLetNoEscape _ _ binds expr) =
  cgLneBinds binds expr

doCgExpr (StgCase expr _ _ binder _ altType alts) =
  traceCg (str "StgCase" <+> ppr expr <+> ppr binder <+> ppr altType) >>
  cgCase expr binder altType alts
doCgExpr _ = unimplemented "cgExpr"

cgLneBinds :: StgBinding -> StgExpr -> CodeGen ()
cgLneBinds (StgNonRec binder rhs) expr = do
  -- TODO: Optimize this to calculate the smallest type that can hold the target
  label <- newLabel
  targetLoc <- newTemp False jint
  (info, genBindCode) <- cgLetNoEscapeRhsBody binder rhs label 1 targetLoc
  n' <- peekNextLocal
  bindCode <- genBindCode n'
  addBinding info
  exprCode <- forkLneBody $ cgExpr expr
  let (bindLabel, argLocs) = expectJust "cgLneBinds:StgNonRec"
                                        . maybeLetNoEscape $ info
  emit $ fold (map storeDefault argLocs)
      <> letNoEscapeCodeBlocks label targetLoc [(bindLabel, bindCode)] exprCode

cgLneBinds (StgRec pairs) expr = do
  label <- newLabel
  targetLoc <- newTemp False jint
  let lneInfos = snd $ foldr (\(a,b) (n,xs) -> (n - 1, (a,b,label,n,targetLoc):xs))
                             (length pairs, []) pairs

  result <- sequence $ map (\(a,b,c,d,e) -> cgLetNoEscapeRhsBody a b c d e) lneInfos
  n' <- peekNextLocal
  let (infos, genBindCodes) = unzip result
      (labels, argLocss) = unzip $ map (expectJust "cgLneBinds:StgRec"
                                       . maybeLetNoEscape) infos
  addBindings infos
  bindCodes <- sequence $ ($ n') <$> genBindCodes
  exprCode <- forkLneBody $ cgExpr expr
  emit $ fold (fold (map (map storeDefault) argLocss))
      <> letNoEscapeCodeBlocks label targetLoc (zip labels bindCodes) exprCode

cgLetNoEscapeRhsBody :: Id -> StgRhs -> Label -> Int -> CgLoc -> CodeGen (CgIdInfo, Int -> CodeGen Code)
cgLetNoEscapeRhsBody binder (StgRhsClosure _ _ _ _ _ args body) jumpLabel target targetLoc
  = cgLetNoEscapeClosure binder (nonVoidIds args) body jumpLabel target targetLoc
cgLetNoEscapeRhsBody binder (StgRhsCon _ con args) jumpLabel target targetLoc
  = cgLetNoEscapeClosure binder [] (StgConApp con args) jumpLabel target targetLoc

cgLetNoEscapeClosure
  :: Id -> [NonVoid Id] -> StgExpr -> Label -> Int -> CgLoc -> CodeGen (CgIdInfo, Int -> CodeGen Code)
cgLetNoEscapeClosure binder args body label target targetLoc = do
  argLocs <- mapM newIdLoc args
  let code n' = forkLneBody $ do
        bindArgs $ zip args argLocs
        setNextLocal n'
        cgExpr body
  return (lneIdInfo binder label target targetLoc argLocs, code)

letNoEscapeCodeBlocks :: Label -> CgLoc -> [(Int, Code)] -> Code -> Code
letNoEscapeCodeBlocks label targetLoc labelledCode body =
     storeDefault targetLoc
  <> startLabel label
  <> intSwitch (loadLoc targetLoc) labelledCode (Just body)

maybeLetNoEscape :: CgIdInfo -> Maybe (Int, [CgLoc])
maybeLetNoEscape CgIdInfo { cgLocation = LocLne _label target _targetLoc argLocs }
  = Just (target, argLocs)
maybeLetNoEscape _ = Nothing

cgIdApp :: Id -> [StgArg] -> CodeGen ()
cgIdApp funId [] | isVoidTy (idType funId) = emitReturn []
cgIdApp funId args = do
  dflags       <- getDynFlags
  funInfo      <- getCgIdInfo funId
  selfLoopInfo <- getSelfLoop
  scoped       <- getScopedBindings
  allowScoping <- getAllowScoping
  let cgFunId = cgId funInfo
      funName = idName cgFunId
      lfInfo = cgLambdaForm funInfo
      funLoc = cgLocation funInfo
      nArgs  = length args
      vArgs  = length $ filter (isVoidTy . stgArgType) args
      mScopeInfo
        | isEmptyVarEnv scoped || not allowScoping = Nothing
        | otherwise = fmap cgLocation $ lookupVarEnv scoped funId
  case getCallMethod dflags funName cgFunId lfInfo nArgs vArgs funLoc
                     selfLoopInfo mScopeInfo of
    ReturnIt -> traceCg (str "cgIdApp: ReturnIt") >>
                emitReturn [funLoc]
    EnterIt  -> traceCg (str "cgIdApp: EnterIt") >>
                emitEnter funLoc
    SlowCall -> do
      traceCg (str "cgIdApp: SlowCall")
      argFtCodes <- getRepFtCodes args
      withContinuation $ slowCall dflags funLoc argFtCodes
    DirectEntry entryCode arity -> do
      traceCg (str "cgIdApp: DirectEntry")
      argFtCodes <- getRepFtCodes args
      withContinuation $ directCall False entryCode arity argFtCodes
    JumpToIt label cgLocs mLne -> do
      traceCg (str "cgIdApp: JumpToIt")
      codes <- getNonVoidArgCodes args
      emit $ multiAssign cgLocs codes
          <> maybe mempty
               (\(target, targetLoc) ->
                  storeLoc targetLoc (iconst (locFt targetLoc) $ fromIntegral target))
               mLne
          <> goto label

emitEnter :: CgLoc -> CodeGen ()
emitEnter thunk = do
  sequel <- getSequel
  case sequel of
    Return ->
      emit $ enterMethod thunk <> greturn closureType
    AssignTo cgLocs -> do
      emit $ evaluateMethod thunk <> mkReturnEntry cgLocs

cgConApp :: DataCon -> [StgArg] -> CodeGen ()
cgConApp con args
  | isUnboxedTupleCon con = do
      repCodes <- getNonVoidArgRepCodes args
      emitReturn $ map mkRepLocDirect repCodes
  | otherwise = do
      (idInfo, genInitCode) <- buildDynCon (dataConWorkId con) con args []
      (initCode, _recIndexes, _dataFt) <- genInitCode
      emit initCode
      emitReturn [cgLocation idInfo]

cgCase :: StgExpr -> Id -> AltType -> [StgAlt] -> CodeGen ()
cgCase (StgOpApp (StgPrimOp op) args _) binder (AlgAlt tyCon) alts
  | isEnumerationTyCon tyCon = do
      dflags <- getDynFlags
      tagExpr <- doEnumPrimop op args
      let closureCode = snd $ tagToClosure dflags tyCon tagExpr
      loadCode <- if not $ isDeadBinder binder then do
          bindLoc <- newIdLoc (NonVoid binder)
          bindArg (NonVoid binder) bindLoc
          emitAssign bindLoc closureCode
          return $ loadLoc bindLoc
        else return closureCode
      (maybeDefault, branches) <- cgAlgAltRhss (NonVoid binder) alts
      emit $ intSwitch (getTagMethod loadCode) branches maybeDefault
  where doEnumPrimop :: PrimOp -> [StgArg] -> CodeGen Code
        doEnumPrimop TagToEnumOp [arg] =
          getArgLoadCode (NonVoid arg)
        doEnumPrimop primop args = do
          codes <- cgPrimOp primop args
          return $ head codes

cgCase (StgApp v []) _ (PrimAlt _) alts
  | isVoidRep (idPrimRep v)
  , [(DEFAULT, _, _, rhs)] <- alts
  = cgExpr rhs

cgCase (StgApp v []) binder altType@(PrimAlt _) alts
  | isUnLiftedType (idType v)
  || repsCompatible
  = do
      unless repsCompatible $
        panic "cgCase: reps do not match, perhaps a dodgy unsafeCoerce?"
      vInfo <- getCgIdInfo v
      binderLoc <- newIdLoc nvBinder
      emitAssign binderLoc (idInfoLoadCode vInfo)
      bindArgs [(nvBinder, binderLoc)]
      cgAlts nvBinder altType alts
  where repsCompatible = vRep == idPrimRep binder
        -- TODO: Allow integer conversions?
        nvBinder = NonVoid binder
        vRep = idPrimRep v

cgCase scrut@(StgApp v []) _ (PrimAlt _) _ = do
  cgLoc <- newIdLoc (NonVoid v)
  withSequel (AssignTo [cgLoc]) $ forbidScoping $ cgExpr scrut
  panic "cgCase: bad unsafeCoerce!"
  -- TODO: Generate infinite loop here?

cgCase (StgOpApp (StgPrimOp SeqOp) [StgVarArg a, _] _) binder altType alts
  = cgCase (StgApp a []) binder altType alts

cgCase scrut binder altType alts = do
  altLocs <- mapM newIdLoc retBinders
  -- Take into account uses for unboxed tuples
  -- Case-of-case expressions need special care
  -- Since there can be multiple bindings to return
  -- binder.
  when (isCaseOfCase scrut) $ do
    emit $ fold (map storeDefault altLocs)
  withSequel (AssignTo altLocs) $ forbidScoping $ cgExpr scrut
  bindArgs $ zip retBinders altLocs
  cgAlts (NonVoid binder) altType alts
  where retBinders = chooseReturnBinders binder altType alts
        isCaseOfCase = go
        go (StgLet _ e) = go e
        go (StgTick _ e) = go e
        go (StgCase _ _ _ _ _ _ _) = True
        go _ = False

chooseReturnBinders :: Id -> AltType -> [StgAlt] -> [NonVoid Id]
chooseReturnBinders binder (PrimAlt _) _ = nonVoidIds [binder]
chooseReturnBinders _ (UbxTupAlt _) [(_, ids, _, _)] = nonVoidIds ids
chooseReturnBinders binder (AlgAlt _) _ = nonVoidIds [binder]
chooseReturnBinders binder PolyAlt _ = nonVoidIds [binder]
chooseReturnBinders _ _ _ = panic "chooseReturnBinders"

cgAlts :: NonVoid Id -> AltType -> [StgAlt] -> CodeGen ()
cgAlts _ PolyAlt [(_, _, _, rhs)] = cgExpr rhs
cgAlts _ (UbxTupAlt _) [(_, _, _, rhs)] = cgExpr rhs
cgAlts binder (PrimAlt _) alts = do
  taggedBranches <- cgAltRhss binder alts
  binderLoc <- if null (nonVoidIds [unsafeStripNV binder]) then
                 return $ mkLocDirect False (jint, mempty)
               else
                 getCgLoc binder
  let (DEFAULT, deflt) = head taggedBranches
      taggedBranches' = [(lit, code) | (LitAlt lit, code) <- taggedBranches]
  emit $ litSwitch (locFt binderLoc) (loadLoc binderLoc) taggedBranches' deflt
cgAlts binder (AlgAlt _) alts = do
  (maybeDefault, branches) <- cgAlgAltRhss binder alts
  binderLoc <- getCgLoc binder
  emit $ intSwitch (getTagMethod $ loadLoc binderLoc) branches maybeDefault
cgAlts _ _ _ = panic "cgAlts"

cgAltRhss :: NonVoid Id -> [StgAlt] -> CodeGen [(AltCon, Code)]
cgAltRhss binder alts =
  forkAlts $ map cgAlt alts
  where cgAlt :: StgAlt -> (AltCon, CodeGen ())
        cgAlt (con, binders, uses, rhs) =
          ( con
          ,  bindConArgs con binder binders uses
          >> cgExpr rhs )

bindConArgs :: AltCon -> NonVoid Id -> [Id] -> [Bool] -> CodeGen ()
bindConArgs (DataAlt con) binder args uses
  | not (null args), or uses = do
    dflags <- getDynFlags
    let conClass = dataConClass dflags con
        dataFt   = obj conClass
    base <- getCgLoc binder
    emit $ loadLoc base
        <> gconv conType dataFt
    -- TODO: Take into account uses as well
    forM_ indexedFields $ \(i, (ft, (arg, use))) ->
      when use $ do
        let nvArg = NonVoid arg
        cgLoc <- newIdLoc nvArg
        emitAssign cgLoc $ dup dataFt
                        <> getfield (mkFieldRef conClass (constrField i) ft)
        bindArg nvArg cgLoc
    -- TODO: Remove this pop in a clever way
    emit $ pop dataFt
    where indexedFields = indexList . mapMaybe (\(mb, args) ->
                                                  case mb of
                                                    Just m -> Just (m, args)
                                                    Nothing -> Nothing)
                                    $ zip maybeFields (zip args uses)
          maybeFields = map repFieldType_maybe $ dataConRepArgTys con
bindConArgs _ _ _ _ = return ()

cgAlgAltRhss :: NonVoid Id -> [StgAlt] -> CodeGen (Maybe Code, [(Int, Code)])
cgAlgAltRhss binder alts = do
  taggedBranches <- cgAltRhss binder alts
  let (maybeDefault, branches) =
        case taggedBranches of
          ((DEFAULT, rhs) : _) -> (Just rhs, allBranches)
          {- INVARIANT: length alts > 0

             We select the *last* alternative since that will
             typically have a higher tag and will require more
             bytecode to perform the check if it's a simple
             case with 2 alternatives (the most frequent case). -}
          _                    -> (Just $ snd remainingBranch, remainingBranches)
      (remainingBranches, remainingBranch) = (init allBranches, last allBranches)
      allBranches = [ (getDataConTag con, code)
                    | (DataAlt con, code) <- taggedBranches ]
  return (maybeDefault, branches)

cgTick :: Tickish Id -> CodeGen ()
cgTick (SourceNote srcSpan _) = do
  let srcLoc = realSrcSpanStart srcSpan
  traceCg (str $ "StgTick , tickish: SourceNote, srcSpan: " ++ show srcSpan)
  addLineNumber $ srcLocLine srcLoc
  setSourceFileName $ fastStringText $ srcLocFile srcLoc
cgTick _ = return ()
