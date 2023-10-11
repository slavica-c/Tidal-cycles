{-# LANGUAGE OverloadedStrings, CPP #-}

module Sound.Tidal.ExceptionsTest where

import Test.Microspec
import Control.Exception
import Control.DeepSeq
import Data.Typeable ()
import Prelude hiding ((<*), (*>))

import Sound.Tidal.Types

run :: Microspec ()
run =
  describe "NFData, forcing and catching exceptions" $ do
    describe "instance NFData (Pattern a)" $ do
      it "rnf forces argument" $ do
        evaluate (rnf (Signal undefined :: Signal ()))
          `shouldThrow` anyException


-- copied from http://hackage.haskell.org/package/hspec-expectations-0.8.2/docs/src/Test-Hspec-Expectations.html#shouldThrow

shouldThrow :: (Exception e) => IO a -> Selector e -> Microspec ()
action `shouldThrow` p = prop "shouldThrow" $ monadicIO $ do
  r <- Test.Microspec.run $ try action
  case r of
    Right _ ->
      -- "finished normally, but should throw exception: " ++ exceptionType
      Test.Microspec.assert False
    Left e ->
      -- "threw exception that did not meet expectation")
      Test.Microspec.assert $ p e
  where
    -- a string repsentation of the expected exception's type
    {-
    exceptionType = (show . typeOf . instanceOf) p
      where
        instanceOf :: Selector a -> a
        instanceOf _ = error "Test.Hspec.Expectations.shouldThrow: broken Typeable instance"
    -}

-- |
-- A @Selector@ is a predicate; it can simultaneously constrain the type and
-- value of an exception.

type Selector a = (a -> Bool)

anyException :: Selector SomeException
anyException = const True

anyErrorCall :: Selector ErrorCall
anyErrorCall = const True

errorCall :: String -> Selector ErrorCall
#if MIN_VERSION_base(4,9,0)
errorCall s (ErrorCallWithLocation msg _) = s == msg
#else
errorCall s (ErrorCall msg) = s == msg
#endif

anyIOException :: Selector IOException
anyIOException = const True

anyArithException :: Selector ArithException
anyArithException = const True
