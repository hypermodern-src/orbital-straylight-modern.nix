{-# LANGUAGE OverloadedStrings #-}

{- | The projection manifest — the DECLARATIVE replacement for the ad-hoc
projection stratum (mkSelfContained fixups, floorProjectCell, cudaMin-style
prune scripts, de-shell runCommands).

A manifest names its sources, a sequence of typed operations over the output
tree, and the gate policy the finished tree must satisfy. @modern project@
interprets it; the ELF suite enforces the gate. Nothing here is spliced into
a shell string — every operation is data.
-}
module Modern.Manifest (
  Manifest (..),
  Op (..),
  Rewrite (..),
  Gate (..),
  loadManifest,
) where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Map.Strict (Map)
import Data.Text (Text)

data Manifest = Manifest
  { mName :: Text
  , mSources :: Map Text FilePath
  -- ^ symbolic source name -> tree path (store paths, injected by the caller)
  , mOps :: [Op]
  , mGate :: Maybe Gate
  }
  deriving (Show)

data Op
  = -- | copy a whole source tree into the output (symlinks preserved,
    -- exec bits preserved, hardlinks split) — @cp -r src\/. out\/to@;
    -- @deref@ resolves symlinks to content (@cp -rL@, the §4.2 projection)
    OpCopy {opFrom :: Text, opTo :: FilePath, opDeref :: Bool}
  | -- | copy ONE path (file, dir, or symlink) out of a source — the
    -- cudaMin\/pythonMin prune pattern, inverted: keep what you name.
    -- @rename@ (optional) gives the copied entry a new name at the
    -- destination (@cp src to\/rename@ instead of @cp src to\/@).
    OpCopyPath {opFrom :: Text, opPath :: FilePath, opTo :: FilePath, opOptional :: Bool, opDeref :: Bool, opRename :: Maybe FilePath}
  | -- | delete tree entries matching root-relative globs (@*@ crosses @\/@)
    OpRemove {opGlobs :: [String]}
  | -- | run @strip@ (a manifest-declared tool, not a dependency) over paths
    OpStrip {opTool :: FilePath, opPaths :: [FilePath], opOptional :: Bool}
  | -- | create\/replace a symlink at @at@ pointing to @target@; the de-shell
    -- primitive (wrapper scripts become symlinks at the real floor ELF)
    OpSymlink {opAt :: FilePath, opTarget :: FilePath, opIfMissing :: Bool}
  | -- | literal string rewrites in one text file (GHC settings repointing)
    OpRewrite {opFile :: FilePath, opRewrites :: [Rewrite]}
  | -- | the Gate-F de-nix scrub: kill @\/nix\/store@ literals, closure store
    -- hashes (from a closure file), and volatile build dirs — all
    -- length-preserving (ELF offsets survive)
    OpScrub {opClosure :: Maybe FilePath}
  | -- | ensure a directory exists
    OpMkdir {opDir :: FilePath}
  deriving (Show)

data Rewrite = Rewrite {rFrom :: Text, rTo :: Text}
  deriving (Show)

data Gate = Gate
  { gPolicy :: Text
  -- ^ \"static\" or \"floor\"
  , gAllow :: [String]
  , gIgnore :: [String]
  , gNeededClosure :: Bool
  }
  deriving (Show)

instance FromJSON Manifest where
  parseJSON = withObject "Manifest" $ \o ->
    Manifest
      <$> o .: "name"
      <*> o .: "sources"
      <*> o .: "ops"
      <*> o .:? "gate"

instance FromJSON Op where
  parseJSON = withObject "Op" $ \o -> do
    op <- o .: "op" :: Parser Text
    case op of
      "copy" -> OpCopy <$> o .: "from" <*> o .:? "to" .!= "." <*> o .:? "deref" .!= False
      "copyPath" ->
        OpCopyPath
          <$> o .: "from"
          <*> o .: "path"
          <*> o .:? "to" .!= "."
          <*> o .:? "optional" .!= False
          <*> o .:? "deref" .!= False
          <*> o .:? "rename"
      "remove" -> OpRemove <$> o .: "globs"
      "strip" ->
        OpStrip
          <$> o .: "tool"
          <*> o .: "paths"
          <*> o .:? "optional" .!= False
      "symlink" ->
        OpSymlink
          <$> o .: "at"
          <*> o .: "target"
          <*> o .:? "ifMissing" .!= False
      "rewrite" -> OpRewrite <$> o .: "file" <*> o .: "replace"
      "scrub" -> OpScrub <$> o .:? "closure"
      "mkdir" -> OpMkdir <$> o .: "dir"
      other -> fail ("unknown op: " <> show other)

instance FromJSON Rewrite where
  parseJSON = withObject "Rewrite" $ \o -> Rewrite <$> o .: "from" <*> o .: "to"

instance FromJSON Gate where
  parseJSON = withObject "Gate" $ \o ->
    Gate
      <$> o .: "policy"
      <*> o .:? "allow" .!= []
      <*> o .:? "ignore" .!= []
      <*> o .:? "neededClosure" .!= False

loadManifest :: FilePath -> IO (Either String Manifest)
loadManifest = eitherDecodeFileStrict'
