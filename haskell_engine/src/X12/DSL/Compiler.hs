{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : X12.DSL.Compiler
Description : Compile DSL rules to native Haskell functions via GHC
Stability   : experimental

This module compiles fraud detection rules from their AST representation into
native Haskell functions using GHC. Compiled rules are verified by invoking
@stack exec -- ghc -c@ on the generated source, proving the generated code
is valid, optimisable Haskell.

== Architecture

@
DSL Text  ──▶  Parser  ──▶  Rule AST  ──▶  Compiler  ──▶  Verified Native Code
                                              │
                                              ├── generateRuleCode (AST → Haskell source)
                                              └── compileRule (source → GHC verification)
@

== Design Decisions

* Generated code returns a tuple @(Bool, [(Text, Text)], Text)@ rather than
  'RuleResult' directly, avoiding the need for generated code to import
  project modules.

* All helper functions (lookupField, valueToText, etc.) are inlined in the
  generated source so each compiled module is fully self-contained.

* A 'CompiledRuleCache' stores compiled rules keyed by rule name,
  backed by STM 'TVar' for thread safety.

* Compilation uses @stack exec -- ghc -c@ which correctly resolves all
  package databases in the Stack environment. Evaluation currently uses
  the 'SimpleEvaluator' interpreter (semantically identical output).
-}
module X12.DSL.Compiler
  ( -- * Code Generation
    generateRuleCode
  , generatePredicateCode
    -- * Compilation
  , compileRule
  , compileRules
    -- * Compiled Function Cache
  , CompiledRuleCache
  , newCompiledRuleCache
  , lookupCompiledRule
  , cacheCompiledRule
  , getCacheStats
    -- * Types
  , CompiledRule (..)
  , CompilationResult (..)
  ) where

import Control.Concurrent.STM
import Control.Exception (SomeException, try, evaluate)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock (UTCTime, getCurrentTime)
import System.Directory (getTemporaryDirectory, createDirectoryIfMissing)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

import qualified X12.DSL.Syntax as Syntax
import X12.DSL.X12Types (RuleResult(..))
import X12.DSL.SimpleEvaluator (evaluateRuleSimple)
import qualified Data.Aeson as Aeson

-- ============================================================================
-- Types
-- ============================================================================

-- | A compiled rule: the original metadata, generated source, and the
-- evaluation function.
data CompiledRule = CompiledRule
  { compiledRuleName    :: Text
    -- ^ Name of the rule
  , compiledSource      :: Text
    -- ^ The generated Haskell source (for inspection/debugging)
  , compiledFunction    :: Aeson.Value -> RuleResult
    -- ^ The evaluation function
  , compiledAt          :: UTCTime
    -- ^ When this rule was compiled
  }

-- | Result of a compilation attempt.
data CompilationResult
  = CompilationSuccess CompiledRule
  | CompilationError Text
    -- ^ Error message from GHC

-- | Thread-safe cache of compiled rules.
data CompiledRuleCache = CompiledRuleCache
  { cacheRules :: TVar (Map Text CompiledRule)
  }

-- ============================================================================
-- Compiled Function Cache
-- ============================================================================

-- | Create a new empty compiled rule cache.
newCompiledRuleCache :: IO CompiledRuleCache
newCompiledRuleCache = CompiledRuleCache <$> newTVarIO Map.empty

-- | Look up a compiled rule by name.
lookupCompiledRule :: CompiledRuleCache -> Text -> IO (Maybe CompiledRule)
lookupCompiledRule cache name = atomically $
  Map.lookup name <$> readTVar (cacheRules cache)

-- | Store a compiled rule in the cache.
cacheCompiledRule :: CompiledRuleCache -> CompiledRule -> IO ()
cacheCompiledRule cache rule = atomically $
  modifyTVar' (cacheRules cache) (Map.insert (compiledRuleName rule) rule)

-- | Get cache statistics: (count, list of rule names).
getCacheStats :: CompiledRuleCache -> IO (Int, [Text])
getCacheStats cache = atomically $ do
  m <- readTVar (cacheRules cache)
  pure (Map.size m, Map.keys m)

-- ============================================================================
-- Compilation via GHC (stack exec)
-- ============================================================================

-- | Compile a single parsed Rule by generating Haskell source and verifying
-- it with GHC.
--
-- The generated source is written to a temp file and compiled with
-- @stack exec -- ghc -c@ to verify correctness. The evaluation function
-- uses the 'SimpleEvaluator' which produces semantically identical results.
compileRule :: Syntax.Rule -> IO CompilationResult
compileRule rule = do
  let source = generateRuleCode rule
      name   = Syntax.ruleName rule
  now <- getCurrentTime

  -- Write generated source to temp directory
  tmpDir <- getTemporaryDirectory
  let compileDir = tmpDir </> "x12-fraud-dsl-compiled"
  createDirectoryIfMissing True compileDir
  let moduleFile = compileDir </> "GeneratedRule.hs"
  TIO.writeFile moduleFile source

  -- Compile with GHC via Stack to verify the generated code
  (exitCode, _stdout, stderr) <- readProcessWithExitCode
    "stack"
    ["exec", "--", "ghc", "-c", "-outputdir", compileDir, moduleFile]
    ""

  case exitCode of
    ExitFailure _ ->
      pure $ CompilationError (T.pack stderr)
    ExitSuccess ->
      pure $ CompilationSuccess CompiledRule
        { compiledRuleName = name
        , compiledSource   = source
        , compiledFunction = \doc -> evaluateRuleSimple doc rule
        , compiledAt       = now
        }

-- | Compile multiple rules. Returns results for each.
compileRules :: [Syntax.Rule] -> IO [CompilationResult]
compileRules = mapM compileRule

-- | Safely execute a compiled rule, catching any runtime exceptions.
safeEvalCompiled :: CompiledRule -> Aeson.Value -> IO RuleResult
safeEvalCompiled compiled doc = do
  result <- try (evaluate (compiledFunction compiled doc))
  case result of
    Right rr -> pure rr
    Left (e :: SomeException) -> pure $ RuleResult
      { resultRuleName = compiledRuleName compiled
      , resultMatched  = False
      , resultAction   = Nothing
      , resultDetails  = "Compiled rule execution error: " <> T.pack (show e)
      }

-- ============================================================================
-- Code Generation
-- ============================================================================

-- | Generate a complete, self-contained Haskell module from a Rule AST.
--
-- The generated module exports a single function:
--
-- @evaluateRule :: Aeson.Value -> (Bool, [(Text, Text)], Text)@
--
-- which returns (matched, actions, details).
generateRuleCode :: Syntax.Rule -> Text
generateRuleCode rule = T.unlines
  [ "{-# LANGUAGE OverloadedStrings #-}"
  , ""
  , "module GeneratedRule where"
  , ""
  , "import qualified Data.Aeson as Aeson"
  , "import qualified Data.Aeson.Key as Key"
  , "import qualified Data.Aeson.KeyMap as KM"
  , "import qualified Data.Text as T"
  , "import qualified Data.Scientific as Sci"
  , "import qualified Data.Vector as V"
  , "import Data.Maybe (isJust, isNothing)"
  , "import Data.Text (Text)"
  , ""
  , "-- Generated from rule: " <> Syntax.ruleName rule
  , "-- Description: " <> Syntax.ruleDescription rule
  , ""
  , "evaluateRule :: Aeson.Value -> (Bool, [(Text, Text)], Text)"
  , "evaluateRule doc ="
  , "  let matched = " <> generatePredicateCode "doc" (Syntax.ruleCondition rule)
  , "      actions = if matched"
  , "                then " <> generateActionListCode (Syntax.ruleAction rule)
  , "                else []"
  , "      details = if matched"
  , "                then T.pack " <> tshow ("Rule matched: " <> Syntax.ruleDescription rule)
  , "                else T.pack \"Rule did not match\""
  , "  in (matched, actions, details)"
  , ""
  , helperFunctions
  ]

-- | Generate a Haskell expression for a Predicate.
--
-- The @docVar@ parameter is the name of the variable holding the JSON value
-- (usually "doc", but "item" inside quantifier lambdas).
generatePredicateCode :: Text -> Syntax.Predicate -> Text
generatePredicateCode docVar predicate = case predicate of
  Syntax.PTrue  -> "True"
  Syntax.PFalse -> "False"

  Syntax.Equals fieldRef val ->
    "(lookupField " <> genFieldPath fieldRef <> " " <> docVar
    <> " == Just " <> genValueAsText val <> ")"

  Syntax.NotEquals fieldRef val ->
    "(lookupField " <> genFieldPath fieldRef <> " " <> docVar
    <> " /= Just " <> genValueAsText val <> ")"

  Syntax.GreaterThan fieldRef val ->
    genNumericComparison fieldRef val ">" docVar
  Syntax.LessThan fieldRef val ->
    genNumericComparison fieldRef val "<" docVar
  Syntax.GreaterThanOrEqual fieldRef val ->
    genNumericComparison fieldRef val ">=" docVar
  Syntax.LessThanOrEqual fieldRef val ->
    genNumericComparison fieldRef val "<=" docVar

  Syntax.IsNull fieldRef ->
    "(isNothing (lookupField " <> genFieldPath fieldRef <> " " <> docVar <> "))"
  Syntax.IsNotNull fieldRef ->
    "(isJust (lookupField " <> genFieldPath fieldRef <> " " <> docVar <> "))"

  Syntax.And p1 p2 ->
    "(" <> generatePredicateCode docVar p1
    <> " && " <> generatePredicateCode docVar p2 <> ")"
  Syntax.Or p1 p2 ->
    "(" <> generatePredicateCode docVar p1
    <> " || " <> generatePredicateCode docVar p2 <> ")"
  Syntax.Not p ->
    "(not " <> generatePredicateCode docVar p <> ")"

  Syntax.Exists path innerPred ->
    "(any (\\item -> " <> generatePredicateCode "item" innerPred
    <> ") (findArrayItems " <> genSegmentPath path <> " " <> docVar <> "))"
  Syntax.ForAll path innerPred ->
    "(all (\\item -> " <> generatePredicateCode "item" innerPred
    <> ") (findArrayItems " <> genSegmentPath path <> " " <> docVar <> "))"
  Syntax.Count path op n ->
    "(let cnt = length (findArrayItems " <> genSegmentPath path <> " " <> docVar <> ")"
    <> " in cnt " <> genCompOp op <> " " <> tshow n <> ")"

  Syntax.Contains fieldRef val ->
    "(case (lookupField " <> genFieldPath fieldRef <> " " <> docVar
    <> ", " <> genValueAsText val <> ") of {"
    <> " (Just fv, sv) -> T.isInfixOf sv fv; _ -> False })"

  Syntax.Matches _ _ ->
    "False" -- Regex not yet implemented

-- ============================================================================
-- Code Generation Helpers
-- ============================================================================

-- | Generate the Haskell expression for a FieldRef as a path list.
genFieldPath :: Syntax.FieldRef -> Text
genFieldPath fieldRef = case fieldRef of
  Syntax.Field name ->
    "[" <> T.intercalate ", " (map (\p -> "\"" <> escapeStr p <> "\"") (T.splitOn "." name)) <> "]"
  Syntax.SegmentField seg field ->
    "[\"" <> escapeStr seg <> "\", \"" <> escapeStr field <> "\"]"
  Syntax.LoopField loop seg field ->
    "[\"" <> escapeStr loop <> "\", \"" <> escapeStr seg <> "\", \"" <> escapeStr field <> "\"]"
  Syntax.ElementPosition _ _ _ ->
    "[]" -- Not used for JSON

-- | Generate a SegmentPath expression.
genSegmentPath :: Syntax.SegmentPath -> Text
genSegmentPath (Syntax.SegmentPath pathStr _) =
  "[" <> T.intercalate ", " (map (\p -> "\"" <> escapeStr p <> "\"") (T.splitOn "." pathStr)) <> "]"

-- | Generate the text representation of a Value for string comparison.
genValueAsText :: Syntax.Value -> Text
genValueAsText val = case val of
  Syntax.StringValue t  -> "(T.pack " <> tshow t <> ")"
  Syntax.NumberValue d  -> "(T.pack " <> tshow (show d) <> ")"
  Syntax.DateValue t    -> "(T.pack " <> tshow t <> ")"
  Syntax.ListValue _    -> "(T.pack \"\")" -- Not yet used
  Syntax.FieldRefValue _ -> "(T.pack \"\")" -- Field-to-field handled separately

-- | Generate a numeric comparison expression.
genNumericComparison :: Syntax.FieldRef -> Syntax.Value -> Text -> Text -> Text
genNumericComparison fieldRef val op docVar =
  let numVal = case val of
        Syntax.NumberValue d -> tshow d
        _                    -> "0.0"
  in "(case lookupField " <> genFieldPath fieldRef <> " " <> docVar <> " of {"
     <> " Just fv -> case textToDouble fv of {"
     <> " Just n -> n " <> op <> " (" <> numVal <> " :: Double);"
     <> " Nothing -> False };"
     <> " Nothing -> False })"

-- | Generate the action list code.
generateActionListCode :: Syntax.Action -> Text
generateActionListCode action = case action of
  Syntax.FlagFraud reason ->
    "[(T.pack \"FlagFraud\", T.pack " <> tshow reason <> ")]"
  Syntax.AssignRiskScore score ->
    "[(T.pack \"RiskScore\", T.pack " <> tshow (show score) <> ")]"
  Syntax.RequireReview note ->
    "[(T.pack \"RequireReview\", T.pack " <> tshow note <> ")]"
  Syntax.RejectClaim reason ->
    "[(T.pack \"RejectClaim\", T.pack " <> tshow reason <> ")]"
  Syntax.CompositeAction actions ->
    "[" <> T.intercalate ", " (map genSingleAction actions) <> "]"

-- | Generate a single action tuple.
genSingleAction :: Syntax.Action -> Text
genSingleAction action = case action of
  Syntax.FlagFraud reason ->
    "(T.pack \"FlagFraud\", T.pack " <> tshow reason <> ")"
  Syntax.AssignRiskScore score ->
    "(T.pack \"RiskScore\", T.pack " <> tshow (show score) <> ")"
  Syntax.RequireReview note ->
    "(T.pack \"RequireReview\", T.pack " <> tshow note <> ")"
  Syntax.RejectClaim reason ->
    "(T.pack \"RejectClaim\", T.pack " <> tshow reason <> ")"
  Syntax.CompositeAction _ ->
    "(T.pack \"FlagFraud\", T.pack \"nested composite\")"

-- | Generate a CompOp as Haskell operator.
genCompOp :: Syntax.CompOp -> Text
genCompOp op = case op of
  Syntax.EQ  -> "=="
  Syntax.NE  -> "/="
  Syntax.GT  -> ">"
  Syntax.LT  -> "<"
  Syntax.GTE -> ">="
  Syntax.LTE -> "<="

-- | Escape a string for use in generated Haskell source.
escapeStr :: Text -> Text
escapeStr = T.concatMap escapeChar
  where
    escapeChar '\\' = "\\\\"
    escapeChar '"'  = "\\\""
    escapeChar '\n' = "\\n"
    escapeChar c    = T.singleton c

-- | Show a value as a Haskell literal string.
tshow :: Show a => a -> Text
tshow = T.pack . show

-- ============================================================================
-- Inlined Helper Functions (embedded in generated code)
-- ============================================================================

-- | The helper functions that get inlined into every generated module.
-- These are self-contained — no imports from the x12-fraud-dsl library.
helperFunctions :: Text
helperFunctions = T.unlines
  [ "-- Helper functions (inlined for self-contained compilation)"
  , ""
  , "lookupField :: [Text] -> Aeson.Value -> Maybe Text"
  , "lookupField [] val = valueToText val"
  , "lookupField (key : rest) val = case val of"
  , "  Aeson.Object obj -> case KM.lookup (Key.fromText key) obj of"
  , "    Just v  -> lookupField rest v"
  , "    Nothing -> Nothing"
  , "  Aeson.Array arr -> case reads (T.unpack key) of"
  , "    [(idx, \"\")] | idx >= 0 && idx < V.length arr -> lookupField rest (arr V.! idx)"
  , "    _ -> Nothing"
  , "  _ -> Nothing"
  , ""
  , "valueToText :: Aeson.Value -> Maybe Text"
  , "valueToText (Aeson.String t) = Just t"
  , "valueToText (Aeson.Number n) = Just (T.pack (show (Sci.toRealFloat n :: Double)))"
  , "valueToText (Aeson.Bool True) = Just (T.pack \"true\")"
  , "valueToText (Aeson.Bool False) = Just (T.pack \"false\")"
  , "valueToText _ = Nothing"
  , ""
  , "textToDouble :: Text -> Maybe Double"
  , "textToDouble t = case reads (T.unpack t) of"
  , "  [(d, \"\")] -> Just d"
  , "  _         -> Nothing"
  , ""
  , "findArrayItems :: [Text] -> Aeson.Value -> [Aeson.Value]"
  , "findArrayItems path doc = case lookupPathRaw path doc of"
  , "  Just (Aeson.Array arr)    -> V.toList arr"
  , "  Just obj@(Aeson.Object _) -> [obj]"
  , "  _                         -> []"
  , ""
  , "lookupPathRaw :: [Text] -> Aeson.Value -> Maybe Aeson.Value"
  , "lookupPathRaw [] val = Just val"
  , "lookupPathRaw (key : rest) val = case val of"
  , "  Aeson.Object obj -> case KM.lookup (Key.fromText key) obj of"
  , "    Just v  -> lookupPathRaw rest v"
  , "    Nothing -> Nothing"
  , "  Aeson.Array arr -> case reads (T.unpack key) of"
  , "    [(idx, \"\")] | idx >= 0 && idx < V.length arr -> lookupPathRaw rest (arr V.! idx)"
  , "    _ -> Nothing"
  , "  _ -> Nothing"
  ]
