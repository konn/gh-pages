{-# LANGUAGE DeriveAnyClass, DeriveGeneric, DerivingStrategies            #-}
{-# LANGUAGE FlexibleInstances, GeneralizedNewtypeDeriving, LambdaCase    #-}
{-# LANGUAGE NamedFieldPuns, NoMonomorphismRestriction, OverloadedStrings #-}
{-# LANGUAGE RecordWildCards, StandaloneDeriving, ViewPatterns            #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module MissingSake
       ( tryWithFile, PageInfo(..), ContentsIndex(..)
       , Routing(..), (</?>), hasSnapshot, writeItem, Snapshot(..), SnapshotName
       , Patterns, (.&&.), (.||.), complement, stripDirectory
       , (?===), (%%>), conjoin, disjoin, globDirectoryFiles, ifChanged
       , replaceDir, withRouteRules, loadAllItemsAfter, loadOriginal, getSourcePath
       , loadContentsIndex, saveSnapshot, loadSnapshot, loadAllSnapshots
       ) where
import           Control.Monad              (forM, when)
import           Crypto.Hash.SHA256         (hash)
import           Data.Aeson                 (Value)
import qualified Data.Binary                as Bin
import qualified Data.ByteString            as BS
import           Data.Functor.Contravariant (Contravariant (..))
import           Data.HashMap.Strict        (HashMap)
import qualified Data.HashMap.Strict        as HM
import qualified Data.HashSet               as HS
import qualified Data.List                  as L
import           Data.Scientific            (Scientific (..))
import           Data.Semigroup             (Semigroup, (<>))
import           Data.Store                 (Store (..))
import           Data.String                (IsString (..))
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           GHC.Generics               (Generic)
import           System.Directory           (createDirectoryIfMissing)
import           System.IO                  (IOMode (..), withFile)
import           Web.Sake                   (Action, FilePattern,
                                             Identifier (..), Item (..),
                                             Metadata, MonadAction, Readable,
                                             Rules, alternatives, copyFile',
                                             doesFileExist, filePattern,
                                             getDirectoryFiles, itemBody,
                                             itemIdentifier, itemPath,
                                             liftAction, liftIO, loadItem,
                                             makeRelative, need, putNormal,
                                             readFromBinaryFile',
                                             removeFilesAfter, withTempFile,
                                             writeBinaryFile, writeToFile, (%>),
                                             (<//>), (</>), (?==), (?>), (~>))
import           Web.Sake.Conf              (SakeConf (..))

tryWithFile :: MonadAction m => FilePath -> m a -> m (Maybe a)
tryWithFile fp act = do
  ex <- liftAction $ doesFileExist fp
  if ex
    then Just <$> act
    else return Nothing

data Clause = Clause { _positives :: HS.HashSet FilePattern
                     , _negatives :: HS.HashSet FilePattern
                     }
            deriving (Read, Show, Eq, Generic, Store)

newtype Patterns = DNF [Clause]
                   -- ^ Disjunction Normal Form (disjunction of conjunctions of literals)
                 deriving (Read, Show, Eq, Generic)
                 deriving newtype (Store)

data Snapshot = Snapshot { snapshotName   :: String
                         , snapshotTarget :: Patterns
                         , snapshotSource :: Patterns
                         }
              deriving (Read, Show, Eq, Generic, Store)

-- | Pattern syntax is @[[sourcePattern "|" |]targetPattern#]snapshot_name@ and you can escape @|@, @#@ and @\\@ by prefixing @\\@.
--   Forexample, @"content"@ is equivalent to @'Snapshot' { snapshotName = "content", snapshotSource = "//*", snapshotTarget = "//*"}@,
-- @"//*.html#content"@ to @'Snapshot' { snapshotName = "content", snapshotSource = "//*", snapshotTarget = "//*.html"}@, and
-- @"//source-\\#*.md|//index-\\|*.html#content"@ to @'Snapshot' { snapshotName = "content", snapshotSource = "//source-#*.md", snapshotTarget = "//index-|*.html"}@.

instance IsString Snapshot where
  fromString = parseSnapshot . T.pack

parseSnapshot :: Text -> Snapshot
parseSnapshot src =
  case breakOnEscaped '#' src of
    (snap, "") -> defSnap { snapshotName = fromString $ T.unpack snap }
    (pths, t)  ->
      let snapshotName = T.unpack $ T.tail t
      in case breakOnEscaped '|' pths of
        (targ, "")  -> defSnap { snapshotName, snapshotTarget = fromString $ T.unpack targ }
        (srcPat, targ) ->
          let snapshotTarget = fromString $ T.unpack $ T.tail targ
              snapshotSource = fromString $ T.unpack srcPat
          in Snapshot {..}
  where
    defSnap = Snapshot "" "//*" "//*"

breakOnEscaped :: Char -> Text -> (Text, Text)
breakOnEscaped c = breakEscaped' ""
  where
    breakEscaped' acc str =
      case T.break (`elem` [c, '\\']) str of
        (left, T.uncons -> Just ('\\', T.uncons -> Just ('\\', r)))
          -> breakEscaped' (acc <> left <> "\\") r
        (left, T.uncons -> Just ('\\', T.uncons -> Just (d, r)))
          | d == c -> breakEscaped' (acc <> left `T.snoc` c) r
          | otherwise -> breakEscaped' (acc <> left `T.snoc` '\\' `T.snoc` d) r
        (left, r0@(T.uncons -> Just (_, _))) -> (acc <> left, r0)
        (l, r) -> (acc <> l, r)

instance IsString Patterns where
  fromString = DNF . pure . flip Clause HS.empty . HS.singleton . fromString

instance Semigroup Clause

instance Monoid Clause where
  mempty = Clause HS.empty HS.empty
  mappend (Clause ls rs) (Clause us ts) = Clause (ls <> us) (rs <> ts)

infixr 2 .||.
infixr 3 .&&.

(.||.) :: Patterns -> Patterns -> Patterns
DNF xs .||. DNF ys = DNF (xs ++ ys)

(.&&.) :: Patterns -> Patterns -> Patterns
DNF [xs] .&&. DNF [ys] = DNF [xs <> ys]
DNF xs .&&. DNF ys =
  removeRedundants $ DNF $ concatMap (\x -> map (x <>) ys) xs

negateClause :: Clause -> Patterns
negateClause (Clause ls rs) = DNF $ [ Clause HS.empty (HS.singleton f) | f <- HS.toList ls]
                                 ++ [ Clause (HS.singleton g) HS.empty | g <- HS.toList rs]

complement :: Patterns -> Patterns
complement (DNF fs) = foldr1 (.&&.) $ map negateClause fs

removeRedundants :: Patterns -> Patterns
removeRedundants (DNF cs) = DNF $ filter (\(Clause ps ns) -> HS.null $ ps `HS.intersection` ns) cs

clMatch :: Clause -> FilePath -> Bool
clMatch (Clause ps ns) fp =
  all (?== fp) ps && all (not . (?== fp)) ns

conjoin :: Foldable t => t Patterns -> Patterns
conjoin = foldr1 (.&&.)

disjoin :: Foldable t => t Patterns -> Patterns
disjoin = foldr1 (.||.)

infix 4 ?===
(?===) :: Patterns -> FilePath -> Bool
DNF cls ?=== fp = any (`clMatch` fp) cls

infix 1 %%>

(%%>) :: Patterns -> (FilePath -> Action ()) -> Rules ()
pats %%> act = (pats ?===) ?> act

data Routing = Convert Patterns (FilePath -> FilePath)
             | Copy Patterns
             | Cached Patterns (FilePath -> FilePath)
             | Create FilePath
             deriving (Generic)

generatePageInfo :: SakeConf -> Patterns -> FilePath -> (FilePath -> FilePath) -> Action [(FilePath, PageInfo)]
generatePageInfo SakeConf{..} pats toD f = do
  chs <- filter (not . ignoreFile) <$> globDirectoryFiles sourceDir pats
  forM chs $ \fp -> do
    let path = toD </> f fp
    return (path, PageInfo $ Just $ sourceDir </> fp)

globDirectoryFiles :: FilePath -> Patterns -> Action [FilePath]
globDirectoryFiles dir (DNF cs) = fmap concat $ forM cs $ \(Clause ps ns) ->
  filter (\fp -> all (not . (?== fp)) ns) <$> getDirectoryFiles dir (HS.toList ps)

newtype PageInfo = PageInfo { sourcePath :: Maybe FilePath }
                 deriving (Read, Show, Eq, Ord, Generic)
                 deriving anyclass (Store)

newtype ContentsIndex =
  ContentsIndex { runContentsInfo :: HashMap FilePath PageInfo }
  deriving (Read, Show, Eq, Generic)
  deriving anyclass (Store)

pageListName :: FilePath
pageListName = "pages.bin"

stripDirectory :: FilePath -> FilePath -> Maybe FilePath
stripDirectory parent target
  | parent `L.isPrefixOf` target = Just $ makeRelative parent target
  | otherwise = Nothing

-- | Creating routing and cleaning rules.
withRouteRules :: SakeConf -> [Routing] -> Rules () -> Rules ()
withRouteRules sakeConf@SakeConf{..} rconfs rules = alternatives $ do
  "site" ~> do
    liftIO $ do
      createDirectoryIfMissing True destinationDir
      createDirectoryIfMissing True sourceDir
      createDirectoryIfMissing True snapshotDir
    ContentsIndex dic0 <- readFromBinaryFile' (cacheDir </> pageListName)
    need $ map fst $ HM.toList dic0

  cacheDir </> pageListName %> \out -> do
    dic0 <- fmap (concat . reverse) $ forM rconfs $ \case
      Convert pats f -> generatePageInfo sakeConf pats destinationDir f
      Copy pats -> generatePageInfo sakeConf pats destinationDir id
      Cached pats f -> generatePageInfo sakeConf pats cacheDir f
      Create fp -> return [(destinationDir </> fp, PageInfo Nothing)]
    writeBinaryFile out $ ContentsIndex $ HM.fromList dic0

  snapshotDir </> "*" <//> "*" %> \out -> do
    let Just [_, rest, fname] = filePattern (snapshotDir </> "*" <//> "*") out
        orig = destinationDir </> rest </> fname
    need [orig]

  "clean" ~> do
    removeFilesAfter destinationDir ["//*"]
    removeFilesAfter cacheDir ["//*"]
    removeFilesAfter snapshotDir ["//*"]

  rules

  let copyPats = disjoin $
                 foldMap (\case {Copy pat -> [pat]; Create fp -> [fromString fp]; _ -> []}) rconfs

  (\fp -> not (ignoreFile fp) &&
          maybe False (copyPats ?===) (stripDirectory destinationDir fp)) ?> \out -> do
    let orig = replaceDir destinationDir sourceDir out
    putNormal $ "Falling back to copy rule: " ++ out ++ "; copied from: " ++ orig
    copyFile' orig out

loadAllItemsAfter :: FilePath -> Patterns -> Action [Item Text]
loadAllItemsAfter fp pats =
  mapM (loadItem . (fp </>)) =<< globDirectoryFiles fp pats

instance Store Scientific where
  size = contramap Bin.encode size
  peek = Bin.decode <$> peek
  poke = poke . Bin.encode

deriving instance Store Value

data Snapshotted a = Snapshotted { snapBody       :: a
                                 , snapIdentifier :: FilePath
                                 , snapTarget     :: FilePath
                                 , snapMetadata   :: Metadata
                                 }
                      deriving (Read, Show, Eq, Generic, Store)

snapToItem :: Snapshotted a -> Item a
snapToItem
  Snapshotted { snapBody = itemBody
              , snapIdentifier = (Identifier -> itemIdentifier)
              , snapTarget = itemTarget
              , snapMetadata = itemMetadata
              } = Item{..}

itemToSnap :: Item a -> Snapshotted a
itemToSnap
  Item{ itemBody = snapBody
      , itemIdentifier = Identifier snapIdentifier
      , itemTarget = snapTarget
      , itemMetadata = snapMetadata
      } = Snapshotted{..}

type SnapshotName = String


saveSnapshot :: (Store a) => SakeConf -> SnapshotName -> Item a -> Action (Item a)
saveSnapshot SakeConf{..} name i@Item{..} = do
  writeBinaryFile (replaceDir destinationDir (snapshotDir </> name) itemTarget) $
    itemToSnap i
  return i

loadSnapshot :: (Store a) => SakeConf -> SnapshotName -> FilePath -> Action (Item a)
loadSnapshot cnf name pat =
  head <$> loadAllSnapshots cnf (fromString name) { snapshotTarget = fromString pat }

loadAllSnapshots :: (Store a) => SakeConf -> Snapshot -> Action [Item a]
loadAllSnapshots SakeConf{..} sn@Snapshot{..} = do
  ContentsIndex dic <- readFromBinaryFile' (cacheDir </> pageListName)
  let targs = [ fp
              | (fp, pinfo) <- HM.toList dic
              , maybe False (snapshotTarget ?===) $
                stripDirectory destinationDir fp
              , maybe False (snapshotSource ?===) $
                stripDirectory sourceDir =<< sourcePath pinfo
              ]
  forM targs $ \fp ->
    snapToItem <$> readFromBinaryFile' (replaceDir destinationDir (snapshotDir </> snapshotName) fp)

hasSnapshot :: SakeConf -> SnapshotName -> Item a -> Action Bool
hasSnapshot SakeConf{..} snap i =
  doesFileExist $ replaceDir sourceDir (snapshotDir </> snap) (itemTarget i)

replaceDir :: FilePath -> FilePath -> FilePath -> FilePath
replaceDir from to pth = to </> makeRelative from pth

loadOriginal :: Readable a => SakeConf -> FilePath -> Action (Item a)
loadOriginal cnf fp = do
  i <- loadItem =<< getSourcePath cnf fp
  return i { itemTarget = fp }

getSourcePath :: SakeConf -> FilePath -> Action FilePath
getSourcePath SakeConf{..} fp = do
  ContentsIndex dic <- readFromBinaryFile' (cacheDir </> pageListName)
  case HM.lookup fp dic of
    Just PageInfo{ sourcePath = Just pth } -> return pth
    _           -> error $ "No Source Path found: " ++ fp

writeItem :: SakeConf -> Item Text -> Action ()
writeItem c@SakeConf{..} i@Item{itemTarget} =
  writeToFile itemTarget . itemBody =<< saveSnapshot c "_final" i

ifChanged :: (FilePath -> a -> Action ()) -> FilePath -> a -> Action ()
ifChanged write fp bdy = do
  exist <- doesFileExist fp
  if not exist
    then write fp bdy
    else withTempFile $ \tmp -> do
    write tmp bdy
    b <- liftIO $ withFile tmp ReadMode $ \htmp -> withFile fp ReadMode $ \h -> do
      stmp <- BS.hGetContents htmp
      src <- BS.hGetContents h
      return (hash src /= hash stmp)
    when b $ write fp bdy

loadContentsIndex :: SakeConf -> Action ContentsIndex
loadContentsIndex SakeConf{..} = readFromBinaryFile' (cacheDir </> pageListName)

infixr 5 </?>
(</?>) :: FilePath -> Patterns -> Patterns
dir </?> DNF cls = fromString (dir ++ "//*") .&&. DNF (map go cls)
  where
    go (Clause ps ns) = Clause (HS.map (dir </>) ps) (HS.map (dir </>) ns)