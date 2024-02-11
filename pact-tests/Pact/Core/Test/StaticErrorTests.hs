{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE QuasiQuotes #-}

module Pact.Core.Test.StaticErrorTests(tests) where

import Test.Tasty
import Test.Tasty.HUnit

import Control.Lens
import Data.IORef
import Data.Text (Text)
import Data.Default
import Data.Maybe(isJust)
import NeatInterpolation (text)

import Pact.Core.Builtin
import Pact.Core.Environment
import Pact.Core.Errors
import Pact.Core.Gas
import Pact.Core.Persistence.MockPersistence (mockPactDb)
import Pact.Core.Repl.Compile
import Pact.Core.Repl.Utils
import Pact.Core.Serialise (serialisePact_repl_spaninfo)
import Pact.Core.Test.TestPrisms

isParseError :: Prism' ParseError a -> PactErrorI -> Bool
isParseError p s = isJust $ preview (_PEParseError . _1 . p) s

isDesugarError :: Prism' DesugarError a -> PactErrorI -> Bool
isDesugarError p s = isJust $ preview (_PEDesugarError . _1 . p) s

isExecutionError :: Prism' EvalError a -> PactErrorI -> Bool
isExecutionError p s = isJust $ preview (_PEExecutionError . _1 . p) s

runStaticTest :: String -> Text -> (PactErrorI -> Bool) -> Assertion
runStaticTest label src predicate = do
  gasRef <- newIORef (Gas 0)
  gasLog <- newIORef Nothing
  pdb <- mockPactDb serialisePact_repl_spaninfo
  ee <- defaultEvalEnv pdb replCoreBuiltinMap
  let source = SourceCode label src
      rstate = ReplState
            { _replFlags = mempty
            , _replEvalState = def
            , _replPactDb = pdb
            , _replGas = gasRef
            , _replEvalLog = gasLog
            , _replCurrSource = source
            , _replEvalEnv = ee
            , _replUserDocs = mempty
            , _replTLDefPos = mempty
            , _replTx = Nothing
            }
  stateRef <- newIORef rstate
  v <- runReplT stateRef (interpretReplProgram source (const (pure ())))
  case v of
    Left err ->
      assertBool ("Expected Error to match predicate, but got " <> show err <> " instead") (predicate err)
    Right _v -> assertFailure ("Error: Static failure test succeeded for test: " <> label)

parseTests :: [(String, PactErrorI -> Bool, Text)]
parseTests =
  [ ("defpact_empty", isParseError _ParsingError, [text|
      (module m g (defcap g () true)
        (defpact f ())
        )
      |])
  , ("defpact_outside_module", isParseError _ParsingError, [text|
      (defpact f ()
        (step "step-0")
        )
      |])
  , ("defcap_outside_module", isParseError _ParsingError, [text|
      (defcap G () true)
      |])
  ]

desugarTests :: [(String, PactErrorI -> Bool, Text)]
desugarTests =
  [ ("no_bind_body", isDesugarError _EmptyBindingBody, [text|(bind {"a":1} {"a":=a})|])
  , ("defpact_last_step_rollback", isDesugarError _LastStepWithRollback, [text|
      (module m g (defcap g () true)

        (defpact f ()
          (step-with-rollback 1 1)
          )
        )
      |])
  , ("enforce-one_no_list", isDesugarError _InvalidSyntax, [text|
      (module m g (defcap g () true)
        (defun enforce-cap ()
          (enforce-one "foo" 1)
          )
        )
      |])
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
  , ("invalid_var_kind", isDesugarError _InvalidDefInTermVariable, [text|
      (module m g (defcap g () true)
        (defschema p flag:bool)
        (defun i () p)
      )
      |])
    -- TODO better error; intended to trigger `UnboundTypeVariable` instead in `renameDefTable`
  , ("invalid_def_table_nonexistent", isDesugarError _NoSuchModule, [text|
      (module fdb G
        (defcap G () true)
        (deftable fdb-tbl:{fdb-test})
        )
      |])
  , ("invalid_def_table_wrong_type", isDesugarError _InvalidDefInSchemaPosition, [text|
      (module fdb G
        (defcap G () true)
        (defun i () true)
        (deftable fdb-tbl:{i})
        )
      |])
    -- TODO better errror; intended to trigger `expectedFree` instead
  , ("defmanaged_wrong_ref", isDesugarError _NoSuchModule, [text|
      (module m g (defcap g () true)
        (defcap CAP:bool (a:integer b:integer)
          @managed a b
          true
        )
        )
      |])
  , ("invalid_ifdefcap_ref_mod", isDesugarError _NoSuchModuleMember, [text|
      (module m g (defcap g () true)
        (defun i () true)
        )
      (interface iface
        (defcap CAP:bool (a:integer)
          @managed a m
        )
        )
      |])
  , ("invalid_ifdefcap_ref_qual", isDesugarError _NoSuchModuleMember, [text|
      (module m g (defcap g () true)
        (defun i () true)
        )
      (interface iface
        (defcap CAP:bool (a:integer)
          @managed a m.i
        )
        )
      |])
  , ("resolve_qualified_failure", isDesugarError _NoSuchModuleMember, [text|
      (module m g (defcap g () true)
        (defun f () true)
        )
      (module n ng (defcap ng () true)
        (defun f () m.nonexistent)
        )
      |])
  , ("resolve_qualified_shadowing", isDesugarError _NoSuchModuleMember, [text|
      (module m g (defcap g () true)
        (defun fff () true)
        )
      (module n ng (defcap ng () true)
        (defun f () m.f)
        )
      |])
  , ("dyninvoke_unbound", isDesugarError _UnboundTermVariable, [text|
      (module m g (defcap g () true)
        (defun i () true)
        )
      (module n ng (defcap ng () true)
        (defun g () m::i)
        )
      |])
  , ("dyninvoke_invalid_bound", isDesugarError _InvalidDynamicInvoke, [text|
      (defun f () 1)
      (defun invalid-dynamic-invoke () (f::g))
      |])
  , ("cyclic_defs", isDesugarError _RecursionDetected, [text|
      (module m g (defcap g () true)
        (defun f1 () f2)
        (defun f2 () f1)
        )
      |])
  , ("cyclic_defs_longer", isDesugarError _RecursionDetected, [text|
      (module m g (defcap g () true)
        (defun f1 () f2)
        (defun f2 () f3)
        (defun f3 () f1)
        )
      |])
  , ("dup_defs", isDesugarError _DuplicateDefinition, [text|
      (module m g (defcap g () true)
        (defun f () true)
        (defun f () false)
        )
      |])
  , ("dup_defs_different_kind", isDesugarError _DuplicateDefinition, [text|
      (module m g (defcap g () true)
        (defun f () true)
        (defconst f true)
        )
      |])
  , ("governance_wrong", isDesugarError _InvalidGovernanceRef, [text|
      (module m g (defconst g true))
      |])
  , ("governance_nonexistent", isDesugarError _InvalidGovernanceRef, [text|
      (module m g (defconst k true))
      |])
  , ("module_implements_nonexistent", isDesugarError _NoSuchModule, [text|
      (module m g (defcap g () true)
        (implements nonexistent)
        )
      |])
  , ("module_implements_module", isDesugarError _NoSuchInterface, [text|
      (module notiface ng (defcap ng () true))

      (module m g (defcap g () true)
        (implements notiface)
        )
      |])
  , ("module_implements_dfun_missing", isDesugarError _NotImplemented, [text|
      (interface iface
        (defun f:integer (a:integer b:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        )
      |])
  , ("module_implements_dfun_wrong_kind", isDesugarError _ImplementationError, [text|
      (interface iface
        (defun f:integer (a:integer b:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defconst f true)
        )
      |])
  , ("module_implements_dfun_wrong_ret", isDesugarError _ImplementationError, [text|
      (interface iface
        (defun f:integer (a:integer b:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defun f:bool (a:integer b:integer) true)
        )
      |])
  , ("module_implements_dfun_wrong_args_type", isDesugarError _ImplementationError, [text|
      (interface iface
        (defun f:integer (a:integer b:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defun f:bool (a:integer b:bool) true)
        )
      |])
  , ("module_implements_dfun_wrong_args_count_less", isDesugarError _ImplementationError, [text|
      (interface iface
        (defun f:integer (a:integer b:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defun f:bool (a:integer) true)
        )
      |])
  , ("module_implements_dfun_wrong_args_count_more", isDesugarError _ImplementationError, [text|
      (interface iface
        (defun f:integer (a:integer b:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defun f:bool (a:integer b:integer c:integer) true)
        )
      |])
  , ("module_implements_dfun_wrong_args_unspec", isDesugarError _ImplementationError, [text|
      (interface iface
        (defun f:integer (a:integer b:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defun f:integer (a b) a)
        )
      |])
  , ("module_implements_defcap_missing", isDesugarError _NotImplemented, [text|
      (interface iface
        (defcap CAP:bool (a:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        )
      |])
  , ("module_implements_defcap_wrong_kind", isDesugarError _ImplementationError, [text|
      (interface iface
        (defcap CAP:bool (a:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defun CAP:bool (a:integer) true)
        )
      |])
  , ("module_implements_defcap_wrong_meta", isDesugarError _ImplementationError, [text|
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
  , ("module_implements_defcap_wrong_args_count_more", isDesugarError _ImplementationError, [text|
      (interface iface
        (defcap CAP:bool (a:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defcap CAP:bool (a:integer b:bool) true)
        )
      |])
  , ("module_implements_defcap_wrong_args_count_less", isDesugarError _ImplementationError, [text|
      (interface iface
        (defcap CAP:bool (a:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defcap CAP:bool () true)
        )
      |])
  , ("module_implements_defcap_wrong_args_type", isDesugarError _ImplementationError, [text|
      (interface iface
        (defcap CAP:bool (a:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defcap CAP:bool (a:bool) true)
        )
      |])
  , ("module_implements_defcap_wrong_ret_type", isDesugarError _ImplementationError, [text|
      (interface iface
        (defcap CAP:bool (a:integer))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defcap CAP:integer (a:integer) 1)
        )
      |])
  , ("module_implements_defpact_missing", isDesugarError _NotImplemented, [text|
      (interface iface
        (defpact p:string (arg:string))
        )

      (module m g (defcap g () true)
        (implements iface)
        )
      |])
  , ("module_implements_defpact_wrong_kind", isDesugarError _ImplementationError, [text|
      (interface iface
        (defpact p:string (arg:string))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defun p:string (arg:string) arg)
        )
      |])
  , ("module_implements_defpact_wrong_ret_type", isDesugarError _ImplementationError, [text|
      (interface iface
        (defpact p:string (arg:string))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defpact p:bool (arg:string)
          (step "step-0"))
        )
      |])
  , ("module_implements_defpact_wrong_arg_type", isDesugarError _ImplementationError, [text|
      (interface iface
        (defpact p:string (arg:string))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defpact p:string (arg:bool)
          (step "step-0"))
        )
      |])
  , ("module_implements_defpact_wrong_arg_count_less", isDesugarError _ImplementationError, [text|
      (interface iface
        (defpact p:string (arg:string))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defpact p:string ()
          (step "step-0"))
        )
      |])
  , ("module_implements_defpact_wrong_arg_count_more", isDesugarError _ImplementationError, [text|
      (interface iface
        (defpact p:string (arg:string))
        )

      (module m g (defcap g () true)
        (implements iface)
        (defpact p:string (arg:string b:bool)
          (step "step-0"))
        )
      |])
  , ("module_use_invalid_hash", isDesugarError _InvalidBlessedHash, [text|
      (module m g (defcap g () true))

      (use m "definitelynotanykindofhash")
      |])
  , ("module_use_wrong_hash", isDesugarError _InvalidImportModuleHash, [text|
      (module m g (defcap g () true))

      (use m "A_fIcwIweiXXYXnKU59CNCAUoIXHXwQtB_D8xhEflLY")
      |])
  ]

executionTests :: [(String, PactErrorI -> Bool, Text)]
executionTests =
  [ ("import_unknown_module_namespaced_self_nons", isExecutionError _ModuleDoesNotExist, [text|
      (env-data { "carl-keys" : ["carl"], "carl.carl-keys": ["carl"] })
      (env-keys ["carl"])

      (define-namespace 'carl (read-keyset 'carl-keys) (read-keyset 'carl-keys))
      (namespace 'carl)
      (module m g (defcap g () true)
        (use m)
        )
      |])
  ]

tests :: TestTree
tests =
  testGroup "CoreStaticTests" (go <$> parseTests <> desugarTests <> executionTests)
  where
  go (label, p, srcText) = testCase label $ runStaticTest label srcText p
