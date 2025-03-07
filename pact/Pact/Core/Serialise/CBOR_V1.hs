-- |
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE TypeApplications #-}


module Pact.Core.Serialise.CBOR_V1
  ( encodeModuleData, decodeModuleData
  , encodeModuleData_repl_spaninfo, decodeModuleData_repl_spaninfo
  , encodeModuleData_raw_spaninfo, decodeModuleData_raw_spaninfo
  , encodeKeySet, decodeKeySet
  , encodeDefPactExec, decodeDefPactExec
  , encodeNamespace, decodeNamespace
  , encodeRowData, decodeRowData
  , encodeRowDataNoGas
  -- only used for legacy translation
  , encodeModuleName
  , encodeModuleHash
  , SerialiseV1(..)
  ) where

import Control.Lens
import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Write (toStrictByteString)
import Codec.Serialise
import Codec.CBOR.Encoding
import Codec.CBOR.Decoding
import Data.ByteString (ByteString, fromStrict)
import Data.Decimal
import Data.Foldable
import Data.Coerce
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified GHC.Integer.Logarithms as IntLog
import GHC.Int(Int(..))

import Pact.Core.Builtin
import Pact.Core.Capabilities
import Pact.Core.ChainData
import Pact.Core.DefPacts.Types
import Pact.Core.Gas
import Pact.Core.Guards
import Pact.Core.Hash
import Pact.Core.Imports
import Pact.Core.Info
import Pact.Core.IR.Term
import Pact.Core.Literal
import Pact.Core.ModRefs
import Pact.Core.Names
import Pact.Core.Namespace
import Pact.Core.PactValue
import Pact.Core.Persistence
import Pact.Core.Pretty
import Pact.Core.Type
import Pact.Time.Internal (UTCTime(..), NominalDiffTime(..))
import qualified Data.Set as S
import qualified Data.Map.Strict as M
import Unsafe.Coerce (unsafeCoerce)
import Data.Word (Word16)

newtype SerialiseV1 a
  = SerialiseV1 { _getSV1 :: a }
  deriving newtype (Eq, Show, Ord)


encodeModuleData :: ModuleData CoreBuiltin () -> ByteString
encodeModuleData = toStrictByteString . encodeS

encodeModuleData_repl_spaninfo :: ModuleData ReplCoreBuiltin SpanInfo -> ByteString
encodeModuleData_repl_spaninfo = toStrictByteString . encodeS

encodeModuleData_raw_spaninfo :: ModuleData CoreBuiltin SpanInfo -> ByteString
encodeModuleData_raw_spaninfo = toStrictByteString . encodeS

decodeModuleData :: ByteString -> Maybe (ModuleData CoreBuiltin ())
decodeModuleData bs = either (const Nothing) (Just . _getSV1) (deserialiseOrFail (fromStrict bs))

decodeModuleData_repl_spaninfo :: ByteString -> Maybe (ModuleData ReplCoreBuiltin SpanInfo)
decodeModuleData_repl_spaninfo bs =
  case deserialiseOrFail (fromStrict bs) of
    Right (SerialiseV1 v) -> Just v
    Left _ -> Nothing

decodeModuleData_raw_spaninfo :: ByteString -> Maybe (ModuleData CoreBuiltin SpanInfo)
decodeModuleData_raw_spaninfo bs = either (const Nothing) (Just . _getSV1) (deserialiseOrFail (fromStrict bs))


encodeModuleName :: ModuleName -> ByteString
encodeModuleName = toStrictByteString . encodeS

encodeModuleHash :: ModuleHash -> ByteString
encodeModuleHash = toStrictByteString . encodeS

encodeKeySet :: KeySet -> ByteString
encodeKeySet = toStrictByteString . encodeS

decodeKeySet :: ByteString -> Maybe KeySet
decodeKeySet bs = either (const Nothing) (Just . snd) (deserialiseFromBytes decodeS (fromStrict bs))


encodeDefPactExec :: Maybe DefPactExec -> ByteString
encodeDefPactExec =  toStrictByteString . encodeS

decodeDefPactExec :: ByteString -> Maybe (Maybe DefPactExec)
decodeDefPactExec bs = either (const Nothing) (Just . snd) (deserialiseFromBytes decodeS (fromStrict bs))

encodeNamespace :: Namespace -> ByteString
encodeNamespace = toStrictByteString . encodeS

decodeNamespace :: ByteString -> Maybe Namespace
decodeNamespace bs =either (const Nothing) (Just . snd) (deserialiseFromBytes decodeS (fromStrict bs))


encodeRowData :: RowData -> GasM b i ByteString
encodeRowData rd = do
  gasSerializeRowData rd
  pure . toStrictByteString $ encodeS rd

encodeRowDataNoGas :: RowData -> ByteString
encodeRowDataNoGas rd =
  toStrictByteString $ encodeS rd

chargeGasMSerialize :: MilliGas -> GasM b i ()
chargeGasMSerialize amount = do
  chargeGasM (GAConstant amount)

gasSerializeRowData :: forall i b. RowData -> GasM b i ()
gasSerializeRowData (RowData fields) = do

  -- Charge for keys
  chargeGasMString $ Text.concat $ _field <$> Map.keys fields

  -- Charge for values
  traverse_ gasSerializePactValue fields

  where

    gasSerializePactValue :: PactValue -> GasM b i ()
    gasSerializePactValue = \case
      PLiteral l -> gasSerializeLiteral l
      PList vs -> do
        traverse_ gasSerializePactValue vs
      PGuard g -> do
        gasSerializeGuard g
      PModRef modRef -> gasModRef modRef
      PObject o -> do
        chargeGasMString $ Text.concat $ _field <$> Map.keys o
        traverse_ gasSerializePactValue o
      PCapToken (CapToken name args) -> do
        chargeGasMString (renderText name)
        traverse_ gasSerializePactValue args
      PTime _ -> do
        SerializationCosts { timeCostMilliGas } <- view (_1 . geGasModel . gmSerialize)
        chargeGasMSerialize $ MilliGas timeCostMilliGas

    gasSerializeLiteral l = do
      SerializationCosts {
        boolMilliGasCost,
        unitMilliGasCost,
        integerCostMilliGasPerDigit,
        decimalCostMilliGasOffset,
        decimalCostMilliGasPerDigit} <- view (_1 . geGasModel . gmSerialize)
      case l of
        LString s ->
          -- See the analysis in `Bench.hs` - `pact-string-2` for details.
          chargeGasMString s
        LInteger i ->
          -- See the analysis in `Bench.hs` - `pact-ineger-2` for details.
          chargeGasMSerialize $ MilliGas $ integerCostMilliGasPerDigit * fromIntegral (I# (IntLog.integerLogBase# 10 (abs i)))
        LDecimal d ->
          chargeGasMSerialize $ MilliGas $ decimalCostMilliGasOffset + decimalCostMilliGasPerDigit * fromIntegral (I# (IntLog.integerLogBase# 10 (decimalMantissa d)))
        LBool _ -> chargeGasMSerialize $ MilliGas boolMilliGasCost
        LUnit -> chargeGasMSerialize $ MilliGas unitMilliGasCost

    gasSerializeGuard = \case

      GKeyset keyset -> gasSerializeKeySet keyset
      GKeySetRef keysetName -> chargeGasMString (renderText keysetName)
      GUserGuard (UserGuard name term) -> do
        chargeGasMString (renderText name)
        traverse_ gasSerializePactValue term
      GCapabilityGuard (CapabilityGuard name args defpactId) -> do
        chargeGasMString (renderText name)
        traverse_ gasSerializePactValue args
        traverse_ (chargeGasMString . renderText) defpactId
      GModuleGuard (ModuleGuard moduleName guardName) -> do
        chargeGasMString (renderText moduleName)
        chargeGasMString (renderText guardName)
      GDefPactGuard (DefPactGuard defpactId name) -> do
        chargeGasMString (renderText defpactId)
        chargeGasMString (renderText name)

    gasSerializeKeySet :: KeySet -> GasM b i ()
    gasSerializeKeySet (KeySet keys pred') = do
      -- See the analysis in `Bench.hs` - `pact-keyset-2` for details.
      chargeGasMString (renderText pred')
      traverse_ (chargeGasMString . renderText) keys

    gasModRef :: ModRef -> GasM b i ()
    gasModRef (ModRef name implemented) = do
      chargeGasMString (renderText name)
      traverse_ (chargeGasMString . renderText) implemented

    chargeGasMString :: Text.Text -> GasM b i ()
    chargeGasMString str = do
      SerializationCosts {
        objectKeyCostMilliGasOffset,
        objectKeyCostMilliGasPer1000Chars
        } <- view (_1 . geGasModel . gmSerialize)
      chargeGasMSerialize $ MilliGas $ objectKeyCostMilliGasOffset + objectKeyCostMilliGasPer1000Chars * fromIntegral (Text.length str) `div` 1000


decodeRowData :: ByteString -> Maybe RowData
decodeRowData bs = either (const Nothing) (Just . snd) (deserialiseFromBytes decodeS (fromStrict bs))

encodeS :: Serialise (SerialiseV1 a) => a -> Encoding
encodeS a = encode (SerialiseV1 a)
{-# INLINE encodeS #-}

decodeS :: Serialise (SerialiseV1 a) => Decoder s a
decodeS = c decode
  where
  c :: Decoder s (SerialiseV1 a) -> Decoder s a
  c = coerce
{-# INLINE decodeS #-}

instance Serialise (SerialiseV1 ()) where
  encode _ = encode ()
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> decode
  {-# INLINE decode #-}

instance {-# OVERLAPPABLE #-}
  (Serialise (SerialiseV1 a), Functor f, (forall b. (Serialise b) => Serialise (f b))) => Serialise (SerialiseV1 (f a)) where
  encode (SerialiseV1 m) = encode (SerialiseV1 <$> m)
  {-# INLINE encode #-}
  decode = SerialiseV1 . fmap _getSV1 <$> decode
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 Namespace) where
  encode (SerialiseV1 (Namespace n user admin)) = encodeS n <> encodeS user <> encodeS admin
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (Namespace <$> decodeS <*> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 RowData) where
  encode (SerialiseV1 (RowData m)) = encode (SerialiseV1 <$> m)
  {-# INLINE encode #-}
  decode = SerialiseV1 . RowData . fmap _getSV1 <$> decode
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 NamespaceName) where
  encode (SerialiseV1 (NamespaceName ns)) = encode ns
  {-# INLINE encode #-}
  decode  = SerialiseV1 . NamespaceName <$> decode
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 ModuleName) where
  encode (SerialiseV1 (ModuleName mn mns)) = encode mn <> encode (SerialiseV1 <$> mns)
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (ModuleName <$> decode <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 KeySetName) where
  encode (SerialiseV1 (KeySetName ksn ns)) = encode ksn <> encodeS ns
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (KeySetName <$> decode <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 PublicKeyText) where
  encode (SerialiseV1 (PublicKeyText t)) = encode t
  {-# INLINE encode #-}
  decode = SerialiseV1 . PublicKeyText <$> decode
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 KeySet) where
  encode (SerialiseV1 (KeySet ks p)) = encode ks <> encodeS p
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (KeySet <$> decode <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 KSPredicate) where
  encode (SerialiseV1 k) = case k of
    KeysAll -> encodeWord 0
    Keys2 -> encodeWord 1
    KeysAny -> encodeWord 2
    CustomPredicate pn -> encodeWord 3 <> encodeS pn
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> pure KeysAll
    1 -> pure Keys2
    2 -> pure KeysAny
    3 -> CustomPredicate <$> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 QualifiedName) where
  encode (SerialiseV1 (QualifiedName qn mn)) = encode qn <> encodeS mn
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (QualifiedName <$> decode <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 BareName) where
  encode (SerialiseV1 (BareName bn)) = encode bn
  {-# INLINE encode #-}
  decode = SerialiseV1 . BareName <$> decode
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 DynamicName) where
  encode (SerialiseV1 (DynamicName dn dcall)) = encode dn <> encode dcall
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (DynamicName <$> decode <*> decode)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 ParsedName) where
  encode (SerialiseV1 n) = case n of
    QN qn -> encodeWord 0 <> encodeS qn
    BN bn -> encodeWord 1 <> encodeS bn
    DN dn -> encodeWord 2 <> encodeS dn
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> QN <$> decodeS
    1 -> BN <$> decodeS
    2 -> DN <$> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 ParsedTyName) where
  encode (SerialiseV1 n) = case n of
    TQN qn -> encodeWord 0 <> encodeS qn
    TBN bn -> encodeWord 1 <> encodeS bn
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> TQN <$> decodeS
    1 -> TBN <$> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}


instance Serialise (SerialiseV1 Hash) where
  encode (SerialiseV1 (Hash h)) = encode h
  {-# INLINE encode #-}
  decode = SerialiseV1 . Hash <$> decode
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 ModuleHash) where
  encode (SerialiseV1 (ModuleHash mh)) = encodeS mh
  {-# INLINE encode #-}
  decode = SerialiseV1 . ModuleHash <$> decodeS
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 FullyQualifiedName) where
  encode (SerialiseV1 (FullyQualifiedName mn fqn h)) = encodeS mn <> encode fqn <> encodeS h
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (FullyQualifiedName <$> decodeS <*> decode <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 (Governance Name)) where
  encode (SerialiseV1 g) = case g of
    KeyGov ksn -> encodeWord 0 <> encodeS ksn
    CapGov cgn -> encodeWord 1 <> encodeS cgn
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> KeyGov <$> decodeS
    1 -> CapGov <$> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance (Serialise (SerialiseV1 ty), Serialise (SerialiseV1 i)) => Serialise (SerialiseV1 (Arg ty i)) where
  encode (SerialiseV1 (Arg n ty i)) = encode n <> encodeS ty <> encodeS i
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (Arg <$> decode <*> decodeS <*> decodeS)
  {-# INLINE decode #-}


instance Serialise (SerialiseV1 Decimal) where
  encode (SerialiseV1 (Decimal places mantissa)) = encode places <> encode mantissa
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (Decimal <$> decode <*> decode)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 Literal) where
  encode (SerialiseV1 l) = case l of
    LString s -> encodeWord 0 <> encode s
    LInteger i -> encodeWord 1 <> encode i
    LDecimal d -> encodeWord 2 <> encodeS d
    LUnit -> encodeWord 3
    LBool b -> encodeWord 4 <> encode b
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> LString <$> decode
    1 -> LInteger <$> decode
    2 -> LDecimal <$> decodeS
    3 -> pure LUnit
    4 -> LBool <$> decode
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 Field) where
  encode (SerialiseV1 (Field f)) = encode f
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (Field <$> decode)
  {-# INLINE decode #-}

instance (Serialise (SerialiseV1 b), Serialise (SerialiseV1 i))
  => Serialise (SerialiseV1 (BuiltinForm (Term Name Type b i))) where
  encode (SerialiseV1 bf) = case bf of
      CAnd t1 t2 -> encodeWord 0 <> encodeS t1 <> encodeS t2
      COr t1 t2 -> encodeWord 1 <> encodeS t1 <> encodeS t2
      CIf t1 t2 t3 -> encodeWord 2 <> encodeS t1 <> encodeS t2 <> encodeS t3
      CEnforceOne t1 t2 -> encodeWord 3 <> encodeS t1 <> encodeS t2
      CEnforce t1 t2 -> encodeWord 4 <> encodeS t1 <> encodeS t2
      CWithCapability t1 t2 -> encodeWord 5 <> encodeS t1 <> encodeS t2
      CTry t1 t2 -> encodeWord 6 <> encodeS t1 <> encodeS t2
      CCreateUserGuard t1 -> encodeWord 7 <> encodeS t1
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> CAnd <$> decodeS <*> decodeS
    1 -> COr <$> decodeS <*> decodeS
    2 -> CIf <$> decodeS <*> decodeS <*> decodeS
    3 -> CEnforceOne <$> decodeS <*> decodeS
    4 -> CEnforce <$> decodeS <*> decodeS
    5 -> CWithCapability <$> decodeS <*> decodeS
    6 -> CTry <$> decodeS <*> decodeS
    7 -> CCreateUserGuard <$> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance
  (Serialise (SerialiseV1 b), Serialise (SerialiseV1 i))
  => Serialise (SerialiseV1 (Term Name Type b i)) where
  encode (SerialiseV1 term) = case term of
    Var n i -> encodeWord 0 <> encodeS n <> encodeS i
    Lam args body i -> encodeWord 1 <> encodeS args <> encodeS body <> encodeS i
    Let arg t1 t2 i -> encodeWord 2 <> encodeS arg <> encodeS t1 <> encodeS t2 <> encodeS i
    App t1 t2 i -> encodeWord 3 <> encodeS t1 <> encodeS t2 <> encodeS i
    Sequence t1 t2 i -> encodeWord 4 <> encodeS t1 <> encodeS t2 <> encodeS i
    Nullary t i -> encodeWord 5 <> encodeS t <> encodeS i
    BuiltinForm bi i -> encodeWord 6 <> encodeS bi <> encodeS i
    Builtin bi i -> encodeWord 7 <> encodeS bi <> encodeS i
    Constant lit i -> encodeWord 8 <> encodeS lit <> encodeS i
    ListLit t i -> encodeWord 9 <> encodeS t <> encodeS i
    ObjectLit o i -> encodeWord 10 <> encodeS o <> encodeS i
    InlineValue pv i -> encodeWord 11 <> encodeS pv <> encodeS i
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> Var <$> decodeS <*> decodeS
    1 -> Lam <$> decodeS <*> decodeS <*> decodeS
    2 -> Let <$> decodeS <*> decodeS <*> decodeS <*> decodeS
    3 -> App <$> decodeS <*> decodeS <*> decodeS
    4 -> Sequence <$> decodeS <*> decodeS <*> decodeS
    5 -> Nullary <$> decodeS <*> decodeS
    6 -> BuiltinForm <$> decodeS <*> decodeS
    7 -> Builtin <$> decodeS <*> decodeS
    8 -> Constant <$> decodeS <*> decodeS
    9 -> ListLit <$> decodeS <*> decodeS
    10 -> ObjectLit <$> decodeS <*> decodeS
    -- Internal term used for back. compat pact < 5
    11 -> InlineValue <$> decodeS <*> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance
  (Serialise (SerialiseV1 b), Serialise (SerialiseV1 i))
  => Serialise (SerialiseV1 (Defun Name Type b i)) where
  encode (SerialiseV1 (Defun spec args term i)) = encodeS spec <> encodeS args <> encodeS term <> encodeS i
  {-# INLINE encode #-}

  decode = SerialiseV1 <$> (Defun <$> decodeS <*> decodeS <*> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance
  (Serialise (SerialiseV1 b), Serialise (SerialiseV1 i))
  => Serialise (SerialiseV1 (DefConst Name Type b i)) where
  encode (SerialiseV1 (DefConst spec term i)) = encodeS spec <> encodeS term <> encodeS i
  {-# INLINE encode #-}

  decode = SerialiseV1 <$> (DefConst <$> decodeS <*> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance (Serialise (SerialiseV1 term)) => Serialise (SerialiseV1 (ConstVal term)) where
  encode (SerialiseV1 c) = case c of
    TermConst t -> encodeWord 0 <> encodeS t
    EvaledConst pv -> encodeWord 1 <> encodeS pv
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> TermConst <$> decodeS
    1 -> EvaledConst <$> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 (FQNameRef Name)) where
  encode (SerialiseV1 (FQName fqn)) = encodeS fqn
  {-# INLINE encode #-}
  decode = SerialiseV1 . FQName <$> decodeS
  {-# INLINE decode #-}

instance (Serialise (SerialiseV1 name)) => Serialise (SerialiseV1 (DefManagedMeta name)) where
  encode (SerialiseV1 dmm) = case dmm of
    DefManagedMeta i ref -> encodeWord 0 <> encode i <> encodeS ref
    AutoManagedMeta -> encodeWord 1
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> DefManagedMeta <$> decode <*> decodeS
    1 -> pure AutoManagedMeta
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 name) => Serialise (SerialiseV1 (DefCapMeta name)) where
  encode (SerialiseV1 dcm) = case dcm of
    DefEvent -> encodeWord 0
    DefManaged meta -> encodeWord 1 <> encodeS meta
    Unmanaged -> encodeWord 2
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> pure DefEvent
    1 -> DefManaged <$> decodeS
    2 -> pure Unmanaged
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance (Serialise (SerialiseV1 b), Serialise (SerialiseV1 i)) => Serialise (SerialiseV1 (DefCap Name Type b i)) where
  encode (SerialiseV1 (DefCap spec args term meta i)) =
    encodeS spec
    <> encodeS args
    <> encodeS term
    <> encodeS meta
    <> encodeS i
  {-# INLINE encode #-}

  decode =
    SerialiseV1 <$> (DefCap <$> decodeS <*> decodeS <*> decodeS <*> decodeS <*> decodeS)
  {-# INLINE decode #-}


instance (Serialise (SerialiseV1 ty), Serialise (SerialiseV1 i)) => Serialise (SerialiseV1 (DefSchema ty i)) where
  encode (SerialiseV1 (DefSchema n schema i)) = encode n <> encodeS schema <> encodeS i
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (DefSchema <$> decode <*> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 (TableSchema Name)) where
  encode (SerialiseV1 (ResolvedTable n)) = encodeS n
  {-# INLINE encode #-}
  decode = SerialiseV1 . ResolvedTable <$> decodeS
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 i) => Serialise (SerialiseV1 (DefTable Name i)) where
  encode (SerialiseV1 (DefTable n schema i)) = encode n <> encodeS schema <> encodeS i
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (DefTable <$> decode <*> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance
  (Serialise (SerialiseV1 b), Serialise (SerialiseV1 i))
  => Serialise (SerialiseV1 (Step Name Type b i)) where
  encode (SerialiseV1 step) = case step of
    Step t -> encodeWord 0 <> encodeS t
    StepWithRollback t rb -> encodeWord 1 <> encodeS t <> encodeS rb
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> Step <$> decodeS
    1 -> StepWithRollback <$> decodeS <*> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance
  (Serialise (SerialiseV1 b), Serialise (SerialiseV1 i))
  => Serialise (SerialiseV1 (DefPact Name Type b i)) where
  encode (SerialiseV1 (DefPact spec args steps i)) =
    encodeS spec <> encodeS args <> encodeS steps <> encodeS i
  {-# INLINE encode #-}

  decode = SerialiseV1 <$> (DefPact <$> decodeS <*> decodeS <*> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance
  (Serialise (SerialiseV1 b), Serialise (SerialiseV1 i))
  => Serialise (SerialiseV1 (Def Name Type b i)) where
  encode (SerialiseV1 defn) = case defn of
    Dfun df -> encodeWord 0 <> encodeS df
    DConst dc -> encodeWord 1 <> encodeS dc
    DCap cap -> encodeWord 2 <> encodeS cap
    DSchema schema -> encodeWord 3 <> encodeS schema
    DTable table -> encodeWord 4 <> encodeS table
    DPact dp -> encodeWord 5 <> encodeS dp
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> Dfun <$> decodeS
    1 -> DConst <$> decodeS
    2 -> DCap <$> decodeS
    3 -> DSchema <$> decodeS
    4 -> DTable <$> decodeS
    5 -> DPact <$> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 DynamicRef) where
  encode (SerialiseV1 (DynamicRef n b)) = encode n <> encode b
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (DynamicRef <$> decode <*> decode)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 NameKind) where
  encode (SerialiseV1 nk) = case nk of
    NBound d -> encodeWord 0 <> encode d
    NTopLevel mn mh -> encodeWord 1 <> encodeS mn <> encodeS mh
    NModRef mn ms -> encodeWord 2 <> encodeS mn <> encodeS ms
    NDynRef dref -> encodeWord 3 <> encodeS dref
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> NBound <$> decode
    1 -> NTopLevel <$> decodeS <*> decodeS
    2 -> NModRef <$> decodeS <*> decodeS
    3 -> NDynRef <$> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 Name) where
  encode (SerialiseV1 (Name n k)) = encode n <> encodeS k
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (Name <$> decode <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 PrimType) where
  encode (SerialiseV1 pt) = case pt of
    PrimInt -> encodeWord 0
    PrimDecimal -> encodeWord 1
    PrimBool -> encodeWord 2
    PrimString -> encodeWord 3
    PrimGuard -> encodeWord 4
    PrimTime -> encodeWord 5
    PrimUnit -> encodeWord 6
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> pure PrimInt
    1 -> pure PrimDecimal
    2 -> pure PrimBool
    3 -> pure PrimString
    4 -> pure PrimGuard
    5 -> pure PrimTime
    6 -> pure PrimUnit
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 Schema) where
  encode (SerialiseV1 (Schema sc m)) =
    encodeS sc <> encodeS m
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (Schema <$> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 Type) where
  encode (SerialiseV1 ty) = case ty of
    TyPrim pt -> encodeWord 0 <> encodeS pt
    TyList t -> encodeWord 1 <> encodeS t
    TyAnyList -> encodeWord 2
    TyModRef mr -> encodeWord 3 <> encode (coerceSetToSerialize mr)
    TyObject s -> encodeWord 4 <> encodeS s
    TyAnyObject -> encodeWord 5
    TyTable s -> encodeWord 6 <> encodeS s
    TyCapToken -> encodeWord 7
    TyAny -> encodeWord 8
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> TyPrim <$> decodeS
    1 -> TyList <$> decodeS
    2 -> pure TyAnyList
    3 -> TyModRef . coerceSetFromSerialize <$> decode
    4 -> TyObject <$> decodeS
    5 -> pure TyAnyObject
    6 -> TyTable <$> decodeS
    7 -> pure TyCapToken
    8 -> pure TyAny
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 Import) where
  encode (SerialiseV1 (Import mn mh mimp)) = encodeS mn <> encodeS mh <> encode mimp
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (Import <$> decodeS <*> decodeS <*> decode)
  {-# INLINE decode #-}

instance
  (Serialise (SerialiseV1 b), Serialise (SerialiseV1 i))
  => Serialise (SerialiseV1 (EvalModule b i)) where
  encode (SerialiseV1 (Module mn mg mdef mbless mimports mimpl mhash txhash minfo)) =
    encodeS mn <> encodeS mg <> encodeS mdef
    <> encode (coerceSetToSerialize mbless) <> encodeS mimports <> encodeS mimpl
    <> encodeS mhash <> encodeS txhash <> encodeS minfo
  {-# INLINE encode #-}

  decode = fmap SerialiseV1 $
    Module <$> decodeS <*> decodeS <*> decodeS <*> (coerceSetFromSerialize <$> decode) <*> decodeS
           <*> decodeS <*> decodeS <*> decodeS <*> decodeS
  {-# INLINE decode #-}


instance
  Serialise (SerialiseV1 i)
  => Serialise (SerialiseV1 (IfDefun Type i)) where
  encode (SerialiseV1 (IfDefun spec args i)) = encodeS spec <> encodeS args <> encodeS i
  {-# INLINE encode #-}

  decode = SerialiseV1 <$> (IfDefun <$> decodeS <*> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance
  Serialise (SerialiseV1 i)
  => Serialise (SerialiseV1 (IfDefCap name Type i)) where
  encode (SerialiseV1 (IfDefCap spec args meta i)) =
    encodeS spec <> encodeS args <> encodeS meta <> encodeS i
  {-# INLINE encode #-}

  decode = SerialiseV1 <$> (IfDefCap <$> decodeS <*> decodeS <*> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance
  Serialise (SerialiseV1 i)
  => Serialise (SerialiseV1 (IfDefPact Type i)) where
  encode (SerialiseV1 (IfDefPact spec args i)) = encodeS spec <> encodeS args <> encodeS i
  {-# INLINE encode #-}

  decode = SerialiseV1 <$> (IfDefPact <$> decodeS <*> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance
  (Serialise (SerialiseV1 b), Serialise (SerialiseV1 i))
  => Serialise (SerialiseV1 (IfDef Name Type b i)) where
  encode (SerialiseV1 ifdef) = case ifdef of
    IfDfun df -> encodeWord 0 <> encodeS df
    IfDConst dc -> encodeWord 1 <> encodeS dc
    IfDCap cap -> encodeWord 2 <> encodeS cap
    IfDSchema schema -> encodeWord 3 <> encodeS schema
    IfDPact dp ->  encodeWord 4 <> encodeS dp
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> IfDfun <$> decodeS
    1 -> IfDConst <$> decodeS
    2 -> IfDCap <$> decodeS
    3 -> IfDSchema <$> decodeS
    4 -> IfDPact <$> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance
  (Serialise (SerialiseV1 b), Serialise (SerialiseV1 i))
  => Serialise (SerialiseV1 (EvalInterface b i)) where
  encode (SerialiseV1 (Interface n defs imp h txh i)) =
    encodeS n <> encodeS defs <> encodeS imp <> encodeS h <> encodeS txh <> encodeS i
  {-# INLINE encode #-}

  decode = SerialiseV1 <$> (Interface <$> decodeS <*> decodeS <*> decodeS <*> decodeS <*> decodeS <*> decodeS)
  {-# INLINE decode #-}

coerceMapFromSerialise :: M.Map (SerialiseV1 k) (SerialiseV1 v) -> M.Map k v
coerceMapFromSerialise = unsafeCoerce

coerceMapToSerialise :: M.Map k v -> M.Map (SerialiseV1 k) (SerialiseV1 v)
coerceMapToSerialise = unsafeCoerce

coerceSetToSerialize :: S.Set k -> S.Set (SerialiseV1 k)
coerceSetToSerialize = unsafeCoerce

coerceSetFromSerialize :: S.Set (SerialiseV1 k) -> S.Set k
coerceSetFromSerialize = unsafeCoerce

instance
  (Serialise (SerialiseV1 b), Serialise (SerialiseV1 i))
  => Serialise (SerialiseV1 (ModuleData b i)) where
  encode (SerialiseV1 md) = case md of
    ModuleData em m -> encodeWord 0 <> encodeS em <> encode (coerceMapToSerialise m)
    InterfaceData ei m -> encodeWord 1 <> encodeS ei <> encode (coerceMapToSerialise m)
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> ModuleData <$> decodeS <*> (coerceMapFromSerialise <$> decode)
    1 -> InterfaceData <$> decodeS <*> (coerceMapFromSerialise <$> decode)
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}


instance Serialise (SerialiseV1 SpanInfo) where
  encode (SerialiseV1 (SpanInfo sl sc el ec)) = encode sl <> encode sc <> encode el <> encode ec
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (SpanInfo <$> decode <*> decode <*> decode <*> decode)
  {-# INLINE decode #-}

-- Note: this encoder/decoder relies on the derived `Enum` instance
-- for `CoreBuiltin`. That said: we _do_ have a golden test in
-- ConTagGolden.hs for ensuring that any constructor ordering changes
-- are caught.
instance Serialise (SerialiseV1 CoreBuiltin) where
  encode (SerialiseV1 cb) =
    encodeWord16 $ fromIntegral (fromEnum cb)
  {-# INLINE encode #-}

  decode = do
    d <- decodeWord16
    if d <= cbMax then pure (SerialiseV1 (toEnum (fromIntegral d)))
    else fail "unexpected decoding: CoreBuiltin"
    where
    cbMax :: Word16
    cbMax = fromIntegral $ fromEnum $ (maxBound :: CoreBuiltin)
  {-# INLINE decode #-}


instance Serialise (SerialiseV1 ReplOnlyBuiltin) where
  encode = encodeWord . fromIntegral . fromEnum . _getSV1
  {-# INLINE encode #-}
  decode = do
    vInd <- toEnum . fromIntegral <$> decodeWord
    pure $ SerialiseV1 (toEnum vInd)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 ReplCoreBuiltin) where
  encode (SerialiseV1 rb) = case rb of
    RBuiltinWrap b -> encodeWord 0 <> encodeS b
    RBuiltinRepl r -> encodeWord 1 <> encodeS r
  {-# INLINE encode #-}

  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> RBuiltinWrap <$> decodeS
    1 -> RBuiltinRepl <$> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}



-- DefPacts

instance Serialise (SerialiseV1 (UserGuard QualifiedName PactValue)) where
  encode (SerialiseV1 (UserGuard f a)) = encodeS f <> encodeS a
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (UserGuard <$> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 DefPactId) where
  encode (SerialiseV1 (DefPactId pid)) = encode pid
  {-# INLINE encode #-}
  decode = SerialiseV1 . DefPactId <$> decode
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 (CapabilityGuard QualifiedName PactValue)) where
  encode (SerialiseV1 (CapabilityGuard n a pid)) = encodeS n <> encodeS a <> encodeS pid
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (CapabilityGuard <$> decodeS <*> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 ModuleGuard) where
  encode (SerialiseV1 (ModuleGuard mn n)) = encodeS mn <> encode n
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (ModuleGuard <$> decodeS <*> decode)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 (Guard QualifiedName PactValue)) where
  encode (SerialiseV1 g) = case g of
    GKeyset ks -> encodeWord 0 <> encodeS ks
    GKeySetRef ksn -> encodeWord 1 <> encodeS ksn
    GUserGuard ug -> encodeWord 2 <> encodeS ug
    GCapabilityGuard cg -> encodeWord 3 <> encodeS cg
    GModuleGuard mg -> encodeWord 4 <> encodeS mg
    GDefPactGuard dpg -> encodeWord 5 <> encodeS dpg
  {-# INLINE encode #-}
  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> GKeyset <$> decodeS
    1 -> GKeySetRef <$> decodeS
    2 -> GUserGuard <$> decodeS
    3 -> GCapabilityGuard <$> decodeS
    4 -> GModuleGuard <$> decodeS
    5 -> GDefPactGuard <$> decodeS
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 DefPactGuard) where
  encode (SerialiseV1 (DefPactGuard i name)) = encodeS i <> encode name
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (DefPactGuard <$> decodeS <*> decode)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 ModRef) where
  encode (SerialiseV1 (ModRef mn imp)) = encodeS mn <> encode (coerceSetToSerialize imp)
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (ModRef <$> decodeS <*> (coerceSetFromSerialize <$> decode))
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 name) => Serialise (SerialiseV1 (CapToken name PactValue)) where
  encode (SerialiseV1 (CapToken n a)) = encodeS n <> encodeS a
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (CapToken <$> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 PactValue) where
  encode (SerialiseV1 pv) = case pv of
    PLiteral l -> encodeWord 0 <> encodeS l
    PList l -> encodeWord 1 <> encodeS l
    PGuard g -> encodeWord 2 <> encodeS g
    PObject o -> encodeWord 3 <> encodeS o
    PModRef mr -> encodeWord 4 <> encodeS mr
    PCapToken ct -> encodeWord 5 <> encodeS ct
    PTime (UTCTime (NominalDiffTime pt)) -> encodeWord 6 <> encode pt
  {-# INLINE encode #-}
  decode = decodeWord >>= fmap SerialiseV1 . \case
    0 -> PLiteral <$> decodeS
    1 -> PList <$> decodeS
    2 -> PGuard <$> decodeS
    3 -> PObject <$> decodeS
    4 -> PModRef <$> decodeS
    5 -> PCapToken <$> decodeS
    6 -> PTime . UTCTime . NominalDiffTime <$> decode
    _ -> fail "unexpected decoding"
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 ChainId) where
  encode (SerialiseV1 (ChainId cid)) = encode cid
  {-# INLINE encode #-}
  decode = SerialiseV1 . ChainId <$> decode
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 Provenance) where
  encode (SerialiseV1 (Provenance tcid mh)) = encodeS tcid <> encodeS mh
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (Provenance <$> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 Yield) where
  encode (SerialiseV1 (Yield d p s)) = encodeS d <> encodeS p <> encodeS s
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (Yield <$> decodeS <*> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 (DefPactContinuation QualifiedName PactValue)) where
  encode (SerialiseV1 (DefPactContinuation n a)) = encodeS n <> encodeS a
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (DefPactContinuation <$> decodeS <*> decodeS)
  {-# INLINE decode #-}

instance Serialise (SerialiseV1 DefPactExec) where
  encode (SerialiseV1 (DefPactExec sc y s dpid cont rb ndp)) =
    encode sc <> encodeS y <> encode s <> encodeS dpid <> encodeS cont <> encode rb <> encode (coerceMapToSerialise ndp)
  {-# INLINE encode #-}
  decode = SerialiseV1 <$> (DefPactExec <$> decode <*> decodeS <*> decode <*> decodeS <*> decodeS <*> decode <*> (coerceMapFromSerialise <$> decode))
  {-# INLINE decode #-}

