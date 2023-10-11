{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DerivingVia #-}


module Pact.Core.Syntax.LexUtils where

import Control.Lens hiding (uncons)
import Control.Monad.Except
import Control.Monad.State.Strict
import Data.Word (Word8)
import Data.Text(Text)
import Data.List(intersperse)
import Data.ByteString.Internal(w2c)
import Data.ByteString(ByteString)
import Data.Default

import qualified Data.ByteString as B
import qualified Data.Text as T

import Pact.Core.Info
import Pact.Core.Errors
import Pact.Core.Names
import Pact.Core.Pretty (Pretty(..))
import Pact.Core.Syntax.ParseTree

type ParserT = Either PactErrorI
type ParsedExpr = Expr SpanInfo
type ParsedDefun = Defun SpanInfo
type ParsedDef = Def SpanInfo
type ParsedDefConst = DefConst SpanInfo
type ParsedModule = Module SpanInfo
type ParsedTopLevel = TopLevel SpanInfo
type ParsedIfDef = IfDef SpanInfo
type ParsedInterface = Interface SpanInfo
type ParsedReplTopLevel = ReplTopLevel SpanInfo

data PosToken =
  PosToken
  { _ptToken :: Token
  , _ptInfo :: SpanInfo
  }
  deriving (Show, Eq)

data Token
  -- Keywords
  = TokenLet
  | TokenIf
  | TokenLambda
  | TokenTry
  | TokenError
  | TokenModule
  | TokenKeyGov
  | TokenCapGov
  | TokenInterface
  | TokenImport
  | TokenStep
  | TokenStepWithRollback
  -- Def keywords
  | TokenDefun
  | TokenDefConst
  | TokenDefCap
  | TokenDefPact
  | TokenDefSchema
  | TokenDefTable
  | TokenDefProperty
  | TokenBless
  | TokenImplements
  -- Annotations
  | TokenDocAnn
  | TokenModelAnn
  | TokenEventAnn
  | TokenManagedAnn
  -- Delimiters
  | TokenOpenBrace -- {
  | TokenCloseBrace -- }
  | TokenOpenParens -- (
  | TokenCloseParens -- )
  | TokenOpenBracket
  | TokenCloseBracket
  | TokenComma
  | TokenColon
  | TokenDot
    -- Capabilities
  | TokenWithCapability
  | TokenCreateUserGuard
  -- | TokenRequireCapability
  -- | TokenComposeCapability
  -- | TokenInstallCapability
  -- | TokenEmitEvent
  -- Operators
  -- | TokenEq
  -- | TokenNeq
  -- | TokenGT
  -- | TokenGEQ
  -- | TokenLT
  -- | TokenLEQ
  -- | TokenPlus
  -- | TokenMinus
  -- | TokenMult
  -- | TokenDiv
  -- | TokenPow
  -- | TokenBitAnd
  -- | TokenBitOr
  -- | TokenBitComplement
  | TokenAnd
  | TokenOr
  | TokenSingleTick !Text
  | TokenIdent !Text
  | TokenNumber !Text
  | TokenString !Text
  | TokenTrue
  | TokenFalse
  | TokenBlockIntro
  | TokenSuspend
  | TokenDynAcc
  | TokenBindAssign
  -- Repl-specific tokens
  | TokenLoad
  -- Layout
  | TokenEOF
  deriving (Eq, Show)


data AlexInput
 = AlexInput
 { _inpLine   :: {-# UNPACK #-} !Int
 , _inpColumn :: {-# UNPACK #-} !Int
 , _inpLast :: {-# UNPACK #-} !Char
 , _inpStream :: ByteString
 }
 deriving (Eq, Show)

makeLenses ''AlexInput

alexPrevInputChar :: AlexInput -> Char
alexPrevInputChar = _inpLast

alexGetByte :: AlexInput -> Maybe (Word8, AlexInput)
alexGetByte (AlexInput line col _ stream) =
  advance <$> B.uncons stream
  where
  advance (c, rest) | w2c c  == '\n' =
    (c
    , AlexInput
    { _inpLine  = line +1
    , _inpColumn = 0
    , _inpLast = '\n'
    , _inpStream = rest})
  advance (c, rest) =
    (c
    , AlexInput
    { _inpLine  = line
    , _inpColumn = col +1
    , _inpLast = w2c c
    , _inpStream = rest})

newtype Layout
  = Layout Int
  deriving (Eq, Show)

newtype LexerM a =
  LexerM (StateT AlexInput (Either PactErrorI) a)
  deriving
    ( Functor, Applicative
    , Monad
    , MonadState AlexInput
    , MonadError PactErrorI)
  via (StateT AlexInput (Either PactErrorI))


initState :: ByteString -> AlexInput
initState = AlexInput 0 0 '\n'

getSpanInfo :: LexerM SpanInfo
getSpanInfo = do
  input <- get
  pure (SpanInfo (_inpLine input) (_inpColumn input) (_inpLine input) (_inpColumn input))

emit :: (Text -> Token) -> Text -> SpanInfo -> LexerM PosToken
emit f e s = pure (PosToken (f e) s)

token :: Token -> Text -> SpanInfo -> LexerM PosToken
token tok _ s = pure (PosToken tok s)

throwLexerError :: LexerError -> SpanInfo -> LexerM a
throwLexerError le = throwError . PELexerError le

throwLexerError' :: LexerError -> LexerM a
throwLexerError' le = getSpanInfo >>= throwLexerError le

throwParseError :: ParseError -> SpanInfo -> ParserT a
throwParseError pe = throwError . PEParseError pe

toAppExprList :: SpanInfo -> [Either ParsedExpr [(Field, MArg)]] -> [ParsedExpr]
toAppExprList i  (h:hs) = case h of
  Left e -> e : toAppExprList i hs
  Right binds -> [Binding binds (toAppExprList i hs) i]
toAppExprList _ [] = []

primType :: SpanInfo -> Text -> ParserT Type
primType i = \case
  "integer" -> pure TyInt
  "bool" -> pure TyBool
  "unit" -> pure TyUnit
  "guard" -> pure TyGuard
  "decimal" -> pure TyDecimal
  "time" -> pure TyTime
  "string" -> pure TyString
  "list" -> pure TyPolyList
  "object" -> pure TyPolyObject
  "keyset" -> pure TyKeyset
  e -> throwParseError (InvalidBaseType e) i

objType :: SpanInfo -> Text -> ParsedTyName -> ParserT Type
objType i t p = case t of
  "object" -> pure (TyObject p)
  "table" -> pure (TyTable p)
  e -> throwParseError (InvalidBaseType e) i

parseError :: ([PosToken], [String]) -> ParserT a
parseError (remaining, exps) =
  case (remaining, exps) of
    (_, []) -> handleTooMuchInput remaining
    (x:_, _) -> handleWithLastToken (_ptInfo x)
    (_, _) -> handleWithLastToken def
  where
  renderList e =
    "[" <> T.concat (intersperse ", " e) <> "]"
  renderRemaining r
    | length r <= 10 = renderList r
    | otherwise = renderList $ (<> ["..."]) $ take 10 r
  handleWithLastToken i =
    throwParseError (ParsingError (renderRemaining (T.pack <$> exps))) i
  handleTooMuchInput = \case
    (PosToken TokenCloseParens i):rest ->
      let rem' = renderRemaining (renderTokenText . _ptToken <$> rest)
      in throwParseError (TooManyCloseParens rem') i
    xs ->
      let rem' = renderRemaining (renderTokenText . _ptToken <$> xs)
      in throwParseError (UnexpectedInput rem') $ case xs of
        [] -> def
        x:_ -> _ptInfo x

runLexerT :: LexerM a -> ByteString -> Either PactErrorI a
runLexerT (LexerM act) s = evalStateT act (initState s)

renderTokenText :: Token -> Text
renderTokenText = \case
  TokenLet -> "let"
  TokenIf -> "if"
  TokenLambda -> "lambda"
  TokenTry -> "try"
  TokenError -> "error"
  TokenModule -> "module"
  TokenKeyGov -> "keyGov"
  TokenCapGov -> "capGov"
  TokenInterface -> "interface"
  TokenImport -> "use"
  TokenStep -> "step"
  TokenStepWithRollback -> "step-with-rollback"
  TokenDefun -> "defun"
  TokenDefConst -> "defconst"
  TokenDefCap -> "defcap"
  TokenDefPact -> "defpact"
  TokenDefSchema -> "defschema"
  TokenDefProperty -> "defproperty"
  TokenDefTable -> "deftable"
  TokenDocAnn -> "@doc"
  TokenEventAnn -> "@event"
  TokenManagedAnn ->  "@managed"
  TokenModelAnn -> "@model"
  TokenBless -> "bless"
  TokenImplements -> "implements"
  TokenOpenBrace -> "{"
  TokenCloseBrace -> "}"
  TokenOpenParens -> "("
  TokenCloseParens -> ")"
  TokenOpenBracket -> "["
  TokenCloseBracket -> "]"
  TokenComma -> ","
  TokenColon -> ":"
  TokenDot -> "."
  TokenBindAssign -> ":="
  TokenDynAcc -> "::"
  -- TokenEq -> "="
  -- TokenNeq -> "!="
  -- TokenGT -> ">"
  -- TokenGEQ -> ">="
  -- TokenLT -> "<"
  -- TokenLEQ -> "<="
  -- TokenPlus -> "+"
  -- TokenMinus -> "-"
  -- TokenMult -> "*"
  -- TokenDiv -> "/"
  -- TokenPow -> "^"
  -- TokenBitAnd -> "&"
  -- TokenBitOr -> "|"
  -- TokenBitComplement -> "~"
  TokenBlockIntro -> "progn"
  TokenAnd -> "and"
  TokenOr -> "or"
  TokenIdent t -> "ident<" <> t <> ">"
  TokenNumber n -> "number<" <> n <> ">"
  TokenSingleTick s -> "\'" <> s
  TokenString s -> "\"" <> s <> "\""
  TokenTrue -> "true"
  TokenFalse -> "false"
  TokenEOF -> "EOF"
  TokenSuspend -> "suspend"
  TokenLoad -> "load"
  TokenWithCapability -> "with-capability"
  TokenCreateUserGuard -> "create-user-guard"
  -- TokenRequireCapability -> "require-capability"
  -- TokenComposeCapability -> "compose-capability"
  -- TokenInstallCapability -> "install-capability"
  -- TokenEmitEvent -> "emit-event"



instance Pretty Token where
  pretty = pretty . renderTokenText

instance Pretty PosToken where
  pretty = pretty . _ptToken
