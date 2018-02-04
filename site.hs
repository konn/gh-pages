{-# LANGUAGE DeriveDataTypeable, ExtendedDefaultRules, FlexibleContexts    #-}
{-# LANGUAGE GADTs, LambdaCase, NoMonomorphismRestriction                  #-}
{-# LANGUAGE OverloadedStrings, PatternGuards, QuasiQuotes                 #-}
{-# LANGUAGE RecordWildCards, TemplateHaskell, TupleSections, TypeFamilies #-}
{-# LANGUAGE ViewPatterns                                                  #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind -fno-warn-type-defaults         #-}
module Main where
import           Blaze.ByteString.Builder        (toByteString)
import           Control.Applicative
import           Control.Lens                    (rmapping, (%~), (.~), (<&>), (<>~), (^?), _Unwrapping')


import           Control.Monad                   hiding (mapM, sequence)
import           Control.Monad.Error.Class       (throwError)
import           Data.Binary
import qualified Data.ByteString.Char8           as BS
import qualified Data.CaseInsensitive            as CI
import           Data.Char                       hiding (Space)
import           Data.Data
import           Data.Function
import           Data.List                       hiding (stripPrefix)
import qualified Data.List                       as L
import           Data.Maybe
import           Data.Monoid
import           Data.Ord
import           Data.String
import qualified Data.Text                       as T
import qualified Data.Text.Lazy                  as LT
import           Data.Text.Lens                  (packed)
import           Data.Time
import           Data.Traversable                hiding (forM)
import           Filesystem
import           Filesystem.Path.CurrentOS       hiding (concat, empty, null,
                                                  (<.>), (</>))
import qualified Filesystem.Path.CurrentOS       as Path
import           Hakyll                          hiding (fromFilePath,
                                                  toFilePath, writePandoc)
import qualified Hakyll
import           Instances
import           Language.Haskell.TH             (litE, runIO, stringL)
import           MathConv
import           Network.HTTP.Types
import           Network.URI                     hiding (query)
import           Prelude                         hiding (FilePath, div, mapM,
                                                  sequence, span)
import qualified Prelude                         as P
import           Shelly                          hiding (tag)
import           Skylighting                     hiding (Context (), Style)
import qualified System.FilePath.Posix           as PFP
import           System.IO                       (hPutStrLn, stderr)
import           Text.Blaze.Html.Renderer.String
import           Text.Blaze.Html5                ((!))
import qualified Text.Blaze.Html5                as H5
import qualified Text.Blaze.Html5.Attributes     as H5
import           Text.CSL                        (Reference, Style,
                                                  readBiblioFile, readCSLFile)
import           Text.CSL.Pandoc
import           Text.Hamlet
import           Text.HTML.TagSoup
import qualified Text.HTML.TagSoup               as TS
import           Text.LaTeX.Base                 (render)
import           Text.LaTeX.Base.Parser
import           Text.LaTeX.Base.Syntax
import qualified Text.Mustache                   as Mus
import           Text.Pandoc                     hiding (runIO)
import           Text.Pandoc.Builder             hiding (fromList)
import qualified Text.Pandoc.Builder             as Pan
import           Text.Pandoc.Shared              (stringify)
import           Text.Pandoc.Walk
import           Text.TeXMath

import           Control.Exception    (IOException, handle)
import           Control.Lens         (imap)
import           Data.Aeson           (Result (..), fromJSON)
import qualified Data.ByteString.Lazy as LBS
import           Data.Foldable        (asum)
import qualified Data.HashMap.Strict  as HM
import           Data.Yaml            (object, toJSON, (.=))
import qualified Data.Yaml            as Y
import           Lenses
import           Macro
import           Settings
import           System.Exit          (ExitCode (..))

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

  {-
  tags <- buildTagsWith myGetTags
          (("**.md" .||. "**.tex") .&&. complement ("index.md" .||. "*/index.md"))
          (fromCapture "tags/*.html")
  -}

  match "index.md" $ do
    route $ setExtension "html"
    compile' $ do
      (count, posts) <- postList (Just 5) subContentsWithoutIndex
      let ctx = mconcat [ constField "child-count" (show count)
                        , constField "updates" posts
                        , defaultContext
                        ]
      myPandocCompiler
              >>= applyDefaultTemplate ctx {- tags -}

  match "archive.md" $ do
    route $ setExtension "html"
    compile' $ do
      (count, posts) <- postList Nothing subContentsWithoutIndex
      let ctx = mconcat [ constField "child-count" (show count)
                        , constField "children" posts
                        , defaultContext
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

  match "*/index.md" $ do
    route $ setExtension "html"
    compile' $ do
      chs <- listChildren True
      (count, chl) <- postList Nothing (fromList $ map itemIdentifier chs)
      let ctx = mconcat [ constField "child-count" (show count)
                        , constField "children" chl
                        , defaultContext
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
  match "math/**.tex" $ version "html" $ do
    route $ setExtension "html"
    compile' $ do
      CopyFile{} <- loadBody "katex/katex.min.js"
      fp <- decodeString . fromJust <$> (getRoute =<< getUnderlying)
      macs <- loadBody "config/macros.yml"
      cmacs <- itemMacros =<< getResourceBody
      (style, bibs) <- cslAndBib
      ipandoc <- mapM (unsafeCompiler . texToMarkdown (cmacs <> macs) fp) =<< getResourceBody
      ip' <- mapM (myProcCites style bibs) ipandoc
      conv'd <- mapM (return . addPDFLink ("/" </> replaceExtension fp "pdf") .
                      addAmazonAssociateLink "konn06-22"
                      <=< procSchemes) ip'
      let item = writePandocWith
                     writerConf $ procCrossRef <$> conv'd
      saveSnapshot "content" =<< applyDefaultTemplate (pandocContext $ itemBody conv'd) item

  match "math/**.tex" $ version "pdf" $ do
    route $ setExtension "pdf"
    compile' $ getResourceBody >>= compileToPDF

  match ("math/**.png" .||. "math/**.jpg" .||. "math/**.svg") $
    route idRoute >> compile' copyFileCompiler

  match (("articles/**.md" .||. "articles/**.html" .||. "profile.md" .||. "math/**.md" .||. "prog/**.md" .||. "writing/**.md") .&&. complement ("index.md" .||. "**/index.md")) $ do
    route $ setExtension "html"
    compile' $
      myPandocCompiler >>= saveSnapshot "content" >>= applyDefaultTemplate mempty

  create ["feed.xml"] $ do
    route idRoute
    compile $
      loadAllSnapshots subContentsWithoutIndex "content"
        >>= myRecentFirst
        >>= return . take 10 . filter (matches ("index.md" .||. complement "**/index.md") . itemIdentifier)
        >>= renderAtom feedConf feedCxt

  create ["sitemap.xml"] $ do
    route idRoute
    compile $ do
      items <- filterM isPublished
               =<< loadAll  (("**.md" .||. ("math/**.tex" .&&. hasVersion "html")) .&&. complement ("t/**" .||. "templates/**"))
      tpl <- loadBody "templates/sitemap-item.xml"
      loadAndApplyTemplate "templates/sitemap.xml"
        defaultContext
        =<< makeItem
        =<< applyTemplateList tpl
               (defaultContext  <> modificationTimeField "date" "%Y-%m-%d")
               items

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

pandocContext :: Pandoc -> Context a
pandocContext (Pandoc meta _)
  | Just abst <- lookupMeta "abstract" meta =
        constField "abstract" $ T.unpack $
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
    Pandoc _ body' = doc $ mconcat [ para $ "[" <> link (encodeString plink) "PDF版" "PDF版" <> "]"
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
               .&&. complement (fromList [ident] .||. hasVersion "pdf")
  loadAll pat >>= myRecentFirst

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

feedCxt :: Context String
feedCxt =  mconcat [ field "published" itemDateStr
                   , field "updated" itemDateStr
                   , bodyField "description"
                   , defaultContext
                   ]

itemDateStr :: Item a -> Compiler String
itemDateStr = fmap (formatTime defaultTimeLocale "%Y/%m/%d %X %Z") . itemDate

feedConf :: FeedConfiguration
feedConf = FeedConfiguration { feedTitle = "konn-san.com 建設予定地"
                             , feedDescription = "数理論理学を中心に数学、Haskell、推理小説、評論など。"
                             , feedAuthorName = "Hiromi ISHII"
                             , feedAuthorEmail = ""
                             , feedRoot = "http://konn-san.com"
                             }


writerConf :: WriterOptions
writerConf =
  def{ writerHTMLMathMethod = MathJax "http://konn-san.com/math/mathjax/MathJax.js?config=xypic"
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
     >=> return . addAmazonAssociateLink "konn06-22")

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

applyDefaultTemplate :: Context String -> Item String -> Compiler (Item String)
applyDefaultTemplate addCtx item = do
  bc <- makeBreadcrumb item
  nav <- makeNavBar $ itemIdentifier item
  pub <- isPublished item
  descr <- fromMaybe "" <$> getMetadataField (itemIdentifier item) "description"
  r <- fromMaybe "" <$> getRoute (itemIdentifier item)
  let imgs = map (("http://konn-san.com/" <>) . resolveRelatives (PFP.takeDirectory r)) $
             extractLocalImages $ TS.parseTags $ itemBody item
      navbar = constField "navbar" nav
      thumb  = constField "thumbnail" $
               fromMaybe "http://konn-san.com/img/myface_mosaic.jpg" $
               listToMaybe imgs
      bcrumb = constField "breadcrumb" bc
      sdescr = either (const "") (T.unpack . T.replace "\n" " ") $ runPure $
               writePlain def . bottomUp unicodiseMath =<< readMarkdown readerConf (T.pack descr)
      plainDescr = constField "short_description" sdescr
      unpublished = boolField "unpublished" $ \_ -> not pub
      date = field "date" itemDateStr
      toc = field "toc" $ return . buildTOC . readHtml' readerConf . T.pack . itemBody
      noTopStar = field "no-top-star" $ \i ->
        getMetadataField (itemIdentifier i) "top-star" <&> \case
          Just t | Just False <- txtToBool t  -> return (error "NO Text Data")
          _ -> empty
      hdr = field "head" $ \i -> return $
        if "math" `isPrefixOf` Hakyll.toFilePath (itemIdentifier i) && "math/index.md" /= toFilePath (itemIdentifier i)
        then renderHtml [shamlet|<link rel="stylesheet" href="/css/math.css">|]
        else ""
      meta = field "meta" $ \i -> do
        [desc0, tags] <- forM ["description", "tag"] $ \key ->
          fromMaybe "" <$> getMetadataField (itemIdentifier i) key
        let desc = fromPure $ writePlain writerConf { writerHTMLMathMethod = PlainMath
                                         , writerWrapText = WrapNone }
                              =<< readMarkdown readerConf (T.pack desc0)
        return $ renderHtml $ do
          H5.meta ! H5.name "Keywords"    ! H5.content (H5.toValue tags)
          H5.meta ! H5.name "description" ! H5.content (H5.toValue desc)
      cxt  = mconcat [ thumb, plainDescr, unpublished, toc, addCtx, navbar, bcrumb
                     , hdr, meta, date, noTopStar, defaultContext]
  let item' = demoteHeaders . withTags addRequiredClasses <$> item
      links = filter isURI $ getUrls $ parseTags $ itemBody item'
  unsafeCompiler $ do
    broken <- filterM isLinkBroken links
    forM_ broken $ \l -> hPutStrLn stderr $ "*** Link Broken: " ++ l

  applyAsTemplate cxt item'
    >>= loadAndApplyTemplate "templates/default.html" cxt
    >>= relativizeUrls
    >>= procKaTeX

procKaTeX :: Traversable t => t String -> Compiler (t String)
procKaTeX item = do
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
  debugCompiler $ "cDic: " ++ show cDic
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
  postItemTpl <- loadBody "templates/update.html"
  posts <- fmap (maybe id take mcount) . myRecentFirst =<< loadAll pat
  let myDateField = field "date" itemDateStr
      pdfField = field "pdf" itemPDFLink
      descField = field "description" $ \item -> do
        let ident = itemIdentifier item
        descr <- T.pack <$> getMetadataField' ident "description"
        fp <- fromJust <$> getRoute ident
        src <- loadBody $ itemIdentifier item
        let Right (Pandoc _ obs) = runPure $ readHtml readerConf $ T.pack src
            refs = buildRefInfo obs
        let output = T.unpack $ fromPure $
                     writeHtml5String writerConf . bottomUp (citeLink fp refs)
                     =<< readMarkdown readerConf descr
        return $ output

  src <- unsafeCompiler . prerenderKaTeX =<<
         applyTemplateList postItemTpl (pdfField <> myDateField <> descField <> defaultContext) posts
  return (length posts, src)

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
      refs = filter isReference pan'
      body = filter (not . isReference) pan'
  return $ bottomUp removeTeXGomiStr $
     if null pars
     then p
     else Pandoc info (body ++ [Header 1 ("biblio", [], []) [Str "参考文献"]] ++ refs)

citeLink :: String -> HM.HashMap String RefInfo -> Inline -> Inline
citeLink base refInfo (Cite cs _) =
  let ctLinks = [ maybe
                    (Strong [Str citationId])
                    (\RefInfo{..} -> Link ("", [], []) [Str refLabel] (base ++ "#" ++ refAnchor, ""))
                    mres
                | Citation{..} <- cs
                , let mres = HM.lookup citationId refInfo
                ]
  in Span ("", ["citation"], [("data-cites", intercalate "," $ map citationId cs)]) $
     concat [ [Str "["], ctLinks, [Str "]"]]

citeLink _ _ i                    = i

isReference :: Block -> Bool
isReference (Div (_, ["references"], _) _) = True
isReference _                              = False

data RefInfo = RefInfo { refAnchor :: String, refLabel :: String }
             deriving (Read, Show, Eq, Ord)

buildRefInfo :: Walkable Block b => b -> HM.HashMap [Char] RefInfo
buildRefInfo = query $ \case
  Div (ref, _, _) [Para is]
    | Just ident <- L.stripPrefix "ref-" ref
    -> let lab = unbracket $ stringify $ takeWhile (/= Space) $ dropWhile (== Space) is
       in HM.singleton ident (RefInfo ref lab)
  _ -> HM.empty

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
  cd "data"
  setStdin $ T.pack src
  T.unpack <$> cmd "node" "prerender.js"

fromPure :: PandocPure T.Text -> T.Text
fromPure = either (const "") id . runPure

myExts :: Extensions
myExts = extensionsFromList exts <> pandocExtensions
  where
    exts = [ Ext_backtick_code_blocks
           , Ext_definition_lists
           , Ext_fenced_code_attributes
           , Ext_footnotes
           , Ext_raw_html
           , Ext_raw_tex
           , Ext_tex_math_dollars
           ]
