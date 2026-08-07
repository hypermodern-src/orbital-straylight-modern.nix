{-# LANGUAGE OverloadedStrings #-}

-- | The @modern@ CLI. @modern project MANIFEST --out DIR [--elf-suite PATH]@
-- interprets a projection manifest into a §12 tree and enforces its gate.
-- The suite location falls back to the @MODERN_ELF_SUITE@ environment
-- variable (the nix package bakes it).
module Main (main) where

import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as BL
import Modern.Gate (renderViolation)
import Modern.Manifest (loadManifest)
import Modern.Project (ProjectError (..), runProject)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure, exitWith, ExitCode (..))
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ("project" : rest) -> project rest
    _ -> usage

usage :: IO ()
usage = do
  hPutStrLn stderr "usage: modern project MANIFEST --out DIR [--elf-suite PATH]"
  exitWith (ExitFailure 2)

project :: [String] -> IO ()
project rest = do
  (manifestPath, outDir, suiteFlag) <- parse rest (Nothing, Nothing, Nothing)
  suiteEnv <- lookupEnv "MODERN_ELF_SUITE"
  suite <- case maybe suiteEnv Just suiteFlag of
    Just s -> pure s
    Nothing -> hPutStrLn stderr "modern: no --elf-suite and MODERN_ELF_SUITE unset" >> exitFailure >> pure ""
  em <- loadManifest manifestPath
  case em of
    Left err -> do
      hPutStrLn stderr ("modern: manifest parse error: " <> err)
      exitWith (ExitFailure 2)
    Right m -> do
      r <- runProject suite m outDir
      case r of
        Right () -> putStrLn ("modern: projected " <> outDir)
        Left (GateFailed vs) -> do
          mapM_ (hPutStrLn stderr . renderViolation) vs
          mapM_ (BL.hPutStrLn stderr . encode) vs
          hPutStrLn stderr "modern: gate FAILED"
          exitFailure
        Left e -> do
          hPutStrLn stderr ("modern: " <> show e)
          exitFailure
 where
  parse [] (Just mf, Just o, s) = pure (mf, o, s)
  parse [] _ = usage >> undefined
  parse ("--out" : v : xs) (mf, _, s) = parse xs (mf, Just v, s)
  parse ("--elf-suite" : v : xs) (mf, o, _) = parse xs (mf, o, Just v)
  parse (x : xs) (Nothing, o, s) | take 2 x /= "--" = parse xs (Just x, o, s)
  parse (x : _) _ = hPutStrLn stderr ("modern: bad arg " <> x) >> usage >> undefined
