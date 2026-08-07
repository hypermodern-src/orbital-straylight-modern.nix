{-# LANGUAGE OverloadedStrings #-}

{- | The gate: run the ELF suite's @elf-verify@ over a projected tree and
surface violations as TYPED errors naming the offending file — a poisoned
manifest (a smuggled store ref, a wrapper script under bin\/) fails here,
before anything downstream sees the tree.
-}
module Modern.Gate (
  GateViolation (..),
  runGate,
  renderViolation,
) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.List (stripPrefix)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Modern.Manifest (Gate (..))
import System.Exit (ExitCode (..))
import System.Process (proc, readCreateProcessWithExitCode)

-- | One violated invariant at one file — the typed error the task demands.
data GateViolation = GateViolation
  { gvFile :: FilePath
  , gvReason :: Text
  }
  deriving (Eq, Show)

instance ToJSON GateViolation where
  toJSON (GateViolation f r) =
    object ["error" .= ("gate-violation" :: Text), "file" .= f, "reason" .= r]

renderViolation :: GateViolation -> String
renderViolation (GateViolation f r) = "gate violation: " <> f <> ": " <> T.unpack r

-- | Run @elf-verify@ (from the suite at @suiteBin@) with the manifest's gate
-- policy over @tree@. Right () = clean; Left = the typed violations.
runGate :: FilePath -> Gate -> FilePath -> IO (Either [GateViolation] ())
runGate suiteBin g tree = do
  let args =
        ["--policy=" <> T.unpack (gPolicy g)]
          ++ concatMap (\a -> ["--allow", a]) (gAllow g)
          ++ concatMap (\i -> ["--ignore", i]) (gIgnore g)
          ++ ["--needed-closure" | gNeededClosure g]
          ++ [tree]
  (code, out, err) <- readCreateProcessWithExitCode (proc (suiteBin <> "/bin/elf-verify") args) ""
  case code of
    ExitSuccess -> pure (Right ())
    ExitFailure _ ->
      let vs = mapMaybe parseLine (lines out)
       in pure . Left $
            if null vs
              then [GateViolation tree (T.pack ("elf-verify failed: " <> err))]
              else vs
 where
  parseLine l = do
    rest <- stripPrefix "VIOLATION " l
    let (file, reason) = break (== ':') rest
    pure (GateViolation file (T.pack (drop 2 reason)))
