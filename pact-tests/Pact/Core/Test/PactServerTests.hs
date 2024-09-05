{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE QuasiQuotes #-}

{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

-- |

module Pact.Core.Test.PactServerTests where

import Control.Monad.IO.Class
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as LBS
import Pact.Core.Command.Util
import Data.ByteString (ByteString)
import Data.Default
import qualified Data.List.NonEmpty as NE
import Data.Proxy
import Data.Text
import Data.Text.Encoding
import qualified Network.HTTP.Types   as HTTP
import Pact.Core.ChainData
import Pact.Core.Command.Client
import Pact.Core.Command.Crypto
import Pact.Core.Command.RPC
import Pact.Core.Command.Server
import Pact.Core.Command.Types
import Pact.Core.Hash
import Pact.Core.PactValue
import Pact.Core.StableEncoding
import qualified Pact.JSON.Encode as J
import Servant.API
import Servant.Client
import Servant.Server
import Test.Tasty
import qualified Test.Tasty.HUnit as HUnit
import Test.Tasty.Wai
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Pact.Core.Names
import NeatInterpolation (text)
import Pact.Core.Guards
import qualified Data.Vector as V
import qualified Data.Map.Strict as M


sendClient :: SendRequest -> ClientM SendResponse
pollClient :: PollRequest -> ClientM PollResponse
listenClient :: ListenRequest -> ClientM ListenResponse
localClient :: LocalRequest -> ClientM LocalResponse
versionClient :: ClientM Text
(sendClient :<|> pollClient :<|> listenClient :<|> localClient) :<|> versionClient = client (Proxy @API)

tests :: IO TestTree
tests =  do
  env <- defaultEnv
  pure $ testGroup "PactServer"
    [ t404 env
    , sendTests env
    , listenTests env
    , versionTest env
    , integrationTests env
    , localTests env
    , testPactContinuation env
    ]
  where
  testCase env = testWai (serve (Proxy @API) (server env))
  t404 env = testCase env "non-existing endpoint gives 404" $ do
    r404 <- get "/does/not/exists/"
    assertStatus 404 r404
  sendTests env = testGroup "send endpoint"
    [ testCase env "unsupported media type (no header set)" $ do
        res <- post "/api/v1/send" mempty
        assertStatus 415 res
    , testCase env "unsupported media type (wrong media type)" $ do
        res <- postWithHeaders "/api/v1/send" mempty [(HTTP.hContentType, "text/html; charset=utf-8")]
        assertStatus 415 res
    , testCase env "accept valid request" $ do
        serializedCmd <- liftIO mkSubmitBatch
        res <- postWithHeaders "/api/v1/send" serializedCmd [(HTTP.hContentType, "application/json")]
        assertStatus 200 res
    ]
  listenTests env = testGroup "listen endpoint"
    [ testCase env "non existing request key results in 404" $ do
        -- hash with pactHashLength (32) size
        let h = Hash "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            req = J.encode $ J.build $ ListenRequest (RequestKey h)
        res <- postWithHeaders "/api/v1/listen" req  [(HTTP.hContentType, "application/json")]
        assertStatus 404 res

    , testCase env "request with invalid request key results in 400" $ do
        let h = Hash ""
            req = J.encode $ J.build $ ListenRequest (RequestKey h)
        res <- postWithHeaders "/api/v1/listen" req  [(HTTP.hContentType, "application/json")]
        assertStatus 400 res
    ]
  localTests env = testGroup "local endpoint"
    [ testCase env "return correct result" $ do
        cmd <- liftIO  mkLocalRequest
        res@(SResponse _ _ reqResp) <- postWithHeaders "/api/v1/local" cmd [(HTTP.hContentType, "application/json")]
        assertStatus 200 res
        let (Just (LocalResponse cmdResult)) :: Maybe LocalResponse = A.decodeStrict $ LBS.toStrict reqResp
        assertEqual "Result match expected output" (PactResultOk $ PInteger 3) (_crResult cmdResult)
    ]
  integrationTests env = testGroup "integration test (combined send and listen)"
    [ testCase env "send and listen request" $ do
        cmd <- liftIO mkSubmitBatch
        res@(SResponse _ _ reqResp) <- postWithHeaders "/api/v1/send" cmd [(HTTP.hContentType, "application/json")]
        assertStatus 200 res

        let (Just (SendResponse (RequestKeys rks))) :: Maybe SendResponse = A.decodeStrict $ LBS.toStrict reqResp
        assertBool "Response contains one request key" (NE.length rks == 1)

        let req = J.encode $ J.build $ ListenRequest (NE.head rks)

        res'@(SResponse _ _ reqResp') <- postWithHeaders "/api/v1/listen" req  [(HTTP.hContentType, "application/json")]
        assertStatus 200 res'

        let (Just (ListenResponse cmdResult)) :: Maybe ListenResponse = A.decodeStrict $ LBS.toStrict reqResp'
        assertEqual "Result match expected output" (PactResultOk $ PInteger 3) (_crResult cmdResult)
    ]
  versionTest env = testCase env "version endpoint" $ do
    res@(SResponse _ _ cnt) <- get "/version"
    assertStatus 200 res
    let cnt' = T.decodeUtf8 $ LBS.toStrict cnt
    assertBool "should contain 'pact version' string" (T.isPrefixOf "pact version" cnt')

  testPactContinuation env = testGroup "pact continuation" [
    testCase env "executes the next step and updates pact's state" $ do
        ks <- liftIO generateEd25519KeyPair
        modCmd <- liftIO $ mkCmd ks (threeStepPactCode "testCorrectNextStep")
        -- testCmd <- liftIO $ mkCmd ks "(testCorrectNextStep.tester)"
        -- contCmd <- liftIO $ mkCont (DefPactId $ hashToText (_cmdHash testCmd)) 1 False PUnit (def :: PublicMeta) [(DynEd25519KeyPair ks, [])] [] (Just "nonce") Nothing Nothing
        let cmds = J.encode $ J.build $ SubmitBatch $ modCmd NE.:| [] --[testCmd, contCmd]
        resp@(SResponse _ _ reqResp) <- postWithHeaders "/api/v1/send" cmds [(HTTP.hContentType, "application/json; charset=utf-8")]
        assertStatus 200 resp

        let (Just (SendResponse (RequestKeys h@(modDeploy NE.:| _ )))) :: Maybe SendResponse = A.decodeStrict $ LBS.toStrict reqResp

        -- check module deployment
        let req = J.encode $ J.build $ ListenRequest (cmdToRequestKey modCmd)
        res <- postWithHeaders "/api/v1/listen" req  [(HTTP.hContentType, "application/json")]

        
        liftIO $ print res
    ]
assertBool :: String -> Bool -> Session ()
assertBool msg c = liftIO (HUnit.assertBool msg c)

assertEqual :: (Eq a , Show a)=> String -> a -> a -> Session ()
assertEqual msg a b = liftIO (HUnit.assertEqual msg a b)

mkSubmitBatch :: IO LBS.ByteString
mkSubmitBatch = do
  ks <- generateEd25519KeyPair
  let rpc :: PactRPC Text = Exec (ExecMsg "(+ 1 2)" PUnit)
      metaData = J.build $ StableEncoding (def :: PublicMeta)
  cmd <- mkCommand [(ks, [])] [] metaData "nonce" Nothing rpc
  pure $ J.encode $ J.build $ SubmitBatch $ fmap decodeUtf8 cmd NE.:| []

mkLocalRequest :: IO LBS.ByteString
mkLocalRequest = do
  ks <- generateEd25519KeyPair
  let rpc :: PactRPC Text = Exec (ExecMsg "(+ 1 2)" PUnit)
      metaData = J.build $ StableEncoding (def :: PublicMeta)
  cmd <- mkCommand [(ks, [])] [] metaData "nonce" Nothing rpc
  pure $ J.encode $ J.build $ LocalRequest $ fmap decodeUtf8 cmd

mkCmd :: Ed25519KeyPair -> Text -> IO (Command Text)
mkCmd ks code = do
  let mguard = toB16Text $ getPublic ks
      md = PObject $ M.fromList [("admin-keyset", PList (V.fromList [PString mguard]))]
      rpc :: PactRPC Text = Exec (ExecMsg code md)
      metaData = J.build $ StableEncoding (def :: PublicMeta)
  cmd <- mkCommand [(ks, [])] [] metaData "nonce" Nothing rpc
  liftIO $ print cmd
  pure $ fmap decodeUtf8 cmd

threeStepPactCode :: T.Text -> T.Text
threeStepPactCode moduleName =
  [text|
    (define-keyset 'k (read-keyset "admin-keyset"))
      (module $moduleName 'k
        (defpact tester ()
          (step "step 0")
          (step "step 1")
          (step "step 2"))) |]
