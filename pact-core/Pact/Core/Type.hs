{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TemplateHaskell #-}


module Pact.Core.Type
 ( PrimType(..)
 , Type(..)
 , TypeScheme(..)
 , pattern TyInt
 , pattern TyDecimal
--  , pattern TyTime
 , pattern TyBool
 , pattern TyString
 , pattern TyUnit
 , pattern TyGuard
 , pattern (:~>)
 , tyFunToArgList
 , typeOfLit
 , BuiltinTC(..)
 , Pred(..)
 , renderType
 , renderPred
 , TypeOfDef(..)
 , Arg(..)
 , argName
 , argType
 ) where

import Control.Lens
import Data.Text(Text)
import qualified Data.Text as T

import Pact.Core.Literal
import Pact.Core.Names
import Pact.Core.Pretty(Pretty(..), (<+>))

import qualified Pact.Core.Pretty as Pretty

data PrimType =
  PrimInt |
  PrimDecimal |
  -- PrimTime |
  PrimBool |
  PrimString |
  PrimGuard |
  PrimUnit
  deriving (Eq,Ord,Show, Enum, Bounded)

instance Pretty PrimType where
  pretty = \case
    PrimInt -> "integer"
    PrimDecimal -> "decimal"
    -- PrimTime -> "time"
    PrimBool -> "bool"
    PrimString -> "string"
    PrimGuard -> "guard"
    PrimUnit -> "unit"

-- Todo: caps are a bit strange here
-- same with defpacts. Not entirely sure how to type those yet.
-- | Our internal core type language
--   Tables, rows and and interfaces are quite similar,
--    t ::= B
--      |   v
--      |   t -> t
--      |   row
--      |   list<t>
--      |   interface name row
--
--    row  ::= {name:t, row*}
--    row* ::= name:t | ϵ
data Type n
  = TyVar n
  -- ^ Type variables.
  | TyPrim PrimType
  -- ^ Built-in types
  | TyFun (Type n) (Type n)
  -- ^ Row objects
  | TyList (Type n)
  -- ^ List aka [a]
  -- ^ Type of Guards.
  | TyModRef ModuleName
  -- ^ Module references
  -- TODO: remove?
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

instance Plated (Type n) where
  plate f = \case
    TyVar n -> pure (TyVar n)
    TyPrim pt -> pure (TyPrim pt)
    TyFun ty ty' -> TyFun <$> f ty <*> f ty'
    TyList ty -> TyList <$> f ty
    TyModRef mn -> pure (TyModRef mn)

pattern TyInt :: Type n
pattern TyInt = TyPrim PrimInt

pattern TyDecimal :: Type n
pattern TyDecimal = TyPrim PrimDecimal

-- pattern TyTime :: Type n
-- pattern TyTime = TyPrim PrimTime

pattern TyBool :: Type n
pattern TyBool = TyPrim PrimBool

pattern TyString :: Type n
pattern TyString = TyPrim PrimString

pattern TyUnit :: Type n
pattern TyUnit = TyPrim PrimUnit

pattern TyGuard :: Type n
pattern TyGuard = TyPrim PrimGuard

pattern (:~>) :: Type n -> Type n -> Type n
pattern l :~> r  = TyFun l r

infixr 5 :~>

-- Built in typeclasses
data BuiltinTC
  = Eq
  | Ord
  | Show
  | Add
  | Num
  | ListLike
  | Fractional
  deriving (Show, Eq, Ord)

instance Pretty BuiltinTC where
  pretty = \case
    Eq -> "Eq"
    Ord -> "Ord"
    Show -> "Show"
    Add -> "Add"
    Num -> "Num"
    ListLike -> "ListLike"
    Fractional -> "Fractional"

-- Note, no superclasses, for now
data Pred tv
  = Pred BuiltinTC (Type tv)
  deriving (Show, Eq, Functor, Foldable, Traversable)

data TypeScheme tv =
  TypeScheme [tv] [Pred tv]  (Type tv)
  deriving Show

data TypeOfDef tv
  = DefunType (Type tv)
  | DefcapType [Type tv] (Type tv)
  deriving (Show, Functor, Foldable, Traversable)

tyFunToArgList :: Type n -> ([Type n], Type n)
tyFunToArgList (TyFun l r) =
  unFun [l] r
  where
  unFun args (TyFun l' r') = unFun (l':args) r'
  unFun args ret = (reverse args, ret)
tyFunToArgList r = ([], r)

typeOfLit :: Literal -> Type n
typeOfLit = TyPrim . \case
  LString{} -> PrimString
  LInteger{} -> PrimInt
  LDecimal{} -> PrimDecimal
  LBool{} -> PrimBool
  LUnit -> PrimUnit

renderType :: (Pretty n) => Type n -> Text
renderType = T.pack . show . pretty

renderPred :: (Pretty n) => Pred n -> Text
renderPred = T.pack . show . pretty

data Arg tv
  = Arg
  { _argName :: !Text
  , _argType :: Maybe (Type tv)
  } deriving (Show, Eq)

instance Pretty n => Pretty (Pred n) where
  pretty (Pred tc ty) = pretty tc <>  Pretty.angles (pretty ty)

instance Pretty n => Pretty (Type n) where
  pretty = \case
    TyVar n -> pretty n
    TyPrim p -> pretty p
    TyGuard -> "guard"
    TyFun l r -> fnParens l <+> "->" <+> pretty r
      where
        fnParens t@TyFun{} = Pretty.parens (pretty t)
        fnParens t = pretty t
    TyList l -> "list" <+> liParens l
      where
      liParens t@TyVar{} = pretty t
      liParens t@TyPrim{} = pretty t
      liParens t = Pretty.parens (pretty t)
    TyModRef mr ->
      "module" <> Pretty.braces (pretty mr)

instance Pretty tv => Pretty (TypeScheme tv) where
  pretty (TypeScheme tvs preds ty) =
    quant tvs <> qual preds <> pretty ty
    where
    renderTvs xs suffix =
      Pretty.hsep $ fmap (\n -> Pretty.parens (pretty n <> ":" <+> suffix)) xs
    quant [] = mempty
    quant as =
      "∀" <> renderTvs as "*" <> ". "
    qual [] = mempty
    qual as =
      Pretty.parens (Pretty.commaSep as) <+> "=> "

makeLenses ''Arg
