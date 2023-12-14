{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE QuasiQuotes #-}

module Pact.Core.Test.StaticErrorTests(tests) where

import Test.Tasty
import Test.Tasty.HUnit

import Control.Lens
import Data.Default
import Data.IORef
import Data.Text (Text)
import Data.Maybe(isJust)
import NeatInterpolation (text)

import Pact.Core.Builtin
import Pact.Core.Environment
import Pact.Core.Errors
import Pact.Core.Gas
import Pact.Core.Persistence
import Pact.Core.Repl.Compile
import Pact.Core.Repl.Utils
import Pact.Core.Test.TestPrisms

isDesugarError :: Prism' DesugarError a -> PactErrorI -> Bool
isDesugarError p s = isJust $ preview (_PEDesugarError . _1 . p) s

isExecutionError :: Prism' EvalError a -> PactErrorI -> Bool
isExecutionError p s = isJust $ preview (_PEExecutionError . _1 . p) s

runStaticTest :: String -> Text -> (PactErrorI -> Bool) -> Assertion
runStaticTest label src predicate = do
  gasRef <- newIORef (Gas 0)
  gasLog <- newIORef Nothing
  pdb <- mockPactDb
  let ee = defaultEvalEnv pdb replRawBuiltinMap
      source = SourceCode label src
      rstate = ReplState
            { _replFlags = mempty
            , _replEvalState = def
            , _replPactDb = pdb
            , _replGas = gasRef
            , _replEvalLog = gasLog
            , _replCurrSource = source
            , _replEvalEnv = ee
            , _replTx = Nothing
            }
  stateRef <- newIORef rstate
  v <- runReplT stateRef (interpretReplProgram source (const (pure ())))
  case v of
    Left err ->
      assertBool ("Expected Error to match predicate, but got " <> show err <> " instead") (predicate err)
    Right _v -> assertFailure ("Error: Static failure test succeeded for test: " <> label)

staticTests :: [(String, PactErrorI -> Bool, Text)]
staticTests =
  [ ("no_bind_body", isDesugarError _EmptyBindingBody, [text|(bind {"a":1} {"a":=a})|])
  , ("defpact_last_step_rollback", isDesugarError _LastStepWithRollback, [text|
      (module m g (defcap g () true)

        (defpact f ()
          (step-with-rollback 1 1)
          )
        )
      |])
  , ("interface_defcap_meta_impl", isDesugarError _ImplementationError, [text|
      (interface iface
        (defcap CAP:bool (a:integer)
          @managed a CAP-MGR
        )
        (defun CAP-MGR:integer (a:integer b:integer))
        )

      (module m g (defcap g () true)
        (implements iface)

        (defcap CAP:bool (a:integer) true)
        (defun CAP-MGR:integer (a:integer b:integer) 1)
        )
      |])
  , ("enforce-one_no_list", isDesugarError _InvalidSyntax, [text|
      (module m g (defcap g () true)
        (defun enforce-cap ()
          (enforce-one "foo" 1)
          )
        )
      |])
  {- TODO unable to trigger Desugar.hs:336/344 in `desugarDefun`, parser gets there first
  , ("defun_outside_module", isDesugarError _NotAllowedOutsideModule, [text|
      (interface iface
        (defun foo:string (m:string) m)
        )
      |]) -}
  {- TODO ditto in desugarDefPact
  , ("defpact_empty", isDesugarError _EmptyDefPact, [text|
      (module m g (defcap g () true)
        (defpact f ())
        )
      |]) -}
  {- TODO ditto in desugarDefPact
  , ("defpact_outside_module", isDesugarError _NotAllowedOutsideModule, [text|
      (defpact f ()
        (step "step-0")
        )
      |]) -}
  {- TODO ditto in desugarDefCap
  , ("defcap_outside_module", isDesugarError _NotAllowedOutsideModule, [text|(defcap G () true)|]) -}
  , ("managed_invalid", isDesugarError _InvalidManagedArg, [text|
      (module mgd-mod G
        (defcap G () true)
        (defcap C:bool (id:string) @managed notId foo true)
        (defun foo:string (a:string b:string) a)
        )
      |])
  , ("import_invalid_set", isDesugarError _InvalidImports, [text|
      (module m mg (defcap mg () true))

      (module n ng (defcap ng () true)
        (use m [ nonexistent ])
        )
      |])
  , ("module_instead_of_interface", isDesugarError _InvalidModuleReference, [text|
      (interface iface
        (defun foo:string (a:integer b:integer))
        )
      iface
      |])
  , ("interface_instead_of_module", isDesugarError _InvalidModuleReference, [text|
      (module mod G (defcap G () true))

      (module other-mod OG (defcap OG () true)
        (defun foo:string (a:string b:module{mod}) a)
        )
      |])
  , ("interface_instead_of_module_same", isDesugarError _NoSuchModule, [text|
      (module mod G (defcap G () true)
        (defun foo:string (a:string b:module{mod}) a)
        )
      |])
  , ("import_unknown_module", isDesugarError _NoSuchModule, [text|
      (module m g (defcap g () true)
        (use nonexistent)
        )
      |])
  , ("import_unknown_module_self", isDesugarError _NoSuchModule, [text|
      (module m g (defcap g () true)
        (use m)
        )
      |])
  , ("import_unknown_module_namespaced_self", isDesugarError _NoSuchModule, [text|
      (env-data { "carl-keys" : ["carl"], "carl.carl-keys": ["carl"] })
      (env-keys ["carl"])

      (define-namespace 'carl (read-keyset 'carl-keys) (read-keyset 'carl-keys))
      (namespace 'carl)
      (module m g (defcap g () true)
        (use carl.m)
        )
      |])
  , ("import_unknown_module_namespaced_self_nons", isExecutionError _ModuleDoesNotExist, [text|
      (env-data { "carl-keys" : ["carl"], "carl.carl-keys": ["carl"] })
      (env-keys ["carl"])

      (define-namespace 'carl (read-keyset 'carl-keys) (read-keyset 'carl-keys))
      (namespace 'carl)
      (module m g (defcap g () true)
        (use m)
        )
      |])
  , ("import_unknown_module_namespaced_outside", isDesugarError _NoSuchModule, [text|
      (begin-tx)
      (env-data { "carl-keys" : ["carl"], "carl.carl-keys": ["carl"] })
      (env-keys ["carl"])

      (define-namespace 'carl (read-keyset 'carl-keys) (read-keyset 'carl-keys))
      (namespace 'carl)
      (module m g (defcap g () true))
      (commit-tx)

      (module n ng (defcap ng () true)
        (use carl.n)
        )
      |])
    -- TODO better error
  , ("invalid_schema_iface_wrong_name", isDesugarError _NoSuchModule, [text|
      (interface iface
        (defconst c:object{nonexistent} { 'flag:true })
        )
      |])
    -- TODO better error
  , ("invalid_schema_iface_wrong_ref", isDesugarError _NoSuchModule, [text|
      (interface iface
        (defun i ())
        (defconst c:object{i} { 'flag:true })
        )
      |])
    -- TODO better error
  , ("invalid_schema_iface_wrong_ref_qual", isDesugarError _NoSuchModuleMember, [text|
      (interface iface
        (defun i ())
      )
      (interface iface2
        (defconst c:object{m.i} { 'flag:true })
        )
      |])
    -- TODO better error
  , ("invalid_schema_mod_wrong_name", isDesugarError _NoSuchModule, [text|
      (module m g (defcap g () true)
        (defconst c:object{nonexistent} { 'flag:true })
        )
      |])
  , ("invalid_schema_mod_wrong_ref", isDesugarError _InvalidDefInSchemaPosition, [text|
      (module m g (defcap g () true)
        (defun i () true)
        (defconst c:object{i} { 'flag:true })
        )
      |])
  , ("invalid_schema_mod_wrong_ref_other", isDesugarError _InvalidDefInSchemaPosition, [text|
      (module m g (defcap g () true)
        (defun i () true)
      )
      (interface iface2
        (defconst c:object{m.i} { 'flag:true })
        )
      |])
  ]

tests :: TestTree
tests =
  testGroup "CoreStaticTests" (go <$> staticTests)
  where
  go (label, p, srcText) = testCase label $ runStaticTest label srcText p
