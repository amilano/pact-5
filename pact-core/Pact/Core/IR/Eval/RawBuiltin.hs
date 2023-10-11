{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE ConstraintKinds #-}

module Pact.Core.IR.Eval.RawBuiltin
 ( rawBuiltinRuntime
 , rawBuiltinEnv ) where

-- |
-- Module      :  Pact.Core.Eval.RawBuiltin
-- Copyright   :  (C) 2022 Kadena
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Jose Cardona <jose@kadena.io>
--
-- CEK runtime for our IR term
--

import Control.Lens hiding (from, to, op)
import Control.Monad(when, unless, foldM)
import Control.Monad.IO.Class
import Data.Containers.ListUtils(nubOrd)
import Data.Bits
import Data.Foldable(foldl', traverse_)
import Data.Decimal(roundTo', Decimal)
import Data.Vector(Vector)
import Data.Maybe(isJust)
import Numeric(showIntAtBase)
import qualified Data.Vector as V
import qualified Data.Vector.Algorithms.Intro as V
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Char as Char
import qualified Data.ByteString as BS
-- import qualified Data.RAList as RAList

import Pact.Core.Builtin
import Pact.Core.Literal
import Pact.Core.Errors
import Pact.Core.Hash
import Pact.Core.Names
import Pact.Core.Guards
import Pact.Core.Type
import Pact.Core.PactValue
import Pact.Core.Persistence
import Pact.Core.Environment
import Pact.Core.Capabilities

import Pact.Core.IR.Term
import Pact.Core.IR.Eval.Runtime
import Pact.Core.IR.Eval.CEK


----------------------------------------------------------------------
-- Our builtin definitions start here
----------------------------------------------------------------------

-- -- Todo: runtime error
unaryIntFn :: (IsBuiltin b, MonadEval b i m) => (Integer -> Integer) -> NativeFunction b i m
unaryIntFn op = \info b cont handler _env -> \case
  [VLiteral (LInteger i)] -> returnCEKValue cont handler (VLiteral (LInteger (op i)))
  args -> argsError info b args
{-# INLINE unaryIntFn #-}

binaryIntFn
  :: (IsBuiltin b, MonadEval b i m)
  => (Integer -> Integer -> Integer)
  -> NativeFunction b i m
binaryIntFn op = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VLiteral (LInteger i')] -> returnCEKValue cont handler (VLiteral (LInteger (op i i')))
  args -> argsError info b args
{-# INLINE binaryIntFn #-}

roundingFn :: (IsBuiltin b, MonadEval b i m) => (Rational -> Integer) -> NativeFunction b i m
roundingFn op = \info b cont handler _env -> \case
  [VLiteral (LDecimal i)] -> returnCEKValue cont handler (VLiteral (LInteger (truncate (roundTo' op 0 i))))
  args -> argsError info b args
{-# INLINE roundingFn #-}

---------------------------------
-- Arithmetic Ops
------------------------------
rawAdd :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawAdd = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VLiteral (LInteger i')] -> returnCEKValue cont handler (VLiteral (LInteger (i + i')))
  [VLiteral (LDecimal i), VLiteral (LDecimal i')] -> returnCEKValue cont handler (VLiteral (LDecimal (i + i')))
  [VLiteral (LString i), VLiteral (LString i')] ->
    returnCEKValue cont handler  (VLiteral (LString (i <> i')))
  [VObject l, VObject r] ->
    let o' = VObject (l `M.union` r)
    in returnCEKValue cont handler o'
  [VList l, VList r] -> returnCEKValue cont handler (VList (l <> r))
  args -> argsError info b args

rawSub :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawSub = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VLiteral (LInteger i')] -> returnCEKValue cont handler (VLiteral (LInteger (i - i')))
  [VLiteral (LDecimal i), VLiteral (LDecimal i')] -> returnCEKValue cont handler (VLiteral (LDecimal (i - i')))
  args -> argsError info b args

rawMul :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawMul = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VLiteral (LInteger i')] -> returnCEKValue cont handler (VLiteral (LInteger (i * i')))
  [VLiteral (LDecimal i), VLiteral (LDecimal i')] -> returnCEKValue cont handler (VLiteral (LDecimal (i * i')))
  args -> argsError info b args

rawPow :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawPow = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VLiteral (LInteger i')] -> do
    when (i' < 0) $ throwExecutionError info (ArithmeticException "negative exponent in integer power")
    returnCEKValue cont handler (VLiteral (LInteger (i ^ i')))
  [VLiteral (LDecimal l), VLiteral (LDecimal r)] -> do
    let result = dec2F l ** dec2F r
    guardNanOrInf info result
    returnCEKValue cont handler (VLiteral (LDecimal (f2Dec result)))
  args -> argsError info b args

rawLogBase :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawLogBase = \info b cont handler _env -> \case
  [VLiteral (LInteger base), VLiteral (LInteger n)] -> do
    when (base < 0 || n <= 0) $ throwExecutionError info (ArithmeticException "Illegal log base")
    let base' = fromIntegral base :: Double
        n' = fromIntegral n
        out = round (logBase base' n')
    returnCEKValue cont handler (VLiteral (LInteger out))
    -- if i' == 0 then throwExecutionError' (ArithmeticException "div by zero")
    -- else returnCEKValue cont handler (VLiteral (LInteger (div i i')))
  [VLiteral (LDecimal base), VLiteral (LDecimal arg)] -> do
    when (base < 0 || arg <= 0) $ throwExecutionError info (ArithmeticException "Invalid base or argument in log")
    let result = logBase (dec2F base) (dec2F arg)
    guardNanOrInf info result
    returnCEKValue cont handler (VLiteral (LDecimal (f2Dec result)))
  args -> argsError info b args

rawDiv :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawDiv = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VLiteral (LInteger i')] ->
    if i' == 0 then throwExecutionError info (ArithmeticException "div by zero")
    else returnCEKValue cont handler (VLiteral (LInteger (div i i')))
  [VLiteral (LDecimal i), VLiteral (LDecimal i')] ->
    if i' == 0 then throwExecutionError info (ArithmeticException "div by zero, decimal")
    else returnCEKValue cont handler (VLiteral (LDecimal (i / i')))
  args -> argsError info b args

rawNegate :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawNegate = \info b cont handler _env -> \case
  [VLiteral (LInteger i)] ->
    returnCEKValue cont handler (VLiteral (LInteger (negate i)))
  [VLiteral (LDecimal i)] ->
    returnCEKValue cont handler (VLiteral (LDecimal (negate i)))
  args -> argsError info b args

rawEq :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawEq = \info b cont handler _env -> \case
  [VPactValue pv, VPactValue pv'] -> returnCEKValue cont handler (VBool (pv == pv'))
  args -> argsError info b args

modInt :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
modInt = binaryIntFn mod

rawNeq :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawNeq = \info b cont handler _env -> \case
  [VPactValue pv, VPactValue pv'] ->
    returnCEKValue cont handler (VBool (pv /= pv'))
  args -> argsError info b args

rawGt :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawGt = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VLiteral (LInteger i')] -> returnCEKValue cont handler (VLiteral (LBool (i > i')))
  [VLiteral (LDecimal i), VLiteral (LDecimal i')] -> returnCEKValue cont handler (VLiteral (LBool (i > i')))
  [VLiteral (LString i), VLiteral (LString i')] -> returnCEKValue cont handler (VLiteral (LBool (i > i')))
  args -> argsError info b args

rawLt :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawLt = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VLiteral (LInteger i')] -> returnCEKValue cont handler (VLiteral (LBool (i < i')))
  [VLiteral (LDecimal i), VLiteral (LDecimal i')] -> returnCEKValue cont handler (VLiteral (LBool (i < i')))
  [VLiteral (LString i), VLiteral (LString i')] -> returnCEKValue cont handler (VLiteral (LBool (i < i')))
  args -> argsError info b args

rawGeq :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawGeq = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VLiteral (LInteger i')] -> returnCEKValue cont handler (VLiteral (LBool (i >= i')))
  [VLiteral (LDecimal i), VLiteral (LDecimal i')] -> returnCEKValue cont handler (VLiteral (LBool (i >= i')))
  [VLiteral (LString i), VLiteral (LString i')] -> returnCEKValue cont handler (VLiteral (LBool (i >= i')))
  args -> argsError info b args

rawLeq :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawLeq = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VLiteral (LInteger i')] -> returnCEKValue cont handler (VLiteral (LBool (i <= i')))
  [VLiteral (LDecimal i), VLiteral (LDecimal i')] -> returnCEKValue cont handler (VLiteral (LBool (i <= i')))
  [VLiteral (LString i), VLiteral (LString i')] -> returnCEKValue cont handler (VLiteral (LBool (i <= i')))
  args -> argsError info b args

bitAndInt :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
bitAndInt = binaryIntFn (.&.)

bitOrInt :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
bitOrInt = binaryIntFn (.|.)

bitComplementInt :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
bitComplementInt = unaryIntFn complement

bitXorInt :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
bitXorInt = binaryIntFn xor

bitShiftInt :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
bitShiftInt =  binaryIntFn (\i s -> shift i (fromIntegral s))

rawAbs :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawAbs = \info b cont handler _env -> \case
  [VLiteral (LInteger i)] ->
    returnCEKValue cont handler (VLiteral (LInteger (abs i)))
  [VLiteral (LDecimal e)] -> do
    returnCEKValue cont handler (VLiteral (LDecimal (abs e)))
  args -> argsError info b args

rawExp :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawExp = \info b cont handler _env -> \case
  [VLiteral (LInteger i)] -> do
    let result = exp (fromIntegral i)
    guardNanOrInf info result
    returnCEKValue cont handler (VLiteral (LDecimal (f2Dec result)))
  [VLiteral (LDecimal e)] -> do
    let result = exp (dec2F e)
    guardNanOrInf info result
    returnCEKValue cont handler (VLiteral (LDecimal (f2Dec result)))
  args -> argsError info b args

rawLn :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawLn = \info b cont handler _env -> \case
  [VLiteral (LInteger i)] -> do
    let result = log (fromIntegral i)
    guardNanOrInf info result
    returnCEKValue cont handler (VLiteral (LDecimal (f2Dec result)))
  [VLiteral (LDecimal e)] -> do
    let result = log (dec2F e)
    guardNanOrInf info result
    returnCEKValue cont handler (VLiteral (LDecimal (f2Dec result)))
  args -> argsError info b args

rawSqrt :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawSqrt = \info b cont handler _env -> \case
  [VLiteral (LInteger i)] -> do
    when (i < 0) $ throwExecutionError info (ArithmeticException "Square root must be non-negative")
    let result = sqrt (fromIntegral i)
    guardNanOrInf info result
    returnCEKValue cont handler (VLiteral (LDecimal (f2Dec result)))
  [VLiteral (LDecimal e)] -> do
    when (e < 0) $ throwExecutionError info (ArithmeticException "Square root must be non-negative")
    let result = sqrt (dec2F e)
    guardNanOrInf info result
    returnCEKValue cont handler (VLiteral (LDecimal (f2Dec result)))
  args -> argsError info b args

-- Todo: fix all show instances
rawShow :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawShow = \info b cont handler _env -> \case
  [VLiteral (LInteger i)] ->
    returnCEKValue cont handler (VLiteral (LString (T.pack (show i))))
  [VLiteral (LDecimal i)] ->
    returnCEKValue cont handler (VLiteral (LString (T.pack (show i))))
  [VLiteral (LString i)] ->
    returnCEKValue cont handler (VLiteral (LString (T.pack (show i))))
  [VLiteral (LBool i)] ->
    returnCEKValue cont handler (VLiteral (LString (T.pack (show i))))
  [VLiteral LUnit] ->
    returnCEKValue cont handler (VLiteral (LString "()"))
  args -> argsError info b args

rawContains :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawContains = \info b cont handler _env -> \case
  [VString f, VObject o] ->
    returnCEKValue cont handler (VBool (M.member (Field f) o))
  [VString s, VString s'] ->
    returnCEKValue cont handler (VBool (s `T.isInfixOf` s'))
  [VPactValue v, VList vli] ->
    returnCEKValue cont handler (VBool (v `V.elem` vli))
  args -> argsError info b args

rawSort :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawSort = \info b cont handler _env -> \case
  [VList vli]
    | V.null vli -> returnCEKValue cont handler (VList mempty)
    | otherwise -> do
    vli' <- liftIO $ do
      v' <- V.thaw vli
      V.sort v'
      V.freeze v'
    returnCEKValue cont handler (VList vli')
  args -> argsError info b args

rawRemove :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawRemove = \info b cont handler _env -> \case
  [VString s, VObject o] -> returnCEKValue cont handler (VObject (M.delete (Field s) o))
  args -> argsError info b args

asObject
  :: (MonadEval b i m, IsBuiltin b)
  => i
  -> b
  -> PactValue
  -> m (M.Map Field PactValue)
asObject info b = \case
  PObject o -> pure o
  arg -> argsError info b [VPactValue arg]

rawSortObject :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawSortObject = \info b cont handler _env -> \case
  [VList fields, VList objs]
    | V.null fields -> returnCEKValue cont handler (VList objs)
    | V.null objs -> returnCEKValue cont handler (VList objs)
    | otherwise -> do
        objs' <- traverse (asObject info b) objs
        fields' <- traverse (fmap Field . asString info b) fields
        v' <- liftIO $ do
          mobjs <- V.thaw objs'
          V.sortBy (sort fields') mobjs
          V.freeze mobjs
        returnCEKValue cont handler (VList (PObject <$> v'))
    where
    sort fs o o' =
      foldr go EQ fs
      where
      go field EQ = case (,) <$> M.lookup field o <*> M.lookup field o' of
        Just (PLiteral l1, PLiteral l2) -> l1 `compare` l2
        _ -> EQ
      go _ ne = ne
  args -> argsError info b args


-- -------------------------
-- double ops
-- -------------------------

guardNanOrInf :: MonadEval b i m => i -> Double -> m ()
guardNanOrInf info a =
  when (isNaN a || isInfinite a) $ throwExecutionError info (FloatingPointError "Floating operation resulted in Infinity or NaN")

dec2F :: Decimal -> Double
dec2F = fromRational . toRational

f2Dec :: Double -> Decimal
f2Dec = fromRational . toRational

roundDec :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
roundDec = roundingFn round

floorDec :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
floorDec = roundingFn floor

ceilingDec :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
ceilingDec = roundingFn ceiling

---------------------------
-- bool ops
---------------------------
notBool :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
notBool = \info b cont handler _env -> \case
  [VLiteral (LBool i)] -> returnCEKValue cont handler  (VLiteral (LBool (not i)))
  args -> argsError info b args

---------------------------
-- string ops
---------------------------

rawTake :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawTake = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VLiteral (LString t)]
    | i >= 0 -> do
      let clamp = min (fromIntegral i) (T.length t)
      returnCEKValue cont handler  (VLiteral (LString (T.take clamp t)))
    | otherwise -> do
      let clamp = min (abs (T.length t + fromIntegral i)) (T.length t)
      returnCEKValue cont handler  (VLiteral (LString (T.drop clamp t)))
  [VLiteral (LInteger i), VList li]
    | i >= 0 -> do
      let clamp = fromIntegral $ min i (fromIntegral (V.length li))
      returnCEKValue cont handler  (VList (V.take clamp li))
    | otherwise -> do
      let clamp = fromIntegral $ max (fromIntegral (V.length li) + i) 0
      returnCEKValue cont handler (VList (V.drop clamp li))
  args -> argsError info b args

rawDrop :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawDrop = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VLiteral (LString t)]
    | i >= 0 -> do
      let clamp = min (fromIntegral i) (T.length t)
      returnCEKValue cont handler  (VLiteral (LString (T.drop clamp t)))
    | otherwise -> do
      let clamp = min (abs (T.length t + fromIntegral i)) (T.length t)
      returnCEKValue cont handler  (VLiteral (LString (T.take clamp t)))
  [VLiteral (LInteger i), VList li]
    | i >= 0 -> do
      let clamp = fromIntegral $ min i (fromIntegral (V.length li))
      returnCEKValue cont handler  (VList (V.drop clamp li))
    | otherwise -> do
      let clamp = fromIntegral $ max (fromIntegral (V.length li) + i) 0
      returnCEKValue cont handler (VList (V.take clamp li))
  args -> argsError info b args

rawLength :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawLength = \info b cont handler _env -> \case
  [VLiteral (LString t)] -> do
    returnCEKValue cont handler  (VLiteral (LInteger (fromIntegral (T.length t))))
  [VList li] -> returnCEKValue cont handler (VLiteral (LInteger (fromIntegral (V.length li))))
  args -> argsError info b args

rawReverse :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
rawReverse = \info b cont handler _env -> \case
  [VList li] ->
    returnCEKValue cont handler (VList (V.reverse li))
  [VLiteral (LString t)] -> do
    returnCEKValue cont handler  (VLiteral (LString (T.reverse t)))
  args -> argsError info b args

coreConcat :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreConcat = \info b cont handler _env -> \case
  [VList li] -> do
    li' <- traverse (asString info b) li
    returnCEKValue cont handler (VString (T.concat (V.toList li')))
  args -> argsError info b args

strToList :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
strToList = \info b cont handler _env -> \case
  [VLiteral (LString s)] -> do
    let v = VList (V.fromList (PLiteral . LString . T.singleton <$> T.unpack s))
    returnCEKValue cont handler v
  args -> argsError info b args


zipList :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
zipList = \info b cont handler _env -> \case
  [VClosure clo, VList l, VList r] -> zip' (V.toList l) (V.toList r) []
    where
    zip' (x:xs) (y:ys) acc = unsafeApplyTwo clo (VPactValue x) (VPactValue y) >>= \case
       EvalValue v -> enforcePactValue v >>= zip' xs ys . (:acc)
       v@VError{} -> returnCEK cont handler v
    zip' _ _ acc = returnCEKValue cont handler (VList (V.fromList (reverse acc)))
  args -> argsError info b args

-- (try [1] (map (+ 1) [1 2 (enforce false "greg")])
coreMap :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreMap = \info b cont handler _env -> \case
  [VClosure fn, VList li] -> map' (V.toList li) []
    where
    map' (x:xs) acc = applyLam fn [VPactValue x] Mt CEKNoHandler >>= \case
       EvalValue cv -> enforcePactValue cv >>= map' xs . (:acc)
       v@VError{} -> returnCEK cont handler v
    map' _ acc = returnCEKValue cont handler (VList (V.fromList (reverse acc)))
  args -> argsError info b args

coreFilter :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreFilter = \info b cont handler _env -> \case
  [VClosure fn, VList li] -> filter' (V.toList li) []
    where
    filter' (x:xs) acc = unsafeApplyOne fn (VPactValue x) >>= \case
      EvalValue (VLiteral (LBool b')) ->
        if b' then filter' xs (x:acc) else filter' xs acc
      EvalValue v -> argsError info b [v]
      v@VError{} ->
        returnCEK cont handler v
    filter' [] acc = returnCEKValue cont handler (VList (V.fromList (reverse acc)))
  args -> argsError info b args

coreFold :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreFold = \info b cont handler _env -> \case
  [VClosure fn, initElem, VList li] ->
    fold' initElem (V.toList li)
    where
    fold' e (x:xs) = unsafeApplyTwo fn e (VPactValue x) >>= \case
      EvalValue v -> fold' v xs
      v -> returnCEK cont handler v
    fold' e [] = returnCEKValue cont handler e
  args -> argsError info b args

coreEnumerate :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreEnumerate = \info b cont handler _env -> \case
  [VLiteral (LInteger from), VLiteral (LInteger to)] -> do
    v <- createEnumerateList info from to (if from > to then -1 else 1)
    returnCEKValue cont handler (VList (PLiteral . LInteger <$> v))
  args -> argsError info b args

createEnumerateList
  :: (MonadEval b i m)
  => i
  -> Integer
  -- ^ from
  -> Integer
  -- ^ to
  -> Integer
  -- ^ Step
  -> m (Vector Integer)
createEnumerateList info from to inc
  | from == to = pure (V.singleton from)
  | inc == 0 = pure mempty
  | from < to, from + inc < from =
    throwExecutionError info (EnumerationError "enumerate: increment diverges below from interval bounds.")
  | from > to, from + inc > from =
    throwExecutionError info (EnumerationError "enumerate: increment diverges above from interval bounds.")
  | otherwise = let
    step = succ (abs (from - to) `div` abs inc)
    in pure $ V.enumFromStepN from inc (fromIntegral step)

coreEnumerateStepN :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreEnumerateStepN = \info b cont handler _env -> \case
  [VLiteral (LInteger from), VLiteral (LInteger to), VLiteral (LInteger inc)] -> do
    v <- createEnumerateList info from to inc
    returnCEKValue cont handler (VList (PLiteral . LInteger <$> v))
  args -> argsError info b args

-- concatList :: (IsBuiltin b, MonadEval b i m) => b -> NativeFn b i m
-- concatList = \info b cont handler env -> \case
--   [VList li] -> do
--     li' <- traverse asList li
--     returnCEKValue cont handler (VList (V.concat (V.toList li')))
--   _ -> failInvariant "takeList"

makeList :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
makeList = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VPactValue v] -> do
    returnCEKValue cont handler (VList (V.fromList (replicate (fromIntegral i) v)))
  args -> argsError info b args

coreAccess :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreAccess = \info b cont handler _env -> \case
  [VLiteral (LInteger i), VList vec] ->
    case vec V.!? fromIntegral i of
      Just v -> returnCEKValue cont handler (VPactValue v)
      _ -> throwExecutionError info (ArrayOutOfBoundsException (V.length vec) (fromIntegral i))
  [VString field, VObject o] ->
    case M.lookup (Field field) o of
      Just v -> returnCEKValue cont handler (VPactValue v)
      Nothing ->
        let msg = "Object does not have field: " <> field
        in returnCEK cont handler (VError msg)
  args -> argsError info b args

-----------------------------------
-- try-related ops
-----------------------------------

coreEnforce :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreEnforce = \info b cont handler _env -> \case
  [VLiteral (LBool b'), VLiteral (LString s)] ->
    if b' then returnCEKValue cont handler (VLiteral LUnit)
    else returnCEK cont handler (VError s)
  args -> argsError info b args


-----------------------------------
-- Guards and reads
-----------------------------------


-----------------------------------
-- Other Core forms
-----------------------------------

coreB64Encode :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreB64Encode = \info b cont handler _env -> \case
  [VLiteral (LString l)] ->
    returnCEKValue cont handler $ VLiteral $ LString $ toB64UrlUnpaddedText $ T.encodeUtf8 l
  args -> argsError info b args


coreB64Decode :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreB64Decode = \info b cont handler _env -> \case
  [VLiteral (LString s)] -> case fromB64UrlUnpaddedText $ T.encodeUtf8 s of
    Left{} -> throwExecutionError info (DecodeError "invalid b64 encoding")
    Right txt -> returnCEKValue cont handler (VLiteral (LString txt))
  args -> argsError info b args

coreEnforceGuard :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreEnforceGuard = \info b cont handler env -> \case
  [VGuard g] -> case g of
      GKeyset ks -> do
        cond <- enforceKeyset ks
        if cond then returnCEKValue cont handler VUnit
        else returnCEK cont handler (VError "enforce keyset failure")
      GKeySetRef ksn -> do
        cond <- enforceKeysetName info env ksn
        if cond then returnCEKValue cont handler VUnit
        else returnCEK cont handler (VError "enforce keyset failure")
      GUserGuard ug -> runUserGuard info cont handler env ug
      GCapabilityGuard cg -> enforceCapGuard cont handler cg
      GModuleGuard (ModuleGuard mn _) -> calledByModule mn >>= \case
        True -> returnCEKValue cont handler VUnit
        False -> do
          md <- getModule info env mn
          acquireModuleAdmin info env md
          returnCEKValue cont handler VUnit
  args -> argsError info b args

keysetRefGuard :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
keysetRefGuard = \info b cont handler _env -> \case
  [VString g] ->
    returnCEKValue cont handler (VGuard (GKeySetRef (KeySetName g)))
  args -> argsError info b args

coreReadInteger :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreReadInteger = \info b cont handler _env -> \case
  [VString s] -> do
    EnvData envData <- viewCEKEnv eeMsgBody
    case M.lookup (Field s) envData of
      Just (PInteger p) -> returnCEKValue cont handler (VInteger p)
      _ -> returnCEK cont handler (VError "read-integer failure")
  args -> argsError info b args

coreReadDecimal :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreReadDecimal = \info b cont handler _env -> \case
  [VString s] -> do
    EnvData envData <- viewCEKEnv eeMsgBody
    case M.lookup (Field s) envData of
      Just (PDecimal p) -> returnCEKValue cont handler (VDecimal p)
      _ -> returnCEK cont handler (VError "read-integer failure")
  args -> argsError info b args

coreReadString :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreReadString = \info b cont handler _env -> \case
  [VString s] -> do
    EnvData envData <- viewCEKEnv eeMsgBody
    case M.lookup (Field s) envData of
      Just (PString p) -> returnCEKValue cont handler (VString p)
      _ -> returnCEK cont handler (VError "read-integer failure")
  args -> argsError info b args

readKeyset' :: (MonadEval b i m) => T.Text -> m (Maybe (KeySet FullyQualifiedName))
readKeyset' ksn = do
    EnvData envData <- viewCEKEnv eeMsgBody
    case M.lookup (Field ksn) envData of
      Just (PObject dat) -> parseObj dat
        where
        parseObj d = pure $ do
          keys <- M.lookup (Field "keys") d
          keyText <- preview _PList keys >>= traverse (fmap PublicKeyText . preview (_PLiteral . _LString))
          predRaw <- M.lookup (Field "pred") d
          p <- preview (_PLiteral . _LString) predRaw
          pred' <- readPredicate p
          let ks = S.fromList (V.toList keyText)
          pure (KeySet ks pred')
        readPredicate = \case
          "keys-any" -> pure KeysAny
          "keys-2" -> pure Keys2
          "keys-all" -> pure KeysAll
          _ -> Nothing
      Just (PList li) ->
        case parseKeyList li of
          Just ks -> pure (Just (KeySet ks KeysAll))
          Nothing -> pure Nothing
        where
        parseKeyList d =
          S.fromList . V.toList . fmap PublicKeyText <$> traverse (preview (_PLiteral . _LString)) d
      _ -> pure Nothing


coreReadKeyset :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreReadKeyset = \info b cont handler _env -> \case
  [VString ksn] ->
    readKeyset' ksn >>= \case
      Just ks -> returnCEKValue cont handler (VGuard (GKeyset ks))
      Nothing -> returnCEK cont handler (VError "read-keyset failure")
    -- EnvData envData <- viewCEKEnv eeMsgBody
    -- case M.lookup (Field s) envData of
    --   Just (PObject dat) ->
    --     case parseObj dat of
    --       Just (ks, p) -> returnCEKValue cont handler (VGuard (GKeyset (KeySet ks p)))
    --       Nothing -> returnCEK cont handler (VError "read-keyset failure")
    --     where
    --     parseObj d = do
    --       keys <- M.lookup (Field "keys") d
    --       keyText <- preview _PList keys >>= traverse (fmap PublicKeyText . preview (_PLiteral . _LString))
    --       predRaw <- M.lookup (Field "pred") d
    --       p <- preview (_PLiteral . _LString) predRaw
    --       (S.fromList (V.toList keyText),) <$> readPredicate p
    --     readPredicate = \case
    --       "keys-any" -> pure KeysAny
    --       "keys-2" -> pure Keys2
    --       "keys-all" -> pure KeysAll
    --       _ -> Nothing
    --   Just (PList li) ->
    --     case parseKeyList li of
    --       Just ks -> returnCEKValue cont handler (VGuard (GKeyset (KeySet ks KeysAll)))
    --       Nothing -> returnCEK cont handler (VError "read-keyset failure")
    --     where
    --     parseKeyList d =
    --       S.fromList . V.toList . fmap PublicKeyText <$> traverse (preview (_PLiteral . _LString)) d
    --   _ -> returnCEK cont handler (VError "read-keyset failure")
  args -> argsError info b args

enforceCapGuard
  :: MonadEval b i m
  => Cont b i m
  -> CEKErrorHandler b i m
  -> CapabilityGuard FullyQualifiedName PactValue
  -> m (EvalResult b i m)
enforceCapGuard cont handler (CapabilityGuard fqn args) = do
  let ct = CapToken (fqnToQualName fqn) args
  caps <- useEvalState (esCaps.csSlots)
  let csToSet cs = S.insert (_csCap cs) (S.fromList (_csComposed cs))
      capSet = foldMap csToSet caps
  if S.member ct capSet then returnCEKValue cont handler VUnit
  else do
    let errMsg = "Capability guard enforce failure cap not in scope: " <> renderFullyQualName fqn
    returnCEK cont handler (VError errMsg)

runUserGuard
  :: MonadEval b i m
  => i
  -> Cont b i m
  -> CEKErrorHandler b i m
  -> CEKEnv b i m
  -> UserGuard FullyQualifiedName PactValue
  -> m (EvalResult b i m)
runUserGuard info cont handler env (UserGuard fqn args) =
  lookupFqName fqn >>= \case
    Just (Dfun d) -> do
      when (length (_dfunArgs d) /= length args) $ throwExecutionError info CannotApplyPartialClosure
      let env' = sysOnlyEnv env
      clo <- mkDefunClosure d (_fqModule fqn) env'
      -- clo <- ugTerm env' (_dfunTerm d)
          -- clo = Closure (_dfunName d) (_fqModule fqn) cloargs (NE.length cloargs) (_dfunTerm d) (_dfunRType d) env' (_dfunInfo d)
      -- Todo: sys only here
      applyLam (C clo) (VPactValue <$> args) cont handler
    Just d -> throwExecutionError info (InvalidDefKind (defKind d) "run-user-guard")
    Nothing -> throwExecutionError info (NameNotInScope fqn)

coreBind :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreBind = \info b cont handler _env -> \case
  [v@VObject{}, VClosure clo] ->
    applyLam clo [v] cont handler
  args -> argsError info b args


--------------------------------------------------
-- Db functions
--------------------------------------------------

createTable :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
createTable = \info b cont handler env -> \case
  [VTable tv@(TableValue tn mn _ _)] -> do
    guardTable info env tv
    let pdb = view cePactDb env
    -- Todo: error handling here
    -- Todo: guard table
    liftDbFunction info (_pdbCreateUserTable pdb tn mn)
    returnCEKValue cont handler VUnit
  args -> argsError info b args

dbSelect :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
dbSelect = \info b cont handler env -> \case
  [VTable tv, VClosure clo] -> do
    let pdb = view cePactDb env
    guardTable info env tv
    ks <- liftDbFunction info (_pdbKeys pdb (tvToDomain tv))
    go pdb ks []
    where
    go _ [] acc = returnCEKValue cont handler (VList (V.fromList (reverse acc)))
    go pdb (k:ks) acc = do
      liftDbFunction info (_pdbRead pdb (tvToDomain tv) k) >>= \case
        Just (RowData rdata) -> applyLam clo [VObject rdata] cont handler >>= \case
          EvalValue (VBool cond) ->
            if cond then go pdb ks (PObject rdata:acc) else go pdb ks acc
          EvalValue _ -> returnCEK cont handler (VError "select query error")
          VError e -> returnCEK cont handler (VError e)
        Nothing -> returnCEK cont handler (VError "select is not enabled")

  args -> argsError info b args

-- Todo: error handling
foldDb :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
foldDb = \info b cont handler env -> \case
  [VTable tv, VClosure queryClo, VClosure consumer] -> do
    let pdb = view cePactDb env
    guardTable info env tv
    let tblDomain = DUserTables (_tvName tv)
    keys <- liftDbFunction info (_pdbKeys pdb tblDomain)
    go pdb [] keys
    where
      -- todo: weird key invariant
      go pdb acc (rk@(RowKey k):ks) = do
        liftDbFunction info (_pdbRead pdb (DUserTables (_tvName tv)) rk) >>= \case
          Just (RowData row) -> do
            applyLam queryClo [VString k, VObject row] Mt CEKNoHandler >>= \case
              EvalValue (VBool qry) -> if qry then do
                applyLam consumer [VString k, VObject row] Mt CEKNoHandler >>= \case
                  EvalValue (VPactValue v) -> go pdb (v:acc) ks
                  EvalValue _ -> error "Fold db did not return a pact value"
                  v -> returnCEK cont handler v
                else go pdb acc ks
              EvalValue _ -> error "Folddb query was not a boolean"
              v@VError{} -> returnCEK cont handler v
          Nothing -> error "no key despite keys"
      go _ acc [] =
        returnCEKValue cont handler (VList (V.fromList (reverse acc)))
  args -> argsError info b args

dbRead :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
dbRead = \info b cont handler env -> \case
  [VTable tv, VString k] -> do
    let pdb = view cePactDb env
    guardTable info env tv
    liftDbFunction info (_pdbRead pdb (DUserTables (_tvName tv)) (RowKey k)) >>= \case
      Just (RowData v) -> returnCEKValue cont handler (VObject v)
      Nothing -> returnCEK cont handler (VError "no such read object")
  args -> argsError info b args

dbWithRead :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
dbWithRead = \info b cont handler env -> \case
  [VTable tv, VString k, VClosure clo] -> do
    let pdb = view cePactDb env
    guardTable info env tv
    liftDbFunction info (_pdbRead pdb (DUserTables (_tvName tv)) (RowKey k)) >>= \case
      Just (RowData v) -> applyLam clo [VObject v] cont handler
      Nothing -> returnCEK cont handler (VError "no such read object")
  args -> argsError info b args

dbWithDefaultRead :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
dbWithDefaultRead = \info b cont handler env -> \case
  [VTable tv, VString k, VObject defaultObj, VClosure clo] -> do
    let pdb = view cePactDb env
    guardTable info env tv
    liftDbFunction info (_pdbRead pdb (DUserTables (_tvName tv)) (RowKey k)) >>= \case
      Just (RowData v) -> applyLam clo [VObject v] cont handler
      Nothing -> applyLam clo [VObject defaultObj] cont handler
  args -> argsError info b args

-- | Todo: schema checking here? Or only on writes?
dbWrite :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
dbWrite = write' Write

dbInsert :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
dbInsert = write' Insert

write' :: (IsBuiltin b, MonadEval b i m) => WriteType -> NativeFunction b i m
write' wt = \info b cont handler env -> \case
  [VTable tv, VString key, VObject o] -> do
    guardTable info env tv
    if checkSchema o (_tvSchema tv) then do
        let pdb = view cePactDb env
        let rowData = RowData o
        liftDbFunction info (_pdbWrite pdb wt (tvToDomain tv) (RowKey key) rowData)
        returnCEKValue cont handler (VString "Write succeeded")
    else
        returnCEK cont handler (VError "object does not match schema")
  args -> argsError info b args

dbUpdate :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
dbUpdate = \info b cont handler env -> \case
  [VTable tv, VString key, VObject o] -> do
    guardTable info env tv
    if checkPartialSchema o (_tvSchema tv) then do
        let pdb = view cePactDb env
        let rowData = RowData o
        liftDbFunction info (_pdbWrite pdb Update (tvToDomain tv) (RowKey key) rowData)
        returnCEKValue cont handler (VString "Write succeeded")
    else returnCEK cont handler (VError "object does not match schema")
  args -> argsError info b args

dbKeys :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
dbKeys = \info b cont handler env -> \case
  [VTable tv] -> do
    guardTable info env tv
    let pdb = view cePactDb env
    ks <- liftDbFunction info (_pdbKeys pdb (tvToDomain tv))
    let li = V.fromList (PString . _rowKey <$> ks)
    returnCEKValue cont handler (VList li)
  args -> argsError info b args

dbTxIds :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
dbTxIds = \info b cont handler env -> \case
  [VTable tv, VInteger tid] -> do
    guardTable info env tv
    let pdb = view cePactDb env
    ks <- liftDbFunction info (_pdbTxIds pdb (_tvName tv) (TxId (fromIntegral tid)))
    let li = V.fromList (PInteger . fromIntegral . _txId <$> ks)
    returnCEKValue cont handler (VList li)
  args -> argsError info b args


dbTxLog :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
dbTxLog = \info b cont handler env -> \case
  [VTable tv, VInteger tid] -> do
    guardTable info env tv
    let pdb = view cePactDb env
        txId = TxId (fromInteger tid)
    ks <- liftDbFunction info (_pdbGetTxLog pdb (_tvName tv) txId)
    let li = V.fromList (txLogToObj <$> ks)
    returnCEKValue cont handler (VList li)
    where
    txLogToObj (TxLog domain key (RowData v)) = do
      PObject $ M.fromList
        [ (Field "table", PString domain)
        , (Field "key", PString key)
        , (Field "value", PObject v)]
  args -> argsError info b args

tvToDomain :: TableValue -> Domain RowKey RowData b i
tvToDomain tv =
  DUserTables(_tvName tv)

-- | Todo: isProperSubmapOf
checkSchema :: M.Map Field PactValue -> Schema -> Bool
checkSchema o (Schema sc) = isJust $ do
  let keys = M.keys o
  when (keys /= M.keys sc) $ Nothing
  traverse_ go (M.toList o)
  where
  go (k, v) = M.lookup k sc >>= (`checkPvType` v)

checkPartialSchema :: M.Map Field PactValue -> Schema -> Bool
checkPartialSchema o (Schema sc) =
  M.isSubmapOfBy (\obj ty -> isJust (checkPvType ty obj)) o sc

defineKeySet'
  :: (MonadEval b i m)
  => i
  -> Cont b i m
  -> CEKErrorHandler b i m
  -> CEKEnv b i m
  -> T.Text
  -> KeySet FullyQualifiedName
  -> m (EvalResult b i m)
defineKeySet' info cont handler env ksname newKs  = do
  let pdb = view cePactDb env
  liftDbFunction info (_pdbRead pdb DKeySets (KeySetName ksname)) >>= \case
    Just oldKs -> do
      cond <- enforceKeyset oldKs
      if cond then do
          liftDbFunction info (_pdbWrite pdb Write DKeySets (KeySetName ksname) newKs)
          returnCEKValue cont handler (VString "Keyset write success")
      else returnCEK cont handler (VError "enforce keyset failure")
    Nothing -> do
      liftDbFunction info (_pdbWrite pdb Write DKeySets (KeySetName ksname) newKs)
      returnCEKValue cont handler (VString "Keyset write success")

defineKeySet :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
defineKeySet = \info b cont handler env -> \case
  [VString ksname, VGuard (GKeyset ks)] ->
    defineKeySet' info cont handler env ksname ks
  [VString ksname] ->
    readKeyset' ksname >>= \case
      Just newKs ->
        defineKeySet' info cont handler env ksname newKs
      Nothing -> returnCEK cont handler (VError "read-keyset failure")
  args -> argsError info b args

--------------------------------------------------
-- Capabilities
--------------------------------------------------

requireCapability :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
requireCapability = \info b cont handler _env -> \case
  [VCapToken ct] -> requireCap cont handler ct
  args -> argsError info b args

composeCapability :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
composeCapability = \info b cont handler env -> \case
  [VCapToken ct] -> composeCap cont handler env ct
  args -> argsError info b args

installCapability :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
installCapability = \info b cont handler _env -> \case
  [VCapToken ct] -> do
    _ <- installCap ct
    returnCEKValue cont handler VUnit
  args -> argsError info b args

coreEmitEvent :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreEmitEvent = \info b cont handler _env -> \case
  [VCapToken ct] -> emitEvent cont handler ct
  args -> argsError info b args

createCapGuard :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
createCapGuard = \info b cont handler _env -> \case
  [VCapToken ct] ->
    let cg = CapabilityGuard (_ctName ct) (_ctArgs ct)
    in returnCEKValue cont handler (VGuard (GCapabilityGuard cg))
  args -> argsError info b args

createModuleGuard :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
createModuleGuard = \info b cont handler _env -> \case
  [VString n] ->
    findCallingModule >>= \case
      Just mn ->  do
        let cg = GModuleGuard (ModuleGuard mn n)
        returnCEKValue cont handler (VGuard cg)
      Nothing ->
        returnCEK cont handler (VError "not-in-module")
  args -> argsError info b args


coreIntToStr :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreIntToStr = \info b cont handler _env -> \case
  [VInteger base, VInteger v]
    | base >= 2 && base <= 16 -> do
      let v' = T.pack $ showIntAtBase base Char.intToDigit v ""
      returnCEKValue cont handler (VString v')
    | base == 64 && v >= 0 -> do
      let v' = toB64UrlUnpaddedText $ integerToBS v
      returnCEKValue cont handler (VString v')
    | base == 64 -> returnCEK cont handler (VError "only positive values allowed for base64URL conversion")
    | otherwise -> returnCEK cont handler (VError "invalid base for base64URL conversion")
  args -> argsError info b args

coreStrToInt :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreStrToInt = \info b cont handler _env -> \case
  [VString s] ->
    checkLen info s *> doBase info cont handler 10 s
  args -> argsError info b args

coreStrToIntBase :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreStrToIntBase = \info b _ _ _env -> \case
  [VInteger _base, VString _s] -> error "todo: base64"
  args -> argsError info b args

coreDistinct  :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreDistinct = \info b cont handler _env -> \case
  [VList s] ->
    returnCEKValue cont handler
      $ VList
      $ V.fromList
      $ nubOrd
      $ V.toList s
  args -> argsError info b args

checkLen
  :: (MonadEval b i m)
  => i
  -> T.Text
  -> m ()
checkLen info txt =
  unless (T.length txt <= 512) $
      throwExecutionError info $ DecodeError $ "Invalid input, only up to 512 length supported"

doBase
  :: (MonadEval b i m)
  => i
  -> Cont b i m
  -> CEKErrorHandler b i m
  -> Integer
  -> T.Text
  -> m (EvalResult b i m)
doBase info cont handler base txt = case baseStrToInt base txt of
  Left e -> throwExecutionError info (DecodeError e)
  Right n -> returnCEKValue cont handler (VInteger n)

baseStrToInt :: Integer -> T.Text -> Either T.Text Integer
baseStrToInt base t =
  if base <= 1 || base > 16
  then Left $ "unsupported base: " `T.append` T.pack (show base)
  else
    if T.null t
    then Left $ "empty text: " `T.append` t
    else foldM go 0 $ T.unpack t
  where
    go :: Integer -> Char -> Either T.Text Integer
    go acc c' =
      let val = fromIntegral . Char.digitToInt $ c'
      in if val < base
         then pure $ base * acc + val
         else Left $ "character '" <> T.singleton c' <>
                "' is out of range for base " <> T.pack (show base) <> ": " <> t

_bsToInteger :: BS.ByteString -> Integer
_bsToInteger bs = fst $ foldl' go (0,(BS.length bs - 1) * 8) $ BS.unpack bs
  where
    go (i,p) w = (i .|. (shift (fromIntegral w) p),p - 8)

integerToBS :: Integer -> BS.ByteString
integerToBS v = BS.pack $ reverse $ go v
  where
    go i | i <= 0xff = [fromIntegral i]
         | otherwise = (fromIntegral (i .&. 0xff)):go (shift i (-8))


coreAndQ :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreAndQ = \info b cont handler _env -> \case
  [VClosure l, VClosure r, e] -> do
    applyLam l [e] Mt CEKNoHandler >>= \case
      EvalValue (VBool out)
        | out -> applyLam r [e] Mt CEKNoHandler >>= \case
            EvalValue (VBool out') -> returnCEKValue cont handler (VBool out')
            VError err -> returnCEK cont handler (VError err)
            _ -> returnCEK cont handler invalidCloValue
        | otherwise -> returnCEKValue cont handler (VBool out)
      EvalValue _ -> returnCEK cont handler invalidCloValue
      VError err -> returnCEK cont handler (VError err)
    where
    invalidCloValue = VError "invalid return application for and? closure"
  args -> argsError info b args

coreOrQ :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreOrQ = \info b cont handler _env -> \case
  [VClosure l, VClosure r, e] -> do
    applyLam l [e] Mt CEKNoHandler >>= \case
      EvalValue (VBool out)
        | out -> returnCEKValue cont handler (VBool out)
        | otherwise -> applyLam r [e] Mt CEKNoHandler >>= \case
            EvalValue (VBool out') -> returnCEKValue cont handler (VBool out')
            VError err -> returnCEK cont handler (VError err)
            _ -> returnCEK cont handler invalidCloValue
      EvalValue _ -> returnCEK cont handler invalidCloValue
      VError err -> returnCEK cont handler (VError err)
    where
    invalidCloValue = VError "invalid return application for and? closure"
  args -> argsError info b args

coreNotQ :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreNotQ = \info b cont handler _env -> \case
  [VClosure l, e] -> do
    applyLam l [e] Mt CEKNoHandler >>= \case
      EvalValue (VBool out) -> returnCEKValue cont handler (VBool (not out))
      EvalValue _ -> returnCEK cont handler invalidCloValue
      VError err -> returnCEK cont handler (VError err)
    where
    invalidCloValue = VError "invalid return application for and? closure"
  args -> argsError info b args

coreWhere :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreWhere = \info b cont handler _env -> \case
  [VString field, VClosure app, VObject o] -> do
    case M.lookup (Field field) o of
      Just v -> applyLam app [VPactValue v] Mt CEKNoHandler >>= \case
        EvalValue (VBool cond) -> returnCEKValue cont handler (VBool cond)
        EvalValue _ -> returnCEK cont handler (VError "where application did not result in a boolean")
        VError err -> returnCEK cont handler (VError err)
      Nothing -> returnCEK cont handler (VError "no such field in object in where application")
  args -> argsError info b args

coreHash :: (IsBuiltin b, MonadEval b i m) => NativeFunction b i m
coreHash = \info b cont handler _env -> \case
  [VString s] -> do
    returnCEKValue cont handler $ VString $ hashToText $ pactHash $ T.encodeUtf8 s
  args -> argsError info b args

-----------------------------------
-- Core definitions
-----------------------------------

unimplemented :: NativeFunction b i m
unimplemented = error "unimplemented"

rawBuiltinEnv
  :: (MonadEval RawBuiltin i m)
  => BuiltinEnv RawBuiltin i m
rawBuiltinEnv i b env = mkBuiltinFn i b env (rawBuiltinRuntime b)

rawBuiltinRuntime
  :: (MonadEval b i m, IsBuiltin b)
  => RawBuiltin
  -> NativeFunction b i m
rawBuiltinRuntime = \case
  RawAdd -> rawAdd
  RawSub -> rawSub
  RawMultiply -> rawMul
  RawDivide -> rawDiv
  RawNegate -> rawNegate
  RawAbs -> rawAbs
  RawPow -> rawPow
  RawNot -> notBool
  RawEq -> rawEq
  RawNeq -> rawNeq
  RawGT -> rawGt
  RawGEQ -> rawGeq
  RawLT -> rawLt
  RawLEQ -> rawLeq
  RawBitwiseAnd -> bitAndInt
  RawBitwiseOr -> bitOrInt
  RawBitwiseXor -> bitXorInt
  RawBitwiseFlip -> bitComplementInt
  RawBitShift -> bitShiftInt
  RawRound -> roundDec
  RawCeiling -> ceilingDec
  RawFloor -> floorDec
  RawExp -> rawExp
  RawLn -> rawLn
  RawSqrt -> rawSqrt
  RawLogBase -> rawLogBase
  RawLength -> rawLength
  RawTake -> rawTake
  RawDrop -> rawDrop
  RawConcat -> coreConcat
  RawReverse -> rawReverse
  RawMod -> modInt
  RawMap -> coreMap
  RawFilter -> coreFilter
  RawZip -> zipList
  RawIntToStr -> coreIntToStr
  RawStrToInt -> coreStrToInt
  RawStrToIntBase -> coreStrToIntBase
  RawFold -> coreFold
  RawDistinct -> coreDistinct
  RawContains -> rawContains
  RawSort -> rawSort
  RawSortObject -> rawSortObject
  RawRemove -> rawRemove
  RawEnforce -> coreEnforce
  RawEnforceOne -> unimplemented
  RawEnumerate -> coreEnumerate
  RawEnumerateStepN -> coreEnumerateStepN
  RawShow -> rawShow
  RawReadInteger -> coreReadInteger
  RawReadDecimal -> coreReadDecimal
  RawReadString -> coreReadString
  RawReadKeyset -> coreReadKeyset
  RawEnforceGuard -> coreEnforceGuard
  RawKeysetRefGuard -> keysetRefGuard
  RawAt -> coreAccess
  RawMakeList -> makeList
  RawB64Encode -> coreB64Encode
  RawB64Decode -> coreB64Decode
  RawStrToList -> strToList
  RawBind -> coreBind
  RawRequireCapability -> requireCapability
  RawComposeCapability -> composeCapability
  RawInstallCapability -> installCapability
  RawCreateCapabilityGuard -> createCapGuard
  RawCreateModuleGuard -> createModuleGuard
  RawEmitEvent -> coreEmitEvent
  RawCreateTable -> createTable
  RawDescribeKeyset -> unimplemented
  RawDescribeModule -> unimplemented
  RawDescribeTable -> unimplemented
  RawDefineKeySet -> defineKeySet
  RawDefineKeysetData -> defineKeySet
  RawFoldDb -> foldDb
  RawInsert -> dbInsert
  RawWrite -> dbWrite
  RawKeyLog -> unimplemented
  RawKeys -> dbKeys
  RawRead -> dbRead
  RawSelect -> dbSelect
  RawUpdate -> dbUpdate
  RawWithDefaultRead -> dbWithDefaultRead
  RawWithRead -> dbWithRead
  RawTxLog -> dbTxLog
  RawTxIds -> dbTxIds
  RawAndQ -> coreAndQ
  RawOrQ -> coreOrQ
  RawWhere -> coreWhere
  RawNotQ -> coreNotQ
  RawHash -> coreHash

