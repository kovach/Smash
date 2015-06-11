{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleInstances, TypeSynonymInstances #-}

module Language.Plover.Quote
 ( plover
 ) where

import Language.Haskell.TH as TH
import Language.Haskell.TH.Quote
--import Data.Typeable
--import Data.Data
import Data.Functor.Fixedpoint
import Text.ParserCombinators.Parsec
import Text.ParserCombinators.Parsec.Pos
import Text.ParserCombinators.Parsec.Expr
import Text.ParserCombinators.Parsec.Language
import qualified Text.ParserCombinators.Parsec.Token as Token
import Text.Printf
import Control.Monad
import Control.Monad.Free
import Control.Applicative hiding (many, (<|>))
import Data.Maybe
import Language.Plover.QuoteTypes

import qualified Language.Plover.Types as T

plover :: QuasiQuoter
plover = QuasiQuoter
         { quoteExp = ploverQuoteExp
         , quotePat = undefined
         , quoteType = undefined
         , quoteDec = undefined
         }

ploverQuoteExp :: String -> Q Exp
ploverQuoteExp s =
  do loc <- TH.location
     let parser' = do setPosition
                        (newPos
                         (TH.loc_filename loc)
                         (fst $ TH.loc_start loc)
                         (snd $ TH.loc_start loc))
                      toplevel
     case parse parser' "" s of
      Left e -> do fail ("Parse error " ++ show e) --reportError $ show e
                   --fail "Parse error" --reportError (show e) >> fail "Parse error"
      Right r -> return undefined

type Lexer = GenParser Char LexerState
data LexerState = LexerState {}

--runLexer :: String -- ^ Input file name
--            -> String -- ^ Input file contents
--            -> Either ParseError [Token]
--runLexer ifname input
--  = runParser lexer lexerState ifname input
--    where lexerState = LexerState {}

structFieldName = (:) <$> letter <*> many (alphaNum <|> char '_') <* whiteSpace

languageDef =
  emptyDef { Token.commentStart = "{-"
           , Token.commentEnd = "-}"
           , Token.commentLine = "--"
           , Token.nestedComments = True
           , Token.identStart = letter <|> oneOf "_"
           , Token.identLetter = alphaNum <|> oneOf "_'"
           , Token.opStart = mzero -- Token.opLetter languageDef
           , Token.opLetter = oneOf ":!#$%&*+./<=>?@\\^|-~"
           , Token.reservedOpNames = ["::", ":", "<-", "->", ":=", "~", "*", "-", "+", "/",
                                      "#", ".", ".*", "^", "$"]
           , Token.reservedNames = [
             "module", "function", "declare", "define", "extern", "static", "inline",
             "struct", "field",
             "vec", "for", "sum", "in", "if", "then", "else",
             "True", "False", "Void", "T", "_",
             "array", "and", "or", "not"
             ]
           , caseSensitive = True
           }

lexer = Token.makeTokenParser languageDef

identifier = Token.identifier lexer
lexeme = Token.lexeme lexer
reserved = Token.reserved lexer
reservedOp = Token.reservedOp lexer
parens = Token.parens lexer
symbol = Token.symbol lexer
brackets = Token.brackets lexer
braces = Token.braces lexer
naturalOrFloat = Token.naturalOrFloat lexer
stringLiteral = Token.stringLiteral lexer
semi = Token.semi lexer
whiteSpace = Token.whiteSpace lexer


withPos :: Parser (Expr' Expr) -> Parser Expr
withPos p = do pos <- getPosition
               v <- p
               return $ wrapPos pos v

-- Expression parser
expr :: Parser Expr
expr = store

-- Parse stores
store :: Parser Expr
store = do pos <- getPosition
           d <- tuple
           st pos d <|> def pos d <|> return d
  where st pos d = reservedOp "<-" >> (wrapPos pos . StoreExpr d <$> tuple)
        def pos d = reservedOp ":=" >> (wrapPos pos . DefExpr d <$> tuple)

-- Parse tuples
tuple :: Parser Expr
tuple = do pos <- getPosition
           ts <- tupleSep range (reservedOp ",")
           case ts of
            Right v -> return v
            Left vs -> return $ wrapPos pos $ Tuple vs
  where tupleSep p sep = do v <- p
                            vs <- many (try $ sep >> p)
                            trailing <- optionMaybe sep
                            if isNothing trailing && null vs
                              then return $ Right v
                              else return $ Left (v : vs)

range :: Parser Expr
range = noStart <|> withStart
  where noStart = do pos <- getPosition
                     reservedOp ":"
                     restRange pos Nothing
        withStart = do pos <- getPosition
                       t <- operators
                       (reservedOp ":" >> restRange pos (Just t)) <|> return t
        restRange pos t = do end <- optionMaybe operators
                             step <- optionMaybe (reservedOp ":" >> operators)
                             return $ wrapPos pos $ Range t end step

operators :: Parser Expr
operators = buildExpressionParser ops application
  where
    -- NB prefix operators at same precedence cannot appear together (like "-*x"; do "-(*x)")
    ops = [ [ Prefix (un Deref (reservedOp "*"))
            ]
          , [ Prefix (un Neg (reservedOp "-"))
            , Prefix (un Pos (reservedOp "+"))
            ]
          , [ Infix (bin Pow (reservedOp "^")) AssocRight ]
          , [ Infix (bin Mul (reservedOp "*")) AssocLeft
            , Infix (bin Div (reservedOp "/")) AssocLeft
            ]
          , [ Infix (bin Concat (reservedOp "&")) AssocLeft ]
          , [ Infix (bin Add (reservedOp "+")) AssocLeft
            , Infix (bin Sub (reservedOp "-")) AssocLeft
            ]
          , [ Infix (bin EqualOp (reservedOp "==")) AssocNone
            , Infix (bin LTOp (reservedOp "<")) AssocNone
            , Infix (bin LTEOp (reservedOp "<=")) AssocNone
            , Infix (fmap flip $ bin LTOp (reservedOp ">")) AssocNone
            , Infix (fmap flip $ bin LTEOp (reservedOp ">=")) AssocNone
            ]
          , [ Prefix (un Not (reserved "not")) ]
          , [ Infix (bin And (reserved "and")) AssocLeft ]
          , [ Infix (bin Or (reserved "or")) AssocLeft ]
          , [ Infix dollar AssocRight ] -- TODO Should this be a real operator? or is App suff.?
          , [ Infix (bin Type (reserved "::")) AssocNone ]
          ]
    un op s = do pos <- getPosition
                 s
                 return $ wrapPos pos . UnExpr op
    bin op s = do pos <- getPosition
                  s
                  return $ (wrapPos pos .) . BinExpr op
    dollar = do pos <- getPosition
                reservedOp "$"
                return $ \x y -> wrapPos pos $ App x [Arg y]

-- Parse a sequence of terms as a function application
application :: Parser Expr
application = do pos <- getPosition
                 f <- term
                 args <- many parg
                 case args of
                  [] -> return f -- so not actually a function application
                  _ -> return $ wrapPos pos $ App f args
  where parg = braces (ImpArg <$> expr) <|> (Arg <$> term)

term :: Parser Expr
term = literal >>= doMember
  where doMember e = do pos <- getPosition
                        (brackets (wrapPos pos . Index e <$> expr) >>= doMember)
                          <|> (reservedOp ".*" >> (wrapPos pos . FieldDeref e <$> structFieldName)
                               >>= doMember)
                          <|> (reservedOp "." >> (wrapPos pos . Field e <$> structFieldName)
                               >>= doMember)
                          <|> return e

-- Parse a literal or parenthesis group
literal :: Parser Expr
literal = voidlit <|> holelit <|> transposelit <|> numlit <|> binlit <|> strlit
          <|> ref <|> parenGroup
          <|> veclit <|> form
  where ref = withPos $ Ref <$> identifier
        voidlit = withPos $ reserved "Void" >> return VoidExpr
        holelit = withPos $ reserved "_" >> return Hole
        transposelit = withPos $ reserved "T" >> return T
        numlit = withPos $ either integer float <$> naturalOrFloat
        binlit = withPos $ do
          b <- ((reserved "True" >> return True)
                <|> (reserved "False" >> return False))
               <?> "boolean"
          return $ BoolLit b
        strlit = withPos $ StrLit <$> stringLiteral
        parenGroup = symbol "(" *> mstatements <* symbol ")"
        veclit = -- basically match tuple. TODO better vec literal?
          withPos $ do
            try (reserved "vec" >> symbol "(")
            xs <- sepEndBy range (symbol ",")
            symbol ")"
            return $ VecLit xs


form :: Parser Expr
form = iter Vec "vec" <|> iter Sum "sum" <|> iter For "for" <|> ifexpr
  where iter cons s = withPos $ do
          reserved s
          vs <- sepBy ((,) <$> identifier <* reserved "in" <*> range) (symbol ",")
          reservedOp "->"
          cons vs <$> expr
        ifexpr = withPos $ do
          reserved "if"
          cond <- expr
          reserved "then"
          cons <- expr
          reserved "else"
          alt <- expr
          return $ If cond cons alt

-- Parse semicolon-separated sequenced statements
mstatements :: Parser Expr
mstatements = do pos <- getPosition
                 xs <- sepEndBy1 expr (symbol ";")
                 case xs of
                  [x] -> return x -- so no need to sequence
                  _ -> return $ wrapPos pos $ SeqExpr xs

toplevelStatement :: Parser Expr
toplevelStatement = extern <|> static <|> struct <|> expr
  where extern = withPos $ do reserved "extern"
                              x <- toplevelStatement
                              return $ Extern x
        static = withPos $ do reserved "static"
                              x <- toplevelStatement
                              return $ Static x
        struct = withPos $ do reserved "struct"
                              name <- identifier
                              xs <- parens $ sepEndBy1 expr (symbol ";")
                              return $ Struct name xs


-- Parse entire toplevel
toplevel :: Parser Expr
toplevel = do whiteSpace
              withPos $ SeqExpr <$> sepEndBy toplevelStatement (symbol ";") <* eof

parseString :: String -> Expr
parseString str =
  case parse toplevel "*parseString*" str of
   Left e -> error $ show e
   Right r -> r
   
parseFile :: String -> IO Expr
parseFile file =
  do program <- readFile file
     case parse toplevel file program of
      Left e -> print e >> fail "Parse error"
      Right r -> return r


-- Converting to plover type

data ConvertError = ConvertError !SourcePos [String]
                  deriving (Show)

makeExpr :: Expr -> Either ConvertError T.CExpr
makeExpr exp@(Fix (PosExpr' e')) = case stripTag e' of
  Vec [] e -> makeExpr e
  Vec ((v,r):bs) e -> do rng <- makeRange r
                         ee <- makeExpr e
                         return $ T.Vec v rng ee
  Sum [] e -> makeExpr e
  Sum ((v,r):bs) e -> do rng <- makeRange r
                         ee <- makeExpr e
                         return $ T.Unary T.Sum $ T.Vec v rng ee
  For [] e -> makeExpr e
  For ((v,r):bs) e -> do rng <- makeRange r
                         ee <- makeExpr e
                         return $ T.Unary T.For $ T.Vec v rng ee
  Ref v -> return $ T.Get $ T.Ref' v
  VoidExpr -> return $ T.VoidExpr
  T -> Left $ ConvertError (makePos exp) ["Unexpected transpose operator in non-exponent position"]
  Hole -> return $ T.Hole
  IntLit t i -> return $ T.IntLit t i
  FloatLit t x -> return $ T.FloatLit t x
  BoolLit b -> return $ T.BoolLit b
  StrLit s -> return $ T.StrLit s
  VecLit es -> do es' <- mapM makeExpr es
                  return $ T.VecLit es'
  If a b c -> do a' <- makeExpr a
                 b' <- makeExpr b
                 c' <- makeExpr c
                 return $ T.If a' b' c'
  UnExpr Deref a -> do a' <- makeExpr a
                       return $ T.Get $ T.Deref a'
  UnExpr Pos a -> do a' <- makeExpr a
                     return $ T.AssertType a' T.NumType
  UnExpr op a -> do a' <- makeExpr a
                    return $ T.Unary (tr op) a'
    where tr Neg = T.Neg
          tr Pos = error "Not translatable here"
          tr Deref = error "Not translatable here"
          tr Transpose = T.Transpose
          tr Inverse = T.Inverse
          tr Not = T.Not
  BinExpr Pow a b@(Fix (PosExpr' b')) -> case stripTag b' of
    T -> T.Unary T.Transpose <$> makeExpr a  -- A^T is transpose of A
    UnExpr Neg (Fix (PosExpr' b'))
      | IntLit _ 1 <- stripTag b'  -> T.Unary T.Inverse <$> makeExpr a  -- A^(-1) is A inverse
      | T <- stripTag b'  -> do a' <- makeExpr a -- A^(-T) is transpose of A inverse
                                return $ T.Unary T.Transpose (T.Unary T.Inverse a')
    _ -> T.Binary T.Pow <$> makeExpr a <*> makeExpr b
  BinExpr Type a b -> do a' <- makeExpr a
                         b' <- makeType b
                         return $ T.AssertType a' b'
  BinExpr op a b -> do a' <- makeExpr a
                       b' <- makeExpr b
                       return $ T.Binary (tr op) a' b'
    where tr Add = T.Add
          tr Sub = T.Sub
          tr Mul = T.Mul
          tr Div = T.Div
          tr Pow = error "Not translatable here"
          tr Concat = T.Concat
          tr Type = error "Not translatable here"
          tr And = T.And
          tr Or = T.Or
          tr EqualOp = T.EqOp
          tr LTOp = T.LTOp
          tr LTEOp = T.LTEOp

  Field _ _ -> T.Get <$> makeLocation exp
  FieldDeref _ _ -> T.Get <$> makeLocation exp
  Index _ _ -> T.Get <$> makeLocation exp

  Tuple _ -> Left $ ConvertError (makePos exp) ["What do we do with tuples?"]
  Range _ _ _ -> T.RangeVal <$> makeRange exp

  App f args -> T.App <$> makeExpr f <*> (mapM $ \arg -> case arg of
                                           Arg a -> T.Arg <$> makeExpr a
                                           ImpArg a -> T.ImpArg <$> makeExpr a) args

  SeqExpr [] -> return $ T.VoidExpr
  SeqExpr [x] -> makeExpr x
  SeqExpr exprs -> do exprs' <- mapM makeExpr exprs
                      return $ foldr1 (T.:>) exprs'
  --DefExpr _ _ -> 
  StoreExpr loc a -> do loc' <- makeLocation loc
                        a' <- makeExpr a
                        return $ T.Set loc' a'

  Extern _ -> Left $ ConvertError (makePos exp) ["Non-toplevel extern"]
  Static _ -> Left $ ConvertError (makePos exp) ["Non-toplevel static"]
  _ -> Left $ ConvertError (makePos exp) ["Unimplemented expression " ++ show exp]

makeLocation :: Expr -> Either ConvertError (T.Location T.CExpr)
makeLocation exp@(Fix (PosExpr' e')) = case stripTag e' of
  Field a n -> do a' <- makeExpr a
                  return $ T.Field' a' n
  FieldDeref a n -> do a' <- makeExpr a
                       return $ T.Deref' $ T.Get $ T.Field' a' n
  Index a (Fix (PosExpr' idx))
    | (Tuple idxs) <- stripTag idx -> do a' <- makeExpr a
                                         idxs' <- mapM makeExpr idxs
                                         return $ T.Index' a' idxs'
  UnExpr Deref a -> do a' <- makeExpr a
                       return $ T.Deref' a'
  Index a b -> do a' <- makeExpr a
                  idx' <- makeExpr b
                  return $ T.Index' a' [idx']

  _ -> Left $ ConvertError (makePos exp) ["Expecting location instead of " ++ show exp]

makeRange :: Expr -> Either ConvertError (T.Range T.CExpr)
makeRange exp@(Fix (PosExpr' e')) = case stripTag e' of
  Range start stop step -> do start' <- maybe (return 0) makeExpr start
                              stop' <- maybe (return T.Hole) makeExpr stop
                              step' <- maybe (return 1) makeExpr step
                              return $ T.Range start' stop' step'
  _ -> do ee <- makeExpr exp
          return $ T.Range 0 ee 1

makeType :: Expr -> Either ConvertError (T.Type)
makeType exp@(Fix (PosExpr' e')) = case stripTag e' of
  Index a (Fix (PosExpr' idx))
    | (Tuple idxs) <- stripTag idx -> do a' <- makeType a
                                         idxs' <- mapM makeExpr idxs
                                         return $ T.VecType idxs' a'
  Index a b -> do a' <- makeType a
                  b' <- makeExpr b
                  return $ T.VecType [b'] a'
  -- (no way to write the type of a function.)
  Ref v -> case v of
    "u8" -> return $ T.IntType (Just T.U8)
    "s8" -> return $ T.IntType (Just T.S8)
    "u16" -> return $ T.IntType (Just T.U16)
    "s16" -> return $ T.IntType (Just T.S16)
    "u32" -> return $ T.IntType (Just T.U32)
    "s32" -> return $ T.IntType (Just T.S32)
    "u64" -> return $ T.IntType (Just T.U64)
    "s64" -> return $ T.IntType (Just T.S64)
    "float" -> return $ T.FloatType (Just T.Float)
    "double" -> return $ T.FloatType (Just T.Float)
    "Int" -> return $ T.IntType Nothing
    "String" -> return $ T.StringType
    "Bool" -> return $ T.StringType
    _ -> return $ T.TypedefType v
  UnExpr Deref a -> T.PtrType <$> makeType a
  VoidExpr -> return T.Void
  _ -> Left $ ConvertError (makePos exp) ["Expecting type instead of " ++ show exp]

--  ee <- makeExpr exp
--  case ee of

makeDefs :: Expr -> Either ConvertError [T.DefBinding]
makeDefs exp@(Fix (PosExpr' pe)) = case stripTag pe of
  SeqExpr xs -> fmap join $ mapM makeDefs xs
  Extern a -> fmap (map (\z -> z { T.extern = True })) $ makeDefs a
  Static a -> fmap (map (\z -> z { T.static = True })) $ makeDefs a
  BinExpr Type (Fix (PosExpr' a)) b
    | Ref v <- stripTag a  -> do t <- makeType b
                                 return $ [T.mkBinding v $ T.ValueDef Nothing t]
    | App (Fix (PosExpr' f)) args <- stripTag a ->
        case stripTag f of
         Ref v -> do t <- makeType b
                     at <- funArgs args
                     return $ [T.mkBinding v $ T.ValueDef Nothing (T.FnType (T.FnT at t))]
    | otherwise -> Left $ ConvertError (makePos exp) ["Prototype must be variable or function."]
  _ -> Left $ ConvertError (makePos exp) ["Unexpected top-level form."]

funArgs :: [Arg Expr] -> Either ConvertError [(Variable, Bool, T.Type)]
funArgs [] = return []
funArgs ((Arg e@(Fix (PosExpr' pe))):args)
  | BinExpr Type (Fix (PosExpr' a)) b  <- stripTag pe, Ref v <- stripTag a = do
      t <- makeType b
      ([(v, True, t)] ++) <$> funArgs args
  | otherwise  = Left $ ConvertError (makePos e) ["Argument definition must have explicit type."]
funArgs ((ImpArg e@(Fix (PosExpr' pe))):args)
  | BinExpr Type (Fix (PosExpr' a)) b  <- stripTag pe, Ref v <- stripTag a = do
      t <- makeType b
      ([(v, False, t)] ++) <$> funArgs args
  | otherwise  = Left $ ConvertError (makePos e) ["Implicit argument definition must have explicit type."]


makePos :: Expr -> SourcePos
makePos (Fix (PosExpr' e')) = case maybeTag e' of
  Just pos -> pos
  Nothing -> newPos "<unknown>" (-1) (-1)