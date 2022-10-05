-- (c) Alex McLean, Aravind Mohandas and contributors 2022
-- Shared under the terms of the GNU Public License v3.0

module Sound.Tidal.Pattern where

import Data.Ratio

import qualified Data.Map.Strict as Map

import Sound.Tidal.Types

class (Functor p, Applicative p, Monad p) => Pattern p where
  toSignal :: p a -> Signal a
  slowcat :: [p a] -> p a
  fastcat :: [p a] -> p a
  fastcat pats = _fast (toRational $ length pats) $ slowcat pats
  _fast :: Rational -> p a -> p a
  silence :: p a
  atom :: a -> p a
  stack :: [p a] -> p a
  _patternify :: (a -> p b -> p c) -> (p a -> p b -> p c)
  _patternify2 :: (a -> b -> p c -> p d) -> (p a -> p b -> p c -> p d)
  _patternify3 :: (a -> b -> c -> p d -> p e) -> (p a -> p b -> p c -> p d -> p e)
  rev :: p a -> p a
  _ply :: Rational -> p a-> p a
  euclid :: p Int -> p Int -> p a -> p a
  _euclid :: Int -> Int -> p a -> p a
  timeCat :: [(Rational, p a)] -> p a
  _run :: (Enum a, Num a) => a -> p a
  _scan :: (Enum a, Num a) => a -> p a
  -- every :: p Int -> (p b -> p b) -> p b -> p b
  when :: p Bool -> (p b -> p b) -> p b -> p b
  -- listToPat :: [a] -> p a
  iter :: p Int -> p a -> p a
  iter' :: p Int -> p a -> p a
  _iter :: Int -> p a -> p a
  _iter' :: Int -> p a -> p a
  collect :: Eq a => p a -> p [a]
  uncollect :: p [a] -> p a

overlay :: Pattern p => p x -> p x -> p x
overlay a b = stack [a, b]

superimpose :: Pattern p => (p x -> p x) -> p x -> p x
superimpose p pat = overlay pat (p pat)

_slow :: Pattern p => Rational -> p x -> p x
_slow t = _fast (1/t)

slow :: Pattern p => p Rational -> p x -> p x
slow = _patternify _slow

-- | An alias for @slow@
sparsity :: Pattern p => p Rational -> p x -> p x
sparsity = slow

fast :: Pattern p => p Rational -> p x -> p x
fast = _patternify _fast

-- | An alias for @fast@
density :: Pattern p => p Rational -> p x -> p x
density = fast

-- | An alias for @fastCat@
fastCat :: Pattern p => [p a] -> p a
fastCat = fastcat

fastAppend :: Pattern p => p x -> p x -> p x
fastAppend a b = fastcat [a,b]

slowAppend :: Pattern p => p x -> p x -> p x
slowAppend a b = slowcat [a,b]

append :: Pattern p => p x -> p x -> p x
append = slowAppend

-- | Converts from a range from 0 to 1, to a range from -1 to 1
toBipolar :: (Pattern p, Fractional x) => p x -> p x
toBipolar pat = fmap (\v -> (v*2)-1) pat

-- | Converts from a range from -1 to 1, to a range from 0 to 1
fromBipolar :: (Pattern p, Fractional x) => p x -> p x
fromBipolar pat = fmap (\v -> (v+1)/2) pat

-- | Turns a list of values into a pattern
fromList :: Pattern t => [a] -> t a
fromList = slowcat . map pure

-- | Turns a list of values into a pattern
fastFromList :: Pattern t => [a] -> t a
fastFromList = fastcat . map pure

-- | 'fromMaybes; is similar to 'fromList', but allows values to
-- be optional using the 'Maybe' type, so that 'Nothing' results in
-- gaps in the pattern.
fromMaybes :: Pattern t => [Maybe a] -> t a
fromMaybes = fastcat . map f
  where f Nothing = silence
        f (Just x) = pure x

run :: (Pattern t, Enum a, Num a) => t a -> t a
run = (>>= _run)

scan :: (Pattern t, Enum a, Num a) => t a -> t a
scan = (>>= _run)

_firstOf :: Pattern t => Int -> (t a -> t a) -> t a -> t a
_firstOf n f pat | n <= 0 = silence
                 | otherwise = when (fromList
                                     (True : (replicate (n - 1) False))
                                    ) f pat

_lastOf :: Pattern t => Int -> (t a -> t a) -> t a -> t a
_lastOf n f pat | n <= 0 = silence
                | otherwise = when (fromList
                                    ((replicate (n - 1) False) ++ [True])
                                   ) f pat

_every :: Pattern t => Int -> (t a -> t a) -> t a -> t a
_every = _lastOf

{- | `range` will take a pattern which goes from 0 to 1 (like `sine`), and range it to a different range - between the first and second arguments. In the below example, `range 1 1.5` shifts the range of `sine1` from 0 - 1 to 1 - 1.5.

@
d1 $ jux (iter 4) $ sound "arpy arpy:2*2"
  |+ speed (slow 4 $ range 1 1.5 sine1)
@
-}
range :: (Pattern t, Num a) => t a -> t a -> t a -> t a
range = _patternify2 _range

_range :: (Functor f, Num b) => b -> b -> f b -> f b
_range from to p = (+ from) . (* (to-from)) <$> p

-- ************************************************************ --



