module Language.Fortran.Transformation.Grouping ( groupIf
                                                , groupDo
                                                , groupLabeledDo
                                                , groupCase
                                                ) where

import Language.Fortran.AST
import Language.Fortran.Analysis
import Language.Fortran.Transformation.TransformMonad

import Debug.Trace

genericGroup :: ([ Block (Analysis a) ] -> [ Block (Analysis a) ]) -> Transform a ()
genericGroup groupingFunction =
    modifyProgramFile $
      \(ProgramFile mi pus e) ->
        ProgramFile mi (zip (map fst pus) . map (go . snd) $ pus) e
  where
    go pu =
      case pu of
        PUMain a s n bs subPUs ->
          PUMain a s n (groupingFunction bs) (map go <$> subPUs)
        PUModule a s n bs subPUs ->
          PUModule a s n (groupingFunction bs) (map go <$> subPUs)
        PUSubroutine a s r n as bs subPUs ->
          PUSubroutine a s r n as (groupingFunction bs) (map go <$> subPUs)
        PUFunction a s r rec n as res bs subPUs ->
          PUFunction a s r rec n as res (groupingFunction bs) (map go <$> subPUs)
        bd@PUBlockData{} -> bd -- Block data cannot have any if statements.

--------------------------------------------------------------------------------
-- Grouping if statement blocks into if blocks in entire parse tree
--------------------------------------------------------------------------------

groupIf :: Transform a ()
groupIf = genericGroup groupIf'

-- Actual grouping is done here.
-- 1. Case: head is a statement block with an IF statement:
-- 1.1  Group everything to the right of the statement.
-- 1.2  Prepend the head
-- 1.3  Decompose into if components (blocks and condition pairs).
-- 1.4  Using original if statement and decomposition artefacts synthesise a
--        structured if block.
-- 1.5  Prepend the block to the left over artefacts, which have already been
--        grouped in 1.1
-- 2. Case: head is a statement block contianing any other statement:
-- 2.1  Group everything to the right and prepend the head.
groupIf' :: [ Block (Analysis a) ] -> [ Block (Analysis a) ]
groupIf' [] = []
groupIf' (b:bs) = b' : bs'
  where
    (b', bs') = case b of
      BlStatement a s label st
        | StIfThen _ _ mName _ <- st -> -- If statement
          let ( conditions, blocks, leftOverBlocks, endLabel ) =
                decomposeIf (b:groupedBlocks)
          in ( BlIf a (getTransSpan s blocks) label mName conditions blocks endLabel
             , leftOverBlocks)
      b | containsGroups b -> -- Map to subblocks for groupable blocks
        ( applyGroupingToSubblocks groupIf' b, groupedBlocks )
      _ -> ( b, groupedBlocks )
    groupedBlocks = groupIf' bs -- Assume everything to the right is grouped.

-- A program has the following structure:
--
--[ block... ]
-- if <condition> then
--   [ block... ]
-- else if <condition>
--   [ block... ]
-- else
--   [ block... ]
-- end if
-- [ block... ]
--
-- This function must only receive a list of blocks that start with if.
--
-- Internally it uses a more permissive breaking function that processes
-- individual (if-then, block), (else-if, block), and (else, block) pairs.
--
-- In that case it decomposes the block into list of (maybe) conditions and
-- blocks that those conditions correspond to. Additionally, it returns
-- whatever is after the if block.
decomposeIf :: [ Block (Analysis a) ]
            -> ( [ Maybe (Expression (Analysis a)) ],
                 [ [ Block (Analysis a) ] ],
                 [ Block (Analysis a) ],
                 Maybe (Expression (Analysis a)) )
decomposeIf blocks@(BlStatement _ _ _ (StIfThen _ _ mTargetName _):rest) =
    decomposeIf' blocks
  where
    decomposeIf' (BlStatement _ _ mLabel st:rest) =
      case st of
        StIfThen _ _ _ condition -> go (Just condition) rest
        StElsif _ _ _ condition -> go (Just condition) rest
        StElse{} -> go Nothing rest
        StEndif _ _ mName
          | mName == mTargetName -> ([], [], rest, mLabel)
          | otherwise -> error $ "If statement name does not match that of " ++
                                   "the corresponding end if statement."
        _ -> error "Block with non-if related statement. Should never occur."
    go maybeCondition blocks =
      let (nonConditionBlocks, rest') = collectNonConditionalBlocks blocks
          (conditions, listOfBlocks, rest'', endLabel) = decomposeIf' rest'
      in ( maybeCondition : conditions
         , nonConditionBlocks : listOfBlocks
         , rest''
         , endLabel )

-- This compiles the executable blocks under various if conditions.
collectNonConditionalBlocks :: [ Block (Analysis a) ] -> ([ Block (Analysis a) ], [ Block (Analysis a) ])
collectNonConditionalBlocks blocks =
  case blocks of
    BlStatement _ _ _ StElsif{}:_ -> ([], blocks)
    BlStatement _ _ _ StElse{}:_ -> ([], blocks)
    -- Here end block is included within the blocks unlike the other
    -- conditional directives. The reason is that this block can be
    -- a branch target if it is labeled according to the specification, hence
    -- it is presence in the parse tree is meaningful.
    b@(BlStatement _ _ _ StEndif{}):_ -> ([], blocks)
    -- Catch all case for all non-if related blocks.
    b:bs -> let (bs', rest) = collectNonConditionalBlocks bs in (b : bs', rest)
    -- In this case the structured if block is malformed and the file ends
    -- prematurely.
    _ -> error "Premature file ending while parsing structured if block."

--------------------------------------------------------------------------------
-- Grouping new do statement blocks into do blocks in entire parse tree
--------------------------------------------------------------------------------

groupDo :: Transform a ()
groupDo = genericGroup groupDo'

groupDo' :: [ Block (Analysis a) ] -> [ Block (Analysis a) ]
groupDo' [ ] = [ ]
groupDo' blocks@(b:bs) = b' : bs'
  where
    (b', bs') = case b of
      BlStatement a s label st
        -- Do While statement
        | StDoWhile _ _ mTarget _ condition <- st ->
          let ( blocks, leftOverBlocks, endLabel ) =
                collectNonDoBlocks groupedBlocks mTarget
          in ( BlDoWhile a (getTransSpan s blocks) label mTarget condition blocks endLabel
             , leftOverBlocks)
        -- Vanilla do statement
        | StDo _ _ mName Nothing doSpec <- st ->
          let ( blocks, leftOverBlocks, endLabel ) =
                collectNonDoBlocks groupedBlocks mName
          in ( BlDo a (getTransSpan s blocks) label mName Nothing doSpec blocks endLabel
             , leftOverBlocks)
      b | containsGroups b ->
        ( applyGroupingToSubblocks groupDo' b, groupedBlocks )
      _ -> ( b, groupedBlocks )
    groupedBlocks = groupDo' bs -- Assume everything to the right is grouped.

collectNonDoBlocks :: [ Block (Analysis a) ] -> Maybe String
                   -> ( [ Block (Analysis a)]
                      , [ Block (Analysis a) ]
                      , Maybe (Expression (Analysis a)) )
collectNonDoBlocks blocks mNameTarget =
  case blocks of
    b@(BlStatement _ _ mLabel (StEnddo _ _ mName)):rest
      | mName == mNameTarget -> ([ ], rest, mLabel)
      | otherwise ->
          error "Do block name does not match that of the end statement."
    b:bs ->
      let (bs', rest, mLabel) = collectNonDoBlocks bs mNameTarget
      in (b : bs', rest, mLabel)
    _ -> error "Premature file ending while parsing structured do block."

--------------------------------------------------------------------------------
-- Grouping labeled do statement blocks into do blocks in entire parse tree
--------------------------------------------------------------------------------

groupLabeledDo :: Transform a ()
groupLabeledDo = genericGroup groupLabeledDo'

groupLabeledDo' :: [ Block (Analysis a) ] -> [ Block (Analysis a) ]
groupLabeledDo' [ ] = [ ]
groupLabeledDo' blos@(b:bs) = b' : bs'
  where
    (b', bs') = case b of
      BlStatement a s label
        (StDo _ _ mn tl@Just{} doSpec) ->
          let ( blocks, leftOverBlocks ) =
                collectNonLabeledDoBlocks tl groupedBlocks
              lastLabel = getLastLabel $ last blocks
          in ( BlDo a (getTransSpan s blocks) label mn tl doSpec blocks lastLabel
             , leftOverBlocks )
      b | containsGroups b ->
        ( applyGroupingToSubblocks groupLabeledDo' b, groupedBlocks )
      _ -> (b, groupedBlocks)

    -- Assume everything to the right is grouped.
    groupedBlocks = groupLabeledDo' bs


collectNonLabeledDoBlocks :: Maybe (Expression (Analysis a)) -> [ Block (Analysis a) ]
                          -> ([ Block (Analysis a) ], [ Block (Analysis a) ])
collectNonLabeledDoBlocks targetLabel blocks =
  case blocks of
    -- Didn't find a statement with matching label; don't group
    [] -> error "Malformed labeled DO group."

    b:bs
      | compLabel (getLastLabel b) targetLabel -> ([ b ], bs)
      | otherwise ->
          let (bs', rest) = collectNonLabeledDoBlocks targetLabel bs
          in (b : bs', rest)

compLabel :: Maybe (Expression a) -> Maybe (Expression a) -> Bool
compLabel (Just (ExpValue _ _ (ValInteger l1)))
          (Just (ExpValue _ _ (ValInteger l2))) = l1 == l2
compLabel _ _ = False

--------------------------------------------------------------------------------
-- Grouping case statements
--------------------------------------------------------------------------------

groupCase :: Transform a ()
groupCase = genericGroup groupCase'

groupCase' :: [ Block (Analysis a) ] -> [ Block (Analysis a) ]
groupCase' [] = []
groupCase' (b:bs) = b' : bs'
  where
    (b', bs') = case b of
      BlStatement a s label st
        | StSelectCase _ _ mName scrutinee <- st ->
          let blocksToDecomp = dropWhile isComment groupedBlocks
              ( conds, blocks, leftOverBlocks, endLabel ) = decomposeCase blocksToDecomp mName
          in ( BlCase a (getTransSpan s blocks) label mName scrutinee conds blocks endLabel
             , leftOverBlocks)
      b | containsGroups b -> -- Map to subblocks for groupable blocks
        ( applyGroupingToSubblocks groupCase' b, groupedBlocks )
      _ -> ( b , groupedBlocks )
    groupedBlocks = groupCase' bs -- Assume everything to the right is grouped.
    isComment b = case b of { BlComment{} -> True; _ -> False }

decomposeCase :: [ Block (Analysis a) ] -> Maybe String
              -> ( [ Maybe (AList Index (Analysis a)) ]
                 , [ [ Block (Analysis a) ] ]
                 , [ Block (Analysis a) ]
                 , Maybe (Expression (Analysis a)) )
decomposeCase blocks@(BlStatement _ _ mLabel st:rest) mTargetName =
    case st of
      StCase _ _ mName mCondition
        | Nothing <- mName -> go mCondition rest
        | mName == mTargetName -> go mCondition rest
        | otherwise -> error $ "Case name does not match that of " ++
                                 "the corresponding select case statement."
      StEndcase _ _ mName
        | mName == mTargetName -> ([], [], rest, mLabel)
        | otherwise -> error $ "End case name does not match that of " ++
                                 "the corresponding select case statement."
      _ -> error "Block with non-case related statement. Must not occur."
  where
    go mCondition blocks =
      let (nonCaseBlocks, rest) = collectNonCaseBlocks blocks
          (conditions, listOfBlocks, rest', endLabel) = decomposeCase rest mTargetName
      in ( mCondition : conditions
         , nonCaseBlocks : listOfBlocks
         , rest', endLabel )

-- This compiles the executable blocks under various if conditions.
collectNonCaseBlocks :: [ Block (Analysis a) ] -> ([ Block (Analysis a) ], [ Block (Analysis a) ])
collectNonCaseBlocks blocks =
  case blocks of
    b@(BlStatement _ _ _ st):_
      | StCase{} <- st -> ( [], blocks )
      | StEndcase{} <- st -> ( [], blocks )
    -- In this case case block is malformed and the file ends prematurely.
    b:bs -> let (bs', rest) = collectNonCaseBlocks bs in (b : bs', rest)
    _ -> error "Premature file ending while parsing select case block."

--------------------------------------------------------------------------------
-- Helpers for grouping of structured blocks with more blocks inside.
--------------------------------------------------------------------------------

containsGroups :: Block (Analysis a) -> Bool
containsGroups b =
  case b of
    BlStatement{} -> False
    BlIf{} -> True
    BlCase{} -> True
    BlDo{} -> True
    BlDoWhile{} -> True
    BlInterface{} -> False
    BlComment{} -> False

applyGroupingToSubblocks :: ([ Block (Analysis a) ] -> [ Block (Analysis a) ]) -> Block (Analysis a) -> Block (Analysis a)
applyGroupingToSubblocks f b
  | BlStatement{} <- b =
      error "Individual statements do not have subblocks. Must not occur."
  | BlIf a s l mn conds blocks el <- b = BlIf a s l mn conds (map f blocks) el
  | BlCase a s l mn scrutinee conds blocks el <- b =
      BlCase a s l mn scrutinee conds (map f blocks) el
  | BlDo a s l n tl doSpec blocks el <- b = BlDo a s l n tl doSpec (f blocks) el
  | BlDoWhile a s l n doSpec blocks el <- b = BlDoWhile a s l n doSpec (f blocks) el
  | BlInterface{} <- b =
      error "Interface blocks do not have groupable subblocks. Must not occur."
  | BlComment{} <- b =
    error "Comment statements do not have subblocks. Must not occur."

--------------------------------------------------

-- Local variables:
-- mode: haskell
-- haskell-program-name: "cabal repl"
-- End:
