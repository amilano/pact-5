{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

-- |
-- Module      :  Pact.Types.RPC
-- Copyright   :  (C) 2016 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>
--
-- Pact API RPC types.
--

module Pact.Core.Types.RPC
  ( -- * Types
    PactRPC(..)
  , ExecMsg(..)
  , ContMsg(..)
  ) where

import Control.Applicative
import Control.DeepSeq
import qualified Data.Aeson as Aeson
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text

import GHC.Generics

import Test.QuickCheck

import Pact.Core.Types.Orphans ()
import Pact.Core.SPV
import Pact.Core.Names

import Pact.JSON.Decode
import Pact.Core.StableEncoding
import qualified Pact.JSON.Encode as J


data PactRPC c =
    Exec !(ExecMsg c) |
    Continuation !ContMsg
    deriving (Eq,Show,Generic,Functor,Foldable,Traversable)

instance NFData c => NFData (PactRPC c)
instance FromJSON c => FromJSON (PactRPC c) where
    parseJSON =
        withObject "RPC" $ \o ->
            (Exec <$> o .: "exec") <|> (Continuation <$> o .: "cont")
    {-# INLINE parseJSON #-}

instance J.Encode c => J.Encode (PactRPC c) where
  build (Exec p) = J.object ["exec" J..= p]
  build (Continuation p) = J.object ["cont" J..= p]
  {-# INLINE build #-}

instance Arbitrary c => Arbitrary (PactRPC c) where
  arbitrary = oneof [Exec <$> arbitrary, Continuation <$> arbitrary]

data ExecMsg c = ExecMsg
  { _pmCode :: c
  , _pmData :: Aeson.Value -- TODO: Greg: Is this the correct type?
  } deriving (Eq,Generic,Show,Functor,Foldable,Traversable)

instance NFData c => NFData (ExecMsg c)
instance FromJSON c => FromJSON (ExecMsg c) where
  parseJSON =
      withObject "PactMsg" $ \o ->
          ExecMsg <$> o .: "code" <*> o .: "data"
  {-# INLINE parseJSON #-}


instance J.Encode c => J.Encode (ExecMsg c) where
  build o = J.object
    [ "data" J..= _pmData o
    , "code" J..= _pmCode o
    ]
  {-# INLINE build #-}

instance Arbitrary c => Arbitrary (ExecMsg c) where
  arbitrary = ExecMsg <$> arbitrary <*> pure (Aeson.String "JSON VALUE")

data ContMsg = ContMsg
  { _cmPactId :: !DefPactId
  , _cmStep :: !Int
  , _cmRollback :: !Bool
  , _cmData :: !Aeson.Value -- TODO: Greg: Is this the correct type?
  , _cmProof :: !(Maybe ContProof)
  } deriving (Eq,Show,Generic)

instance NFData ContMsg
instance FromJSON ContMsg where
  parseJSON =
      withObject "ContMsg" $ \o -> do
          StableEncoding defPactId <- o .: "pactId"
          step <- o .: "step"
          rollback <- o .: "rollback"
          msgData <- o .: "data"
          maybeProof <- o .:? "proof"
          pure $ ContMsg defPactId step rollback msgData maybeProof
          -- ContMsg <$> o .: "pactId" <*> o .: "step" <*> o .: "rollback" <*> o .: "data"
          -- <*> o .: "proof"
  {-# INLINE parseJSON #-}


instance J.Encode ContMsg where
  build o = J.object
    [ "proof" J..= _cmProof o
    , "data" J..= _cmData o
    , "pactId" J..= StableEncoding (_cmPactId o)
    , "rollback" J..= _cmRollback o
    , "step" J..= J.Aeson (_cmStep o)
    ]
  {-# INLINE build #-}

instance Arbitrary ContMsg where
  arbitrary = ContMsg
    <$> fmap (DefPactId . Text.pack) arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> pure (Aeson.String "JSON VALUE")
    <*> fmap (Just . ContProof . Text.encodeUtf8 . Text.pack) arbitrary -- TODO: Greg: This is an odd instance or arbitrary for ContProof.
