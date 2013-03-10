{-# LANGUAGE OverloadedStrings, PatternGuards, QuasiQuotes, TupleSections #-}
module Main where
import           Blaze.ByteString.Builder        (toByteString)
import           Control.Applicative
import           Control.Monad
import qualified Data.ByteString.Char8           as BS
import qualified Data.CaseInsensitive            as CI
import           Data.List                       hiding (span)
import           Data.Maybe
import           Data.Monoid
import           Data.String
import qualified Data.Text                       as T
import           Hakyll
import           Network.HTTP.Types
import           Prelude                         hiding (div, span)
import           System.FilePath
import           Text.Blaze.Html.Renderer.String
import           Text.Hamlet
import           Text.HTML.TagSoup
import           Text.Pandoc

main :: IO ()
main = hakyllWith config $ do
  match "*.css" $ route idRoute >> compile compressCssCompiler
  match ("js/*" .||. "robots.txt" .||. "img/*" .||. "favicon.ico" .||. "files/**") $
    route idRoute >> compile copyFileCompiler
  match "css/*" $ route idRoute >> compile compressCssCompiler
  match "templates/*" $ compile templateCompiler
  match "index.md" $ do
    route $ setExtension "html"
    compile $ myPandocCompiler >>= applyDefaultTemplate >>= relativizeUrls
  match "t/**/*" $ route idRoute >> compile copyFileCompiler
  match "writing/*.md" $ do
    route $ setExtension "html"
    compile $ myPandocCompiler >>= applyDefaultTemplate >>= relativizeUrls
  match "prog/*.md" $ do
    route $ setExtension "html"
    compile $
       myPandocCompiler
         >>= applyDefaultTemplate
         >>= relativizeUrls
  match "prog/automaton/**/*" $ route idRoute >> compile copyFileCompiler
  match "prog/**/*.html" $ route idRoute >> compile copyFileCompiler
  match "prog/**/*.js" $ route idRoute >> compile copyFileCompiler
  match ("math/**/*.pdf" .||. "math/*.pdf") $ route idRoute >> compile copyFileCompiler
  match "math/**/*.html" $ route idRoute >> compile copyFileCompiler
  match ("math/**/*.png" .&&. complement "math/mathjax/**/*") $
    route idRoute >> compile copyFileCompiler
  match "math/*.md" $ do
    route $ setExtension "html"
    compile $
       myPandocCompiler >>= applyDefaultTemplate >>= relativizeUrls

myPandocCompiler :: Compiler (Item String)
myPandocCompiler = pandocCompilerWithTransform def def{ writerHTMLMathMethod = MathJax "/math/mathjax/MathJax.js?config=xypic"} (addAmazonAssociateLink "konn06-22")

applyDefaultTemplate :: Item String -> Compiler (Item String)
applyDefaultTemplate =
  let navbar = field "navbar" $ return . makeNavBar . itemIdentifier
      bcrumb = field "breadcrumb" $ makeBreadcrumb . itemIdentifier
      header = field "head" $ \i -> return $
        if "math" `isPrefixOf` toFilePath (itemIdentifier i) && "math/index.md" /= toFilePath (itemIdentifier i)
        then renderHtml [shamlet|<link rel="stylesheet" href="/css/math.css">|]
        else ""
  in return . fmap (demoteHeaders . withTags addTableClass) >=> loadAndApplyTemplate "templates/default.html" (defaultContext <> navbar <> bcrumb <> header)

addTableClass :: Tag String -> Tag String
addTableClass (TagOpen "table" attr) = TagOpen "table" (("class", "table"):attr)
addTableClass t = t

config :: Configuration
config = defaultConfiguration { deployCommand = "rsync --checksum -av _site/* sakura-vps:~/mighttpd/public_html/"}

addAmazonAssociateLink :: String -> Pandoc -> Pandoc
addAmazonAssociateLink = bottomUp . procAmazon

procAmazon :: String -> Inline -> Inline
procAmazon tag (Link is (url, title))  = Link is (attachTo tag url, title)
procAmazon tag (Image is (url, title)) = Image is (attachTo tag url, title)
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
    | Just as <- T.stripPrefix "asin:" $ T.pack url
    = "http://www.amazon.co.jp/dp/" ++ T.unpack as ++ "/?tag=" ++ key
attachTo _   url = url

amazons :: [T.Text]
amazons = "www.amazon.com":"amazon.com":concatMap (\cc -> [T.concat [www,"amazon.",co,cc] | www <- ["","www."], co <- ["co.", ""]]) ccTLDs

ccTLDs :: [T.Text]
ccTLDs = ["jp"]

catDic :: [(Html, String)]
catDic = [("Home", "/")
         ,("Math", "/math")
         ,("Programming", "/prog")
         ,("Writings", "/writing")
         ,("Blog", "http://blog.konn-san.com/")
         ]

getActive :: Identifier -> String
getActive ident = fromMaybe "/" $ listToMaybe $ filter p $ map snd catDic
  where
    p "/" = False
    p ('/':inp) = fromString (inp++"/*") `matches` ident
    p _ = False

makeBreadcrumb :: Identifier -> Compiler String
makeBreadcrumb ident = do
  mytitle <- fromMaybe (takeBaseName $ toFilePath ident) <$> getMetadataField ident "title"
  let parents = filter (/= toFilePath ident) $ map ((</> "index.md").joinPath) $ init $ inits $ splitPath $ toFilePath ident
  bc <- forM parents $ \fp -> do
    Just path <- getRoute $ fromFilePath fp
    (toUrl path, ) . fromMaybe (takeBaseName fp) <$> getMetadataField (fromFilePath fp) "title"
  return $ renderHtml [shamlet|
      <ul .breadcrumb>
        $forall (path, title) <- bc
          <li>
            <a href=#{path}>#{title}
            <span .divider>/
        <li .active>
          #{mytitle}
    |]

makeNavBar :: Identifier -> String
makeNavBar ident = renderHtml $ do
  let cats = [(path, cat, getActive ident == path) | (cat, path) <- catDic ]
  [shamlet|
  <div .navbar .navbar-inverse .navbar-fixed-top>
    <div .navbar-inner>
      <div .container>
        <button .btn .btn-navbar data-toggle="collapse" data-target=".nav-collapse">
          $forall _ <- catDic
            <span .icon-bar>
        <a .brand href="/">konn-san.com
        <div .nav-collapse .collapse>
          <ul .nav>
            $forall (path, cat, isActive) <- cats
              $if isActive
                 <li .active>
                   <a href="#{path}">#{cat}
              $else
                 <li>
                   <a href="#{path}">#{cat}
  |]

readHierarchy :: String -> [(String, String)]
readHierarchy = mapMaybe (toTup . words) . lines
  where
    toTup (x:y:ys) = Just (y ++ unwords ys, x)
    toTup _        = Nothing
