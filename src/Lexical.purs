module Lexical where

import Prelude
import Control.Monad.Trans (lift)
import Control.Monad.State (State(), modify, gets)
import Control.Apply ((*>), (<*))
import Control.Alt ((<|>))
import Control.Lazy (fix)

import Text.Parsing.Parser (ParserT(..), PState(..), fail)
import Text.Parsing.Parser.Combinators (try, option, between, choice, sepBy)
import Text.Parsing.Parser.Pos (Position(..))
import Text.Parsing.Parser.String
  (skipSpaces, satisfy, string, eof, char, oneOf, anyChar)

import Data.List (List(..), tail, head, last, toUnfoldable, many, some, singleton, length, concat)
import qualified Data.Array as Array
import Data.Maybe (fromMaybe, Maybe(..))
import Data.Either (Either(..))
import Data.String (fromCharArray, joinWith)
import Data.Char (toString)
import Data.Char.Unicode (isAlpha, isDigit, isHexDigit, isPrint)
import Data.Tuple (Tuple(..))
import Data.Generic (class Generic, gShow, gEq, gCompare)

-- Define Token
data TOKEN
  = ID String
  | KEY String
  | OP String
  | SYM String
  | RAW String
  | LIT String
  | BLOCKL | BLOCKR
  | STATEL | STATER
  | NL

derive instance genericTOKEN :: Generic TOKEN
instance showTOKEN :: Show TOKEN where show = gShow
instance eqTOKEN :: Eq TOKEN where eq = gEq

newtype PositionToken = PositionToken {position::Position, token::TOKEN}
type TokenStream = List PositionToken

-- Get Position --
getPos :: forall s m. (Monad m) => ParserT s m Position
getPos = ParserT $ \(PState { input: s, position: pos }) ->
  return { input: s, consumed: false, result: Right pos, position: pos }

makeToken :: Position -> TOKEN -> PositionToken
makeToken pos tok = PositionToken {position: pos, token: tok}

mkStream :: Position -> TOKEN -> TokenStream
mkStream p t = singleton $ makeToken p t

-- Indent State --
data Indent = BlockIndent Int
            | StateIndent Int
            | ParenIndent Int
            | SquareIndent Int
            | BraceIndent Int
            | NoneIndent

type IndentStack = List Indent

-- Some Utils Function --
fromCharList :: List Char -> String
fromCharList = fromCharArray <<< toUnfoldable

joinListWith :: String -> List String -> String
joinListWith sep = joinWith sep <<< toUnfoldable

eol :: forall m. (Monad m) => ParserT String m Unit
eol = (try (string "\r\n") <|> string "\r" <|> string "\n")
      *> return unit

indent :: forall m. (Monad m) => ParserT String m Int
indent = length <$> many (satisfy \c -> c == ' ' || c == '\t')

-- Indent Handle Parser --
type TokenParser a = ParserT String (State IndentStack) a

topIndent :: TokenParser Indent
topIndent = lift $  gets (fromMaybe NoneIndent <<< head)

topIndentNum :: TokenParser Int
topIndentNum = do
  rest <- topIndent
  return $ case rest of
    BlockIndent n -> n
    StateIndent n -> n
    ParenIndent n -> n
    SquareIndent n -> n
    BraceIndent n -> n
    NoneIndent -> 0

popIndent :: TokenParser Unit
popIndent = lift $ modify (fromMaybe (Nil::List Indent) <<< tail)

pushIndent :: Indent -> TokenParser Unit
pushIndent i = lift $ modify (Cons i)

-- Block and Statement Block Start --
blockIndent :: TokenParser TokenStream
blockIndent = do
  skipSpaces
  pos@(Position {line: _, column: col}) <- getPos
  pushIndent (BlockIndent col)
  return $ singleton $ makeToken pos BLOCKL

stateIndent :: TokenParser TokenStream
stateIndent = do
  skipSpaces
  pos@(Position {line: _, column: col}) <- getPos
  pushIndent (StateIndent col)
  return $ singleton $ makeToken pos STATEL

-- Handle Newline And Parens
newline :: TokenParser TokenStream
newline = do
  ind <- (try $ skipSpaces *> eof *> return 0)
       <|> (fromMaybe 0 <<< last <$> some (eol *> indent))
  pos <- getPos
  fix $ \handle -> do
    rest <- topIndent
    case rest of
      ParenIndent n -> if ind > n then return Nil else fail "Indent Error"
      SquareIndent n -> if ind > n then return Nil else fail "Indent Error"
      BraceIndent n -> if ind > n then return Nil else fail "Indent Error"
      NoneIndent -> if ind /= 0 then return Nil else fail "Indent Error"
      StateIndent n -> case compare ind n of
        EQ -> return $ mkStream pos NL
        GT -> pushIndent (StateIndent ind) *> (return $ mkStream pos STATEL)
        LT -> do
          popIndent
          n' <- topIndentNum
          case compare ind n' of
            GT -> fail "Indent Error"
            _ -> (++) (mkStream pos STATER) <$> handle
      BlockIndent n -> case compare ind n of
        EQ -> return $ mkStream pos NL
        GT -> return Nil
        LT -> do
          popIndent
          n' <- topIndentNum
          case compare ind n' of
            GT -> fail "Indent Error"
            _ -> (++) (mkStream pos BLOCKR) <$> handle

parrten :: TokenParser TokenStream
parrten = left <|> right
  where left = do
          pos <- getPos
          tok <- SYM <$> (string "(" <|> string "[" <|> string "{")
          n <- topIndentNum
          case tok of
            SYM "(" -> pushIndent $ ParenIndent n
            SYM "[" -> pushIndent $ SquareIndent n
            SYM "{" -> pushIndent $ BraceIndent n
            _ -> fail "Parse Token Error"
          return $ mkStream pos tok

        right = do
          pos <- getPos
          tok <- SYM <$> (string ")" <|> string "]" <|> string "}")
          fix $ \handle -> do
            top <- topIndent
            case top of
              NoneIndent -> fail "Indent Error"
              BlockIndent _ -> popIndent *> ((++) (mkStream pos BLOCKR) <$> handle)
              StateIndent _ -> popIndent *> ((++) (mkStream pos STATER) <$> handle)
              ParenIndent _ -> if tok == SYM ")" then popIndent *> return (mkStream pos tok) else fail "Paren Error"
              SquareIndent _ -> if tok == SYM "]" then popIndent *> return (mkStream pos tok) else fail "Paren Error"
              BraceIndent _ -> if tok == SYM "}" then popIndent *> return (mkStream pos tok) else fail "Paren Error"

-- ID / Keywrod / Symobl / Operator Token Parser --

isIdStart :: Char -> Boolean
isIdStart c = isAlpha c && c == '_'

isIdBody :: Char -> Boolean
isIdBody c = isAlpha c && isDigit c && c == '_'

isReservedWord :: String -> Boolean
isReservedWord word = (<=) 0 $ fromMaybe (-1) $ Array.elemIndex word
                      [ "let", "in", "where", "if", "then", "else"
                      , "case", "of", "with", "do"
                      , "switch", "return", "while", "break", "continue"
                      , "infixr", "infixl", "prefix", "postfix"
                      , "import", "as", "export"
                      , "true", "false", "null", "undefined" ]

identifier :: TokenParser TokenStream
identifier = do
  pos <- getPos
  str <- fromCharList <$> (Cons <$> satisfy isIdStart <*> (many $ satisfy isIdBody))
  if isReservedWord str
    then case str of
      "true" -> return $ mkStream pos $ LIT str
      "false" -> return $ mkStream pos $ LIT str
      "null" -> return $ mkStream pos $ LIT str
      "undefined" -> return $ mkStream pos $ LIT str
      "where" -> (++) (mkStream pos $ KEY str) <$> blockIndent
      "of" -> (++) (mkStream pos $ KEY str) <$> blockIndent
      "do" -> (++) (mkStream pos $ KEY str) <$> blockIndent
      _ -> return $ mkStream pos $ KEY str
    else return $ mkStream pos $ ID str

isReservedSymbol :: String -> Boolean
isReservedSymbol word = (<=) 0 $ fromMaybe (-1) $ Array.elemIndex word
                      [ "=", "->", "<-", ".", ":", ",", "\\"]

isOpChar :: Char -> Boolean
isOpChar c = (<=) 0 $ fromMaybe (-1) $ Array.elemIndex c 
             ['~','!','@','$','%','^','&','*','_','+','-','=','|','<','>','?','/','.',':',',','\\']

operator :: TokenParser TokenStream
operator = do
  pos <- getPos
  str <- fromCharList <$> some (satisfy isOpChar)
  if isReservedSymbol str
    then case str of
      "=" -> (skipSpaces *> eol *> ((++) (mkStream pos $ SYM str) <$> stateIndent))
             <|> return (mkStream pos (SYM str))
      _ -> return $ mkStream pos $ SYM str
    else return $ mkStream pos $ OP str

-- General Parser --
hexNum :: TokenParser String
hexNum = try $ string "0x" *>
         ((++) "0x" <<< fromCharList <$> many (satisfy isHexDigit))

number :: TokenParser String
number = do
  int <- some (satisfy isDigit)
  dec <- option Nil do
    point <- char '.'
    Cons point <$> some (satisfy isDigit)
  return <<< fromCharList $ int ++ dec

surroundBy :: forall m.(Monad m) => Char -> ParserT String m String
surroundBy c = between (char c) (char c)
                   ( mksurround cStr <<< joinListWith "" <$> many contents)
  where contents = try (string ("\\" ++ cStr))
                   <|> (toString <$> satisfy (\c' -> c /= c' && isPrint c'))
        cStr = toString c
        mksurround c' str = c' ++ str ++ c'

strlit :: TokenParser String
strlit = surroundBy '\'' <|> surroundBy '"'

regexp :: TokenParser String
regexp = do
  exp <- surroundBy '/'
  flags <- fromCharList <$> option Nil (many $ oneOf ['g', 'i', 'm'])
  return $ exp ++ flags

literal :: TokenParser TokenStream
literal = do
  pos <- getPos
  str <- hexNum <|> number <|> strlit <|> regexp
  return $ mkStream pos $ LIT str

raw :: TokenParser TokenStream
raw = do
  pos <- getPos
  mkStream pos <<< RAW <$> surroundBy '`'

-- lexer --
lexer :: TokenParser TokenStream
lexer = concat <$> sepBy tokens spaces
  where spaces = many $ satisfy \c -> c == ' ' || c == '\t'
        tokens = choice [identifier, operator, parrten, literal, raw, newline]

-- lengecy code --

  -- return $ mkStream pos if isReservedSymbol str

  --                       then case str of


-- identifier :: TokenParser TokenStream
-- identifier = do
--   pos <- getPos
--   str <- fromCharList <$> (Cons <$> satisfy isIdStart <*> (many $ satisfy isIdBody))
--   return $ mkStream pos if isReservedWord str
--                         then case str of
--                           "true" -> LIT str
--                           "false" -> LIT str
--                           "null" -> LIT str
--                           "undefined" -> LIT str
--                           _ -> KEY str
--                         else ID str

-- operator :: TokenParser TokenStream
-- operator = do
--   pos <- getPos
--   str <- fromCharList <$> some (satisfy isOpChar)
--   return $ mkStream pos if isReservedSymbol str
--                         then case str of

-- topind :: TokenParser Indent
-- topind = lift $ gets topIndent

-- topindn :: TokenParser Int
-- topindn = do
--   r <- lift $ gets topIndent
--   return $ case r of
--     ExprIndent n -> n
--     StatIndent n -> n
--     NoneIndent -> 0

-- popind :: TokenParser Unit
-- popind  = lift $ modify popIndent

-- pushind :: Indent -> TokenParser Unit
-- pushind i  = lift $ modify (pushIndent i)

-- toptok:: TokenParser TOKEN
-- toptok = lift $ gets topToken

-- poptok :: TokenParser Unit
-- poptok  = lift $ modify popToken

-- pushtok :: TOKEN -> TokenParser Unit
-- pushtok t = lift $ modify (pushToken t)

-- reducetok :: TOKEN -> TokenParser Unit
-- pushtok

-- exprIndent :: TokenParser TokenStream
-- exprIndent = do
--   skipSpaces
--   pos@(Position {line: _, column: col}) <- getPos
--   let blockStart = makeToken pos BLS
--   pushtok BLS
--   pushind (ExprIndent col)
--   return $ singleton blockStart

-- statIndent :: TokenParser TokenStream
-- statIndent = do
--   skipSpaces
--   pos@(Position {line: _, column: col}) <- getPos
--   let blockStart = makeToken pos STS
--   pushtok STS
--   pushind (StatIndent col)
--   return $ singleton blockStart

-- indent :: forall m. (Monad m) => ParserT String m Int
-- indent = length <$> many (satisfy \c -> c == ' ' || c == '\t')

-- eol :: forall m. (Monad m) => ParserT String m Unit
-- eol = (try (string "\r\n") <|> string "\r" <|> string "\n")
--       *> return unit

-- notInPar :: TokenParser Boolean
-- notInPar = do
--   t <- toptok
--   return $ case t of
--     (SYM "(") -> true
--     (SYM "[") -> true
--     (SYM "{") -> true
--     _ -> false

-- newline :: TokenParser TokenStream
-- newline = do
--   indent <- (try $ skipSpaces *> eof *> return 0)
--        <|> (fromMaybe 0 <<< last <$> some (eol *> indent))
--   pos <- getPos
--   let mkSinPosTok = singleton <<< makeToken pos
--   fix $ \handle -> do
--     rest <- Tuple <$> topind <*> toptok
--     case rest of
--       Tuple _ (SYM "(") -> return Nil
--       Tuple _ (SYM "[") -> return Nil
--       Tuple _ (SYM "{") -> return Nil

--       Tuple (StatIndent top) tok -> case compare indent top of
--         EQ -> return <<< mkSinPosTok $ NL
--         GT -> do
--           pushtok STS
--           pushind (StatIndent indent)
--           return <<< mkSinPosTok $ STS
--         LT -> do
--           popind
--           top' <- topindn
--           case compare indent top of
--             GT -> fail "Indent Error"
--             _ -> case tok of
--               STS -> (++) (mkSinPosTok STE) <$> handle <* poptok
--               BLS -> (++) (mkSinPosTok BLE) <$> handle <* poptok
--               _ -> fail "Indent Error"

--       Tuple (ExprIndent top) tok -> case compare indent top of
--         LT -> do
--           popind
--           top' <- topindn
--           case compare indent top of
--             GT -> fail "Indent Error"
--             _ -> case tok of
--               STS -> (++) (mkSinPosTok STE) <$> handle <* poptok
--               BLS -> (++) (mkSinPosTok BLE) <$> handle <* poptok
--               _ -> fail "Indent Error"
--         _ -> return <<< mkSinPosTok $ NL

--       Tuple (NoneIndent) _ -> fail "Indent Error"

-- parrten :: TokenParser TokenStream
-- parrten = left <|> right
--   where left = do
--           pos <- getPos
--           tok <- SYM <$> string "(" <|> string "[" <|> string "{"
--           pushtok tok
--           return <<< singleton $ makeToken pos tok
--         right = do
--           pos <- getPos
--           tok <- SYM <$> string ")" <|> string "]" <|> string "}"
--           let mkSinPosTok = singleton <<< makeToken pos
--           fix \handle -> do
--             top <- toptok
--             case top of
--               STS -> (++) (mkSinPosTok STE) <$> handle <* poptok
--               BLS -> (++) (mkSinPosTok STE) <$> handle <* poptok

      -- Tuple (StatIndent last_indent) (tok) -> 
  -- n <- fromMaybe 0 <<< last <$> some (eol *> indent)
  -- (eof *> return Nil)
  --   <|> fix (\handle -> do
  --           )

-- topIndent :: IndentState -> Indent
-- topIndent (IndentState {indentStack: is, tokenStack: ts}) =
--   fromMaybe NoneIndent <<< head $ is

-- popIndent :: IndentState -> IndentState
-- popIndent (IndentState {indentStack: is, tokenStack: ts}) =
--   (IndentState {indentStack: fromMaybe Nil $ tail is, tokenStack: ts})

-- pushIndent :: Indent -> IndentState -> IndentState
-- pushIndent i (IndentState {indentStack: is, tokenStack: ts}) =
--   (IndentState {indentStack: Cons i is, tokenStack: ts})

-- topToken :: IndentState -> TOKEN
-- topToken (IndentState {indentStack: is, tokenStack: ts}) =
--   fromMaybe NONE <<< head $ ts
--     where emptyPos = Position {line:0, column:0}

-- popToken :: IndentState -> IndentState
-- popToken (IndentState {indentStack: is, tokenStack: ts}) =
--   (IndentState {indentStack: is, tokenStack: fromMaybe Nil $ tail ts})

-- pushToken :: TOKEN -> IndentState -> IndentState
-- pushToken t (IndentState {indentStack: is, tokenStack: ts}) =
--   (IndentState {indentStack: is, tokenStack: Cons t ts})


  -- mkTokStream <$> getPos <*> litStr 
  -- where mkTokStream pos str = singleton $ makeToken pos (LIT str)
  --       litStr = hexNum <|> number <|> strlit <|> regexp
  --                <|> (choice $ map (try <<< string)
  --                     ["true", "false", "null", "undefined"])

    -- contents = try escaped <|> satisfy (\c' -> c /= c' && isPrint c)
    -- escaped = char '\\' *> (escapeMap <$> satisfy isPrint)
    -- escapeMap c' = case c' of
    --   'n' -> '\n'
    --   't' -> '\t'
    --   'r' -> '\r'
    --   '0' -> '\0'
    -- contents = try (string ("\\" ++ cStr)) <|> (toString <$> satisfy ((/=) c))
    -- cStr = toString c
    -- escape c = case c of
      -- ''

-- hexNumStr :: IndTokParser String
-- hexNumStr = try $ string "0x" *> ((++) "0x" <<< fromCharArray <$> many (satisfy isHex))

-- numStr :: IndTokParser String
-- numStr = do
--   int <- some (satisfy isNumber)
--   dec <- option [] do
--     point <- char '.'
--     cons point <$> some (satisfy isNumber)
--   return <<< fromCharArray $ int ++ dec

-- litNum :: IndTokParser TokenStream
-- litNum = withPos $ TLiteral <<< LNummber
--          <$> (numStr <|> hexNumStr)

-- -- Boolean Literal Token Parser --
-- litBool :: IndTokParser TokenStream
-- litBool = withPos $ TLiteral <<< LBoolean
--           <$> (try (string "true") <|> try (string "false"))

-- -- String Literal Token Parser --
-- escBetween :: forall m.(Monad m) => Char -> ParserT String m String
-- escBetween c = between (char c) (char c) ((\s -> cStr ++ s ++ cStr) <<< joinWith "" <$> many contents)
--   where contents = try (string ("\\" ++ cStr)) <|> (toString <$> satisfy ((/=) c))
--         cStr = toString c

-- litStr :: IndTokParser TokenStream
-- litStr = withPos $  TLiteral <<< LString <$> (escBetween '\'' <|> escBetween '"')

-- -- Regexp Literal Token Parser --
-- litReg :: IndTokParser TokenStream
-- litReg = withPos $ TLiteral <<< LRegexp <$> do
--   regexp <- escBetween '/'
--   flags <- fromCharArray <$> option [] (many $ oneOf ['g', 'i', 'm'])
--   return $ regexp ++ flags

-- -- Frogin Literal Token Parser --
-- litFrogin :: IndTokParser TokenStream
-- litFrogin = withPos $ TLiteral <<< LFrogin <$> do
--   try $ between (string "```") (string "```") (fromCharArray <$> many anyChar)

-- -- Null Literal Token Parser --
-- litNull :: IndTokParser TokenStream
-- litNull = withPos $ TLiteral <$> (try (string "null") *> return LNull)

-- -- Undefined Literal Token Parser --
-- litUndef :: IndTokParser TokenStream
-- litUndef = withPos $ TLiteral <$> (try (string "undefined") *> return LNull)

-- Handle Indent and Pair --
-- topIndent :: TokenParser Indent
-- topIndent = lift $ fromMaybe NoneIndent <<< head <$> gets 

-- import Grammar (Literal(..))
-- -- import Global

-- import Control.Monad.Trans (lift)
-- import Control.Monad.State (State, modify, gets)
-- import Control.Apply ((*>))
-- import Control.Alt ((<|>))
-- import Control.Lazy (fix)
-- -- import Data.Monoid ((<>))
-- -- import Data.Array ()

-- import Text.Parsing.Parser (ParserT(..), PState(..), fail)
-- import Text.Parsing.Parser.Combinators (try, option, between)
-- import Text.Parsing.Parser.Pos (Position(..))
-- import Text.Parsing.Parser.String (skipSpaces, satisfy, string, eof, char, oneOf, anyChar)

-- import Data.Maybe (fromMaybe, Maybe(..))
-- import Data.Array (cons, head, tail, many, length, last, some, elemIndex, singleton)
-- import Data.Either (Either(..))
-- -- import Data.Tuple (Tuple(..))
-- import Data.String (indexOf, fromCharArray, joinWith)
-- import Data.Char (toString)

-- data Token
--   = TKeyword String
--   | TID String
--   | TSymbol String
--   | TOperator String
--   | TNewLine
--   | TBS | TBE
--   | TLiteral Literal

-- newtype PositionToken = PositionToken {pos::Position, tok::Token}
-- type TokenStream = Array PositionToken


-- Indent Token Parser --
-- data Indent = ExpIndent Int | StatIndent Int | NoIndent
-- newtype IndentState = IndentStat {indent_stack:: Indent, pair_stack::}

-- type IndTokParser a = ParserT String (Statement)a

-- -- Position --
-- mkPosTok :: Position -> Token -> PositionToken
-- mkPosTok pos tok = PositionToken {pos: pos, tok: tok}

-- getPos :: forall s m. (Monad m) => ParserT s m Position
-- getPos = ParserT $ \(PState { input: s, position: pos }) ->
--   return { input: s, consumed: false, result: Right pos, position: pos }

-- withPos :: IndTokParser Token -> IndTokParser TokenStream
-- withPos tokenizer = getPos >>= \pos -> singleton <<< mkPosTok pos <$> tokenizer

-- withSkip :: forall m a. (Monad m) => ParserT String m a -> ParserT String m a
-- withSkip tokenizer = (many $ satisfy \c -> c == ' ' || c == '\t') *> tokenizer


-- -- Token Parser --
-- maybe2bool :: forall a. Maybe a -> Boolean
-- maybe2bool (Just a) = true
-- maybe2bool (Nothing) = false

-- isHex :: Char -> Boolean
-- isHex c = maybe2bool $ indexOf (toString c) "0123456789abcdefABCDEF"

-- isNumber :: Char -> Boolean
-- isNumber c = maybe2bool $ indexOf (toString c) "01234567890"

-- isAlpha :: Char -> Boolean
-- isAlpha c = maybe2bool $ indexOf (toString c) "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

-- isIDHead :: Char -> Boolean
-- isIDHead c = isAlpha c || c == '_'

-- isIDBody :: Char -> Boolean
-- isIDBody c = isAlpha c || isNumber c || c == '_'

-- isOpChar :: Char -> Boolean
-- isOpChar c = maybe2bool $ indexOf (toString c) "~!@$%^&*_+-=|:<>?/."

-- isComStar :: Char -> Boolean
-- isComStar c = c == '#'

-- isReserved :: String -> Boolean
-- isReserved s = maybe2bool $ elemIndex s reservedList
--   where reservedList = [ "=", "->", "<-", ".", ":", ",", "\\"
--                        , "let", "in", "where", "if", "then", "else", "case", "of", "with", "do"
--                        , "switch", "return", "while", "break", "continue"
--                        , "true", "false", "null", "undefined"
--                        , "infixr", "infixl", "prefix", "postfix"
--                        , "import", "as", "export"]

-- -- shouldWithBlock:: String -> Boolean
-- -- shouldWithBlock = maybe2bool $ elemIndex s reservedList
-- --   where reservedList = [ "=", "->", "<-", ".", ":", ",", "\\"
-- --                        , "let", "in", "where", "if", "else", "case", "of", "with", "do"
-- --                        , "switch", "return", "while", "break", "continue"
-- --                        , "true", "false", "null", "undefined"
-- --                        , "infixr", "infixl", "prefix", "postfix"
-- --                        , "import", "as", "export"]

-- -- ID / Keyword Token Parser --
-- idKeyw :: IndTokParser TokenStream
-- idKeyw = withPos $ do
--   h <- satisfy isIDHead
--   b <- many $ satisfy isIDBody
--   let id = fromCharArray $ cons h b
--   return if isReserved id
--          then case id of
--            "true" -> TLiteral $ LBoolean id
--            "false" -> TLiteral $ LBoolean id
--            "null" -> TLiteral LNull
--            "undefined" -> TLiteral LUndef
--            _ -> TKeyword id
--          else TID id

-- -- Symbol / Operator Token Parser --
-- -- symOp :: IndTokParser Token
-- -- symOp :: IndTokParser

-- -- Number Literal Token Parser --
-- hexNumStr :: IndTokParser String
-- hexNumStr = try $ string "0x" *> ((++) "0x" <<< fromCharArray <$> many (satisfy isHex))

-- numStr :: IndTokParser String
-- numStr = do
--   int <- some (satisfy isNumber)
--   dec <- option [] do
--     point <- char '.'
--     cons point <$> some (satisfy isNumber)
--   return <<< fromCharArray $ int ++ dec

-- litNum :: IndTokParser TokenStream
-- litNum = withPos $ TLiteral <<< LNummber
--          <$> (numStr <|> hexNumStr)

-- -- -- Boolean Literal Token Parser --
-- -- litBool :: IndTokParser TokenStream
-- -- litBool = withPos $ TLiteral <<< LBoolean
-- --           <$> (try (string "true") <|> try (string "false"))

-- -- String Literal Token Parser --
-- escBetween :: forall m.(Monad m) => Char -> ParserT String m String
-- escBetween c = between (char c) (char c) ((\s -> cStr ++ s ++ cStr) <<< joinWith "" <$> many contents)
--   where contents = try (string ("\\" ++ cStr)) <|> (toString <$> satisfy ((/=) c))
--         cStr = toString c

-- litStr :: IndTokParser TokenStream
-- litStr = withPos $  TLiteral <<< LString <$> (escBetween '\'' <|> escBetween '"')

-- -- Regexp Literal Token Parser --
-- litReg :: IndTokParser TokenStream
-- litReg = withPos $ TLiteral <<< LRegexp <$> do
--   regexp <- escBetween '/'
--   flags <- fromCharArray <$> option [] (many $ oneOf ['g', 'i', 'm'])
--   return $ regexp ++ flags

-- -- Frogin Literal Token Parser --
-- litFrogin :: IndTokParser TokenStream
-- litFrogin = withPos $ TLiteral <<< LFrogin <$> do
--   try $ between (string "```") (string "```") (fromCharArray <$> many anyChar)

-- -- -- Null Literal Token Parser --
-- -- litNull :: IndTokParser TokenStream
-- -- litNull = withPos $ TLiteral <$> (try (string "null") *> return LNull)

-- -- -- Undefined Literal Token Parser --
-- -- litUndef :: IndTokParser TokenStream
-- -- litUndef = withPos $ TLiteral <$> (try (string "undefined") *> return LNull)
