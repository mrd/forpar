{-# LANGUAGE ScopedTypeVariables, PatternGuards #-}

-- |
-- Analyse variables/function names and produce unique names that can
-- be used to replace the original names while maintaining program
-- equivalence (a.k.a. alpha-conversion). The advantage of the unique
-- names is that scoping issues can be ignored when doing further
-- analysis.

module Language.Fortran.Analysis.Renaming
  ( analyseRenames, rename, extractNameMap, renameAndStrip, unrename, underRenaming, NameMap )
where

import Debug.Trace

import Language.Fortran.AST hiding (fromList)
import Language.Fortran.Util.Position
import Language.Fortran.Analysis
import Language.Fortran.Analysis.Types

import Prelude hiding (lookup)
import Data.Maybe (maybe, fromMaybe)
import qualified Data.List as L
import Data.Map (findWithDefault, insert, union, empty, lookup, member, Map, fromList)
import qualified Data.Map as M
import Control.Monad.State.Lazy
import Control.Monad
import Data.Generics.Uniplate.Data
import Data.Generics.Uniplate.Operations
import Data.Data
import Data.Tuple

--------------------------------------------------

type NameMap       = Map String String

type Renamer a     = State RenameState a -- the monad.
data RenameState   = RenameState { scopeStack :: [String]
                                 , uniqNums   :: [Int]
                                 , environ    :: [ModEnv]
                                 , nameMap    :: NameMap
                                 , moduleMap  :: ModuleMap }
  deriving (Show, Eq)
type RenamerFunc t = t -> Renamer t

--------------------------------------------------
-- Main interface functions.

-- | Annotate unique names for variable and function declarations and uses.
analyseRenames :: Data a => ProgramFile (Analysis a) -> ProgramFile (Analysis a)
analyseRenames (ProgramFile cm_pus bs) = ProgramFile cm_pus' bs
  where
    cm_pus'        = zip (map fst cm_pus) pus'
    (Just pus', _) = runRenamer (skimProgramUnits pus >> renameSubPUs (Just pus)) renameState0
    pus            = map snd cm_pus

-- | Take the unique name annotations and substitute them into the actual AST.
rename :: Data a => ProgramFile (Analysis a) -> (NameMap, ProgramFile (Analysis a))
rename pf = (extractNameMap pf, trPU fPU (trE fE pf))
  where
    trE :: Data a => (Expression a -> Expression a) -> ProgramFile a -> ProgramFile a
    trE = transformBi
    fE :: Data a => Expression (Analysis a) -> Expression (Analysis a)
    fE (ExpValue a s (ValVariable v)) = ExpValue a s . ValVariable $ fromMaybe v (uniqueName a)
    fE x                 = x

    trPU :: Data a => (ProgramUnit a -> ProgramUnit a) -> ProgramFile a -> ProgramFile a
    trPU = transformBi
    fPU :: Data a => ProgramUnit (Analysis a) -> ProgramUnit (Analysis a)
    fPU (PUFunction a s ty r n args res b subs) =
      PUFunction a s ty r (fromMaybe n (uniqueName a)) args res b subs
    fPU (PUSubroutine a s r n args b subs) =
      PUSubroutine a s r (fromMaybe n (uniqueName a)) args b subs
    fPU x                            = x

-- | Create a map of unique name => original name for each variable
-- and function in the program.
extractNameMap :: Data a => ProgramFile (Analysis a) -> NameMap
extractNameMap pf = eMap `union` puMap
  where
    eMap  = fromList [ (un, n) | ExpValue (Analysis { uniqueName = Just un }) _ (ValVariable n) <- uniE pf ]
    puMap = fromList [ (un, n) | pu <- uniPU pf, Named un <- [puName pu], Named n <- [getName pu], n /= un ]
    uniE :: Data a => ProgramFile a -> [Expression a]
    uniE = universeBi
    uniPU :: Data a => ProgramFile a -> [ProgramUnit a]
    uniPU = universeBi

-- | Perform the rename, stripAnalysis, and extractNameMap functions.
renameAndStrip :: Data a => ProgramFile (Analysis a) -> (NameMap, ProgramFile a)
renameAndStrip pf = fmap stripAnalysis (rename pf)

-- | Take a renamed program and its corresponding NameMap, and undo the renames.
unrename :: Data a => (NameMap, ProgramFile a) -> ProgramFile a
unrename (nm, pf) = trPU fPU . trV fV $ pf
  where
    trV :: Data a => (Value a -> Value a) -> ProgramFile a -> ProgramFile a
    trV = transformBi
    fV :: Data a => Value a -> Value a
    fV (ValVariable v) = ValVariable $ fromMaybe v (v `lookup` nm)
    fV x                 = x

    trPU :: Data a => (ProgramUnit a -> ProgramUnit a) -> ProgramFile a -> ProgramFile a
    trPU = transformBi
    fPU :: Data a => ProgramUnit a -> ProgramUnit a
    fPU (PUFunction a s ty r n args res b subs) = PUFunction a s ty r (fromMaybe n (n `lookup` nm)) args res b subs
    fPU x               = x

-- | Run a function with the program file placed under renaming
-- analysis, then undo the renaming in the result of the function.
underRenaming :: (Data a, Data b) => (ProgramFile (Analysis a) -> b) -> ProgramFile a -> b
underRenaming f pf = tryUnrename `descendBi` f pf'
  where
    (renameMap, pf') = rename . analyseRenames . initAnalysis $ pf
    tryUnrename n = n `fromMaybe` lookup n renameMap

--------------------------------------------------
-- Renaming transformations for pieces of the AST. Uses a language of
-- monadic combinators defined below.

programUnit :: Data a => RenamerFunc (ProgramUnit (Analysis a))
programUnit (PUModule a s name blocks m_contains) = do
  env0        <- initialEnv blocks
  pushScope name env0
  blocks'     <- mapM renameDeclDecls blocks -- handle declarations
  m_contains' <- renameSubPUs m_contains     -- handle contained program units
  env         <- getEnv
  addModEnv name env                         -- save the module environment
  let a'      = a { moduleEnv = Just env }   -- also annotate it on the module
  popScope
  return (PUModule a' s name blocks' m_contains')

programUnit (PUFunction a s ty rec name args res blocks m_contains) = do
  Just name'  <- getFromEnv name                  -- get renamed function name
  blocks1     <- mapM renameEntryPointDecl blocks -- rename any entry points
  env0        <- initialEnv blocks1
  pushScope name env0
  blocks2     <- mapM renameEntryPointResultDecl blocks1 -- rename the result
  res'        <- mapM renameGenericDecls res             -- variable(s) if needed
  args'       <- mapM renameGenericDecls args -- rename arguments
  blocks3     <- mapM renameDeclDecls blocks2 -- handle declarations
  m_contains' <- renameSubPUs m_contains      -- handle contained program units
  blocks4     <- mapM renameBlock blocks3     -- process all uses of variables
  popScope
  return . setUniqueName name' $ PUFunction a s ty rec name args' res' blocks4 m_contains'

programUnit (PUSubroutine a s rec name args blocks m_contains) = do
  Just name'  <- getFromEnv name                  -- get renamed subroutine name
  blocks1     <- mapM renameEntryPointDecl blocks -- rename any entry points
  env0        <- initialEnv blocks1
  pushScope name env0
  args'       <- mapM renameGenericDecls args -- rename arguments
  blocks2     <- mapM renameDeclDecls blocks1 -- handle declarations
  m_contains' <- renameSubPUs m_contains      -- handle contained program units
  blocks3     <- mapM renameBlock blocks2     -- process all uses of variables
  popScope
  return . setUniqueName name' $ PUSubroutine a s rec name args' blocks3 m_contains'

programUnit (PUMain a s n blocks m_contains) = do
  env0        <- initialEnv blocks
  pushScope (fromMaybe "_main" n) env0        -- assume default program name is "_main"
  blocks'     <- mapM renameDeclDecls blocks  -- handle declarations
  m_contains' <- renameSubPUs m_contains      -- handle contained program units
  blocks''    <- mapM renameBlock blocks'     -- process all uses of variables
  popScope
  return (PUMain a s n blocks'' m_contains')

programUnit pu = return pu

declarator :: Data a => RenamerFunc (Declarator (Analysis a))
declarator = renameGenericDecls

expression :: Data a => RenamerFunc (Expression (Analysis a))
expression = renameExp

--------------------------------------------------
-- Helper monadic combinators for composing into renaming
-- transformations.

-- Initial monad state.
renameState0 = RenameState { scopeStack = []
                           , uniqNums = [1..]
                           , environ = [empty]
                           , nameMap = empty
                           , moduleMap = empty }
-- Run the monad.
runRenamer m = runState m

-- Get a freshly generated number.
getUniqNum :: Renamer Int
getUniqNum = do
  uniqNum <- gets (head . uniqNums)
  modify $ \ s -> s { uniqNums = drop 1 (uniqNums s) }
  return uniqNum

-- Concat a scope, a variable, and a freshly generated number together
-- to generate a "unique name".
uniquify :: String -> String -> Renamer String
uniquify scope var = do
  n <- getUniqNum
  return $ scope ++ "_" ++ var ++ show n

isModule (PUModule {}) = True; isModule _             = False

isUseStatement (BlStatement _ _ _ (StUse _ _ (ExpValue _ _ (ValVariable _)) _)) = True
isUseStatement _                                                                = False

isUseID (UseID {}) = True; isUseID _ = False

-- Generate an initial environment for a scope based upon any Use
-- statements in the blocks.
initialEnv :: Data a => [Block (Analysis a)] -> Renamer ModEnv
initialEnv blocks = do
  -- FIXME: add "use renaming" declarations (requires change in
  -- NameMap because it would be possible for the same program object
  -- to have two different names used by different parts of the
  -- program).
  let uses = takeWhile isUseStatement blocks
  fmap M.unions . forM uses $ \ use -> case use of
    (BlStatement _ _ _ (StUse _ _ (ExpValue _ _ (ValVariable m)) Nothing)) -> do
      mMap <- gets moduleMap
      return $ fromMaybe empty (Named m `lookup` mMap)
    (BlStatement _ _ _ (StUse _ _ (ExpValue _ _ (ValVariable m)) (Just onlyAList)))
      | only <- aStrip onlyAList, all isUseID only -> do
      mMap <- gets moduleMap
      let env = fromMaybe empty (Named m `lookup` mMap)
      let onlyNames = map (\ (UseID _ _ v) -> varName v) only
      -- filter for the the mod remappings mentioned in the list, only
      return $ M.filterWithKey (\ k _ -> k `elem` onlyNames) env
    _ -> trace "WARNING: USE renaming not supported (yet)" $ return empty

-- Get the current scope name.
getScope :: Renamer String
getScope = gets (head . scopeStack)

-- Get the concatenated scopes.
getScopes :: Renamer String
getScopes = gets (L.intercalate "_" . reverse . scopeStack)

-- Push a scope onto the lexical stack.
pushScope :: String -> ModEnv -> Renamer ()
pushScope name env0 = modify $ \ s -> s { scopeStack = name : scopeStack s
                                        , environ    = env0 : environ s }

-- Pop a scope from the lexical stack.
popScope :: Renamer ()
popScope = modify $ \ s -> s { scopeStack = drop 1 $ scopeStack s
                             , environ    = drop 1 $ environ s }


-- Add an environment for a module to the table that keeps track of
-- modules.
addModEnv :: String -> ModEnv -> Renamer ()
addModEnv name env = modify $ \ s -> s { moduleMap = insert (Named name) env (moduleMap s) }

-- Get the current environment.
getEnv :: Renamer ModEnv
getEnv = gets (head . environ)

-- Gets an environment composed of all nested environments.
getEnvs :: Renamer ModEnv
getEnvs = M.unionsWith (curry fst) `fmap` gets environ

-- Get a mapping from the current environment if it exists.
getFromEnv :: String -> Renamer (Maybe String)
getFromEnv v = ((fst `fmap`) . lookup v) `fmap` getEnv

-- Get a mapping from the combined nested environment, if it exists.
getFromEnvs :: String -> Renamer (Maybe String)
getFromEnvs v = ((fst `fmap`) . lookup v) `fmap` getEnvs

-- Get a mapping, plus name type, from the combined nested
-- environment, if it exists.
getFromEnvsWithType :: String -> Renamer (Maybe (String, NameType))
getFromEnvsWithType v = lookup v `fmap` getEnvs

-- To conform with Fortran specification about subprogram names:
-- search for subprogram names in all containing scopes first, then
-- search for variables in the current scope.
getFromEnvsIfSubprogram :: String -> Renamer (Maybe String)
getFromEnvsIfSubprogram v = do
  mEntry <- getFromEnvsWithType v
  case mEntry of
    Just (v', NTSubprogram) -> return $ Just v'
    Just (_, NTVariable)    -> getFromEnv v
    _                       -> return $ Nothing

-- Add a renaming mapping to the environment.
addToEnv :: String -> String -> NameType -> Renamer ()
addToEnv v v' nt = modify $ \ s -> s { environ = insert v (v', nt) (head (environ s)) : drop 1 (environ s) }

-- Add a unique renaming to the environment.
addUnique :: String -> NameType -> Renamer String
addUnique v nt = do
  v' <- flip uniquify v =<< getScopes
  addToEnv v v' nt
  return v'

addUnique_ :: String -> NameType -> Renamer ()
addUnique_ v nt = addUnique v nt >> return ()

-- This function will be invoked by occurrences of
-- declarations. First, search to see if v is a subprogram name that
-- exists in any containing scope; if so, use it. Then, search to see
-- if v is a variable in the current scope; if so, use it. Otherwise,
-- assume that it is either a new name or that it is shadowing a
-- variable, so generate a new unique name and add it to the current
-- environment.
maybeAddUnique :: String -> NameType -> Renamer String
maybeAddUnique v nt = maybe (addUnique v nt) return =<< getFromEnvsIfSubprogram v

-- If uniqueName property is not set, then set it.
setUniqueName :: (Annotated f, Data a) => String -> f (Analysis a) -> f (Analysis a)
setUniqueName un x
  | a@(Analysis { uniqueName = Nothing }) <- getAnnotation x = setAnnotation (a { uniqueName = Just un }) x
  | otherwise                                              = x

-- Work recursively into sub-program units.
renameSubPUs :: Data a => RenamerFunc (Maybe [ProgramUnit (Analysis a)])
renameSubPUs Nothing = return Nothing
renameSubPUs (Just pus) = skimProgramUnits pus >> Just `fmap` (mapM programUnit pus)

-- Go through all program units at the same level and add their names
-- to the environment.
skimProgramUnits :: Data a => [ProgramUnit (Analysis a)] -> Renamer ()
skimProgramUnits pus = forM_ pus $ \ pu -> case pu of
  PUModule _ _ name _ _           -> addToEnv name name NTSubprogram
  PUFunction _ _ _ _ name _ _ _ _ -> addUnique_ name NTSubprogram
  PUSubroutine _ _ _ name _ _ _   -> addUnique_ name NTSubprogram
  PUMain _ _ (Just name) _ _      -> addToEnv name name NTSubprogram
  _                               -> return ()

----------
-- rename*Decl[s] functions: possibly generate new unique mappings:

-- Rename any ExpValue variables within a given value by assuming that
-- they are declarations and that they possibly require the creation
-- of new unique mappings.
renameGenericDecls :: (Data a, Data (f (Analysis a))) => RenamerFunc (f (Analysis a))
renameGenericDecls = trans renameExpDecl
  where
    trans :: (Data a, Data (f (Analysis a))) => RenamerFunc (Expression (Analysis a)) -> RenamerFunc (f (Analysis a))
    trans = transformBiM

-- Rename an ExpValue variable assuming that it is to be treated as a
-- declaration that possibly requires the creation of a new unique
-- mapping.
renameExpDecl :: Data a => RenamerFunc (Expression (Analysis a))
renameExpDecl e@(ExpValue _ _ (ValVariable v)) = flip setUniqueName e `fmap` maybeAddUnique v NTVariable
renameExpDecl e                                = return e

-- Find all declarators within a value and then dive within those
-- declarators to rename any ExpValue variables, assuming they might
-- possibly need the creation of new unique mappings.
renameDeclDecls :: (Data a, Data (f (Analysis a))) => RenamerFunc (f (Analysis a))
renameDeclDecls = trans declarator
  where
    trans :: (Data a, Data (f (Analysis a))) => RenamerFunc (Declarator (Analysis a)) -> RenamerFunc (f (Analysis a))
    trans = transformBiM

-- Find all entry points within a block and then rename them, assuming
-- they might possibly need the creation of new unique mappings.
renameEntryPointDecl :: Data a => RenamerFunc (Block (Analysis a))
renameEntryPointDecl (BlStatement a s l (StEntry a' s' v mArgs mRes)) = do
  v' <- renameExpDecl v
  return (BlStatement a s l (StEntry a' s' v' mArgs mRes))
renameEntryPointDecl b = return b

-- Find all entry points within a block and then rename their result
-- variables, if applicable, assuming they might possibly need the
-- creation of new unique mappings.
renameEntryPointResultDecl :: Data a => RenamerFunc (Block (Analysis a))
renameEntryPointResultDecl (BlStatement a s l (StEntry a' s' v mArgs (Just res))) = do
  res' <- renameExpDecl res
  return (BlStatement a s l (StEntry a' s' v mArgs (Just res')))
renameEntryPointResultDecl b = return b

----------
-- Do not generate new unique mappings, instead look in outer scopes:

-- Rename an ExpValue variable, assuming that it is to be treated as a
-- reference to a previous declaration, possibly in an outer scope.
renameExp :: Data a => RenamerFunc (Expression (Analysis a))
renameExp e@(ExpValue _ _ (ValVariable v)) = maybe e (flip setUniqueName e) `fmap` getFromEnvs v
renameExp e                                = return e

-- Rename all ExpValue variables found within the block, assuming that
-- they are to be treated as references to previous declarations,
-- possibly in an outer scope.
renameBlock :: Data a => RenamerFunc (Block (Analysis a))
renameBlock = trans expression
  where
    trans :: Data a => RenamerFunc (Expression a) -> RenamerFunc (Block a)
    trans = transformBiM -- search all expressions, bottom-up

--------------------------------------------------

-- Local variables:
-- mode: haskell
-- haskell-program-name: "cabal repl"
-- End:
