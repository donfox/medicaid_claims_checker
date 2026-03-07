-- |
-- Module      : Claims.RuleCache
-- Description : AST cache for parsed DSL rules
-- Stability   : stable
--
-- Rules are parsed once and stored in a thread-safe cache keyed by name.
-- Claim evaluation calls 'SimpleEvaluator' directly against the cached AST
-- on every request. No Haskell code generation or GHC invocation.
--
-- == Architecture
--
-- @
-- DSL Text  ──▶  Parser  ──▶  Rule AST  ──▶  Cache  ──▶  evaluateRuleSimple
-- @
module Claims.RuleCache
  ( -- * Parse and cache
    compileRule,
    compileRules,

    -- * Cache operations
    CompiledRuleCache,
    newCompiledRuleCache,
    lookupCompiledRule,
    cacheCompiledRule,
    getCacheStats,

    -- * Types
    CompiledRule (..),
    CompilationResult (..),
  )
where

import Control.Concurrent.STM
import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (Day)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Claims.SimpleEvaluator (evaluateRuleSimple)
import Claims.Syntax qualified as Syntax
import Claims.Syntax (RuleResult (..))

-- ============================================================================
-- Types
-- ============================================================================

-- | A cached rule: its name, evaluation function, and cache timestamp.
data CompiledRule = CompiledRule
  { -- | Name of the rule
    compiledRuleName :: Text,
    -- | Evaluation function — calls SimpleEvaluator against the cached AST
    compiledFunction :: Day -> Aeson.Value -> RuleResult,
    -- | When this rule was cached
    compiledAt :: UTCTime
  }

-- | Result of a parse-and-cache attempt.
data CompilationResult
  = CompilationSuccess CompiledRule
  | -- | DSL parse error
    CompilationError Text

-- | Thread-safe cache of parsed rules keyed by rule name.
data CompiledRuleCache = CompiledRuleCache
  { cacheRules :: TVar (Map Text CompiledRule)
  }

-- ============================================================================
-- Cache Operations
-- ============================================================================

-- | Create a new empty rule cache.
newCompiledRuleCache :: IO CompiledRuleCache
newCompiledRuleCache = CompiledRuleCache <$> newTVarIO Map.empty

-- | Look up a cached rule by name.
lookupCompiledRule :: CompiledRuleCache -> Text -> IO (Maybe CompiledRule)
lookupCompiledRule cache name =
  atomically $
    Map.lookup name <$> readTVar (cacheRules cache)

-- | Store a rule in the cache.
cacheCompiledRule :: CompiledRuleCache -> CompiledRule -> IO ()
cacheCompiledRule cache rule =
  atomically $
    modifyTVar' (cacheRules cache) (Map.insert (compiledRuleName rule) rule)

-- | Get cache statistics: (count, list of rule names).
getCacheStats :: CompiledRuleCache -> IO (Int, [Text])
getCacheStats cache = atomically $ do
  m <- readTVar (cacheRules cache)
  pure (Map.size m, Map.keys m)

-- ============================================================================
-- Parse and Cache
-- ============================================================================

-- | Wrap a parsed Rule AST in a CompiledRule ready for caching.
-- Evaluation uses 'evaluateRuleSimple' — no GHC invocation.
compileRule :: Syntax.Rule -> IO CompilationResult
compileRule rule = do
  now <- getCurrentTime
  pure $
    CompilationSuccess
      CompiledRule
        { compiledRuleName = Syntax.ruleName rule,
          compiledFunction = \today doc -> evaluateRuleSimple today doc rule,
          compiledAt = now
        }

-- | Cache multiple rules.
compileRules :: [Syntax.Rule] -> IO [CompilationResult]
compileRules = mapM compileRule
