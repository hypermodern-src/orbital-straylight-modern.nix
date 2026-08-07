{-# LANGUAGE OverloadedStrings #-}

-- | Unit properties for the Gate-F scrub: every rewrite is length-preserving
-- and the three invariants hold on the output.
module Main (main) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Modern.Scrub (scrubBytes)
import System.Exit (exitFailure)

hashA, hashB :: ByteString
hashA = "aaaabbbbccccddddaaaabbbbccccdddd"
hashB = "11112222333344441111222233334444"

cases :: [(String, ByteString)]
cases =
  [ ("store literal", "prefix /nix/store/" <> hashA <> "-gcc-15.2.0/bin/gcc suffix")
  , ("bare closure hash", "crumb ./" <> hashA <> "- in dwarf")
  , ("two hashes", hashA <> " and " <> hashB)
  , ("volatile build dir", "path /nix/var/nix/builds/nix-12345-987654321/x")
  , ("all three", "/nix/store/" <> hashB <> "-x builds/nix-1-2 ./" <> hashA <> "-")
  , ("binary-ish", BS.pack [0 .. 255] <> "/nix/store/" <> hashA <> "-lib/libc.so" <> BS.pack [7, 0, 9])
  , ("no-op", "clean bytes, nothing to scrub")
  ]

main :: IO ()
main = do
  let hashes = [hashA, hashB]
      results = concatMap (check hashes) cases
  mapM_ putStrLn results
  if any (\r -> take 4 r == "FAIL") results then exitFailure else putStrLn "scrub properties hold"
 where
  check hashes (name, input) =
    let output = scrubBytes hashes input
        lenOk = BS.length output == BS.length input
        litOk = not ("/nix/store/" `BS.isInfixOf` output) || noHashAfterStore output
        hashOk = not (any (`BS.isInfixOf` output) hashes)
        idemOk = scrubBytes hashes output == output
     in [ (if lenOk then "ok: " else "FAIL: ") <> name <> " length-preserving"
        , (if litOk then "ok: " else "FAIL: ") <> name <> " store literal gone"
        , (if hashOk then "ok: " else "FAIL: ") <> name <> " closure hashes gone"
        , (if idemOk then "ok: " else "FAIL: ") <> name <> " idempotent"
        ]
  -- a surviving "/nix/store/" not followed by a store hash is inert prose;
  -- the invariant is that no HASHED store path survives
  noHashAfterStore b = case BS.breakSubstring "/nix/store/" b of
    (_, rest)
      | BS.null rest -> True
      | otherwise ->
          let h = BS.take 32 (BS.drop 11 rest)
           in not (BC.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z')) h && BS.length h == 32)
