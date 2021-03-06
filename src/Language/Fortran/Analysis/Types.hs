{-# LANGUAGE ScopedTypeVariables #-}
module Language.Fortran.Analysis.Types ( analyseTypes, analyseTypesWithEnv, TypeEnv ) where

import Language.Fortran.AST

import Prelude hiding (lookup)
import Data.Map (findWithDefault, insert, empty, lookup, Map)
import qualified Data.Map as M
import Control.Monad.State.Strict
import Data.Generics.Uniplate.Data
import Data.Generics.Uniplate.Operations
import Data.Data
import Language.Fortran.Analysis

import Debug.Trace

--------------------------------------------------

-- | Mapping of names to type information.
type TypeEnv = M.Map Name IDType

--------------------------------------------------

-- Monad for type inference work
type Infer a = State InferState a
data InferState = InferState { environ :: TypeEnv, entryPoints :: M.Map Name (Name, Maybe Name) }
  deriving Show
type InferFunc t = t -> Infer ()

--------------------------------------------------

-- | Annotate AST nodes with type information and also return a type
-- environment mapping names to type information.
analyseTypes :: Data a => ProgramFile (Analysis a) -> (ProgramFile (Analysis a), TypeEnv)
analyseTypes = analyseTypesWithEnv M.empty

-- | Annotate AST nodes with type information and also return a type
-- environment mapping names to type information; provided with a
-- starting type environment.
analyseTypesWithEnv :: Data a => TypeEnv -> ProgramFile (Analysis a) -> (ProgramFile (Analysis a), TypeEnv)
analyseTypesWithEnv env pf = fmap environ . runInfer env $ do
  -- Gather information.
  mapM_ programUnit (allProgramUnits pf)
  mapM_ declarator (allDeclarators pf)
  mapM_ statement (allStatements pf)

  -- Gather types for known entry points.
  eps <- gets (M.toList . entryPoints)
  forM eps $ \ (eName, (fName, mRetName)) -> do
    mFType <- getRecordedType fName
    case mFType of
      Just (IDType fVType fCType) -> do
        recordMType fVType fCType eName
        -- FIXME: what about functions that return arrays?
        maybe (return ()) (error "Entry points with result variables unsupported" >> recordMType fVType Nothing) mRetName
      _                           -> return ()

  annotateTypes pf              -- Annotate AST nodes with their types.

type TransType f g a = (f (Analysis a) -> Infer (f (Analysis a))) -> g (Analysis a) -> Infer (g (Analysis a))
annotateTypes :: Data a => ProgramFile (Analysis a) -> Infer (ProgramFile (Analysis a))
annotateTypes pf = (transformBiM :: Data a => TransType Expression ProgramFile a) annotateExpression pf >>=
                   (transformBiM :: Data a => TransType ProgramUnit ProgramFile a) annotateProgramUnit

programUnit :: Data a => InferFunc (ProgramUnit (Analysis a))
programUnit pu@(PUFunction _ _ mRetType _ _ _ mRetVar blocks _)
  | Named n <- puName pu   = do
    -- record some type information that we can glean
    recordCType CTFunction n
    case (mRetType, mRetVar) of
      (Just (TypeSpec _ _ baseType _), Just v) -> recordBaseType baseType n >> recordBaseType baseType (varName v)
      (Just (TypeSpec _ _ baseType _), _)      -> recordBaseType baseType n
      _                                        -> return ()
    -- record entry points for later annotation
    forM_ blocks $ \ block ->
      sequence_ [ recordEntryPoint n (varName v) (fmap varName mRetVar) | (StEntry _ _ v _ mRetVar) <- allStatements block ]
programUnit pu@(PUSubroutine _ _ _ _ _ blocks _) | Named n <- puName pu = do
  -- record the fact that this is a subroutine
  recordCType CTSubroutine n
  -- record entry points for later annotation
  forM_ blocks $ \ block ->
    sequence_ [ recordEntryPoint n (varName v) Nothing | (StEntry _ _ v _ _) <- allStatements block ]
programUnit _                                           = return ()

declarator :: Data a => InferFunc (Declarator (Analysis a))
declarator (DeclArray _ _ v _ _ _) = recordCType CTArray (varName v)
declarator _                       = return ()

statement :: Data a => InferFunc (Statement (Analysis a))
-- maybe FIXME: should Kind Selectors be part of types?
statement (StDeclaration _ _ (TypeSpec _ _ baseType _) mAttrAList declAList)
  | mAttrs  <- maybe [] aStrip mAttrAList
  , isArray <- any isAttrDimension mAttrs
  , isParam <- any isAttrParameter mAttrs
  , decls   <- aStrip declAList = do
    env <- gets environ
    forM_ decls $ \ decl -> case decl of
      DeclArray _ _ v _ _ _         -> recordType baseType CTArray (varName v)
      DeclVariable _ _ v (Just _) _ -> recordType baseType CTVariable (varName v)
      DeclVariable _ _ v Nothing _  -> recordType baseType cType n
        where
          n = varName v
          cType | isArray                                     = CTArray
                | isParam                                     = CTParameter
                | Just (IDType _ (Just ct)) <- M.lookup n env = ct
                | otherwise                                   = CTVariable

statement (StExpressionAssign _ _ (ExpSubscript _ _ v ixAList) _)
  --  | any (not . isIxSingle) (aStrip ixAList) = recordCType CTArray (varName v)  -- it's an array (or a string?) FIXME
  | all isIxSingle (aStrip ixAList) = do
    let n = varName v
    mIDType <- getRecordedType n
    case mIDType of
      Just (IDType mBT (Just CTArray)) -> return ()                -- do nothing, it's already known to be an array
      _                                -> recordCType CTFunction n -- assume it's a function statement

-- FIXME: if StFunctions can only be identified after types analysis
-- is complete and disambiguation is performed, then how do we get
-- them in the first place? (iterate until fixed point?)
statement (StFunction _ _ v _ _) = recordCType CTFunction (varName v)

statement (StDimension _ _ declAList) = do
  let decls = aStrip declAList
  forM_ decls $ \ decl -> case decl of
    DeclArray _ _ v _ _ _ -> recordCType CTArray (varName v)
    _                     -> return ()

statement _ = return ()

annotateExpression :: Data a => Expression (Analysis a) -> Infer (Expression (Analysis a))
annotateExpression e@(ExpValue _ _ (ValVariable _)) = maybe e (flip setIDType e) `fmap` getRecordedType (varName e)
annotateExpression e                                = return e

annotateProgramUnit :: Data a => ProgramUnit (Analysis a) -> Infer (ProgramUnit (Analysis a))
annotateProgramUnit pu | Named n <- puName pu = maybe pu (flip setIDType pu) `fmap` getRecordedType n
annotateProgramUnit pu                        = return pu

--------------------------------------------------
-- Monadic helper combinators.

inferState0 = InferState { environ = M.empty, entryPoints = M.empty }
runInfer env = flip runState (inferState0 { environ = env })

-- Record the type of the given name.
recordType :: BaseType -> ConstructType -> Name -> Infer ()
recordType bt ct n = modify $ \ s -> s { environ = insert n (IDType (Just bt) (Just ct)) (environ s) }

-- Record the type (maybe) of the given name.
recordMType :: Maybe BaseType -> Maybe ConstructType -> Name -> Infer ()
recordMType bt ct n = modify $ \ s -> s { environ = insert n (IDType (bt) (ct)) (environ s) }

-- Record the CType of the given name.
recordCType :: ConstructType -> Name -> Infer ()
recordCType ct n = modify $ \ s -> s { environ = M.alter changeFunc n (environ s) }
  where changeFunc mIDType = Just (IDType (mIDType >>= idVType) (Just ct))

-- Record the BaseType of the given name.
recordBaseType :: BaseType -> Name -> Infer ()
recordBaseType bt n = modify $ \ s -> s { environ = M.alter changeFunc n (environ s) }
  where changeFunc mIDType = Just (IDType (Just bt) (mIDType >>= idCType))

recordEntryPoint :: Name -> Name -> Maybe Name -> Infer ()
recordEntryPoint fn en mRetName = modify $ \ s -> s { entryPoints = M.insert en (fn, mRetName) (entryPoints s) }

getRecordedType :: Name -> Infer (Maybe IDType)
getRecordedType n = gets (M.lookup n . environ)

-- Set the idType annotation
setIDType :: Annotated f => IDType -> f (Analysis a) -> f (Analysis a)
setIDType ty x
  | a@(Analysis {}) <- getAnnotation x = setAnnotation (a { idType = Just ty }) x
  | otherwise                          = x

-- Get the idType annotation
getIDType :: (Annotated f, Data a) => f (Analysis a) -> Maybe IDType
getIDType x = idType (getAnnotation x)

-- Set the CType part of idType annotation
setCType :: (Annotated f, Data a) => ConstructType -> f (Analysis a) -> f (Analysis a)
setCType ct x
  | a@(Analysis { idType = Nothing }) <- getAnnotation x = setAnnotation (a { idType = Just (IDType Nothing (Just ct)) }) x
  | a@(Analysis { idType = Just it }) <- getAnnotation x = setAnnotation (a { idType = Just (it { idCType = Just ct }) }) x

type UniFunc f g a = f (Analysis a) -> [g (Analysis a)]

allProgramUnits :: Data a => UniFunc ProgramFile ProgramUnit a
allProgramUnits = universeBi

allDeclarators :: Data a => UniFunc ProgramFile Declarator a
allDeclarators = universeBi

allStatements :: (Data a, Data (f (Analysis a))) => UniFunc f Statement a
allStatements = universeBi

isAttrDimension (AttrDimension {}) = True
isAttrDimension _                  = False

isAttrParameter (AttrParameter {}) = True
isAttrParameter _                  = False

isIxSingle (IxSingle {}) = True
isIxSingle _             = False

--------------------------------------------------

-- Local variables:
-- mode: haskell
-- haskell-program-name: "cabal repl"
-- End:
