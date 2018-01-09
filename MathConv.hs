{-# LANGUAGE DataKinds, DeriveDataTypeable, ExtendedDefaultRules          #-}
{-# LANGUAGE FlexibleContexts, GADTs, LambdaCase, MultiParamTypeClasses   #-}
{-# LANGUAGE NamedFieldPuns, NoMonomorphismRestriction, OverloadedStrings #-}
{-# LANGUAGE PatternGuards, ScopedTypeVariables, StandaloneDeriving       #-}
{-# LANGUAGE TemplateHaskell, TypeOperators, ViewPatterns                 #-}
{-# OPTIONS_GHC -fno-warn-orphans -fno-warn-type-defaults -fno-warn-unused-do-bind #-}
module MathConv where
import Instances ()
import Lenses
import Macro

import           Control.Arrow                   (left)
import           Control.Lens                    hiding (op, rewrite, (<.>))
import           Control.Lens.Extras             (is)
import           Control.Monad.Identity
import           Control.Monad.State.Strict      (runStateT)
import           Control.Monad.State.Strict      (StateT)
import           Control.Monad.Trans             (MonadIO)
import           Control.Monad.Writer.Strict     (runWriter, tell)
import           Data.Char                       (isSpace)
import           Data.Char                       (isAscii)
import           Data.Char                       (isAlphaNum)
import           Data.Char                       (isLatin1, isLower)
import           Data.Char                       (isLetter, isUpper)
import           Data.Default
import           Data.Foldable                   (toList)
import qualified Data.HashMap.Strict             as HM
import qualified Data.HashSet                    as HS
import qualified Data.List                       as L
import qualified Data.Map                        as M
import           Data.Maybe                      (fromMaybe)
import           Data.Maybe                      (listToMaybe)
import           Data.Maybe                      (mapMaybe)
import           Data.Sequence                   (Seq)
import qualified Data.Text                       as T
import qualified Debug.Trace                     as DT
import           Filesystem.Path.CurrentOS       hiding (concat, null, (<.>),
                                                  (</>))
import qualified MyTeXMathConv                   as MyT
import           Prelude                         hiding (FilePath)
import           Shelly                          hiding (get)
import           Text.Blaze.Html.Renderer.String (renderHtml)
import           Text.Blaze.Html5                (img, object, toValue, (!))
import           Text.Blaze.Html5.Attributes     (alt, class_, data_, src,
                                                  type_)
import           Text.LaTeX.Base                 hiding ((&))
import           Text.LaTeX.Base.Class
import           Text.LaTeX.Base.Parser
import           Text.LaTeX.Base.Syntax
import           Text.LaTeX.CrossRef             (procCrossRef)
import           Text.LaTeX.CrossRef             (RefOptions (..))
import           Text.LaTeX.CrossRef             (Numeral (Arabic))
import           Text.LaTeX.CrossRef             (RefItem (Item))
import           Text.LaTeX.CrossRef             (LabelFormat (ThisCounter))
import qualified Text.LaTeX.CrossRef             as R
import           Text.Pandoc                     hiding (MathType, Writer)
import           Text.Pandoc.Shared
import qualified Text.Parsec                     as P
import           Text.Regex.Applicative          (psym, (<|>))
import           Text.Regex.Applicative          (RE)
import           Text.Regex.Applicative          (replace)
import           Text.TeXMath.Readers.TeX.Macros

default (T.Text , Integer)

fromRight :: Either a b -> b
fromRight ~(Right a) = a

data MachineState = MachineState { _tikzPictures :: Seq LaTeX
                                 , _macroDefs    :: [Macro]
                                 , _imgPath      :: FilePath
                                 , _texMacros    :: TeXMacros
                                 }
                  deriving (Show)
makeLenses ''MachineState

type Machine = StateT MachineState IO

myReaderOpts :: ReaderOptions
myReaderOpts = def { readerExtensions = extensionsFromList exts
                                        <> pandocExtensions
                   }
  where
    exts = [ Ext_raw_html
           , Ext_latex_macros
           , Ext_raw_attribute
           , Ext_raw_tex
           , Ext_tex_math_dollars
           ]

parseTeX :: String -> Either String LaTeX
parseTeX = left show . P.runParser latexParser defaultParserConf "" . T.pack

message :: MonadIO m => String -> m ()
message = liftIO . putStrLn

texToMarkdown :: TeXMacros -> FilePath -> String -> IO Pandoc
texToMarkdown macs0 fp src_ = do
  pth <- liftIO $ shelly $ canonic fp
  macros <- liftIO $ fst . parseMacroDefinitions <$>
            readFile "/Users/hiromi/Library/texmf/tex/platex/mystyle.sty"
  let ltree0 = procCrossRef myCrossRefConf $
                  view _Right $ parseTeX $ applyMacros macros src_
      tlibs0 = queryWith (\ case
                            c@(TeXComm "usetikzlibrary" _) -> [c]
                            c@(TeXComm "tikzset" _) -> [c]
                            c@(TeXComm "pgfplotsset" _) -> [c]
                            _ -> [])
               ltree0
      (latexTree, locMacros) = runWriter $
         transformM (\ case
                         c@(TeXComm "newcommand" _) -> TeXEmpty    <$ tell [c]
                         c@(TeXComm "renewcommand" _) -> TeXEmpty  <$ tell [c]
                         c@(TeXComm "newcommand*" _) -> TeXEmpty   <$ tell [c]
                         c@(TeXComm "renewcommand*" _) -> TeXEmpty <$ tell [c]
                         c -> return c)
               ltree0
      macs  = macs0 <> parseTeXMacros locMacros
      tlibs = tlibs0 ++ locMacros
      initial = T.pack $ applyMacros macros $ T.unpack $ render $
                applyTeXMacro macs $ preprocessTeX $ latexTree
      st0 = MachineState { _tikzPictures = mempty
                         , _macroDefs = macros -- ++ lms
                         , _imgPath = dropExtension fp
                         , _texMacros = macs
                         }
      mabs = either (const Nothing) ((^? _MetaBlocks) <=< M.lookup "abstract" . unMeta . getMeta) $
             runPure $ readLaTeX myReaderOpts initial
  (pan, s) <- do
    (p0@(Pandoc meta0 bdy), s0) <- runStateT (texToMarkdownM initial) st0
    case mabs of
      Nothing -> return (p0, s0)
      Just bs -> do
        let ps0 = Pandoc meta0 bs
            asrc = either (const "") id $ runPure $ writeLaTeX def ps0
        (Pandoc _ abbs, s') <- runStateT (texToMarkdownM asrc) s0
        return (Pandoc (Meta $ M.insert "abstract" (MetaBlocks abbs) $ unMeta meta0)  bdy, s')

  let tikzs = toList $ s ^. tikzPictures
  unless (null tikzs) $ shelly $ silently $ do
    master <- canonic $ dropExtension pth
    mkdir_p master
    -- let tmp = "tmp" in do
    withTmpDir $ \tmp -> do
      cp ".latexmkrc" tmp
      cd tmp
      writefile "image.tex" $ render $ buildTikzer tlibs tikzs
      cmd "latexmk" "-pdflua" "image.tex"
      cmd "tex2img" "--latex=luajittex --fmt=luajitlatex.fmt" "--with-text" "image.tex" "image.svg"
      mv "image.svg" "image-0.svg"
      -- Generating PNGs
      cmd "convert" "-density" "200" "image.pdf" "image-%d.png"
      infos <- cmd "pdftk" "image.pdf" "dump_data_utf8"
      let pages = fromMaybe (0 :: Integer) $ listToMaybe $ mapMaybe
                   (readMaybe . T.unpack <=< T.stripPrefix "NumberOfPages: ")  (T.lines infos)
      forM [1..pages - 1] $ \n -> do
        let targ = fromString ("image-" <> show n) <.> "svg"
        echo $ "generating " <> encode targ
        mv (fromString ("image-" <> show (n + 1)) <.> "svg") targ
      pngs <- findWhen (return . hasExt "png") "."
      svgs <- findWhen (return . hasExt "svg") "."
      mapM_ (flip cp master) (pngs ++ svgs)
  return $ adjustJapaneseSpacing pan

getMeta :: Pandoc -> Meta
getMeta (Pandoc m _) = m

tshow :: Show a => a -> Text
tshow = T.pack . show

readMaybe :: Read a => String -> Maybe a
readMaybe str =
  case reads str of
    [(a, "")] -> Just a
    _         -> Nothing

texToMarkdownM :: Text -> Machine Pandoc
texToMarkdownM s = do
  mcs <- use macroDefs
  let lat = either (error . show) id $ runPure $
            readLaTeX myReaderOpts $ T.pack $
            applyMacros mcs $ T.unpack s
  procTikz =<< rewriteEnv lat

adjustJapaneseSpacing :: Pandoc -> Pandoc
adjustJapaneseSpacing = bottomUp procMathBoundary . bottomUp procStr
  where
    procMathBoundary = replace (insertBoundary (Str " ") (is _Math) (isStrStarting japaneseLetter))
                     . replace (insertBoundary (Str " ") (isStrEnding japaneseLetter) (is _Math))
    procStr = _Str %~ replace (insertBoundary ' ' isAsciiAlphaNum japaneseLetter)
                    . replace (insertBoundary ' ' japaneseLetter isAsciiAlphaNum)

isAsciiAlphaNum :: Char -> Bool
isAsciiAlphaNum c = (isAscii c && isAlphaNum c) || isLatin1 c || (isLower c || isUpper c)

japaneseLetter :: Char -> Bool
japaneseLetter c = not (isLatin1 c || isAscii c || isLower c || isUpper c) && isLetter c

isStrStarting :: (Char -> Bool) -> Inline -> Bool
isStrStarting p = maybe False p . preview (_Str . _head)

isStrEnding :: (Char -> Bool) -> Inline -> Bool
isStrEnding p = maybe False p . preview (_Str . _last)


insertBoundary :: t -> (t -> Bool) -> (t -> Bool) -> RE t [t]
insertBoundary c p q = boundary p q <&> \(l, r) -> [l, c,  r]

boundary :: (a -> Bool) -> (a -> Bool) -> RE a (a, a)
boundary p q = (,) <$> psym p <*> psym q

preprocessTeX :: LaTeX -> LaTeX
preprocessTeX = bottomUp rewrite . bottomUp alterEnv
  where
    expands = ["Set", "Braket"]
    alterEnv (TeXEnv env args body)
      | Just env' <- lookup env envAliases = TeXEnv env' args body
    alterEnv e = e
    rewrite (TeXComm comm [FixArg src_]) | comm `elem` expands =
      case breakTeXOn "|" src_ of
        Just (lhs, rhs) -> TeXComm comm [FixArg lhs, FixArg rhs]
        Nothing -> TeXComm (T.unpack $ T.toLower $ T.pack comm) [FixArg src_]
    rewrite t = t

splitTeXOn :: Text -> LaTeX -> [LaTeX]
splitTeXOn delim t =
  case breakTeXOn delim t  of
    Nothing     -> [tex]
    Just (a, b) -> a : splitTeXOn delim b

breakTeXOn :: T.Text -> LaTeX -> Maybe (LaTeX, LaTeX)
breakTeXOn _ TeXEmpty = Nothing
breakTeXOn s (TeXRaw t) =
  case T.breakOn s t of
    (_, "") -> Nothing
    answer -> answer & _2 %~ T.drop 1
                     & both %~ TeXRaw
                     & Just
breakTeXOn s (TeXSeq l r) =
      do (l0, l1) <- breakTeXOn s l
         return (l0, TeXSeq l1 r)
  <|> do (r0, r1) <- breakTeXOn s r
         return (TeXSeq l r0, r1)
breakTeXOn _ _ = Nothing

myCrossRefConf :: RefOptions
myCrossRefConf = RefOptions { subsumes = HM.empty
                            , formats  = HM.fromList
                                         [(Item 1, [R.Str "(", ThisCounter Arabic, R.Str ")"])]
                            , numberedEnvs = HS.fromList $ map T.pack $ L.delete "proof" envs
                            , remainLabel = True
                            , useHyperlink = True
                            }

envs :: [String]
envs = [ "prop", "proof", "theorem", "lemma", "axiom", "remark","exercise"
       , "definition", "question", "answer", "problem", "corollary"
       , "fact", "conjecture", "claim", "subproof", "notation"
       ]

envAliases :: [(String, String)]
envAliases = [("enumerate*", "enumerate!")
             ,("itemize*", "itemize")
             ]

commandDic :: [(String, Either ([Inline] -> Inline) String)]
commandDic = [("underline", Right "u"), ("bf", Left Strong)
             ,("emph", Left Strong)
             ,("textgt", Left Strong)
             ,("textsf", Left Strong)
             ]

rewriteInlineCmd :: [Inline] -> Machine [Inline]
rewriteInlineCmd = fmap concat . mapM step
  where
    step (RawInline "latex" src_)
        | Right t <- parseTeX src_ = rewrite t
    step i = return [i]
    rewrite (TeXSeq l r) = (++) <$> rewrite l <*> rewrite r
    rewrite (TeXComm "parpic" args) = procParpic args
    rewrite (TeXComm "label" [FixArg lab]) =
      return [ Link (T.unpack $ render lab, [], []) [] ("", "") ]
    rewrite (TeXComm "ruby" [FixArg rb, FixArg rt]) = do
      rubyBody <- concat <$> mapM step (inlineLaTeX (render rb))
      rubyText <- concat <$> mapM step (inlineLaTeX (render rt))
      return $ [RawInline "html" $ "<ruby><rb>"]
               ++ rubyBody
               ++
               [RawInline "html" $ "</rb><rp>（</rp><rt>"]
               ++ rubyText
               ++
               [RawInline "html" $ "</rt><rp>）</rp><ruby>"]
    rewrite c@(TeXComm cm [FixArg arg0]) = do
      arg <- rewrite arg0
      case lookup cm commandDic of
        Just (Right t) -> do
          --- comBody <- concat <$> mapM step (inlineLaTeX (render arg))
          return $ [ RawInline "html" $ "<" ++ t ++ ">" ]
                   ++ arg ++
                   [ RawInline "html" $ "</" ++ t ++ ">" ]
        Just (Left inl) -> return [inl arg]
        _ -> return $ inlineLaTeX $ render c
    rewrite c = return $ inlineLaTeX $ render c

data Align = AlignL | AlignR
           deriving (Read, Show, Eq, Ord)

procParpic :: [TeXArg] -> Machine [Inline]
procParpic [OptArg "r", FixArg lat] = procParpic' AlignR lat
procParpic [OptArg "l", FixArg lat] = procParpic' AlignL lat
procParpic (fixArgs -> [lat])       = procParpic' AlignR lat
procParpic _                        = return []

procParpic' :: Align -> LaTeX -> Machine [Inline]
procParpic' al lat = do
  let pull = case al of
        AlignL -> "pull-left"
        AlignR -> "pull-right"
  pure . Span ("", ["media", pull], []) . concatMap getInlines . pandocBody <$>
     texToMarkdownM (render lat)

getInlines :: Block -> [Inline]
getInlines (Plain b) = b
getInlines (LineBlock b) = concat b
getInlines (Para b) = b
getInlines (CodeBlock lang b2) = [Code lang b2]
getInlines (RawBlock lang b) = [RawInline lang b]
getInlines (BlockQuote b) = concatMap getInlines b
getInlines (OrderedList _ b2) = concatMap (concatMap getInlines) b2
getInlines (BulletList b) = concatMap (concatMap getInlines) b
getInlines (DefinitionList b) = concat [lls++concatMap (concatMap getInlines) bs | (lls, bs)  <- b]
getInlines (Header _ attr b3) = [Span attr b3]
getInlines HorizontalRule = []
getInlines (Table _b1 _b2 _b3 _b4 _b5) = []
getInlines (Div b1 b2) = [Span b1 $ concatMap getInlines b2]
getInlines Null = []

traced :: Show a => String -> a -> a
traced lab a = DT.trace (lab <> ": " <> show a) a

pandocBody :: Pandoc -> [Block]
pandocBody (Pandoc _ body) = body

fixArgs :: Foldable f => f TeXArg -> [LaTeX]
fixArgs = toListOf (folded._FixArg)

inlineLaTeX :: Text -> [Inline]
inlineLaTeX src_ =
  let Pandoc _ body = either (const (Pandoc nullMeta [])) id $ runPure $
                      readLaTeX myReaderOpts src_
  in concatMap getInlines body

rewriteEnv :: Pandoc -> Machine Pandoc
rewriteEnv (Pandoc meta bs) =
  Pandoc meta <$> (bottomUpM rewriteInlineCmd =<< rewriteBeginEnv (bottomUp amendAlignat bs))

rewriteBeginEnv :: [Block] -> Machine [Block]
rewriteBeginEnv = concatMapM step
  where
    step :: Block -> Machine [Block]
    step (RawBlock "latex" src_)
      | Right (TeXEnv "enumerate!" args body) <- parseTeX src_
      = pure <$> procEnumerate args body
      | Right (TeXEnv env0 args body) <- parseTeX src_
      , Just env <- lookupCustomEnv env0 envs = do
          let divStart
                  | null args = concat ["<div class=\"", env, "\">"]
                  | otherwise = concat ["<div class=\"", env, "\" name=\""
                                       , unwords $ map texToEnvNamePlainString args, "\">"
                                       ]
          Pandoc _ myBody <- texToMarkdownM $ render body
          return $ RawBlock "html" divStart : myBody ++ [RawBlock "html" "</div>"]
    step b = return [b]

lookupCustomEnv :: String -> [String] -> Maybe String
lookupCustomEnv e es =
      e <$ guard (e `elem` es)
  <|> e ++ "-plain" <$ guard (e ++ "*" `elem` es)

concatMapM :: Monad m => (a -> m [b]) -> [a] -> m [b]
concatMapM f a = concat <$> mapM f a

procEnumerate :: [TeXArg] -> LaTeX -> Machine Block
procEnumerate args body = do
  Pandoc _ [OrderedList _ blcs] <- rewriteEnv $ either (error . show) id $ runPure $ readLaTeX myReaderOpts $
                                   render $ TeXEnv "enumerate" [] body
  return $ OrderedList (parseEnumOpts args) blcs

tr :: Show a => String -> a -> a
tr lab s = DT.trace (lab <> ": " <> show s) s

splitLeftMostBrace :: LaTeX -> Maybe (LaTeX, LaTeX)
splitLeftMostBrace = loop Nothing
  where
    isEmpty TeXEmpty     = True
    isEmpty (TeXRaw t)   = T.all isSpace t
    isEmpty TeXComment{} = True
    isEmpty _            = False
    loop mrest (TeXBraces t) = Just (t, fromMaybe TeXEmpty mrest)
    loop mrest (TeXSeq l r)
      | isEmpty l = loop mrest r
      | isEmpty r = loop mrest l
      | otherwise = loop (Just $ maybe r (TeXSeq r) mrest) l
    loop _ _      = Nothing

-- Fixes long-standing bad behaviour of parsing alignat(*) in Pandoc parser.
amendAlignat :: Inline -> Inline
amendAlignat (Math DisplayMath tsrc)
  | Right (TeXEnv (T.pack -> env) [] body) <- parseLaTeX $ T.pack tsrc
  , env `elem` ["aligned", "aligned*"]
  , Just (TeXRaw nums, body') <- splitLeftMostBrace body
  , [(i :: Int, "")] <- reads $ T.unpack (T.strip nums)
  = let envedName = T.replace "ed" "edat" env
        args = [FixArg $ TeXRaw $ T.pack $ show i]
    in Math DisplayMath $ T.unpack $ render $ TeXEnv (T.unpack envedName) args body'
amendAlignat i = i

parseEnumOpts :: [TeXArg] -> ListAttributes
parseEnumOpts args =
  let opts = [ (render key, render val)
             | OptArg lat <- args
             , opt <- splitTeXOn "," lat
             , Just (key, val) <- [breakTeXOn "=" opt]
             ]
      styleDic = [("arabic", Decimal)
                 ,("Alph", UpperAlpha)
                 ,("alph", LowerAlpha)
                 ,("Roman", UpperRoman)
                 ,("roman", LowerRoman)
                 ]
      labF = fromMaybe "" $ lookup "label" opts
      start = maybe 1 (read . T.unpack) $ lookup "start" opts
      style = fromMaybe Decimal $ listToMaybe
              [ sty | (com, sty) <- styleDic, ("\\"<>com) `T.isInfixOf` labF]
      oparens = T.count "(" labF
      cparens = T.count ")" labF
      delim
        | max oparens cparens >= 2 = TwoParens
        | max oparens cparens == 1 = OneParen
        | "." `T.isInfixOf` labF   = Period
        | otherwise = DefaultDelim
  in (start, style, delim)


buildTikzer :: [LaTeX] -> [LaTeX] -> LaTeX
buildTikzer tikzLibs tkzs = snd $ runIdentity $ runLaTeXT $ do
  fromLaTeX $ TeXComm "RequirePackage" [FixArg "luatex85"]
  documentclass ["tikz", "preview"] "standalone"
  usepackage ["hiragino-pron"] "luatexja-preset"
  usepackage [] "amsmath"
  usepackage [] "amssymb"
  usepackage [] "pgfplots"
  usepackage [] "mymacros"
  comm1 "usetikzlibrary" "matrix,arrows,backgrounds,calc,shapes"
  mapM_ fromLaTeX tikzLibs
  -- comm1 "tikzset" $ do
  --   "node distance=2cm, auto, >=latex,"
  --   "description/.style="
  --   braces "fill=white,inner sep=1.5pt,auto=false"
  -- comm1 "pgfplotsset" $ do
  --   "tick label style="
  --   braces "font=\\tiny"
  --   ",compat=1.8,width=6cm"
  document $ mapM_ textell tkzs

procTikz :: Pandoc -> Machine Pandoc
procTikz pan = bottomUpM step pan
  where
    step (RawBlock "latex" src_)
      | Right ts <- parseTeX src_ = do
        liftM Plain $ forM [ t | t@(TeXEnv "tikzpicture" _ _) <- universe ts] $ \t -> do
          n <- uses tikzPictures length
          tikzPictures %= (|> t)
          fp <- use imgPath
          let dest = toValue $ encodeString $ ("/" :: String) </> fp </> ("image-"++show n++".svg")
              alts = toValue $ encodeString $ ("/" :: String) </> fp </> ("image-"++show n++".png")
          return $ Span ("", ["img-fluid"], [])
                   [
                   -- Image ("", ["thumbnail", "media-object"], [])
                   --       [Str $ "Figure-" ++ show (n+1 :: Int)]
                   --
                    RawInline "html" $
                    renderHtml $
                    object ! class_ "img-thumbnail media-object"
                           ! type_ "image/svg+xml" ! data_ dest $
                      img ! src alts ! alt "Diagram"
                   ]
    step a = return a

texToEnvNamePlainString :: TeXArg -> String
texToEnvNamePlainString str =
  let cated =
        case str of
          FixArg l     -> render l
          OptArg l     -> render l
          SymArg l     -> render l
          ParArg l     -> render l
          MOptArg lats -> T.intercalate "," $ map render lats
          MSymArg lats -> T.intercalate "," $ map render lats
          MParArg lats -> T.intercalate "," $ map render lats
  in either (const $ T.unpack $ render str) (stringify . bottomUp go) $
     runPure $ readLaTeX myReaderOpts $ cated
  where
    go :: Inline -> Inline
    go = bottomUp $ \a -> case a of
      Math _ math ->  Str $ stringify $ MyT.readTeXMath  math
      t           -> t

mvToBlocks :: MetaValue -> [Block]
mvToBlocks (MetaMap _)       = []
mvToBlocks (MetaList v)      = concatMap mvToBlocks v
mvToBlocks (MetaBool b)      = [ Plain  [ Str $ show b ] ]
mvToBlocks (MetaString s)    = [ Plain [ Str s ] ]
mvToBlocks (MetaInlines ins) = [Plain ins]
mvToBlocks (MetaBlocks bs)   = bs
