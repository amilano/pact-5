{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE UndecidableInstances #-}


-- |
-- Module      :  Pact.Core.IR.Term
-- Copyright   :  (C) 2016 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Jose Cardona <jose@kadena.io>
--
-- Our Analysis IR
--

module Pact.Core.IR.Analysis.Term where

import Control.Lens
import Data.Foldable(fold)
import Data.Text(Text)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict(Map)
import qualified Data.Set as Set
import qualified Data.List.NonEmpty as NE

import Pact.Core.Guards
import Pact.Core.Builtin
import Pact.Core.Hash
import Pact.Core.Literal
import Pact.Core.Type
import Pact.Core.Names
import Pact.Core.Imports
import Pact.Core.Capabilities
import Pact.Core.Pretty

data Defun name ty builtin info
  = Defun
  { _dfunName :: Text
  , _dfunArgs :: [Arg ty]
  , _dfunRType :: Maybe ty
  , _dfunTerm :: Term name ty builtin info
  , _dfunInfo :: info
  } deriving (Show, Functor)

data DefConst name ty builtin info
  = DefConst
  { _dcName :: Text
  , _dcType :: Maybe ty
  , _dcTerm :: Term name ty builtin info
  , _dcInfo :: info
  } deriving (Show, Functor)

data DefCap name ty builtin info
  = DefCap
  { _dcapName :: Text
  , _dcapAppArity :: Int
  , _dcapArgs :: [Arg ty]
  , _dcapRType :: Maybe ty
  , _dcapTerm :: Term name ty builtin info
  , _dcapMeta :: Maybe (DefCapMeta name)
  , _dcapInfo :: info
  } deriving (Show, Functor)

data DefSchema ty info
  = DefSchema
  { _dsName :: Text
  , _dsSchema :: Map Field ty
  , _dsInfo :: info
  } deriving (Show, Functor)

-- | The type of our desugared table schemas
-- TODO: This GADT is unnecessarily complicated and only really necessary
-- because currently, renaming and desugaring are not in sequence. That is:
-- renaming and desugaring a module happens as a full desugar into a full rename.
-- if they ran one after another, this type would not be necessary
-- data TableSchema name where
--   DesugaredTable :: ParsedName -> TableSchema ParsedName
--   ResolvedTable :: Schema -> TableSchema Name

-- instance Show (TableSchema name) where
--   show (DesugaredTable t) = "DesugardTable(" <> show t <> ")"
--   show (ResolvedTable t) = "ResolvedTable(" <> show t <> ")"

data DefTable name info
  = DefTable
  { _dtName :: Text
  , _dtSchema :: name
  , _dtInfo :: info
  } deriving (Show, Functor)

data Def name ty builtin info
  = Dfun (Defun name ty builtin info)
  | DConst (DefConst name ty builtin info)
  | DCap (DefCap name ty builtin info)
  | DSchema (DefSchema ty info)
  | DTable (DefTable name info)
  deriving (Show, Functor)

data Module name ty builtin info
  = Module
  { _mName :: ModuleName
  , _mGovernance :: Governance name
  , _mDefs :: [Def name ty builtin info]
  , _mBlessed :: !(Set.Set ModuleHash)
  , _mImports :: [Import]
  , _mImplements :: [ModuleName]
  , _mHash :: ModuleHash
  , _mInfo :: info
  } deriving (Show, Functor)

data Interface name ty builtin info
  = Interface
  { _ifName :: ModuleName
  , _ifDefns :: [IfDef name ty builtin info]
  , _ifHash :: ModuleHash
  , _ifInfo :: info
  } deriving (Show, Functor)

data IfDefun ty info
  = IfDefun
  { _ifdName :: Text
  , _ifdArgs :: [Arg ty]
  , _ifdRType :: Maybe ty
  , _ifdInfo :: info
  } deriving (Show, Functor)

data IfDefCap ty info
  = IfDefCap
  { _ifdcName :: Text
  , _ifdcArgs :: [Arg ty]
  , _ifdcRType :: Maybe ty
  , _ifdcInfo :: info
  } deriving (Show, Functor)

data IfDef name ty builtin info
  = IfDfun (IfDefun ty info)
  | IfDConst (DefConst name ty builtin info)
  | IfDCap (IfDefCap ty info)
  deriving (Show, Functor)

data TopLevel name ty builtin info
  = TLModule (Module name ty builtin info)
  | TLInterface (Interface name ty builtin info)
  | TLTerm (Term name ty builtin info)
  deriving (Show, Functor)

data ReplTopLevel name ty builtin info
  = RTLTopLevel (TopLevel name ty builtin info)
  | RTLDefConst (DefConst name ty builtin info)
  | RTLDefun (Defun name ty builtin info)
  deriving (Show, Functor)

pattern RTLTerm :: Term name ty builtin info -> ReplTopLevel name ty builtin info
pattern RTLTerm e = RTLTopLevel (TLTerm e)

pattern RTLModule :: Module name ty builtin info -> ReplTopLevel name ty builtin info
pattern RTLModule m = RTLTopLevel (TLModule m)

pattern RTLInterface :: Interface name ty builtin info -> ReplTopLevel name ty builtin info
pattern RTLInterface iface = RTLTopLevel (TLInterface iface)

defName :: Def name t b i -> Text
defName (Dfun d) = _dfunName d
defName (DConst d) = _dcName d
defName (DCap d) = _dcapName d
defName (DSchema d) = _dsName d
defName (DTable d) = _dtName d

defKind :: Def name Type b i -> DefKind
defKind = \case
  Dfun{} -> DKDefun
  DConst{} -> DKDefConst
  DCap{} -> DKDefCap
  DSchema ds -> DKDefSchema (Schema (_dsSchema ds))
  DTable{} -> DKDefTable

ifDefKind :: IfDef name Type b i -> Maybe DefKind
ifDefKind = \case
  IfDfun{} -> Nothing
  IfDCap{} -> Nothing
  IfDConst{} -> Just DKDefConst


ifDefName :: IfDef name ty builtin i -> Text
ifDefName = \case
  IfDfun ifd -> _ifdName ifd
  IfDConst dc -> _dcName dc
  IfDCap ifd -> _ifdcName ifd

defInfo :: Def name ty b i -> i
defInfo = \case
  Dfun de -> _dfunInfo de
  DConst dc -> _dcInfo dc
  DCap dc -> _dcapInfo dc
  DSchema dc -> _dsInfo dc
  DTable dt -> _dtInfo dt


ifDefInfo :: IfDef name ty b i -> i
ifDefInfo = \case
  IfDfun de -> _ifdInfo de
  IfDConst dc -> _dcInfo dc
  IfDCap d -> _ifdcInfo d

type EvalTerm b i = Term Name Type b i
type EvalDef b i = Def Name Type b i
type EvalModule b i = Module Name Type b i
type EvalInterface b i = Interface Name Type b i

data LamInfo
  = TLDefun ModuleName Text
  | TLDefCap ModuleName Text
  | AnonLamInfo
  deriving Show

-- | Core IR
data Term name ty builtin info
  = Var name info
  -- ^ single variables e.g x
  | Lam LamInfo (NonEmpty (Arg ty)) (Term name ty builtin info) info
  -- ^ $f = \x.e
  -- Lambdas are named for the sake of the callstack.
  | Let (Arg ty) (Term name ty builtin info) (Term name ty builtin info) info
  -- ^ let x = e1 in e2
  | App (Term name ty builtin info) (NonEmpty (Term name ty builtin info)) info
  -- ^ (e1 e2)
  | Sequence (Term name ty builtin info) (Term name ty builtin info) info
  -- ^ error term , error "blah"
  | Conditional (BuiltinForm (Term name ty builtin info)) info
  -- ^ Conditional terms
  | Builtin builtin info
  -- ^ Built-in ops, e.g (+)
  | Constant Literal info
  -- ^ Literals
  | ListLit [Term name ty builtin info] info
  -- ^ List Literals
  | Try (Term name ty builtin info) (Term name ty builtin info) info
  -- ^ try (catch expr) (try-expr)
  | CapabilityForm (CapForm name (Term name ty builtin info)) info
  -- ^ Capability Natives
  | ObjectLit [(Field, Term name ty builtin info)] info
  -- ^ an object literal
  | DynInvoke (Term name ty builtin info) Text info
  -- ^ dynamic module reference invocation m::f
  | Error Text info
  -- ^ Error term
  deriving (Show, Functor)

instance (Pretty name, Pretty builtin, Pretty ty) => Pretty (Term name ty builtin info) where
  pretty = \case
    Var name _ -> pretty name
    Lam _ ne te _ ->
      parens ("lambda" <+> parens (fold (NE.intersperse ":" (prettyLamArg <$> ne))) <+> pretty te)
    Let n te te' _ ->
      parens $ "let" <+> parens (pretty n <+> pretty te) <+> pretty te'
    App te ne _ ->
      parens (pretty te <+> hsep (NE.toList (pretty <$> ne)))
    Sequence te te' _ ->
      parens ("seq" <+> pretty te <+> pretty te')
    Conditional o _ ->
      pretty o
    Builtin builtin _ -> pretty builtin
    Constant lit _ ->
      pretty lit
    ListLit tes _ ->
      pretty tes
    CapabilityForm cf _ ->
      pretty cf
    Try te te' _ ->
      parens ("try" <+> pretty te <+> pretty te')
    DynInvoke n t _ ->
      pretty n <> "::" <> pretty t
    ObjectLit _n _ -> "object<todo>"
    Error txt _ ->
      parens ("error" <> pretty txt)
    where
    prettyTyAnn = maybe mempty ((":" <>) . pretty)
    prettyLamArg (Arg n ty) =
      pretty n <> prettyTyAnn ty


----------------------------
-- Aliases for convenience
----------------------------
termBuiltin :: Traversal (Term n t b i) (Term n t b' i) b b'
termBuiltin f = \case
  Var n i -> pure (Var n i)
  Lam li ne te i ->
    Lam li ne <$> termBuiltin f te <*> pure i
  Let n te te' i ->
    Let n <$> termBuiltin f te <*> termBuiltin f te' <*> pure i
  App te ne i ->
    App <$> termBuiltin f te <*> traverse (termBuiltin f) ne <*> pure i
  Sequence te te' i ->
    Sequence <$> termBuiltin f te <*> termBuiltin f te' <*> pure i
  Conditional bf i ->
    Conditional <$> traverse (termBuiltin f) bf <*> pure i
  Builtin b i ->
    Builtin <$> f b <*> pure i
  Constant lit i ->
    pure (Constant lit i)
  ListLit tes i ->
    ListLit <$> traverse (termBuiltin f) tes <*> pure i
  Try te te' i ->
    Try <$> termBuiltin f te <*> termBuiltin f te' <*> pure i
  CapabilityForm cf i ->
    CapabilityForm <$> traverse (termBuiltin f) cf <*> pure i
  ObjectLit m i ->
    ObjectLit <$> (traverse._2) (termBuiltin f) m <*> pure i
  DynInvoke n t i ->
    DynInvoke <$> termBuiltin f n <*> pure t <*> pure i
  Error txt i -> pure (Error txt i)

termInfo :: Lens' (Term name ty builtin info) info
termInfo f = \case
  Var n i -> Var n <$> f i
  Let n t1 t2 i ->
    Let n t1 t2 <$> f i
  Lam li ns term i -> Lam li ns term <$> f i
  App t1 t2 i -> App t1 t2 <$> f i
  Builtin b i -> Builtin b <$> f i
  Constant l i -> Constant l <$> f i
  Sequence e1 e2 i -> Sequence e1 e2 <$> f i
  Conditional o i ->
    Conditional o <$> f i
  ListLit l i  -> ListLit l <$> f i
  Try e1 e2 i -> Try e1 e2 <$> f i
  DynInvoke n t i -> DynInvoke n t <$> f i
  CapabilityForm cf i -> CapabilityForm cf <$> f i
  Error t i -> Error t <$> f i
  ObjectLit m i -> ObjectLit m <$> f i
  -- ObjectOp o i -> ObjectOp o <$> f i

instance Plated (Term name ty builtin info) where
  plate f = \case
    Var n i -> pure (Var n i)
    Lam li ns term i -> Lam li ns <$> f term <*> pure i
    Let n t1 t2 i -> Let n <$> f t1 <*> f t2 <*> pure i
    App t1 t2 i -> App <$> f t1 <*> traverse f t2 <*> pure i
    Builtin b i -> pure (Builtin b i)
    Constant l i -> pure (Constant l i)
    Sequence e1 e2 i -> Sequence <$> f e1 <*> f e2 <*> pure i
    Conditional o i ->
      Conditional <$> traverse (plate f) o <*> pure i
    ListLit m i -> ListLit <$> traverse f m <*> pure i
    CapabilityForm cf i ->
      CapabilityForm <$> traverse f cf <*> pure i
    Try e1 e2 i ->
      Try <$> f e1 <*> f e2 <*> pure i
    ObjectLit o i ->
      ObjectLit <$> (traverse._2) f o <*> pure i
    DynInvoke n t i ->
      pure (DynInvoke n t i)
    Error e i -> pure (Error e i)

-- Todo: qualify all of these
makeLenses ''Module
makeLenses ''Interface
makeLenses ''Defun
makeLenses ''DefConst
makeLenses ''DefCap
makePrisms ''Def
makePrisms ''Term
makePrisms ''IfDef
