{-# LANGUAGE DeriveDataTypeable, DeriveGeneric, ExtendedDefaultRules       #-}
{-# LANGUAGE FlexibleContexts, GADTs, LambdaCase, MultiParamTypeClasses    #-}
{-# LANGUAGE NamedFieldPuns, OverloadedStrings, PatternGuards, QuasiQuotes #-}
{-# LANGUAGE RankNTypes, RecordWildCards, ScopedTypeVariables              #-}
{-# LANGUAGE TemplateHaskell, TupleSections, TypeApplications              #-}
{-# LANGUAGE TypeFamilies, ViewPatterns                                    #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind -fno-warn-type-defaults         #-}
module Main where
import           Lenses
import           Macro
import           MathConv
import qualified MustacheTemplate as MT
import           Settings
import           Utils

import           Blaze.ByteString.Builder        (toByteString)
import           Control.Applicative
import           Control.Exception               (IOException, handle)
import           Control.Lens                    (rmapping, (%~), (.~), (<&>),
                                                  (<>~), (^?), _2, _Unwrapping')
import           Control.Lens                    (imap)
import           Control.Monad                   hiding (mapM)
import           Control.Monad.Error.Class       (throwError)
import           Control.Monad.State
import           Crypto.Hash.SHA256
import           Data.Aeson                      as Aeson (Result (..),
                                                           ToJSON (..),
                                                           fromJSON)
import qualified Data.Aeson                      as Ae
import           Data.Aeson.Types                (camelTo2, defaultOptions,
                                                  fieldLabelModifier,
                                                  genericToJSON)
import           Data.Binary
import qualified Data.ByteString.Char8           as BS
import qualified Data.ByteString.Lazy            as LBS
import qualified Data.CaseInsensitive            as CI
import           Data.Char                       hiding (Space)
import           Data.Data
import           Data.Foldable                   (asum)
import           Data.Function
import qualified Data.HashMap.Strict             as HM
import           Data.List                       hiding (stripPrefix)
import qualified Data.List                       as L
import           Data.Maybe
import           Data.Monoid                     hiding ((<>))
import           Data.Ord
import           Data.Semigroup                  ((<>))
import           Data.String
import qualified Data.Text                       as T
import qualified Data.Text.Encoding              as T
import qualified Data.Text.ICU.Normalize         as UNF
import qualified Data.Text.Lazy                  as LT
import           Data.Text.Lens                  (packed, unpacked)
import           Data.Time
import           Data.Yaml                       (object, toJSON, (.=))
import qualified Data.Yaml                       as Y
import           Filesystem
import           Filesystem.Path.CurrentOS       hiding (concat, empty, null,
                                                  (<.>), (</>))
import qualified Filesystem.Path.CurrentOS       as Path
import           GHC.Generics
import           Hakyll                          hiding (fromFilePath,
                                                  toFilePath, writePandoc)
import qualified Hakyll
import           Hakyll.Core.Compiler.Internal
import           Hakyll.Core.Provider
import qualified Hakyll.Core.Store               as Store
import           Instances
import           Language.Haskell.TH             (litE, runIO, stringL)
import           Network.HTTP.Types
import           Network.URI                     hiding (query)
import           Prelude                         hiding (FilePath, div, mapM,
                                                  sequence, span)
import qualified Prelude                         as P
import           Shelly                          hiding (tag)
import           Skylighting                     hiding (Context (..), Style)
import           System.Exit                     (ExitCode (..))
import qualified System.FilePath.Posix           as PFP
import           System.IO                       (hPutStrLn, stderr)
import           Text.Blaze.Html.Renderer.String
import           Text.Blaze.Html5                ((!))
import qualified Text.Blaze.Html5                as H5
import qualified Text.Blaze.Html5.Attributes     as H5 hiding (span)
import           Text.Blaze.Internal             (Attributable)
import           Text.CSL                        (Reference, Style,
                                                  readBiblioFile, readCSLFile)
import           Text.CSL.Pandoc
import           Text.Hamlet
import           Text.HTML.TagSoup
import qualified Text.HTML.TagSoup               as TS
import           Text.HTML.TagSoup.Match
import           Text.LaTeX.Base                 (render)
import           Text.LaTeX.Base.Parser
import           Text.LaTeX.Base.Syntax          hiding ((<>))
import qualified Text.Mustache                   as Mus
import           Text.Pandoc                     hiding (runIO)
import           Text.Pandoc.Builder             hiding (fromList, (<>))
import qualified Text.Pandoc.Builder             as Pan hiding ((<>))
import           Text.Pandoc.Shared              (stringify)
import           Text.Pandoc.Walk
import           Text.TeXMath

default (T.Text)


toFilePath :: Identifier -> FilePath
toFilePath = decodeString . Hakyll.toFilePath

fromFilePath :: FilePath -> Identifier
fromFilePath = Hakyll.fromFilePath . encodeString

home :: FilePath
home = $(litE . stringL . encodeString =<< runIO getHomeDirectory)

globalBib :: FilePath
globalBib = home </> "Library/texmf/bibtex/bib/myreference.bib"

mustacheCompiler :: Compiler (Item Mus.Template)
mustacheCompiler = cached "mustacheCompiler" $ do
  item <- getResourceString
  file <- getResourceFilePath
  either (throwError . lines . show) (return . Item (itemIdentifier item)) $
    Mus.compileMustacheText (fromString file) . T.pack $ itemBody item

main :: IO ()
main = hakyllWith config $ do
  setting "tree" (def :: SiteTree)
  setting "cards" (def :: Cards)
  setting "schemes" (def :: Schemes)
  setting "navbar" (def :: NavBar)
  setting "macros" (HM.empty :: TeXMacros)

  match "data/katex.min.js" $ compile $ cached "katex" $
    fmap (LBS.toStrict) <$> getResourceLBS

  match "config/schemes.yml" $ compile $ cached "schemes" $ do
    fmap (fromMaybe (Schemes HM.empty) . Y.decode . LBS.toStrict) <$> getResourceLBS

  match "*.css" $ route idRoute >> compile' compressCssCompiler

  match ("js/**" .||. "**/*imgs/**" .||. "img/**" .||. "**/*img/**" .||. "favicon.ico" .||. "files/**" .||. "katex/**" .||. "keybase.txt") $
    route idRoute >> compile' copyFileCompiler

  match "**.css" $
    route idRoute >> compile' compressCssCompiler

  match "css/**.sass" $ do
    route $ setExtension "css"
    compile $ getResourceString >>= withItemBody (unixFilter "sassc" ["-s", "-tcompressed"])

  match ("templates/**" .&&. complement "**.mustache") $ compile' templateCompiler
  match ("templates/**.mustache") $ compile' mustacheCompiler

  match "index.md" $ do
    route $ setExtension "html"
    compile' $ do
      (count, posts) <- postList (Just 5) subContentsWithoutIndex
      let ctx = mconcat [ MT.constField "child-count" (show count)
                        , MT.constField "updates" posts
                        , myDefaultContext
                        ]
      myPandocCompiler
              >>= applyDefaultTemplate ctx {- tags -}

  match "archive.md" $ do
    route $ setExtension "html"
    compile' $ do
      (count, posts) <- postList Nothing subContentsWithoutIndex
      let ctx = mconcat [ MT.constField "child-count" (show count)
                        , MT.constField "children" posts
                        , myDefaultContext
                        ]
      myPandocCompiler
              >>= applyDefaultTemplate ctx {- tags -}

  create [".ignore"] $ do
    route idRoute
    compile $ do
      drafts <- listDrafts
      makeItem $ unlines $ ".ignore" : map (\(a, b) -> Hakyll.toFilePath a ++ "\t" ++ b) drafts

  match "robots.txt" $ do
    route idRoute
    compile $ do
      tmplt <- itemBody <$> mustacheCompiler
      drafts <- map snd <$> listDrafts
      let obj = object ["disallowed" .= map ('/':) drafts]
      makeItem $ LT.unpack $ Mus.renderMustache tmplt obj

  match "logs/index.md" $ do
    route $ setExtension "html"
    compile' $ do
      chs <- mapM toLog =<< myRecentFirst =<< loadAllSnapshots ("logs/*.md" .&&. complement "logs/index.md") "content"
      let ctx = mconcat [ MT.constField "logs" $ map itemBody chs
                        , myDefaultContext
                        ]
      myPandocCompiler >>= applyDefaultTemplate ctx >>= saveSnapshot "content"

  match ("*/index.md" .&&. complement "logs/index.md") $ do
    route $ setExtension "html"
    compile' $ do
      chs <- listChildren True
      (count, chl) <- postList Nothing (fromList $ map itemIdentifier chs)
      let ctx = mconcat [ MT.constField "child-count" (show count)
                        , MT.constField "children" chl
                        , myDefaultContext
                        ]
      myPandocCompiler >>= applyDefaultTemplate ctx >>= saveSnapshot "content"

  match ("t/**" .||. ".well-known/**") $ route idRoute >> compile' copyFileCompiler

  match "prog/automaton/**" $ route idRoute >> compile' copyFileCompiler

  match "math/**.pdf" $ route idRoute >> compile' copyFileCompiler
  match "**.key" $ route idRoute >> compile' copyFileCompiler

  match "prog/doc/*/**" $
    route idRoute >> compile' copyFileCompiler
  match ("**.html" .&&. complement ("articles/**.html" .||. "prog/doc/**.html" .||. "templates/**")) $
    route idRoute >> compile' copyFileCompiler
  match "**.csl" $ compile' cslCompiler
  match "**.bib" $ compile' (fmap biblioToBibTeX <$> biblioCompiler)

  match "math/**.tex" $ version "preprocess" $ compile $ cached "preprocess" $ do
    cmacs <- itemMacros =<< getResourceBody
    macs <- loadBody "config/macros.yml"
    fmap (preprocessLaTeX (cmacs <> macs)) <$> getResourceBody

  match "math/**.tex" $ version "image-source" $ compile $ cached "image-source" $ do
    ident <- getUnderlying
    PreprocessedLaTeX{..} <- loadBody $ setVersion (Just "preprocess") ident
    makeItem $ maybe "" snd images

  match "math/**.tex" $ version "images" $ compile $ cached "images" $ do
    ident <- getUnderlying
    store    <- compilerStore      <$> compilerAsk
    let imgSrcId = setVersion (Just "image-source") ident
        rebuildImages = do
          src <- loadBody @T.Text imgSrcId
          if T.null src
            then makeItem ""
            else do
            fp <- decodeString . fromJust <$> getRoute (setVersion (Just "html") ident)
            unsafeCompiler $ generateImages fp src
            makeItem $ hash $ T.encodeUtf8 src
    provider <- compilerProvider <$> compilerAsk
    if (resourceModified provider imgSrcId)
      then rebuildImages
      else do
        compilerTellCacheHits 1
        x <- compilerUnsafeIO $ Store.get store ["images", show ident]
        case x of
          Store.Found s -> return s
          _             -> rebuildImages

  match "math/**.tex" $ version "html" $ do
    route $ setExtension "html"
    compile' $ do
      ident <- getUnderlying
      fp <- decodeString . fromJust <$> (getRoute =<< getUnderlying)
      PreprocessedLaTeX{..} <- loadBody $ setVersion (Just "preprocess") ident
      forM_ images $ \(count, _) -> do
        void $ loadBody @BS.ByteString $ setVersion (Just "images") ident
        forM_ [0..count-1] $ \n -> do
          let base = dropExtension fp </> fromString ("image-" <> show n)
              svgId = fromString $ encodeString $ base <.> "svg"
              pngId = fromString $ encodeString $ base <.> "png"
          void $ loadBody @CopyFile svgId
          void $ loadBody @CopyFile pngId
      loadBody @CopyFile "katex/katex.min.js"
      ipandoc <- mapM (unsafeCompiler . texToMarkdown fp) =<< makeItem latexSource
      (style, bibs) <- cslAndBib
      ip' <- mapM (myProcCites style bibs) ipandoc
      conv'd <- mapM (linkCard . addPDFLink ("/" </> replaceExtension fp "pdf") .
                      addAmazonAssociateLink "konn06-22"
                      <=< procSchemes) ip'
      let item = ("{{=<% %>=}}\n" ++) <$> writePandocWith writerConf (procCrossRef <$> conv'd)
          panCtx = pandocContext $
                   itemBody conv'd & _Pandoc . _2 %~ (RawBlock "html" "{{=<% %>=}}\n":)
      applyDefaultTemplate panCtx . fmap ("{{=<% %>=}}\n" ++)
        =<< saveSnapshot "content"
        =<< MT.applyAsMustache panCtx item

  match "math/**.tex" $ version "pdf" $ do
    route $ setExtension "pdf"
    compile' $ getResourceBody >>= compileToPDF

  match ("math/**.png" .||. "math/**.jpg" .||. "math/**.svg") $
    route idRoute >> compile' copyFileCompiler
  match ("logs/*.md" .&&. complement "logs/index.md") $ version "html" $ do
    route $ setExtension "html"
    compile' $
      myPandocCompiler >>= saveSnapshot "content"
      >>= applyDefaultTemplate (myDefaultContext <> MT.bodyField "description")

  match (("articles/**.md" .||. "articles/**.html" .||. "profile.md" .||. "math/**.md" .||. "prog/**.md" .||. "writing/**.md") .&&. complement ("logs/**.md" .||. "index.md" .||. "**/index.md")) $ version "html" $ do
    route $ setExtension "html"
    compile' $
      myPandocCompiler >>= saveSnapshot "content" >>= applyDefaultTemplate myDefaultContext

  create ["feed.xml"] $ do
    route idRoute
    compile $
      loadAllSnapshots subContentsWithoutIndex "content"
        >>= myRecentFirst
        >>= return . take 10 . filter (matches ("index.md" .||. complement "**/index.md") . itemIdentifier)
        >>= renderAtom feedConf (MT.musContextToContext feedCxt)

  create ["sitemap.xml"] $ do
    route idRoute
    compile $ do
      items <- filterM isPublished
               =<< loadAll  (("**.md" .||. ("math/**.tex" .&&. hasVersion "html")) .&&. complement ("t/**" .||. "templates/**"))
      let ctx = mconcat [ MT.defaultMusContext
                        , MT.itemsFieldWithContext
                            (MT.defaultMusContext <> MT.modificationTimeField "date" "%Y-%m-%d")
                            "items" (items :: [Item String])
                        ]
      MT.loadAndApplyMustache "templates/sitemap.mustache" ctx
        =<< makeItem ()

cslAndBib :: Compiler (Style, [Reference])
cslAndBib = do
  fp <- decodeString . fromJust <$> (getRoute =<< getUnderlying)
  mbib <- fmap itemBody <$> optional (load $ fromFilePath $ replaceExtension fp "bib")
  gbib <- unsafeCompiler $ readBiblioFile $ encodeString globalBib
  style <- unsafeCompiler . readCSLFile Nothing . Hakyll.toFilePath . itemIdentifier
              =<< load (fromFilePath $ replaceExtension fp "csl")
              <|> (load "default.csl" :: Compiler (Item CSL))
  let bibs = maybe [] (\(BibTeX bs) -> bs) mbib ++ gbib
  return (style, bibs)

pandocContext :: Pandoc -> MT.MusContext a
pandocContext (Pandoc meta _)
  | Just abst <- lookupMeta "abstract" meta =
        MT.constField "abstract" $ T.unpack $
        fromPure $
        writeHtml5String writerConf $ Pandoc meta (mvToBlocks abst)
  | otherwise = mempty

listDrafts :: Compiler [(Identifier, P.FilePath)]
listDrafts = do
  mapM (\i -> let ident = itemIdentifier i in (ident,) . fromMaybe (Hakyll.toFilePath ident) <$> getRoute ident)
    =<< filterM (liftM not . isPublished)
    =<< (loadAll subContentsWithoutIndex :: Compiler [Item String])

compile' :: (Typeable a, Writable a, Binary a) => Compiler (Item a) -> Rules ()
compile' d = compile $ d

addRepo :: Compiler ()
addRepo = do
  item <- getResourceBody
  let ident = itemIdentifier item
  published <- isPublished item
  when published $ do
    let pth = toFilePath ident
    unsafeCompiler $ shelly $ silently $ void $ cmd "git" "add" pth

addPDFLink :: FilePath -> Pandoc -> Pandoc
addPDFLink plink (Pandoc meta body) = Pandoc meta body'
  where
    Pandoc _ body' = doc $ mconcat [ para $ mconcat [ "[", link (encodeString plink) "PDF版" "PDF版", "]"]
                                   , Pan.fromList body
                                   ]

appendBiblioSection :: Pandoc -> Pandoc
appendBiblioSection (Pandoc meta bs) =
    Pandoc meta $ bs ++ [Div ("biblio", [], []) [Header 1 ("biblio", [], []) [Str "参考文献"]]]

listChildren :: Bool -> Compiler [Item String]
listChildren recursive = do
  ident <- getUnderlying
  let dir = directory $ toFilePath ident
      exts = ["md", "tex"]
      wild = if recursive then "**" else "*"
      pat =  (foldr1 (.||.) $ [fromGlob $ encodeString $ dir </> wild <.> e | e <- exts]
              ++ [ "articles/**.html" | dir == "articles/" ])
               .&&. hasVersion "html" .&&. complement (fromList [ident] .||. nonHTMLVersion)
  loadAll pat >>= myRecentFirst

nonHTMLVersion :: Pattern
nonHTMLVersion =
  foldr1 (.||.) $ map hasVersion [ "pdf" , "images" ,  "image-source" , "preprocess" ]

data HTree a = HTree { label :: a, _chs :: [HTree a] } deriving (Read, Show, Eq, Ord)

headerTree :: [Block] -> [HTree Block]
headerTree [] = []
headerTree (b:bs) =
  case span ((> getLevel b).getLevel) bs of
    (lows, dohai) -> HTree b (headerTree lows) : headerTree dohai
  where
    getLevel (Header n _ _) = n
    getLevel _ = error "You promissed this consists of only Headers!"

buildTOC :: Pandoc -> String
buildTOC pan =
  renderHtml $
  H5.nav ! H5.class_ "navbar navbar-light bg-light flex-column" ! H5.id "side-toc" $ do
    H5.a ! H5.class_ "navbar-brand" ! H5.href "#" $ "TOC"
    build $ headerTree $ extractHeaders pan
  where
    build ts =
     H5.nav ! H5.class_ "nav nav-pills flex-column" $
     forM_ ts $ \(HTree (Header _ (ident, _, _) is) cs) -> do
       H5.a ! H5.class_ "nav-link ml-3 my-1"
            ! H5.href (H5.toValue $ '#' : ident)
            $ H5.toMarkup $ stringify is
       unless (null cs) $ build cs

extractHeaders :: Pandoc -> [Block]
extractHeaders = query ext
  where
    ext h@(Header {}) = [h]
    ext _             = []

compileToPDF :: Item String -> Compiler (Item TmpFile)
compileToPDF item = do
  mopts <- getMetadataField (itemIdentifier item) "latexmk"
  TmpFile (decodeString -> texPath) <- newTmpFile "pdflatex.tex"
  let tmpDir  = directory texPath
      pdfPath = filename $ replaceExtension texPath "pdf"
      bibOrig = replaceExtension (toFilePath (itemIdentifier item)) "bib"

  unsafeCompiler $ shelly $ silently $ do
    writefile texPath $ T.pack $ itemBody item
    exts <- test_e =<< absPath bibOrig
    when exts $ cp  bibOrig $ tmpDir </> filename bibOrig
    cp ".latexmkrc" tmpDir
    cd tmpDir
    case mopts of
      Nothing -> cmd "latexmk" "-pdfdvi" $ filename texPath
      Just opts -> run_ "latexmk" (map T.pack (words opts) ++ [Path.encode $ filename texPath])
    return ()
  makeItem $ TmpFile $ encodeString (tmpDir </> pdfPath)

renderMeta :: [Inline] -> T.Text
renderMeta ils = fromPure $ writeHtml5String def $ Pandoc nullMeta [Plain ils]

subContentsWithoutIndex :: Pattern
subContentsWithoutIndex = ("**.md" .||. "articles/**.html" .||. ("math/**.tex" .&&. hasVersion "html"))
                     .&&. complement ("index.md" .||. "**/index.md" .||. "archive.md")

feedCxt :: MT.MusContext String
feedCxt =  mconcat [ MT.field "published" itemDateStr
                   , MT.field "updated" itemDateStr
                   , MT.bodyField "description"
                   , MT.defaultMusContext
                   ]

itemDateStr :: Item a -> Compiler String
itemDateStr = fmap (formatTime defaultTimeLocale "%Y/%m/%d %X %Z") . itemDate

feedConf :: FeedConfiguration
feedConf = FeedConfiguration { feedTitle = "konn-san.com 建設予定地"
                             , feedDescription = "数理論理学を中心に数学、Haskell、推理小説、評論など。"
                             , feedAuthorName = "Hiromi ISHII"
                             , feedAuthorEmail = ""
                             , feedRoot = "https://konn-san.com"
                             }


writerConf :: WriterOptions
writerConf =
  def{ writerHTMLMathMethod = MathJax "https://konn-san.com/math/mathjax/MathJax.js?config=xypic"
     , writerHighlightStyle = Just pygments
     , writerSectionDivs = True
     , writerExtensions = disableExtension Ext_tex_math_dollars myExts
     }

readerConf :: ReaderOptions
readerConf = def { readerExtensions = myExts }

myPandocCompiler :: Compiler (Item String)
myPandocCompiler = do
  (csl, bib) <- cslAndBib
  pandocCompilerWithTransformM
    readerConf
    writerConf
    (    myProcCites csl bib
     >=> procSchemes
     >=> linkCard . addAmazonAssociateLink "konn06-22")

readHtml' :: ReaderOptions -> T.Text -> Pandoc
readHtml' opt = fromRight . runPure . readHtml opt

resolveRelatives :: PFP.FilePath -> PFP.FilePath -> PFP.FilePath
resolveRelatives rt pth =
  let revRoots = reverse $ PFP.splitPath rt
  in go revRoots $ PFP.splitPath pth
  where
    go _        ("/" : rest)   = go [] rest
    go (_ : rs) ("../" : rest) = go rs rest
    go []       ("../" : rest) = go [".."] rest
    go r        ("./" : rest)  = go r rest
    go rs       (fp  : rest)   = go (fp : rs) rest
    go fps      []             = PFP.joinPath $ reverse fps

applyDefaultTemplate :: MT.MusContext String -> Item String -> Compiler (Item String)
applyDefaultTemplate addCtx item = do
  bc <- makeBreadcrumb item
  nav <- makeNavBar $ itemIdentifier item
  pub <- isPublished item
  descr <- fromMaybe "" <$> getMetadataField (itemIdentifier item) "description"
  r <- fromMaybe "" <$> getRoute (itemIdentifier item)
  let imgs = map (("https://konn-san.com/" <>) . resolveRelatives (PFP.takeDirectory r)) $
             extractLocalImages $ TS.parseTags $ itemBody item
      navbar = MT.constField "navbar" nav
      thumb  = MT.constField "thumbnail" $
               fromMaybe "https://konn-san.com/img/myface_mosaic.jpg" $
               listToMaybe imgs
      bcrumb = MT.constField "breadcrumb" bc
      sdescr = either (const "") (T.unpack . T.replace "\n" " ") $ runPure $
               writePlain def . bottomUp unicodiseMath =<< readMarkdown readerConf (T.pack descr)
      plainDescr = MT.constField "short_description" sdescr
      unpublished = MT.boolField "unpublished" $ \_ -> not pub
      date = MT.field "date" itemDateStr
      toc = MT.field "toc" $ return . buildTOC . readHtml' readerConf . T.pack . itemBody
      noTopStar = MT.field "no-top-star" $ \i -> do
        getMetadataField (itemIdentifier i) "top-star" >>= \case
          Just t | Just False <- txtToBool t  -> return True
          _ -> return False
      hdr = MT.field "head" $ \i -> do
        return $
          if "math" `isPrefixOf` Hakyll.toFilePath (itemIdentifier i) && "math/index.md" /= toFilePath (itemIdentifier i)
          then renderHtml [shamlet|<link rel="stylesheet" href="/css/math.css">|]
          else ""
      meta = MT.field "meta" $ \i -> do
        [desc0, tags] <- forM ["description", "tag"] $ \key ->
          fromMaybe "" <$> getMetadataField (itemIdentifier i) key
        let desc = fromPure $ writePlain writerConf { writerHTMLMathMethod = PlainMath
                                         , writerWrapText = WrapNone }
                              =<< readMarkdown readerConf (T.pack desc0)
        return $ renderHtml $ do
          H5.meta ! H5.name "Keywords"    ! H5.content (H5.toValue tags)
          H5.meta ! H5.name "description" ! H5.content (H5.toValue desc)
      cxt  = mconcat [ thumb, plainDescr, unpublished, toc, addCtx, navbar, bcrumb
                     , hdr, meta, date, noTopStar, myDefaultContext]
  let item' = demoteHeaders . withTags addRequiredClasses <$> item
      links = filter isURI $ getUrls $ parseTags $ itemBody item'
  unsafeCompiler $ do
    broken <- filterM isLinkBroken links
    forM_ broken $ \l -> hPutStrLn stderr $ "*** Link Broken: " ++ l
  scms <- loadBody "config/schemes.yml"
  i <-  MT.applyAsMustache cxt item'
    >>= MT.loadAndApplyMustache "templates/default.mustache" cxt
    >>= relativizeUrls
    >>= procKaTeX
    >>= return . fmap ((packed %~ UNF.normalize UNF.NFC) . addAmazonAssociateLink' "konn06-22" . procSchemesUrl scms)
  return i

procKaTeX :: Item String -> Compiler (Item String)
procKaTeX item = do
  -- macs <- (<>) <$> loadBody "config/macros.yml" <*> itemMacros item
  isKat <- useKaTeX =<< getResourceBody
  if isKat
     then unsafeCompiler $ mapM prerenderKaTeX item
     else return item

extractLocalImages :: [Tag String] -> [String]
extractLocalImages ts =
   [ src
   | TagOpen t atts <- ts
   , at <- maybeToList $ lookup t [("img", "src"), ("object", "data")]
   , (a, src) <- atts
   , a == at
   , not $ isExternal src
   , T.takeEnd 4 (T.pack src) /= ".svg"
   ]

isLinkBroken :: String -> IO Bool
isLinkBroken _url = return False

myGetTags :: (Functor m, MonadMetadata m) => Identifier -> m [String]
myGetTags ident =
  maybe [] (map (T.unpack . T.strip) . T.splitOn "," . T.pack) <$> getMetadataField ident "tag"

addRequiredClasses :: Tag String -> Tag String
addRequiredClasses (TagOpen "table" attr) = TagOpen "table" (("class", "table"):attr)
addRequiredClasses (TagOpen "blockquote" attr) = TagOpen "blockquote" (("class", "blockquote"):attr)
addRequiredClasses t = t

config :: Configuration
config = defaultConfiguration
         & _deploySite .~ deploy
         & _ignoreFile.rmapping (_Unwrapping' Any)._Unwrapping' MonoidFun
           <>~ MonoidFun (Any . (== (".ignore" :: String)))

parseIgnorance :: T.Text -> (T.Text, T.Text)
parseIgnorance txt =
  let (a, T.drop 1 -> b) = T.breakOn "\t" txt
  in (a, if T.null b then a else b)

deploy :: t -> IO ExitCode
deploy _config = handle h $ shelly $ do
  ign0 <- T.lines <$> readfile "_site/.ignore"
  let (gign, ign) = unzip $ map parseIgnorance ign0
  echo $ "ignoring: " <> T.intercalate "," ign
  writefile ".git/info/exclude" $ T.unlines gign
  run_ "rsync" $ "--delete-excluded" : "--checksum" : "-av" : map ("--exclude=" <>) ign
              ++ ["_site/", "sakura-vps:~/mighttpd/public_html/"]
  cmd "git" "add" "img" "math" "writing" "prog" "config"
  cmd "git" "commit" "-amupdated"
  cmd "git" "push" "origin" "master"

  return ExitSuccess
  where
    h :: IOException -> IO ExitCode
    h _ = return $ ExitFailure 1


procSchemes :: Pandoc -> Compiler Pandoc
procSchemes = bottomUpM procSchemes0

procSchemesUrl :: Schemes -> String -> String
procSchemesUrl (Schemes dic) =
  withUrls $ \u ->
  case parseURI u of
    Just URI{..}
      | Just Scheme{..} <- HM.lookup (T.pack $ P.init uriScheme) dic
      -> let body = mconcat [ maybe "" uriAuthToString uriAuthority
                            , uriPath
                            , uriQuery
                            , uriFragment
                            ]
         in T.unpack prefix ++ body ++ maybe "" T.unpack postfix
    _  -> u

uriAuthToString :: URIAuth -> String
uriAuthToString (URIAuth a b c) = concat [a, b, c]
procSchemes0 :: Inline -> Compiler Inline
procSchemes0 inl =
  case inl ^? linkUrl of
    Nothing -> return inl
    Just url -> do
      Schemes dic <- loadBody "config/schemes.yml"
      let url' = maybe url T.unpack $ asum $
                 imap (\k v -> fmap (sandwitched (prefix v) (fromMaybe "" $ postfix v)) $
                               T.stripPrefix (k <> ":") $ T.pack url)
                 dic
      return $ inl & linkUrl .~ url'
  where
    sandwitched s e t = s <> t <> e

addAmazonAssociateLink :: String -> Pandoc -> Pandoc
addAmazonAssociateLink = bottomUp . procAmazon

addAmazonAssociateLink' :: String -> String -> String
addAmazonAssociateLink' tag = withUrls (attachTo tag)

procAmazon :: String -> Inline -> Inline
procAmazon tag (Link atts is (url, ttl))  = Link atts is (attachTo tag url, ttl)
procAmazon tag (Image atts is (url, ttl)) = Image atts is (attachTo tag url, ttl)
procAmazon _   il                      = il

attachTo :: String -> String -> String
attachTo key url
    | (p@("http:":"":amazon:paths), qs) <- decodePath (BS.pack url)
    , amazon `elem` amazons
    , let cipath = map CI.mk paths
    , ["o", "asin"] `isPrefixOf` cipath || "dp" `elem` cipath
                        || ["gp", "product"] `isPrefixOf` cipath
    , isNothing (lookup "tag" qs)
         = tail $ BS.unpack $ toByteString $ encodePath p (("tag", Just $ BS.pack key):qs)
attachTo _   url = url

amazons :: [T.Text]
amazons = "www.amazon.com":"amazon.com":concatMap (\cc -> [T.concat [www,"amazon.",co,cc] | www <- ["","www."], co <- ["co.", ""]]) ccTLDs

ccTLDs :: [T.Text]
ccTLDs = ["jp"]

getActive :: [(T.Text, String)] -> Identifier -> String
getActive _ "archive.md" = "/archive.html"
getActive _ "profile.md" = "/profile.html"
getActive cDic ident = do
  fromMaybe "/" $ listToMaybe $ filter p $ map snd cDic
  where
    p "/"       = False
    p ('/':inp) = fromGlob (inp++"/**") `matches` ident
    p _         = False

data Breadcrumb = Breadcrumb { parents      :: [(String, T.Text)]
                             , currentTitle :: String
                             }
                deriving (Show, Eq, Ord)

instance Y.ToJSON Breadcrumb where
  toJSON (Breadcrumb cbs ctr) =
    object ["breadcrumbs" .= [object ["path" .= fp, "name" .= name] | (fp, name) <- cbs ]
             ,"currentTitle" .= ctr
             ]

makeBreadcrumb :: Item String -> Compiler String
makeBreadcrumb item = do
  let ident = itemIdentifier item
  mytitle <- getMetadataField' ident "title"
  st <- loadBody "config/tree.yml"
  let dropIndex fp | filename fp == "index.md" = parent $ dirname fp
                   | otherwise = fp
      pars = map encodeString $ splitDirectories $ dropIndex $ toFilePath ident
      bc | ident == "index.md" = []
         | otherwise = walkTree pars st
  src <- loadBody "templates/breadcrumb.mustache"
  let obj = toJSON $ Breadcrumb bc mytitle
  return $ LT.unpack $ Mus.renderMustache src obj

makeNavBar :: Identifier -> Compiler String
makeNavBar ident = do
  NavBar cDic <- loadBody "config/navbar.yml"
  let cats = toJSON [object ["path" .= pth
                            ,"category" .= cat
                            ,"active" .= (getActive cDic ident == pth)
                            ]
                    | (cat, pth) <- cDic
                    ]
  src <- loadBody "templates/navbar.mustache"
  return $ LT.unpack $ Mus.renderMustache src cats

readHierarchy :: String -> [(String, String)]
readHierarchy = mapMaybe (toTup . words) . lines
  where
    toTup (x:y:ys) = Just (y ++ unwords ys, x)
    toTup _        = Nothing

postList :: Maybe Int -> Pattern -> Compiler (Int, String)
postList mcount pat = do
  postItemTpl <- loadBody "templates/update.mustache"
  posts <- fmap (maybe id take mcount) . myRecentFirst =<< loadAll pat
  let myDateField = MT.field "date" itemDateStr
      pdfField  = MT.field "pdf" $ \item ->
        let ident = itemIdentifier item in
        if "**.tex" `matches` ident
        then do
          Just r <- getRoute ident
          return $ Just $ encodeString $ "/" </> replaceExtension (decodeString r) "pdf"
        else return Nothing
      descField = MT.field "description" $ \item -> do
        let ident = itemIdentifier item
        descr <- maybe "" T.pack <$> (getMetadataField ident "description" <|> getMetadataField ident "body")
        fp <- fromJust <$> getRoute ident
        src <- loadBody $ itemIdentifier item
        let refs = buildRefInfo src
        let output = T.unpack $ fromPure $
                     writeHtml5String writerConf . bottomUp (remoteCiteLink fp refs)
                     =<< readMarkdown readerConf descr
        return $ output
      iCtxs = (pdfField <> myDateField <> descField <> MT.defaultMusContext) :: MT.MusContext String
      postsField = MT.itemsFieldWithContext iCtxs "posts" posts
  src <- procKaTeX
         =<< MT.applyMustache postItemTpl postsField =<< (makeItem ())
  return (length posts, itemBody src)

myDefaultContext :: MT.MusContext String
myDefaultContext =
  mconcat [ disqusCtx, MT.defaultMusContext ]
  where
    blacklist = ["index.md", "**/index.*", "archive.md", "profile.md"]
    disqusCtx = MT.field "disqus" $ \item -> do
      let banned = foldr1 (.||.) blacklist `matches` itemIdentifier item
      dic <- getMetadata $ itemIdentifier item
      let enabled = fromMaybe True $ maybeResult . fromJSON =<< HM.lookup "disqus" dic
      return $ not banned && enabled

itemPDFLink :: Item a -> Compiler String
itemPDFLink item
    | "**.tex" `matches` itemIdentifier item = do
        Just r <- getRoute $ itemIdentifier item
        return $ concat [" [", "<a href=\""
                        , encodeString $ "/" </> replaceExtension (decodeString r) "pdf"
                        , "\">"
                        , "PDF版"
                        , "</a>"
                        , "]"]
    | otherwise                                           = return ""

myRecentFirst :: [Item a] -> Compiler [Item a]
myRecentFirst is0 = do
  is <- filterM isPublished is0
  ds <- mapM itemDate is
  return $ map snd $ sortBy (flip $ comparing (zonedTimeToLocalTime . fst)) $ zip ds is

isPublished :: Item a -> Compiler Bool
isPublished item = do
  let ident = itemIdentifier item
  pub <- getMetadataField ident "published"
  dra <- getMetadataField ident "draft"
  return $ fromMaybe True $ (txtToBool =<< pub)
                         <|> not <$> (txtToBool =<< dra)

maybeResult :: Result a -> Maybe a
maybeResult (Success a) = Just a
maybeResult _           = Nothing

itemMacros :: Item a -> Compiler TeXMacros
itemMacros item = do
  metas <- getMetadata (itemIdentifier item)
  let obj = HM.lookup "macros" metas
  return $ fromMaybe HM.empty $ maybeResult . fromJSON =<< obj

useKaTeX :: MonadMetadata m => Item a -> m Bool
useKaTeX item = do
  let ident = itemIdentifier item
  kat <- getMetadataField ident "katex"
  return $ fromMaybe True $ txtToBool =<< kat

txtToBool :: String -> Maybe Bool
txtToBool txt =
  case txt & capitalize & packed %~ T.strip & reads of
    [(b, "")] -> Just b
    _         -> Nothing

capitalize :: String -> String
capitalize ""      = ""
capitalize (c: cs) = toUpper c : map toLower cs

itemDate :: Item a -> Compiler ZonedTime
itemDate item = do
  let ident = itemIdentifier item
  dateStr <- getMetadataField ident "date"
  let mdate = dateStr >>= parseTimeM True defaultTimeLocale "%Y/%m/%d %X %Z"
  case mdate of
    Just date -> return date
    Nothing -> unsafeCompiler $ utcToLocalZonedTime =<< getModified (toFilePath ident)

extractCites :: Data a => a -> [[Citation]]
extractCites = queryWith collect
  where
    collect (Cite t _) = [t]
    collect _          = []

appendTOC :: Pandoc -> Pandoc
appendTOC d@(Pandoc meta bdy) =
  let toc = generateTOC d
  in Pandoc meta $
     [ Div ("", ["container-fluid"], [])
       [ Div ("", ["row"], [])
       [ RawBlock "html" $ T.unpack toc
       , Div ("", ["col-md-8"], [])
         bdy
       ] ]
     ]

generateTOC :: Pandoc -> T.Text
generateTOC pan =
  let src = parseTags $ fromPure $ writeHtml5String
            writerConf { writerTableOfContents = True
                       , writerTemplate = Just "$toc$"
                       , writerTOCDepth = 4
                       }
            pan
      topAtts = [("class", "col-md-4 hidden-xs-down bg-light sidebar")
                ,("id", "side-toc")
                ]
  in TS.renderTags $
     [ TagOpen "nav" topAtts
     , TagOpen "a" [("class","navbar-brand")]
     , TagText "TOC"
     , TagClose "a"
     ] ++ mapMaybe rewriter src
     ++ [TagClose "nav"]
  where
    rewriter (TagOpen "ul"  atts) =
      Just $ TagOpen "nav" $ ("class", "nav nav-pills flex-column") : atts
    rewriter (TagClose "ul") = Just $ TagClose "nav"
    rewriter (TagOpen "a"  atts) =
      Just $ TagOpen "a" $ ("class", "nav-link") : atts
    rewriter (TagOpen "li" _) = Nothing
    rewriter (TagClose "li" ) = Nothing
    rewriter t = Just t


extractNoCites :: Data c => c -> [[Citation]]
extractNoCites = queryWith collect
  where
    collect (RawInline "latex" src) =
      case parseLaTeX $ T.pack src of
        Left _ -> []
        Right t -> flip queryWith t $ \a -> case a of
          TeXComm "nocite" [cs] -> [[ Citation (trim $ T.unpack w) [] [] NormalCitation 0 0
                                   | w <- T.splitOn "," $ T.init $ T.tail $ render cs]]
          _ -> []
    collect _ = []

myProcCites :: Style -> [Reference] -> Pandoc -> Compiler Pandoc
myProcCites style bib p = do
  let cs = extractCites p
      pars  = map (Para . pure . flip Cite []) $ cs ++ extractNoCites p
      -- Pandoc _ bibs = processCites style bib (Pandoc mempty pars)
      Pandoc info pan' = processCites style bib p
      refs = bottomUp refBlockToList $ filter isReference pan'
      body = filter (not . isReference) pan'
  return $ bottomUp removeTeXGomiStr $ bottomUp linkLocalCite $
     if null pars
     then p
     else Pandoc info (body ++ [Header 1 ("biblio", [], []) [Str "参考文献"]] ++ refs)

refBlockToList :: Block -> Block
refBlockToList
  (Div ("refs", ["references"], atts) divs) =
    RawBlock "html" $ renderHtml $
    applyAtts atts $
    H5.ul ! H5.id "refs" ! H5.class_ "references" $
    mapM_ listise divs
  where
    listise (Div (ident, cls, ats) [Para (Str lab : dv)]) =
      applyAtts ats $
      H5.li ! H5.id (H5.stringValue ident)
            ! H5.class_ (H5.stringValue $ unwords $ "ref" : cls)
            ! H5.dataAttribute "ref-label" (fromString $ unbracket lab) $ do
              H5.span ! H5.class_ "ref-label" $
                fromString lab
              H5.span ! H5.class_ "ref-body" $
                fromRight $ runPure $
                writeHtml5 writerConf $
                Pandoc nullMeta [Plain $ dropWhile (== Space) dv]
    listise _ = ""
refBlockToList d = d

paraToPlain :: Block -> Block
paraToPlain (Para bs) = Plain bs
paraToPlain b         = b

applyAtts :: Attributable b => [(String, String)] -> b -> b
applyAtts ats elt =
  let as = map (\(k, v) -> H5.customAttribute (fromString k) (fromString v)) ats
  in foldl (!) elt as

linkLocalCite :: Inline -> Inline
linkLocalCite (Cite cs bdy) =
  Cite cs [Link ("", [], []) bdy ("#ref-" ++ citationId (head cs), "")]
linkLocalCite i = i

remoteCiteLink :: String -> HM.HashMap String RefInfo -> Inline -> Inline
remoteCiteLink base refInfo (Cite cs _) =
  let ctLinks = [ maybe
                    (Strong [Str citationId])
                    (\RefInfo{..} -> Link ("", [], []) [Str refLabel] (base ++ "#" ++ refAnchor, ""))
                    mres
                | Citation{..} <- cs
                , let mres = HM.lookup citationId refInfo
                ]
  in Span ("", ["citation"], [("data-cites", intercalate "," $ map citationId cs)]) $
     concat [ [Str "["], ctLinks, [Str "]"]]
remoteCiteLink _ _ i                    = i

isReference :: Block -> Bool
isReference (Div (_, ["references"], _) _) = True
isReference _                              = False

data RefInfo = RefInfo { refAnchor :: String, refLabel :: String }
             deriving (Read, Show, Eq, Ord)

buildRefInfo :: String -> HM.HashMap String RefInfo
buildRefInfo =
  foldMap go
  .
  filter (tagOpen (== "li") (maybe False (elem "ref" . words) .  lookup "class"))
  .
  TS.parseTags
  where
    go ~(TagOpen _ atts) =
      maybe HM.empty (\(r, lab) -> HM.singleton r (RefInfo ("ref-" ++ r) lab)) $
        (,) <$> (L.stripPrefix "ref-" =<< lookup "id" atts)
            <*> lookup "data-ref-label" atts

unbracket :: String -> String
unbracket ('[':l)
  | Just lab <- T.stripSuffix "]" (T.pack l) = T.unpack lab
  | otherwise = l
unbracket lab = lab

removeTeXGomiStr :: String -> String
removeTeXGomiStr = packed %~ T.replace "\\qed" ""
                           . T.replace "\\mbox" ""
                           . T.replace "~" ""
                           . T.replace "\\printbibliography" ""
                           . T.replace "\\printbibliography[title=参考文献]" ""
                           . T.replace "\\RequirePackage{luatex85}" ""

procCrossRef :: Pandoc -> Pandoc
procCrossRef p = p

unicodiseMath :: Inline -> Inline
unicodiseMath m@(Math mode eqn) =
  let mmode | InlineMath <- mode = DisplayInline
            | otherwise = DisplayBlock
      inls = either (const [m]) (fromMaybe [] . writePandoc mmode) $ readTeX eqn
  in Span ("", ["math"], []) inls
unicodiseMath i = i

prerenderKaTeX :: String -> IO String
prerenderKaTeX src = shelly $ silently $ handleany_sh (const $ return src) $ do
  cd "katex"
  setStdin $ T.pack src
  nodePath <- get_env_text "NODE_PATH"
  wd <- pwd
  setenv "NODE_PATH" $
    T.intercalate ":" [Path.encode (wd </> "contrib"), Path.encode wd, nodePath]
  T.unpack <$> cmd "node" "../data/prerender.js"

fromPure :: IsString a => PandocPure a -> a
fromPure = either (const "") id . runPure

myExts :: Extensions
myExts = mconcat [extensionsFromList exts, pandocExtensions]
  where
    exts = [ Ext_backtick_code_blocks
           , Ext_definition_lists
           , Ext_fenced_code_attributes
           , Ext_footnotes
           , Ext_raw_html
           , Ext_raw_tex
           , Ext_tex_math_dollars
           , Ext_emoji
           ]

protocol :: T.Text -> Maybe T.Text
protocol url = T.pack . P.init . uriScheme <$> parseURI (T.unpack url)

linkCard :: Pandoc -> Compiler Pandoc
linkCard = bottomUpM $ \case
  Para  bs | Just us <- checkCard bs, not (null us) -> toCards us
  Plain bs | Just us <- checkCard bs, not (null us) -> toCards us
  b -> return b
  where
    toCards us = do
      tmpl <- loadBody "templates/site-card.mustache"
      (gaths, protos, frams) <- unzip3 <$> mapM toCard us
      let gathered = and gaths && and (zipWith (==) protos (tail protos))
      return $ RawBlock "html" $
        LT.unpack $
        Mus.renderMustache tmpl $
          object [ "gather" .= gathered
                 , "frames" .= frams
                 ]
    myStringify Link{} = "LINK"
    myStringify l      = stringify l
    checkCard = mapM isCard . filter (not . all isSpace . myStringify)
    isCard (Link _ [] (url, "")) = Just url
    isCard _                     = Nothing
    toCard (T.pack -> origUrl) = do
      Cards{..} <- loadBody "config/cards.yml"
      let mproto = protocol origUrl
          Card{template = tmpl,gather} =
            fromMaybe defaultCard $ flip HM.lookup cardDic =<< mproto
          urlBody = fromMaybe origUrl $
                    flip T.stripPrefix origUrl . (`T.snoc` ':') =<< mproto
          model = object [ "url" .= origUrl
                         , "urlBody" .= urlBody
                         , "gather" .= gather
                         ]
          body = Mus.renderMustache tmpl model
      return (gather, fromMaybe "*" mproto, body)

data Log = Log { logLog   :: T.Text
               , logTitle :: String
               , logDate  :: String
               , logIdent :: String
               }
  deriving (Generic)

logConf :: Ae.Options
logConf = defaultOptions { fieldLabelModifier = camelTo2 '_' . drop 3 }

toLog :: Item String -> Compiler (Item Log)
toLog i0 = do
  i <- readPandoc i0
  let logIdent = PFP.takeBaseName $ Hakyll.toFilePath $ itemIdentifier i
      Right logLog = runPure (writeHtml5String writerConf $ itemBody i) <&> unpacked %~ demoteHeaders
  logTitle <- getMetadataField' (itemIdentifier i) "title"
  logDate <-  getMetadataField' (itemIdentifier i) "date"
  return $ const Log{..} <$> i

instance ToJSON Log where
  toJSON = genericToJSON logConf
