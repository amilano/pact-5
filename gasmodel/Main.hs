{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}

module Main where

import qualified Criterion.Main as C

import Pact.Core.GasModel.InterpreterGas as InterpreterGas
import Pact.Core.GasModel.BuiltinsGas as BuiltinsGas
import Pact.Core.GasModel.ContractBench as ContractBench

main :: IO ()
main = do
  contractBenches <- ContractBench.allBenchmarks
  C.defaultMain
    [ contractBenches
    , InterpreterGas.benchmarks
    , BuiltinsGas.benchmarks
    ]



