{-# LANGUAGE OverloadedStrings #-}

-- | The mkTypedDerivation demo builder: a Shelly program whose inputs arrive
-- as typed JSON (argv[1]) and whose output root is argv[2]. It stages a tiny
-- cell (bin/ + share/) from its arguments and then gates itself with
-- elf-verify — the whole §12 producer shape, with zero string-spliced bash.
module Main (main) where

import Data.Aeson (FromJSON (..), eitherDecodeFileStrict', withObject, (.:))
import Data.Text (Text)
import Data.Text qualified as T
import Shelly
import System.Environment (getArgs)

data Args = Args
  { aBinary :: FilePath -- a static binary to install at bin/hello
  , aElfSuite :: FilePath -- the ELF suite (the gate)
  , aMotd :: Text -- some data content
  }

instance FromJSON Args where
  parseJSON = withObject "Args" $ \o ->
    Args <$> o .: "binary" <*> o .: "elfSuite" <*> o .: "motd"

main :: IO ()
main = do
  [argsFile, out] <- getArgs
  ea <- eitherDecodeFileStrict' argsFile
  args <- either (errorWithoutStackTrace . ("bad args: " <>)) pure ea
  shelly $ do
    mkdir_p (out </> ("bin" :: FilePath))
    mkdir_p (out </> ("share" :: FilePath))
    cp (aBinary args) (out </> ("bin/hello" :: FilePath))
    run_ "chmod" ["u+w", T.pack (out <> "/bin/hello")]
    writefile (out </> ("share/motd" :: FilePath)) (aMotd args)
    -- the gate, argv-typed (no store-ref predicate here: the specimen is a
    -- plain nixpkgs-glibc static binary, not a de-nixed cell)
    run_
      (aElfSuite args </> ("bin/elf-verify" :: FilePath))
      ["--require-static", "--no-scripts-in-bin", "--check-symlinks", T.pack out]
