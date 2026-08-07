{-# LANGUAGE OverloadedStrings #-}

{- | The Gate-F de-nix scrub — the @finalize.py@ semantics, absorbed.

Three invariants over every regular file, all enforced length-preservingly
(byte-for-byte same size, so ELF section offsets and ar member indices stay
valid):

  1. no @\/nix\/store@ literal — @\/nix\/store\/\<hash\>-@ becomes
     @\/@ + 42 zeros + @-@ (same 44 bytes);
  2. no closure store HASH — each 32-char hash from the build closure gets its
     first byte replaced by @e@ (outside nix's base32 alphabet: inert, same
     length, distinct hashes stay distinct);
  3. no volatile per-build dir — digit runs in @builds\/nix-\<pid\>-\<rand\>@
     are zeroed in place.
-}
module Modern.Scrub (
  scrubBytes,
  scrubTree,
  verifyClean,
  loadClosureHashes,
) where

import Control.Monad (filterM, forM, forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isDigit)
import Data.Maybe (mapMaybe)
import System.Directory (doesFileExist, listDirectory, pathIsSymbolicLink)
import System.FilePath ((</>))
import System.Posix.Files (fileMode, getFileStatus, isDirectory, isRegularFile, getSymbolicLinkStatus, setFileMode, unionFileModes, ownerWriteMode)

storeLit :: ByteString
storeLit = "/nix/store/"

-- Matches finalize.py's @[0-9a-z]{32}@ exactly (NOT the stricter nix base32
-- alphabet): byte-compatibility with the absorbed scrubber is the contract.
storeHashChar :: Char -> Bool
storeHashChar c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z')

-- | The set of 32-char store hashes named by a nix closure store-paths file.
loadClosureHashes :: FilePath -> IO [ByteString]
loadClosureHashes fp = do
  ls <- BC.lines <$> BS.readFile fp
  pure $ mapMaybe stem ls
 where
  stem line =
    let base = snd (BC.breakEnd (== '/') line)
        h = BC.takeWhile (/= '-') base
     in if BS.length h == 32 then Just h else Nothing

-- | Apply all three scrubs. Total and length-preserving by construction.
scrubBytes :: [ByteString] -> ByteString -> ByteString
scrubBytes hashes = scrubBuildDirs . scrubHashes hashes . scrubStoreLiterals

scrubStoreLiterals :: ByteString -> ByteString
scrubStoreLiterals = go
 where
  zeros = "/" <> BC.replicate 42 '0' <> "-"
  go bs = case BS.breakSubstring storeLit bs of
    (pre, rest)
      | BS.null rest -> pre
      | otherwise ->
          let afterLit = BS.drop (BS.length storeLit) rest
              (h, tl) = BS.splitAt 32 afterLit
           in if BS.length h == 32 && BC.all storeHashChar h && BC.take 1 tl == "-"
                then pre <> zeros <> go (BS.drop 1 tl)
                else pre <> storeLit <> go afterLit

scrubHashes :: [ByteString] -> ByteString -> ByteString
scrubHashes hashes bs0 = foldl scrubOne bs0 hashes
 where
  scrubOne bs h = go bs
   where
    placeholder = "e" <> BS.drop 1 h
    go b = case BS.breakSubstring h b of
      (pre, rest)
        | BS.null rest -> pre
        | otherwise -> pre <> placeholder <> go (BS.drop (BS.length h) rest)

scrubBuildDirs :: ByteString -> ByteString
scrubBuildDirs = go
 where
  marker = "builds/nix-" :: ByteString
  go bs = case BS.breakSubstring marker bs of
    (pre, rest)
      | BS.null rest -> pre
      | otherwise ->
          let after = BS.drop (BS.length marker) rest
              (d1, r1) = BC.span isDigit after
              matched =
                not (BS.null d1) && BC.take 1 r1 == "-" &&
                not (BS.null (fst (BC.span isDigit (BS.drop 1 r1))))
           in if matched
                then
                  let (d2, r2) = BC.span isDigit (BS.drop 1 r1)
                   in pre <> marker <> BC.replicate (BS.length d1) '0' <> "-"
                        <> BC.replicate (BS.length d2) '0' <> go r2
                else pre <> marker <> go after

-- | Scrub every regular file under a tree in place.
scrubTree :: [ByteString] -> FilePath -> IO ()
scrubTree hashes root = walk root
 where
  walk dir = do
    names <- listDirectory dir
    forM_ names $ \n -> do
      let p = dir </> n
      st <- getSymbolicLinkStatus p
      if isDirectory st
        then walk p
        else
          if isRegularFile st
            then do
              old <- BS.readFile p
              let new = scrubBytes hashes old
              if new /= old
                then do
                  if BS.length new /= BS.length old
                    then error ("non-length-preserving scrub: " <> p)
                    else do
                      fst' <- getFileStatus p
                      setFileMode p (fileMode fst' `unionFileModes` ownerWriteMode)
                      BS.writeFile p new
                else pure ()
            else pure ()

-- | Post-scrub verification: paths (relative) that still violate Hole F.
verifyClean :: [ByteString] -> FilePath -> IO [(FilePath, String)]
verifyClean hashes root = walk ""
 where
  walk rel = do
    let dir = if null rel then root else root </> rel
    names <- listDirectory dir
    fmap concat . forM names $ \n -> do
      let relPath = if null rel then n else rel </> n
          p = root </> relPath
      isLink <- pathIsSymbolicLink p
      if isLink
        then pure []
        else do
          st <- getSymbolicLinkStatus p
          if isDirectory st
            then walk relPath
            else
              if isRegularFile st
                then do
                  exists <- doesFileExist p
                  if not exists
                    then pure []
                    else do
                      bytes <- BS.readFile p
                      let storeBad = [(relPath, "/nix/store literal") | "/nix/store" `BS.isInfixOf` bytes]
                      hashBad <- filterM (\h -> pure (h `BS.isInfixOf` bytes)) hashes
                      pure (storeBad ++ [(relPath, "store hash " <> BC.unpack h) | h <- take 1 hashBad])
                else pure []
