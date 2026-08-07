{-# LANGUAGE OverloadedStrings #-}

{- | @modern project@ — the manifest interpreter: manifest in, §12 tree out.

Absorbs the semantics of the ad-hoc projection stratum (mkSelfContained's
runCommand fixups, floorProjectCell, the cudaMin\/pythonMin prunes, the
de-shell symlinks, the settings repoints, the Gate-F scrub) as a typed
program over Shelly. No operation is spliced into a shell string; external
tools (cp for the symlink-and-mode-faithful bulk copy, the manifest's own
strip) are invoked argv-typed.
-}
module Modern.Project (
  ProjectError (..),
  runProject,
) where

import Control.Exception (IOException, catch)
import Control.Monad (forM_, when)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Modern.Gate (GateViolation, runGate)
import Modern.Manifest
import Modern.Scrub (loadClosureHashes, scrubTree, verifyClean)
import Shelly (errExit, lastExitCode, run_, shelly, silently)
import System.Directory (
  createDirectoryIfMissing,
  doesDirectoryExist,
  doesFileExist,
  listDirectory,
  pathIsSymbolicLink,
  removePathForcibly,
 )
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files (createSymbolicLink, getSymbolicLinkStatus)

data ProjectError
  = UnknownSource Text
  | MissingPath FilePath
  | GateFailed [GateViolation]
  | ScrubResidue [(FilePath, String)]
  | ToolFailed String
  deriving (Show)

-- | Interpret a manifest into @out@. The suite path powers the gate.
runProject :: FilePath -> Manifest -> FilePath -> IO (Either ProjectError ())
runProject suite m out = do
  createDirectoryIfMissing True out
  r <- steps (mOps m)
  case r of
    Left e -> pure (Left e)
    Right () -> case mGate m of
      Nothing -> pure (Right ())
      Just g -> do
        gr <- runGate suite g out
        pure $ case gr of
          Left vs -> Left (GateFailed vs)
          Right () -> Right ()
 where
  steps [] = pure (Right ())
  steps (o : os) = do
    r <- step o
    case r of
      Left e -> pure (Left e)
      Right () -> steps os

  source name = maybe (Left (UnknownSource name)) Right (Map.lookup name (mSources m))

  -- cp -r: preserves symlinks-as-links and exec bits, and deliberately
  -- SPLITS hardlinks — a REAPI Directory has no hardlink concept, each path
  -- is an independent blob, so the copy fidelity must match the digest's
  -- view (cp -a's --preserve=links would alias later per-path surgery
  -- across inodes: stripping bin/llvm-objcopy must not strip bin/llvm-strip).
  cpA src dst = shelly . silently $ run_ "cp" ["-r", T.pack src, T.pack dst]
  makeWritable p = shelly . silently $ run_ "chmod" ["-R", "u+w", T.pack p]

  step (OpCopy from to) = case source from of
    Left e -> pure (Left e)
    Right src -> do
      let dst = out </> to
      createDirectoryIfMissing True dst
      cpA (src </> ".") dst
      makeWritable dst
      pure (Right ())
  step (OpCopyPath from path to opt) = case source from of
    Left e -> pure (Left e)
    Right src -> do
      let sp = src </> path
      exists <- pathOrLinkExists sp
      if not exists
        then pure (if opt then Right () else Left (MissingPath sp))
        else do
          let dst = out </> to
          createDirectoryIfMissing True dst
          cpA sp dst
          makeWritable dst
          pure (Right ())
  step (OpRemove globs) = do
    entries <- walkRel out
    forM_ entries $ \rel ->
      when (any (`matchGlob` rel) globs) $
        removePathForcibly (out </> rel)
    pure (Right ())
  step (OpStrip tool paths opt) = go paths
   where
    go [] = pure (Right ())
    go (p : ps) = do
      r <- stripOne tool opt p
      case r of
        Left e -> pure (Left e)
        Right () -> go ps
  step (OpSymlink at target ifMissing) = do
    let p = out </> at
    present <- pathOrLinkExists p
    if present && ifMissing
      then pure (Right ())
      else do
        when present (removePathForcibly p)
        createDirectoryIfMissing True (takeDirectory p)
        createSymbolicLink target p
        pure (Right ())
  step (OpRewrite file rws) = do
    let p = out </> file
    ok <- doesFileExist p
    if not ok
      then pure (Left (MissingPath p))
      else do
        old <- BS.readFile p
        let new =
              foldl
                (\b (Rewrite f t) -> replaceAll (TE.encodeUtf8 f) (TE.encodeUtf8 t) b)
                old
                rws
        BS.writeFile p new
        pure (Right ())
  step (OpScrub closure) = do
    hashes <- maybe (pure []) loadClosureHashes closure
    scrubTree hashes out
    residue <- verifyClean hashes out
    pure (if null residue then Right () else Left (ScrubResidue residue))
  step (OpMkdir d) = do
    createDirectoryIfMissing True (out </> d)
    pure (Right ())

  stripOne tool opt rel = do
    let p = out </> rel
    ok <- doesFileExist p
    isLink <- if ok then pathIsSymbolicLink p else pure False
    isElf <-
      if ok && not isLink
        then (\b -> BS.take 4 b == BS.pack [0x7f, 0x45, 0x4c, 0x46]) <$> BS.readFile p
        else pure False
    if not (ok && not isLink && isElf)
      then pure (if opt then Right () else Left (MissingPath p))
      else do
        code <- shelly . silently . errExit False $ do
          run_ "chmod" ["u+w", T.pack p]
          run_ tool ["--strip-all", T.pack p]
          lastExitCode
        pure $
          if code == 0 || opt
            then Right ()
            else Left (ToolFailed (tool <> " --strip-all " <> p <> " exited " <> show code))

pathOrLinkExists :: FilePath -> IO Bool
pathOrLinkExists p =
  (getSymbolicLinkStatus p >> pure True) `catch` \(_ :: IOException) -> pure False

walkRel :: FilePath -> IO [FilePath]
walkRel root = go ""
 where
  go rel = do
    let dir = if null rel then root else root </> rel
    isLink <- if null rel then pure False else pathIsSymbolicLink dir
    isDir <- if isLink then pure False else doesDirectoryExist dir
    if not isDir
      then pure [rel | not (null rel)]
      else do
        names <- listDirectory dir
        subs <- mapM (\n -> go (if null rel then n else rel </> n)) names
        pure ([rel | not (null rel)] ++ concat subs)

-- naive but total: replace every occurrence, left to right
replaceAll :: BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString
replaceAll from to = go
 where
  go b
    | BS.null from = b
    | otherwise = case BS.breakSubstring from b of
        (pre, rest)
          | BS.null rest -> pre
          | otherwise -> pre <> to <> go (BS.drop (BS.length from) rest)

-- glob with '*' crossing '/'
matchGlob :: String -> FilePath -> Bool
matchGlob ('*' : ps) xs = any (matchGlob ps) (tails' xs)
 where
  tails' s = s : case s of [] -> []; (_ : r) -> tails' r
matchGlob (p : ps) (x : xs) = p == x && matchGlob ps xs
matchGlob [] [] = True
matchGlob _ _ = False
