
module Sound.Tidal.UI where

{-
    UI.hs - Tidal's main 'user interface' functions, for transforming
    patterns, building on the Core ones.
    Copyright (C) 2020, Alex McLean and contributors

    This library is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this library.  If not, see <http://www.gnu.org/licenses/>.
-}

import           Prelude hiding ((<*), (*>))

import           Data.Char (digitToInt, isDigit, ord)
import           Data.Bits (testBit, Bits, xor, shiftL, shiftR)

import           Data.Ratio ((%), Ratio)
import           Data.Fixed (mod')
import           Data.List (sort, sortOn, findIndices, elemIndex, groupBy, transpose, intercalate, findIndex)
import           Data.Maybe (isJust, fromJust, fromMaybe, mapMaybe)
import qualified Data.Text as T
import qualified Data.Map.Strict as Map
import           Data.Bool (bool)

import           Sound.Tidal.Bjorklund (bjorklund)
import           Sound.Tidal.Core
import qualified Sound.Tidal.Params as P
import           Sound.Tidal.Pattern
import           Sound.Tidal.Utils

------------------------------------------------------------------------
-- * UI


-- | Composing patterns

{- | The function @seqP@ allows you to define when
a sound within a list starts and ends. The code below contains three
separate patterns in a `stack`, but each has different start times
(zero cycles, eight cycles, and sixteen cycles, respectively). All
patterns stop after 128 cycles:

@
d1 $ seqP [
  (0, 128, sound "bd bd*2"),
  (8, 128, sound "hh*2 [sn cp] cp future*4"),
  (16, 128, sound (samples "arpy*8" (run 16)))
]
@
-}
seqP :: [(Time, Time, Pattern a)] -> Pattern a
seqP ps = stack $ map (\(s, e, p) -> playFor s e (sam s `rotR` p)) ps

-- | Degrades a pattern over the given time.
fadeOut :: Time -> Pattern a -> Pattern a
fadeOut dur p = innerJoin $ (`_degradeBy` p) <$> _slow dur envL

-- | Alternate version to @fadeOut@ where you can provide the time from which the fade starts
fadeOutFrom :: Time -> Time -> Pattern a -> Pattern a
fadeOutFrom from dur p = innerJoin $ (`_degradeBy` p) <$> (from `rotR` _slow dur envL)

-- | 'Undegrades' a pattern over the given time.
fadeIn :: Time -> Pattern a -> Pattern a
fadeIn dur p = innerJoin $ (`_degradeBy` p) <$> _slow dur envLR

-- | Alternate version to @fadeIn@ where you can provide the time from
-- which the fade in starts
fadeInFrom :: Time -> Time -> Pattern a -> Pattern a
fadeInFrom from dur p = innerJoin $ (`_degradeBy` p) <$> (from `rotR` _slow dur envLR)

{- | The 'spread' function allows you to take a pattern transformation
which takes a parameter, such as `slow`, and provide several
parameters which are switched between. In other words it 'spreads' a
function across several values.

Taking a simple high hat loop as an example:

@
d1 $ sound "ho ho:2 ho:3 hc"
@

We can slow it down by different amounts, such as by a half:

@
d1 $ slow 2 $ sound "ho ho:2 ho:3 hc"
@

Or by four thirds (i.e. speeding it up by a third; `4%3` means four over
three):

@
d1 $ slow (4%3) $ sound "ho ho:2 ho:3 hc"
@

But if we use `spread`, we can make a pattern which alternates between
the two speeds:

@
d1 $ spread slow [2,4%3] $ sound "ho ho:2 ho:3 hc"
@

Note that if you pass ($) as the function to spread values over, you
can put functions as the list of values. For example:

@
d1 $ spread ($) [density 2, rev, slow 2, striate 3, (# speed "0.8")]
    $ sound "[bd*2 [~ bd]] [sn future]*2 cp jvbass*4"
@

Above, the pattern will have these transforms applied to it, one at a time, per cycle:

* cycle 1: `density 2` - pattern will increase in speed
* cycle 2: `rev` - pattern will be reversed
* cycle 3: `slow 2` - pattern will decrease in speed
* cycle 4: `striate 3` - pattern will be granualized
* cycle 5: `(# speed "0.8")` - pattern samples will be played back more slowly

After `(# speed "0.8")`, the transforms will repeat and start at `density 2` again.
-}
spread :: (a -> t -> Pattern b) -> [a] -> t -> Pattern b
spread f xs p = slowcat $ map (`f` p) xs

slowspread :: (a -> t -> Pattern b) -> [a] -> t -> Pattern b
slowspread = spread

{- | @fastspread@ works the same as @spread@, but the result is squashed into a single cycle. If you gave four values to @spread@, then the result would seem to speed up by a factor of four. Compare these two:

d1 $ spread chop [4,64,32,16] $ sound "ho ho:2 ho:3 hc"

d1 $ fastspread chop [4,64,32,16] $ sound "ho ho:2 ho:3 hc"

There is also @slowspread@, which is an alias of @spread@.
-}
fastspread :: (a -> t -> Pattern b) -> [a] -> t -> Pattern b
fastspread f xs p = fastcat $ map (`f` p) xs

{- | There's a version of this function, `spread'` (pronounced "spread prime"), which takes a *pattern* of parameters, instead of a list:

@
d1 $ spread' slow "2 4%3" $ sound "ho ho:2 ho:3 hc"
@

This is quite a messy area of Tidal - due to a slight difference of
implementation this sounds completely different! One advantage of
using `spread'` though is that you can provide polyphonic parameters, e.g.:

@
d1 $ spread' slow "[2 4%3, 3]" $ sound "ho ho:2 ho:3 hc"
@
-}
spread' :: Monad m => (a -> b -> m c) -> m a -> b -> m c
spread' f vpat pat = vpat >>= \v -> f v pat

{- | `spreadChoose f xs p` is similar to `slowspread` but picks values from
`xs` at random, rather than cycling through them in order. It has a
shorter alias `spreadr`.
-}
spreadChoose :: (t -> t1 -> Pattern b) -> [t] -> t1 -> Pattern b
spreadChoose f vs p = do v <- _segment 1 (choose vs)
                         f v p

spreadr :: (t -> t1 -> Pattern b) -> [t] -> t1 -> Pattern b
spreadr = spreadChoose

{-| Decide whether to apply one or another function depending on the result of a test function that is passed the current cycle as a number.

@
d1 $ ifp ((== 0).(flip mod 2))
  (striate 4)
  (# coarse "24 48") $
  sound "hh hc"
@

This will apply `striate 4` for every _even_ cycle and aply `# coarse "24 48"` for every _odd_.

Detail: As you can see the test function is arbitrary and does not rely on anything tidal specific. In fact it uses only plain haskell functionality, that is: it calculates the modulo of 2 of the current cycle which is either 0 (for even cycles) or 1. It then compares this value against 0 and returns the result, which is either `True` or `False`. This is what the `ifp` signature's first part signifies `(Int -> Bool)`, a function that takes a whole number and returns either `True` or `False`.
-}
ifp :: (Int -> Bool) -> (Pattern a -> Pattern a) -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
ifp test f1 f2 p = splitQueries $ p {query = q}
  where q a | test (floor $ start $ arc a) = query (f1 p) a
            | otherwise = query (f2 p) a


{- | @whenmod@ has a similar form and behavior to `every`, but requires an
additional number. Applies the function to the pattern, when the
remainder of the current loop number divided by the first parameter,
is greater or equal than the second parameter.

For example the following makes every other block of four loops twice
as dense:

@
d1 $ whenmod 8 4 (density 2) (sound "bd sn kurt")
@
-}
whenmod :: Pattern Time -> Pattern Time -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
whenmod a b f pat = innerJoin $ (\a' b' -> _whenmod a' b' f pat) <$> a <*> b

_whenmod :: Time -> Time -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
_whenmod a b = whenT (\t -> ((t `mod'` a) >= b ))



{- |
Use `within` to apply a function to only a part of a pattern. For example, to
apply `density 2` to only the first half of a pattern:

@
d1 $ within (0, 0.5) (density 2) $ sound "bd*2 sn lt mt hh hh hh hh"
@

Or, to apply `(# speed "0.5") to only the last quarter of a pattern:

@
d1 $ within (0.75, 1) (# speed "0.5") $ sound "bd*2 sn lt mt hh hh hh hh"
@
-}
within :: (Time, Time) -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
within (s, e) f p = stack [filterWhen (\t -> cyclePos t >= s && cyclePos t < e) $ f p,
                           filterWhen (\t -> not $ cyclePos t >= s && cyclePos t < e) p
                          ]

withinArc :: Arc -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
withinArc (Arc s e) = within (s, e)

{- |
For many cases, @within'@ will function exactly as within.
The difference between the two occurs when applying functions that change the timing of notes such as 'fast' or '<~'.
within first applies the function to all notes in the cycle, then keeps the results in the specified interval, and then combines it with the old cycle (an "apply split combine" paradigm).
within' first keeps notes in the specified interval, then applies the function to these notes, and then combines it with the old cycle (a "split apply combine" paradigm).


For example, whereas using the standard version of within

@
d1 $ within (0, 0.25) (fast 2) $ sound "bd hh cp sd"
@

sounds like:

@
d1 $ sound "[bd hh] hh cp sd"
@

using this alternative version, within'

@
d1 $ within' (0, 0.25) (fast 2) $ sound "bd hh cp sd"
@

sounds like:

@
d1 $ sound "[bd bd] hh cp sd"
@

-}
within' :: (Time, Time) -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
within' a@(s, e) f p =
  stack [ filterWhen (\t -> cyclePos t >= s && cyclePos t < e) $ compress a $ f $ zoom a p
        , filterWhen (\t -> not $ cyclePos t >= s && cyclePos t < e) p
        ]

revArc :: (Time, Time) -> Pattern a -> Pattern a
revArc a = within a rev

index :: Real b => b -> Pattern b -> Pattern c -> Pattern c
index sz indexpat pat =
  spread' (zoom' $ toRational sz) (toRational . (*(1-sz)) <$> indexpat) pat
  where
    zoom' tSz s = zoomArc (Arc s (s+tSz))

{-
-- | @prrw f rot (blen, vlen) beatPattern valuePattern@: pattern rotate/replace.
prrw :: (a -> b -> c) -> Int -> (Time, Time) -> Pattern a -> Pattern b -> Pattern c
prrw f rot (blen, vlen) beatPattern valuePattern =
  let
    ecompare (_,e1,_) (_,e2,_) = compare (fst e1) (fst e2)
    beats  = sortBy ecompare $ arc beatPattern (0, blen)
    values = fmap thd' . sortBy ecompare $ arc valuePattern (0, vlen)
    cycles = blen * (fromIntegral $ lcm (length beats) (length values) `div` (length beats))
  in
    _slow cycles $ stack $ zipWith
    (\( _, (start, end), v') v -> (start `rotR`) $ densityGap (1 / (end - start)) $ pure (f v' v))
    (sortBy ecompare $ arc (_fast cycles $ beatPattern) (0, blen))
    (drop (rot `mod` length values) $ cycle values)

-- | @prr rot (blen, vlen) beatPattern valuePattern@: pattern rotate/replace.
prr :: Int -> (Time, Time) -> Pattern String -> Pattern b -> Pattern b
prr = prrw $ flip const

{-|
@preplace (blen, plen) beats values@ combines the timing of @beats@ with the values
of @values@. Other ways of saying this are:
* sequential convolution
* @values@ quantized to @beats@.

Examples:

@
d1 $ sound $ preplace (1,1) "x [~ x] x x" "bd sn"
d1 $ sound $ preplace (1,1) "x(3,8)" "bd sn"
d1 $ sound $ "x(3,8)" <~> "bd sn"
d1 $ sound "[jvbass jvbass:5]*3" |+| (shape $ "1 1 1 1 1" <~> "0.2 0.9")
@

It is assumed the pattern fits into a single cycle. This works well with
pattern literals, but not always with patterns defined elsewhere. In those cases
use @preplace@ and provide desired pattern lengths:
@
let p = slow 2 $ "x x x"

d1 $ sound $ preplace (2,1) p "bd sn"
@
-}
preplace :: (Time, Time) -> Pattern String -> Pattern b -> Pattern b
preplace = preplaceWith $ flip const

-- | @prep@ is an alias for preplace.
prep :: (Time, Time) -> Pattern String -> Pattern b -> Pattern b
prep = preplace

preplace1 :: Pattern String -> Pattern b -> Pattern b
preplace1 = preplace (1, 1)

preplaceWith :: (a -> b -> c) -> (Time, Time) -> Pattern a -> Pattern b -> Pattern c
preplaceWith f (blen, plen) = prrw f 0 (blen, plen)

prw :: (a -> b -> c) -> (Time, Time) -> Pattern a -> Pattern b -> Pattern c
prw = preplaceWith

preplaceWith1 :: (a -> b -> c) -> Pattern a -> Pattern b -> Pattern c
preplaceWith1 f = prrw f 0 (1, 1)

prw1 :: (a -> b -> c) -> Pattern a -> Pattern b -> Pattern c
prw1 = preplaceWith1

(<~>) :: Pattern String -> Pattern b -> Pattern b
(<~>) = preplace (1, 1)

-- | @protate len rot p@ rotates pattern @p@ by @rot@ beats to the left.
-- @len@: length of the pattern, in cycles.
-- Example: @d1 $ every 4 (protate 2 (-1)) $ slow 2 $ sound "bd hh hh hh"@
protate :: Time -> Int -> Pattern a -> Pattern a
protate len rot p = prrw (flip const) rot (len, len) p p

prot :: Time -> Int -> Pattern a -> Pattern a
prot = protate

prot1 :: Int -> Pattern a -> Pattern a
prot1 = protate 1

{-| The @<<~@ operator rotates a unit pattern to the left, similar to @<~@,
but by events rather than linear time. The timing of the pattern remains constant:

@
d1 $ (1 <<~) $ sound "bd ~ sn hh"
-- will become
d1 $ sound "sn ~ hh bd"
@ -}

(<<~) :: Int -> Pattern a -> Pattern a
(<<~) = protate 1

-- | @~>>@ is like @<<~@ but for shifting to the right.
(~>>) :: Int -> Pattern a -> Pattern a
(~>>) = (<<~) . (0-)

-- | @pequal cycles p1 p2@: quickly test if @p1@ and @p2@ are the same.
pequal :: Ord a => Time -> Pattern a -> Pattern a -> Bool
pequal cycles p1 p2 = (sort $ arc p1 (0, cycles)) == (sort $ arc p2 (0, cycles))
-}

-- | @discretise@: the old (deprecated) name for 'segment'
discretise :: Pattern Time -> Pattern a -> Pattern a
discretise = segment

-- @fromNote p@: converts a pattern of human-readable pitch names
-- into pitch numbers. For example, @"cs2"@ will be parsed as C Sharp
-- in the 2nd octave with the result of @11@, and @"b-3"@ as
-- @-25@. Pitches can be decorated using:
--
--    * s = Sharp, a half-step above (@"gs-1"@)
--    * f = Flat, a half-step below (@"gf-1"@)
--    * n = Natural, no decoration (@"g-1" and "gn-1"@ are equivalent)
--    * ss = Double sharp, a whole step above (@"gss-1"@)
--    * ff = Double flat, a whole step below (@"gff-1"@)
--
-- Note that TidalCycles now assumes that middle C is represented by
-- the value 0, rather than the previous value of 60. This function
-- is similar to previously available functions @tom@ and @toMIDI@,
-- but the default octave is now 0 rather than 5.
{-

definition moved to Parse.hs ..

toMIDI :: Pattern String -> Pattern Int
toMIDI p = fromJust <$> (filterValues (isJust) (noteLookup <$> p))
  where
    noteLookup :: String -> Maybe Int
    noteLookup [] = Nothing
    noteLookup s | not (last s `elem` ['0' .. '9']) = noteLookup (s ++ "0")
                 | not (isLetter (s !! 1)) = noteLookup((head s):'n':(tail s))
                 | otherwise = parse s
    parse x = (\a b c -> a+b+c) <$> pc x <*> sym x <*> Just(12*digitToInt (last x))
    pc x = lookup (head x) [('c',0),('d',2),('e',4),('f',5),('g',7),('a',9),('b',11)]
    sym x = lookup (init (tail x)) [("s",1),("f",-1),("n",0),("ss",2),("ff",-2)]
-}

-- @tom p@: Alias for @toMIDI@.
-- tom = toMIDI


{- | The `fit` function takes a pattern of integer numbers, which are used to select values from the given list. What makes this a bit strange is that only a given number of values are selected each cycle. For example:

@
d1 $ sound (fit 3 ["bd", "sn", "arpy", "arpy:1", "casio"] "0 [~ 1] 2 1")
@

The above fits three samples into the pattern, i.e. for the first cycle this will be `"bd"`, `"sn"` and `"arpy"`, giving the result `"bd [~ sn] arpy sn"` (note that we start counting at zero, so that `0` picks the first value). The following cycle the *next* three values in the list will be picked, i.e. `"arpy:1"`, `"casio"` and `"bd"`, giving the pattern `"arpy:1 [~ casio] bd casio"` (note that the list wraps round here).

-}
_fit :: Int -> [a] -> Pattern Int -> Pattern a
_fit perCycle xs p = (xs !!!) <$> (p {query = map (\e -> fmap (+ pos e) e) . query p})
  where pos e = perCycle * floor (start $ part e)

fit :: Pattern Int -> [a] -> Pattern Int -> Pattern a
fit pint xs p = (tParam func) pint (xs,p)
  where func i (xs',p') = _fit i xs' p'

permstep :: RealFrac b => Int -> [a] -> Pattern b -> Pattern a
permstep nSteps things p = unwrap $ (\n -> fastFromList $ concatMap (\x -> replicate (fst x) (snd x)) $ zip (ps !! floor (n * fromIntegral (length ps - 1))) things) <$> _segment 1 p
      where ps = permsort (length things) nSteps
            deviance avg xs = sum $ map (abs . (avg-) . fromIntegral) xs
            permsort n total = map fst $ sortOn snd $ map (\x -> (x,deviance (fromIntegral total / (fromIntegral n :: Double)) x)) $ perms n total
            perms 0 _ = []
            perms 1 n = [[n]]
            perms n total = concatMap (\x -> map (x:) $ perms (n-1) (total-x)) [1 .. (total-(n-1))]

-- | @struct a b@: structures pattern @b@ in terms of the pattern of
-- boolean values @a@. Only @True@ values in the boolean pattern are
-- used.
struct :: Pattern Bool -> Pattern a -> Pattern a
struct ps pv = filterJust $ (\a b -> if a then Just b else Nothing ) <$> ps <* pv

-- | @substruct a b@: similar to @struct@, but each event in pattern @a@ gets replaced with pattern @b@, compressed to fit the timespan of the event.
substruct :: Pattern Bool -> Pattern b -> Pattern b
substruct s p = p {query = f}
  where f st =
          concatMap ((\a' -> queryArc (compressArcTo a' p) a') . wholeOrPart) $ filter value $ query s st

randArcs :: Int -> Pattern [Arc]
randArcs n =
  do rs <- mapM (\x -> pure (toRational x / toRational n) <~ choose [1 :: Int,2,3]) [0 .. (n-1)]
     let rats = map toRational rs
         total = sum rats
         pairs = pairUp $ accumulate $ map (/total) rats
     return pairs
       where pairUp [] = []
             pairUp xs = Arc 0 (head xs) : pairUp' xs
             pairUp' [] = []
             pairUp' [_] = []
             pairUp' [a, _] = [Arc a 1]
             pairUp' (a:b:xs) = Arc a b: pairUp' (b:xs)


-- TODO - what does this do? Something for @stripe@ ..
randStruct :: Int -> Pattern Int
randStruct n = splitQueries $ Pattern {query = f}
  where f st = map (\(a,b,c) -> Event (Context []) (Just a) (fromJust b) c) $ filter (\(_,x,_) -> isJust x) as
          where as = map (\(i, Arc s' e') ->
                    (Arc (s' + sam s) (e' + sam s),
                       subArc (Arc s e) (Arc (s' + sam s) (e' + sam s)), i)) $
                      enumerate $ value $ head $
                      queryArc (randArcs n) (Arc (sam s) (nextSam s))
                (Arc s e) = arc st

-- TODO - what does this do?
substruct' :: Pattern Int -> Pattern a -> Pattern a
substruct' s p = p {query = \st -> concatMap (f st) (query s st)}
  where f st (Event c (Just a') _ i) = map (\e -> e {context = combineContexts [c, context e]}) $ queryArc (compressArcTo a' (inside (pure $ 1/toRational(length (queryArc s (Arc (sam (start $ arc st)) (nextSam (start $ arc st)))))) (rotR (toRational i)) p)) a'
        -- Ignore analog events (ones without wholes)
        f _ _ = []

-- | @stripe n p@: repeats pattern @p@, @n@ times per cycle. So
-- similar to @fast@, but with random durations. The repetitions will
-- be continguous (touching, but not overlapping) and the durations
-- will add up to a single cycle. @n@ can be supplied as a pattern of
-- integers.
stripe :: Pattern Int -> Pattern a -> Pattern a
stripe = tParam _stripe

_stripe :: Int -> Pattern a -> Pattern a
_stripe = substruct' . randStruct

-- | @slowstripe n p@: The same as @stripe@, but the result is also
-- @n@ times slower, so that the mean average duration of the stripes
-- is exactly one cycle, and every @n@th stripe starts on a cycle
-- boundary (in indian classical terms, the @sam@).
slowstripe :: Pattern Int -> Pattern a -> Pattern a
slowstripe n = slow (toRational <$> n) . stripe n

-- Lindenmayer patterns, these go well with the step sequencer
-- general rule parser (strings map to strings)
parseLMRule :: String -> [(String,String)]
parseLMRule s = map (splitOn ':') commaSplit
  where splitOn sep str = splitAt (fromJust $ elemIndex sep str)
                            $ filter (/= sep) str
        commaSplit = map T.unpack $ T.splitOn (T.pack ",") $ T.pack s

-- specific parser for step sequencer (chars map to string)
-- ruleset in form "a:b,b:ab"
parseLMRule' :: String -> [(Char, String)]
parseLMRule' str = map fixer $ parseLMRule str
  where fixer (c,r) = (head c, r)

{- | returns the `n`th iteration of a [Lindenmayer System](https://en.wikipedia.org/wiki/L-system) with given start sequence.

for example:

@
lindenmayer 1 "a:b,b:ab" "ab" -> "bab"
@
-}
lindenmayer :: Int -> String -> String -> String
lindenmayer _ _ [] = []
lindenmayer 1 r (c:cs) = fromMaybe [c] (lookup c $ parseLMRule' r)
                         ++ lindenmayer 1 r cs
lindenmayer n r s = iterate (lindenmayer 1 r) s !! n

{- | @lindenmayerI@ converts the resulting string into a a list of integers
with @fromIntegral@ applied (so they can be used seamlessly where floats or
rationals are required) -}
lindenmayerI :: Num b => Int -> String -> String -> [b]
lindenmayerI n r s = fmap (fromIntegral . digitToInt) $ lindenmayer n r s

{- | @runMarkov n tmat xi seed@ generates a Markov chain (as a list) of length @n@
using the transition matrix @tmat@ starting from initial state @xi@, starting
with random numbers generated from @seed@
Each entry in the chain is the index of state (starting from zero).
Each row of the matrix will be automatically normalized. For example:
@
runMarkov 8 [[2,3], [1,3]] 0 0
@
will produce a two-state chain 8 steps long, from initial state @0@, where the
transition probability from state 0->0 is 2/5, 0->1 is 3/5, 1->0 is 1/4, and
1->1 is 3/4.  -}
runMarkov :: Int -> [[Double]] -> Int -> Time -> [Int]
runMarkov n tp xi seed = reverse $ (iterate (markovStep $ renorm) [xi])!! (n-1) where
  markovStep tp' xs = (fromJust $ findIndex (r <=) $ scanl1 (+) (tp'!!(head xs))) : xs where
    r = timeToRand $ seed + (fromIntegral . length) xs / fromIntegral n
  renorm = [ map (/ sum x) x | x <- tp ]

{- @markovPat n xi tp@ generates a one-cycle pattern of @n@ steps in a Markov
chain starting from state @xi@ with transition matrix @tp@. Each row of the
transition matrix is automatically normalized.  For example:
@
tidal> markovPat 8 1 [[3,5,2], [4,4,2], [0,1,0]]

(0>⅛)|1
(⅛>¼)|2
(¼>⅜)|1
(⅜>½)|1
(½>⅝)|2
(⅝>¾)|1
(¾>⅞)|1
(⅞>1)|0
@ -}
markovPat :: Pattern Int -> Pattern Int -> [[Double]] -> Pattern Int
markovPat = tParam2 _markovPat

_markovPat :: Int -> Int -> [[Double]] -> Pattern Int
_markovPat n xi tp = splitQueries $ Pattern (\(State a@(Arc s _) _) ->
  queryArc (listToPat $ runMarkov n tp xi (sam s)) a)

{-|
Removes events from second pattern that don't start during an event from first.

Consider this, kind of messy rhythm without any rests.

@
d1 $ sound (slowcat ["sn*8", "[cp*4 bd*4, hc*5]"]) # n (run 8)
@

If we apply a mask to it

@
d1 $ s (mask ("1 1 1 ~ 1 1 ~ 1" :: Pattern Bool)
  (slowcat ["sn*8", "[cp*4 bd*4, bass*5]"] ))
  # n (run 8)
@

Due to the use of `slowcat` here, the same mask is first applied to `"sn*8"` and in the next cycle to `"[cp*4 bd*4, hc*5]".

You could achieve the same effect by adding rests within the `slowcat` patterns, but mask allows you to do this more easily. It kind of keeps the rhythmic structure and you can change the used samples independently, e.g.

@
d1 $ s (mask ("1 ~ 1 ~ 1 1 ~ 1")
  (slowcat ["can*8", "[cp*4 sn*4, jvbass*16]"] ))
  # n (run 8)
@
-}
mask :: Pattern Bool -> Pattern a -> Pattern a
mask b p = const <$> p <* (filterValues id b)

-- | TODO: refactor towards union
enclosingArc :: [Arc] -> Arc
enclosingArc [] = Arc 0 1
enclosingArc as = Arc (minimum (map start as)) (maximum (map stop as))

stretch :: Pattern a -> Pattern a
-- TODO - should that be whole or part?
stretch p = splitQueries $ p {query = q}
  where q st = query (zoomArc (cycleArc $ enclosingArc $ map wholeOrPart $ query p (st {arc = Arc (sam s) (nextSam s)})) p) st
          where s = start $ arc st

{- | `fit'` is a generalization of `fit`, where the list is instead constructed by using another integer pattern to slice up a given pattern.  The first argument is the number of cycles of that latter pattern to use when slicing.  It's easier to understand this with a few examples:

@
d1 $ sound (fit' 1 2 "0 1" "1 0" "bd sn")
@

So what does this do?  The first `1` just tells it to slice up a single cycle of `"bd sn"`. The `2` tells it to select two values each cycle, just like the first argument to `fit`.  The next pattern `"0 1"` is the "from" pattern which tells it how to slice, which in this case means `"0"` maps to `"bd"`, and `"1"` maps to `"sn"`.  The next pattern `"1 0"` is the "to" pattern, which tells it how to rearrange those slices.  So the final result is the pattern `"sn bd"`.

A more useful example might be something like

@
d1 $ fit' 1 4 (run 4) "[0 3*2 2 1 0 3*2 2 [1*8 ~]]/2" $ chop 4 $ (sound "breaks152" # unit "c")
@

which uses `chop` to break a single sample into individual pieces, which `fit'` then puts into a list (using the `run 4` pattern) and reassembles according to the complicated integer pattern.

-}
fit' :: Pattern Time -> Int -> Pattern Int -> Pattern Int -> Pattern a -> Pattern a
fit' cyc n from to p = squeezeJoin $ _fit n mapMasks to
  where mapMasks = [stretch $ mask (const True <$> filterValues (== i) from') p'
                     | i <- [0..n-1]]
        p' = density cyc p
        from' = density cyc from

loopFirst :: Pattern a -> Pattern a
loopFirst p = splitQueries $ p {query = f}
  where f st = map
          (\(Event c w p' v) ->
             Event c (plus <$> w) (plus p') v) $
          query p (st {arc = minus $ arc st})
          where minus = fmap (subtract (sam s))
                plus = fmap (+ sam s)
                s = start $ arc st

timeLoop :: Pattern Time -> Pattern a -> Pattern a
timeLoop n = outside n loopFirst

seqPLoop :: [(Time, Time, Pattern a)] -> Pattern a
seqPLoop ps = timeLoop (pure $ maxT - minT) $ minT `rotL` seqP ps
  where minT = minimum $ map (\(x,_,_) -> x) ps
        maxT = maximum $ map (\(_,x,_) -> x) ps

{- | @toScale@ lets you turn a pattern of notes within a scale (expressed as a
list) to note numbers.  For example `toScale [0, 4, 7] "0 1 2 3"` will turn
into the pattern `"0 4 7 12"`.  It assumes your scale fits within an octave;
to change this use `toScale' size`.  Example:
`toScale' 24 [0,4,7,10,14,17] (run 8)` turns into `"0 4 7 10 14 17 24 28"`
-}
toScale' :: Num a => Int -> [a] -> Pattern Int -> Pattern a
toScale' _ [] = const silence
toScale' o s = fmap noteInScale
  where octave x = x `div` length s
        noteInScale x = (s !!! x) + fromIntegral (o * octave x)

toScale :: Num a => [a] -> Pattern Int -> Pattern a
toScale = toScale' 12

{- | `swingBy x n` divides a cycle into `n` slices and delays the notes in
the second half of each slice by `x` fraction of a slice . @swing@ is an alias
for `swingBy (1%3)`
-}
swingBy :: Pattern Time -> Pattern Time -> Pattern a -> Pattern a
swingBy x n = inside n (withinArc (Arc 0.5 1) (x ~>))

swing :: Pattern Time -> Pattern a -> Pattern a
swing = swingBy (pure $ 1%3)

{- | `cycleChoose` is like `choose` but only picks a new item from the list
once each cycle -}
cycleChoose :: [a] -> Pattern a
cycleChoose = segment 1 . choose

{- | Internal function used by shuffle and scramble -}
_rearrangeWith :: Pattern Int -> Int -> Pattern a -> Pattern a
_rearrangeWith ipat n pat = innerJoin $ (\i -> _fast nT $ _repeatCycles n $ pats !! i) <$> ipat
  where
    pats = map (\i -> zoom (fromIntegral i / nT, fromIntegral (i+1) / nT) pat) [0 .. (n-1)]
    nT :: Time
    nT = fromIntegral n

{- | `shuffle n p` evenly divides one cycle of the pattern `p` into `n` parts,
and returns a random permutation of the parts each cycle.  For example,
`shuffle 3 "a b c"` could return `"a b c"`, `"a c b"`, `"b a c"`, `"b c a"`,
`"c a b"`, or `"c b a"`.  But it will **never** return `"a a a"`, because that
is not a permutation of the parts.
-}
shuffle :: Pattern Int -> Pattern a -> Pattern a
shuffle = tParam _shuffle

_shuffle :: Int -> Pattern a -> Pattern a
_shuffle n = _rearrangeWith (randrun n) n

{- | `scramble n p` is like `shuffle` but randomly selects from the parts
of `p` instead of making permutations.
For example, `scramble 3 "a b c"` will randomly select 3 parts from
`"a"` `"b"` and `"c"`, possibly repeating a single part.
-}
scramble :: Pattern Int -> Pattern a -> Pattern a
scramble = tParam _scramble

_scramble :: Int -> Pattern a -> Pattern a
_scramble n = _rearrangeWith (_segment (fromIntegral n) $ _irand n) n

randrun :: Int -> Pattern Int
randrun 0 = silence
randrun n' =
  splitQueries $ Pattern (\(State a@(Arc s _) _) -> events a $ sam s)
  where events a seed = mapMaybe toEv $ zip arcs shuffled
          where shuffled = map snd $ sortOn fst $ zip rs [0 .. (n'-1)]
                rs = timeToRands seed n' :: [Double]
                arcs = zipWith Arc fractions (tail fractions)
                fractions = map (+ (sam $ start a)) [0, 1 / fromIntegral n' .. 1]
                toEv (a',v) = do a'' <- subArc a a'
                                 return $ Event (Context []) (Just a') a'' v


ur :: Time -> Pattern String -> [(String, Pattern a)] -> [(String, Pattern a -> Pattern a)] -> Pattern a
ur t outer_p ps fs = _slow t $ unwrap $ adjust <$> timedValues (getPat . split <$> outer_p)
  where split = wordsBy (==':')
        getPat (s:xs) = (match s, transform xs)
        -- TODO - check this really can't happen..
        getPat _ = error "can't happen?"
        match s = fromMaybe silence $ lookup s ps'
        ps' = map (fmap (_fast t)) ps
        adjust (a, (p, f)) = f a p
        transform (x:_) a = transform' x a
        transform _ _ = id
        transform' str (Arc s e) p = s `rotR` inside (pure $ 1/(e-s)) (matchF str) p
        matchF str = fromMaybe id $ lookup str fs
        timedValues = withEvent (\(Event c (Just a) a' v) -> Event c (Just a) a' (a,v)) . filterDigital

inhabit :: [(String, Pattern a)] -> Pattern String -> Pattern a
inhabit ps p = squeezeJoin $ (\s -> fromMaybe silence $ lookup s ps) <$> p

{- | @spaceOut xs p@ repeats a pattern @p@ at different durations given by the list of time values in @xs@ -}
spaceOut :: [Time] -> Pattern a -> Pattern a
spaceOut xs p = _slow (toRational $ sum xs) $ stack $ map (`compressArc` p) spaceArcs
  where markOut :: Time -> [Time] -> [Arc]
        markOut _ [] = []
        markOut offset (x:xs') = Arc offset (offset+x):markOut (offset+x) xs'
        spaceArcs = map (\(Arc a b) -> Arc (a/s) (b/s)) $ markOut 0 xs
        s = sum xs

-- | @flatpat@ takes a Pattern of lists and pulls the list elements as
-- separate Events
flatpat :: Pattern [a] -> Pattern a
flatpat p = p {query = concatMap (\(Event c b b' xs) -> map (Event c b b') xs) . query p}

-- | @layer@ takes a Pattern of lists and pulls the list elements as
-- separate Events
layer :: [a -> Pattern b] -> a -> Pattern b
layer fs p = stack $ map ($ p) fs

-- | @arpeggiate@ finds events that share the same timespan, and spreads
-- them out during that timespan, so for example @arpeggiate "[bd,sn]"@
-- gets turned into @"bd sn"@. Useful for creating arpeggios/broken chords.
arpeggiate :: Pattern a -> Pattern a
arpeggiate = arpWith id

-- | Shorthand alias for arpeggiate
arpg :: Pattern a -> Pattern a
arpg = arpeggiate

arpWith :: ([EventF (ArcF Time) a] -> [EventF (ArcF Time) b]) -> Pattern a -> Pattern b
arpWith f p = withEvents munge p
  where munge es = concatMap (spreadOut . f) (groupBy (\a b -> whole a == whole b) $ sortOn whole es)
        spreadOut xs = mapMaybe (\(n, x) -> shiftIt n (length xs) x) $ enumerate xs
        shiftIt n d (Event c (Just (Arc s e)) a' v) =
          do
            a'' <- subArc (Arc newS newE) a'
            return (Event c (Just $ Arc newS newE) a'' v)
          where newS = s + (dur * fromIntegral n)
                newE = newS + dur
                dur = (e - s) / fromIntegral d
        -- TODO ignoring analog events.. Should we just leave them as-is?
        shiftIt _ _ _ = Nothing

arp :: Pattern String -> Pattern a -> Pattern a
arp = tParam _arp

_arp :: String -> Pattern a -> Pattern a
_arp name p = arpWith f p
  where f = fromMaybe id $ lookup name arps
        arps :: [(String, [a] -> [a])]
        arps = [("up", id),
                ("down", reverse),
                ("updown", \x -> init x ++ init (reverse x)),
                ("downup", \x -> init (reverse x) ++ init x),
                ("up&down", \x -> x ++ reverse x),
                ("down&up", \x -> reverse x ++ x),
                ("converge", converge),
                ("diverge", reverse . converge),
                ("disconverge", \x -> converge x ++ tail (reverse $ converge x)),
                ("pinkyup", pinkyup),
                ("pinkyupdown", \x -> init (pinkyup x) ++ init (reverse $ pinkyup x)),
                ("thumbup", thumbup),
                ("thumbupdown", \x -> init (thumbup x) ++ init (reverse $ thumbup x))
               ]
        converge [] = []
        converge (x:xs) = x : converge' xs
        converge' [] = []
        converge' xs = last xs : converge (init xs)
        pinkyup xs = concatMap (:[pinky]) $ init xs
          where pinky = last xs
        thumbup xs = concatMap (\x -> [thumb,x]) $ tail xs
          where thumb = head xs

{- | `rolled` plays each note of a chord quickly in order, as opposed to simultaneously; to give a chord a harp-like effect.
This will played from the lowest note to the highest note of the chord
@
rolled $ n "c'maj'4" # s "superpiano"
@


And you can use `rolledBy` or `rolledBy'` to specify the length of the roll. The value in the passed pattern
is the divisor of the cycle length. A negative value will play the arpeggio in reverse order.

@
rolledBy "<1 -0.5 0.25 -0.125>" $ note "c'maj9" # s "superpiano"
@
-}

rolledWith :: Ratio Integer -> Pattern a -> Pattern a
rolledWith t = withEvents aux
         where aux es = concatMap (steppityIn) (groupBy (\a b -> whole a == whole b) $ ((isRev t) es))
               isRev b = (\x -> if x > 0 then id else reverse ) b
               steppityIn xs = mapMaybe (\(n, ev) -> (timeguard n xs ev t)) $ enumerate xs
               timeguard _ _ ev 0 = return ev
               timeguard n xs ev _ = (shiftIt n (length xs) ev)
               shiftIt n d (Event c (Just (Arc s e)) a' v) = do
                         a'' <- subArc (Arc newS e) a'
                         return (Event c (Just $ Arc newS e) a'' v)
                      where newS = s + (dur * fromIntegral n)
                            dur = ((e - s)) / ((1/ (abs t))*fromIntegral d)
               shiftIt _ _ ev =  return ev

rolledBy :: Pattern (Ratio Integer) -> Pattern a -> Pattern a
rolledBy pt = tParam rolledWith (segment 1 $ pt)

rolled :: Pattern a -> Pattern a
rolled = rolledBy (1/4)

{- TODO !

-- | @fill@ 'fills in' gaps in one pattern with events from another. For example @fill "bd" "cp ~ cp"@ would result in the equivalent of `"~ bd ~"`. This only finds gaps in a resulting pattern, in other words @"[bd ~, sn]"@ doesn't contain any gaps (because @sn@ covers it all), and @"bd ~ ~ sn"@ only contains a single gap that bridges two steps.
fill :: Pattern a -> Pattern a -> Pattern a
fill p' p = struct (splitQueries $ p {query = q}) p'
  where
    q st = removeTolerance (s,e) $ invert (s-tolerance, e+tolerance) $ query p (st {arc = (s-tolerance, e+tolerance)})
      where (s,e) = arc st
    invert (s,e) es = map arcToEvent $ foldr remove [(s,e)] (map part es)
    remove (s,e) xs = concatMap (remove' (s, e)) xs
    remove' (s,e) (s',e') | s > s' && e < e' = [(s',s),(e,e')] -- inside
                          | s > s' && s < e' = [(s',s)] -- cut off right
                          | e > s' && e < e' = [(e,e')] -- cut off left
                          | s <= s' && e >= e' = [] -- swallow
                          | otherwise = [(s',e')] -- miss
    arcToEvent a = ((a,a),"x")
    removeTolerance (s,e) es = concatMap (expand) $ map (withPart f) es
      where f a = concatMap (remove' (e,e+tolerance)) $ remove' (s-tolerance,s) a
            expand ((a,xs),c) = map (\x -> ((a,x),c)) xs
    tolerance = 0.01
-}

-- Repeats each event @n@ times within its arc
ply :: Pattern Rational -> Pattern a -> Pattern a
ply = tParam _ply

_ply :: Rational -> Pattern a -> Pattern a
_ply n pat = squeezeJoin $ (_fast n . pure) <$> pat

-- Like ply, but applies a function each time. The applications are compounded.
plyWith :: (Ord t, Num t) => Pattern t -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
plyWith np f p = innerJoin $ (\n -> _plyWith n f p) <$> np

_plyWith :: (Ord t, Num t) => t -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
_plyWith numPat f p = arpeggiate $ compound numPat
  where compound n | n <= 1 = p
                   | otherwise = overlay p (f $ compound $ n-1)

-- | Syncopates a rhythm, shifting each event halfway into its arc (aka timespan), e.g. @"a b [c d] e"@ becomes the equivalent of @"[~ a] [~ b] [[~ c] [~ d]] [~ e]"@
press :: Pattern a -> Pattern a
press = _pressBy 0.5

-- | Like @press@, but allows you to specify the amount in which each event is shifted. @pressBy 0.5@ is the same as @press@, while @pressBy (1/3)@ shifts each event by a third of its arc.
pressBy :: Pattern Time -> Pattern a -> Pattern a
pressBy = tParam _pressBy

_pressBy :: Time -> Pattern a -> Pattern a
_pressBy r pat = squeezeJoin $ (compressTo (r,1) . pure) <$> pat

-- | Uses the first (binary) pattern to switch between the following
-- two patterns. The resulting structure comes from the source patterns, not the
-- binary pattern. See also @stitch@.
sew :: Pattern Bool -> Pattern a -> Pattern a -> Pattern a
sew pb a b = overlay (mask pb a) (mask (inv pb) b)

-- | Uses the first (binary) pattern to switch between the following
-- two patterns. The resulting structure comes from the binary
-- pattern, not the source patterns. See also @sew@.
stitch :: Pattern Bool -> Pattern a -> Pattern a -> Pattern a
stitch pb a b = overlay (struct pb a)  (struct (inv pb) b)

-- | A binary pattern is used to conditionally apply a function to a
-- source pattern. The function is applied when a @True@ value is
-- active, and the pattern is let through unchanged when a @False@
-- value is active. No events are let through where no binary values
-- are active.
while :: Pattern Bool -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
while b f pat = sew b (f pat) pat

stutter :: Integral i => i -> Time -> Pattern a -> Pattern a
stutter n t p = stack $ map (\i -> (t * fromIntegral i) `rotR` p) [0 .. (n-1)]

{- | The `jux` function creates strange stereo effects, by applying a
function to a pattern, but only in the right-hand channel. For
example, the following reverses the pattern on the righthand side:

@
d1 $ slow 32 $ jux (rev) $ striateBy 32 (1/16) $ sound "bev"
@

When passing pattern transforms to functions like [jux](#jux) and [every](#every),
it's possible to chain multiple transforms together with `.`, for
example this both reverses and halves the playback speed of the
pattern in the righthand channel:

@
d1 $ slow 32 $ jux ((# speed "0.5") . rev) $ striateBy 32 (1/16) $ sound "bev"
@
-}
jux
  :: (Pattern ValueMap -> Pattern ValueMap)
     -> Pattern ValueMap -> Pattern ValueMap
jux = juxBy 1
juxcut
  :: (Pattern ValueMap -> Pattern ValueMap)
     -> Pattern ValueMap -> Pattern ValueMap
juxcut f p = stack [p     # P.pan (pure 0) # P.cut (pure (-1)),
                    f $ p # P.pan (pure 1) # P.cut (pure (-2))
                   ]

juxcut' :: [t -> Pattern ValueMap] -> t -> Pattern ValueMap
juxcut' fs p = stack $ map (\n -> ((fs !! n) p |+ P.cut (pure $ 1-n)) # P.pan (pure $ fromIntegral n / fromIntegral l)) [0 .. l-1]
  where l = length fs

{- | In addition to `jux`, `jux'` allows using a list of pattern transform. resulting patterns from each transformation will be spread via pan from left to right.

For example:

@
d1 $ jux' [iter 4, chop 16, id, rev, palindrome] $ sound "bd sn"
@

will put `iter 4` of the pattern to the far left and `palindrome` to the far right. In the center the original pattern will play and mid left mid right the chopped and the reversed version will appear.

One could also write:

@
d1 $ stack [
    iter 4 $ sound "bd sn" # pan "0",
    chop 16 $ sound "bd sn" # pan "0.25",
    sound "bd sn" # pan "0.5",
    rev $ sound "bd sn" # pan "0.75",
    palindrome $ sound "bd sn" # pan "1",
    ]
@

-}
jux' :: [t -> Pattern ValueMap] -> t -> Pattern ValueMap
jux' fs p = stack $ map (\n -> (fs !! n) p |+ P.pan (pure $ fromIntegral n / fromIntegral l)) [0 .. l-1]
  where l = length fs

-- | Multichannel variant of `jux`, _not sure what it does_
jux4
  :: (Pattern ValueMap -> Pattern ValueMap)
     -> Pattern ValueMap -> Pattern ValueMap
jux4 f p = stack [p # P.pan (pure (5/8)), f $ p # P.pan (pure (1/8))]

{- |
With `jux`, the original and effected versions of the pattern are
panned hard left and right (i.e., panned at 0 and 1). This can be a
bit much, especially when listening on headphones. The variant `juxBy`
has an additional parameter, which brings the channel closer to the
centre. For example:

@
d1 $ juxBy 0.5 (density 2) $ sound "bd sn:1"
@

In the above, the two versions of the pattern would be panned at 0.25
and 0.75, rather than 0 and 1.
-}
juxBy
  :: Pattern Double
     -> (Pattern ValueMap -> Pattern ValueMap)
     -> Pattern ValueMap
     -> Pattern ValueMap
juxBy n f p = stack [p |+ P.pan 0.5 |- P.pan (n/2), f $ p |+ P.pan 0.5 |+ P.pan (n/2)]

pick :: String -> Int -> String
pick name n = name ++ ":" ++ show n

-- samples "jvbass [~ latibro] [jvbass [latibro jvbass]]" ((1%2) `rotL` slow 6 "[1 6 8 7 3]")

samples :: Applicative f => f String -> f Int -> f String
samples p p' = pick <$> p <*> p'

samples' :: Applicative f => f String -> f Int -> f String
samples' p p' = flip pick <$> p' <*> p

{-
scrumple :: Time -> Pattern a -> Pattern a -> Pattern a
scrumple o p p' = p'' -- overlay p (o `rotR` p'')
  where p'' = Pattern $ \a -> concatMap
                              (\((s,d), vs) -> map (\x -> ((s,d),
                                                           snd x
                                                          )
                                                   )
                                                   (arc p' (s,s))
                              ) (arc p a)
-}

spreadf :: [a -> Pattern b] -> a -> Pattern b
spreadf = spread ($)

stackwith :: Unionable a => Pattern a -> [Pattern a] -> Pattern a
stackwith p ps | null ps = silence
               | otherwise = stack $ map (\(i, p') -> p' # ((fromIntegral i % l) `rotL` p)) (zip [0::Int ..] ps)
  where l = fromIntegral $ length ps

{-
cross f p p' = Pattern $ \t -> concat [filter flt $ arc p t,
                                       filter (not . flt) $ arc p' t
                                      ]
]  where flt = f . cyclePos . fst . fst
-}

{- | `range` will take a pattern which goes from 0 to 1 (like `sine`), and range it to a different range - between the first and second arguments. In the below example, `range 1 1.5` shifts the range of `sine1` from 0 - 1 to 1 - 1.5.

@
d1 $ jux (iter 4) $ sound "arpy arpy:2*2"
  |+ speed (slow 4 $ range 1 1.5 sine1)
@
-}
range :: Num a => Pattern a -> Pattern a -> Pattern a -> Pattern a
range fromP toP p = (\from to v -> ((v * (to-from)) + from)) <$> fromP *> toP *> p

_range :: (Functor f, Num b) => b -> b -> f b -> f b
_range from to p = (+ from) . (* (to-from)) <$> p

{- | `rangex` is an exponential version of `range`, good for using with
frequencies.  Do *not* use negative numbers or zero as arguments! -}
rangex :: (Functor f, Floating b) => b -> b -> f b -> f b
rangex from to p = exp <$> _range (log from) (log to) p

off :: Pattern Time -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
off tp f p = innerJoin $ (\tv -> _off tv f p) <$> tp

_off :: Time -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
_off t f p = superimpose (f . (t `rotR`)) p

offadd :: Num a => Pattern Time -> Pattern a -> Pattern a -> Pattern a
offadd tp pn p = off tp (+pn) p

-- | Step sequencing
step :: String -> String -> Pattern String
step s cs = fastcat $ map f cs
    where f c | c == 'x' = pure s
              | isDigit c = pure $ s ++ ":" ++ [c]
              | otherwise = silence

steps :: [(String, String)] -> Pattern String
steps = stack . map (uncurry step)

-- | like `step`, but allows you to specify an array of strings to use for 0,1,2...
step' :: [String] -> String -> Pattern String
step' ss cs = fastcat $ map f cs
    where f c | c == 'x' = pure $ head ss
              | isDigit c = pure $ ss !! digitToInt c
              | otherwise = silence


-- ghost'' is kept for backwards compatibility
ghost'' :: Time -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
ghost'' = ghostWith

ghostWith :: Time -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
ghostWith a f p = superimpose (((a*2.5) `rotR`) . f) $ superimpose (((a*1.5) `rotR`) . f) p

ghost' :: Time -> Pattern ValueMap -> Pattern ValueMap
ghost' a p = ghostWith a ((|*| P.gain (pure 0.7)) . (|> P.end (pure 0.2)) . (|*| P.speed (pure 1.25))) p

ghost :: Pattern ValueMap -> Pattern ValueMap
ghost = ghost' 0.125

{- |
   tabby - A more literal weaving than the `weave` function, give number
   of 'threads' per cycle and two patterns, and this function will weave them
   together using a plain (aka 'tabby') weave, with a simple over/under structure
 -}
tabby :: Int -> Pattern a -> Pattern a -> Pattern a
tabby nInt p p' = stack [maskedWarp,
                      maskedWeft
                     ]
  where
    n = fromIntegral nInt
    weft = concatMap (const [[0..n-1], reverse [0..n-1]]) [0 .. (n `div` 2) - 1]
    warp = transpose weft
    thread xs p'' = _slow (n%1) $ fastcat $ map (\i -> zoomArc (Arc (i%n) ((i+1)%n)) p'') (concat xs)
    weftP = thread weft p'
    warpP = thread warp p
    maskedWeft = mask (every 2 rev $ _fast (n % 2) $ fastCat [silence, pure True]) weftP
    maskedWarp = mask (every 2 rev $ _fast (n % 2) $ fastCat [pure True, silence]) warpP

-- | chooses between a list of patterns, using a pattern of floats (from 0-1)
select :: Pattern Double -> [Pattern a] -> Pattern a
select = tParam _select

_select :: Double -> [Pattern a] -> Pattern a
_select f ps =  ps !! floor (max 0 (min 1 f) * fromIntegral (length ps - 1))

-- | chooses between a list of functions, using a pattern of floats (from 0-1)
selectF :: Pattern Double -> [Pattern a -> Pattern a] -> Pattern a -> Pattern a
selectF pf ps p = innerJoin $ (\f -> _selectF f ps p) <$> pf

_selectF :: Double -> [Pattern a -> Pattern a] -> Pattern a -> Pattern a
_selectF f ps p =  (ps !! floor (max 0 (min 0.999999 f) * fromIntegral (length ps))) p

-- | chooses between a list of functions, using a pattern of integers
pickF :: Pattern Int -> [Pattern a -> Pattern a] -> Pattern a -> Pattern a
pickF pInt fs pat = innerJoin $ (\i -> _pickF i fs pat) <$> pInt

_pickF :: Int -> [Pattern a -> Pattern a] -> Pattern a -> Pattern a
_pickF i fs p =  (fs !!! i) p

-- | @contrast p f f' p'@ splits controlpattern @p'@ in two, applying
-- the function @f@ to one and @f'@ to the other. This depends on
-- whether events in it contains values matching with those in @p@.
-- For example in @contrast (# crush 3) (# vowel "a") (n "1") $ n "0 1" # s "bd sn" # speed 3@,
-- the first event will have the vowel effect applied and the second
-- will have the crush applied.
contrast :: (ControlPattern -> ControlPattern) -> (ControlPattern -> ControlPattern)
            -> ControlPattern -> ControlPattern -> ControlPattern
contrast = contrastBy (==)

contrastBy :: (a -> Value -> Bool)
              -> (ControlPattern -> Pattern b)
              -> (ControlPattern -> Pattern b)
              -> Pattern (Map.Map String a)
              -> Pattern (Map.Map String Value)
              -> Pattern b
contrastBy comp f f' p p' = overlay (f matched) (f' unmatched)
  where matches = matchManyToOne (flip $ Map.isSubmapOfBy comp) p p'
        matched :: ControlPattern
        matched = filterJust $ (\(t, a) -> if t then Just a else Nothing) <$> matches
        unmatched :: ControlPattern
        unmatched = filterJust $ (\(t, a) -> if not t then Just a else Nothing) <$> matches

contrastRange
  :: (ControlPattern -> Pattern a)
     -> (ControlPattern -> Pattern a)
     -> Pattern (Map.Map String (Value, Value))
     -> ControlPattern
     -> Pattern a
contrastRange = contrastBy f
      where f (VI s, VI e) (VI v) = v >= s && v <= e
            f (VF s, VF e) (VF v) = v >= s && v <= e
            f (VN s, VN e) (VN v) = v >= s && v <= e
            f (VS s, VS e) (VS v) = v == s && v == e
            f _ _ = False

-- | Like @contrast@, but one function is given, and applied to events with matching controls.
fix :: (ControlPattern -> ControlPattern) -> ControlPattern -> ControlPattern -> ControlPattern
fix f = contrast f id

-- | Like @contrast@, but one function is given, and applied to events
-- with controls which don't match.
unfix :: (ControlPattern -> ControlPattern) -> ControlPattern -> ControlPattern -> ControlPattern
unfix = contrast id

fixRange :: (ControlPattern -> Pattern ValueMap)
            -> Pattern (Map.Map String (Value, Value))
            -> ControlPattern
            -> ControlPattern
fixRange f = contrastRange f id

unfixRange :: (ControlPattern -> Pattern ValueMap)
              -> Pattern (Map.Map String (Value, Value))
              -> ControlPattern
              -> ControlPattern
unfixRange = contrastRange id

-- | limit values in a Pattern (or other Functor) to n equally spaced
-- divisions of 1.
quantise :: (Functor f, RealFrac b) => b -> f b -> f b
quantise n = fmap ((/n) . (fromIntegral :: RealFrac b => Int -> b) . round . (*n))

-- quantise but with floor
qfloor :: (Functor f, RealFrac b) => b -> f b -> f b
qfloor n = fmap ((/n) . (fromIntegral :: RealFrac b => Int -> b) . floor . (*n))

qceiling :: (Functor f, RealFrac b) => b -> f b -> f b
qceiling n = fmap ((/n) . (fromIntegral :: RealFrac b => Int -> b) . ceiling . (*n))

qround :: (Functor f, RealFrac b) => b -> f b -> f b
qround = quantise

-- | Inverts all the values in a boolean pattern
inv :: Functor f => f Bool -> f Bool
inv = (not <$>)

-- | Serialises a pattern so there's only one event playing at any one
-- time, making it 'monophonic'. Events which start/end earlier are given priority.
mono :: Pattern a -> Pattern a
mono p = Pattern $ \(State a cm) -> flatten $ query p (State a cm) where
  flatten :: [Event a] -> [Event a]
  flatten = mapMaybe constrainPart . truncateOverlaps . sortOn whole
  truncateOverlaps [] = []
  truncateOverlaps (e:es) = e : truncateOverlaps (mapMaybe (snip e) es)
  -- TODO - decide what to do about analog events..
  snip a b | start (wholeOrPart b) >= stop (wholeOrPart a) = Just b
           | stop (wholeOrPart b) <= stop (wholeOrPart a) = Nothing
           | otherwise = Just b {whole = Just $ Arc (stop $ wholeOrPart a) (stop $ wholeOrPart b)}
  constrainPart :: Event a -> Maybe (Event a)
  constrainPart e = do a <- subArc (wholeOrPart e) (part e)
                       return $ e {part = a}

-- serialize the given pattern
-- find the middle of the query's arc and use that to query the serialized pattern. We should get either no events or a single event back
-- if we don't get any events, return nothing
-- if we get an event, get the stop of its arc, and use that to query the serialized pattern, to see if there's an adjoining event
-- if there isn't, return the event as-is.
-- if there is, check where we are in the 'whole' of the event, and use that to tween between the values of the event and the next event
-- smooth :: Pattern Double -> Pattern Double

-- TODO - test this with analog events
smooth :: Fractional a => Pattern a -> Pattern a
smooth p = Pattern $ \st@(State a cm) -> tween st a $ query monoP (State (midArc a) cm)
  where
    midArc a = Arc (mid (start a, stop a)) (mid (start a, stop a))
    tween _ _ [] = []
    tween st queryA (e:_) = maybe [e {whole = Just queryA, part = queryA}] (tween' queryA) (nextV st)
      where aStop = Arc (wholeStop e) (wholeStop e)
            nextEs st' = query monoP (st' {arc = aStop})
            nextV st' | null (nextEs st') = Nothing
                      | otherwise = Just $ value (head (nextEs st'))
            tween' queryA' v =
              [ Event
                { context = context e,
                  whole = Just queryA'
                , part = queryA'
                , value = value e + ((v - value e) * pc)}
              ]
            pc | delta' (wholeOrPart e) == 0 = 0
               | otherwise = fromRational $ (eventPartStart e - wholeStart e) / delta' (wholeOrPart e)
            delta' a = stop a - start a
    monoP = mono p

-- | Looks up values from a list of tuples, in order to swap values in the given pattern
swap :: Eq a => [(a, b)] -> Pattern a -> Pattern b
swap things p = filterJust $ (`lookup` things) <$> p

{-
  snowball |
  snowball takes a function that can combine patterns (like '+'),
  a function that transforms a pattern (like 'slow'),
  a depth, and a starting pattern,
  it will then transform the pattern and combine it with the last transformation until the depth is reached
  this is like putting an effect (like a filter) in the feedback of a delay line
  each echo is more effected
  d1 $ note (scale "hexDorian" $ snowball 8 (+) (slow 2 . rev) "0 ~ . -1 . 5 3 4 . ~ -2") # s "gtr"
-}
snowball :: Int -> (Pattern a -> Pattern a -> Pattern a) -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
snowball depth combinationFunction f pattern = cat $ take depth $ scanl combinationFunction pattern $ drop 1 $ iterate f pattern

{- @soak@ |
    applies a function to a pattern and cats the resulting pattern,
    then continues applying the function until the depth is reached
    this can be used to create a pattern that wanders away from
    the original pattern by continually adding random numbers
    d1 $ note (scale "hexDorian" mutateBy (+ (range -1 1 $ irand 2)) 8 $ "0 1 . 2 3 4") # s "gtr"
-}
soak ::  Int -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
soak depth f pattern = cat $ take depth $ iterate f pattern

deconstruct :: Int -> Pattern String -> String
deconstruct n p = intercalate " " $ map showStep $ toList p
  where
    showStep :: [String] -> String
    showStep [] = "~"
    showStep [x] = x
    showStep xs = "[" ++ (intercalate ", " xs) ++ "]"
    toList :: Pattern a -> [[a]]
    toList pat = map (\(s,e) -> map value $ queryArc (_segment n' pat) (Arc s e)) arcs
      where breaks = [0, (1/n') ..]
            arcs = zip (take n breaks) (drop 1 breaks)
            n' = fromIntegral n

{- @squeeze@ ipat pats | uses a pattern of integers to index into a list of patterns.
-}
squeeze :: Pattern Int -> [Pattern a] -> Pattern a
squeeze _ [] = silence
squeeze ipat pats = squeezeJoin $ (pats !!!) <$> ipat

squeezeJoinUp :: Pattern (ControlPattern) -> ControlPattern
squeezeJoinUp pp = pp {query = q}
  where q st = concatMap (f st) (query (filterDigital pp) st)
        f st (Event c (Just w) p v) =
          mapMaybe (munge c w p) $ query (compressArc (cycleArc w) (v |* P.speed (pure $ fromRational $ 1/(stop w - start w)))) st {arc = p}
        -- already ignoring analog events, but for completeness..
        f _ _ = []
        munge co oWhole oPart (Event ci (Just iWhole) iPart v) =
          do w' <- subArc oWhole iWhole
             p' <- subArc oPart iPart
             return (Event (combineContexts [ci,co]) (Just w') p' v)
        munge _ _ _ _ = Nothing

_chew :: Int -> Pattern Int -> ControlPattern  -> ControlPattern
_chew n ipat pat = (squeezeJoinUp $ zoompat <$> ipat) |/ P.speed (pure $ fromIntegral n)
  where zoompat i = zoom (i'/(fromIntegral n), (i'+1)/(fromIntegral n)) (pat)
           where i' = fromIntegral $ i `mod` n

-- TODO maybe _chew could pattern the first parameter directly..
chew :: Pattern Int -> Pattern Int -> ControlPattern  -> ControlPattern
chew npat ipat pat = innerJoin $ (\n -> _chew n ipat pat) <$> npat

__binary :: Data.Bits.Bits b => Int -> b -> [Bool]
__binary n num = map (testBit num) $ reverse [0 .. n-1]

_binary :: Data.Bits.Bits b => Int -> b -> Pattern Bool
_binary n num = listToPat $ __binary n num

_binaryN :: Int -> Pattern Int -> Pattern Bool
_binaryN n p = squeezeJoin $ _binary n <$> p

binaryN :: Pattern Int -> Pattern Int -> Pattern Bool
binaryN n p = tParam _binaryN n p

binary :: Pattern Int -> Pattern Bool
binary = binaryN 8

ascii :: Pattern String -> Pattern Bool
ascii p = squeezeJoin $ (listToPat . concatMap (__binary 8 . ord)) <$> p

grain :: Pattern Double -> Pattern Double -> ControlPattern
grain s w = P.begin b # P.end e
  where b = s
        e = s + w

-- | For specifying a boolean pattern according to a list of offsets
-- (aka inter-onset intervals).  For example `necklace 12 [4,2]` is
-- the same as "t f f f t f t f f f t f". That is, 12 steps per cycle,
-- with true values alternating between every 4 and every 2 steps.
necklace :: Rational -> [Int] -> Pattern Bool
necklace perCycle xs = _slow ((toRational $ sum xs) / perCycle) $ listToPat $ list xs
  where list :: [Int] -> [Bool]
        list [] = []
        list (x:xs') = (True:(replicate (x-1) False)) ++ list xs'
