{-# LANGUAGE ImportQualifiedPost #-}

-- | Runs every engine test. Each module under "Claims" tests the source
-- module of the same name.
module Main (main) where

import Test.Hspec
import BusinessRulesSpec (businessRulesSpec)
import Claims.EvaluatorSpec (evaluatorSpec)
import Claims.MLClientSpec (mlClientSpec)
import Claims.ParserSpec (parserSpec)
import Claims.PipelineSpec (pipelineSpec)
import Claims.PolicyCombinerSpec (policyCombinerSpec)
import Claims.RedundancyCheckerSpec (redundancyCheckerSpec)
import ListenConfigSpec (listenConfigSpec)
import ParserProps (parserProperties)

main :: IO ()
main = hspec $ do
  businessRulesSpec
  listenConfigSpec
  parserProperties
  parserSpec
  evaluatorSpec
  policyCombinerSpec
  mlClientSpec
  pipelineSpec
  redundancyCheckerSpec
