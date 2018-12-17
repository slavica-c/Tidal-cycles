{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, OverloadedStrings #-}

module Sound.Tidal.UI where

import           Prelude hiding ((<*), (*>))

import           Data.Ord (comparing)
import           Data.Char (digitToInt, isDigit)
import           System.Random.MWC
import           Control.Monad.ST
import qualified Data.Vector as V
import           Data.Word (Word32)
import           Data.Ratio ((%),numerator,denominator)
import           Data.List (sort, sortBy, findIndices, elemIndex, groupBy, transpose)
import           Data.Maybe (isJust, fromJust, fromMaybe, mapMaybe, catMaybes)
import qualified Data.Text as T
import           Control.Applicative (liftA2)
import qualified Data.Map.Strict as Map

import           Sound.Tidal.Bjorklund (bjorklund)
import           Sound.Tidal.Core
import qualified Sound.Tidal.Params as P
import           Sound.Tidal.Pattern
import           Sound.Tidal.Utils
 
------------------------------------------------------------------------
-- * UI

-- | Randomisation

timeToRand :: RealFrac a => a -> Double
timeToRand x = runST $ do
  let x' = toRational (x*x) / 1000000
  let n' = fromIntegral $ numerator x'
  let d' = fromIntegral $ denominator x'
  seed <- initialize (V.fromList [n',d'] :: V.Vector Word32)
  uniform seed

{-|

`rand` generates a continuous pattern of (pseudo-)random numbers between `0` and `1`.

@
sound "bd*8" # pan rand
@

pans bass drums randomly

@
sound "sn sn ~ sn" # gain rand
@

makes the snares' randomly loud and quiet.

Numbers coming from this pattern are 'seeded' by time. So if you reset
time (via `cps (-1)`, then `cps 1.1` or whatever cps you want to
restart with) the random pattern will emit the exact same _random_
numbers again.

In cases where you need two different random patterns, you can shift
one of them around to change the time from which the _random_ pattern
is read, note the difference:

@
jux (# gain rand) $ sound "sn sn ~ sn" # gain rand
@

and with the juxed version shifted backwards for 1024 cycles:

@
jux (# ((1024 <~) $ gain rand)) $ sound "sn sn ~ sn" # gain rand
@
-}
rand :: Fractional a => Pattern a
rand = Pattern Analog (\(State a@(Arc s e) _) -> [Event a a (realToFrac $ timeToRand $ (e + s)/2)])

{- | Just like `rand` but for whole numbers, `irand n` generates a pattern of (pseudo-) random whole numbers between `0` to `n-1` inclusive. Notably used to pick a random
samples from a folder:

@
d1 $ n (irand 5) # sound "drum"
@
-}
irand :: Num a => Int -> Pattern a
irand i = (fromIntegral . (floor :: Double -> Int) . (* (fromIntegral i))) <$> rand

{- | 1D Perlin (smooth) noise, works like rand but smoothly moves between random
values each cycle. `perlinWith` takes a pattern as the RNG's "input" instead
of automatically using the cycle count.
@
d1 $ s "arpy*32" # cutoff (perlinWith (saw * 4) * 2000)
@
will generate a smooth random pattern for the cutoff frequency which will
repeat every cycle (because the saw does)
The `perlin` function uses the cycle count as input and can be used much like @rand@.
-}
perlinWith :: Pattern Double -> Pattern Double
perlinWith p = interp <$> (p-pa) <*> (timeToRand <$> pa) <*> (timeToRand <$> pb) where
  pa = ((fromIntegral :: Int -> Double) . floor) <$> p
  pb = ((fromIntegral :: Int -> Double) . (+1) . floor) <$> p
  interp x a b = a + smootherStep x * (b-a)
  smootherStep x = 6.0 * x**5 - 15.0 * x**4 + 10.0 * x**3

perlin :: Pattern Double
perlin = perlinWith (sig fromRational)

{- `perlin2With` is Perlin noise with a 2-dimensional input. This can be
useful for more control over how the randomness repeats (or doesn't).
@
d1 
 $ s "[supersaw:-12*32]" 
 # lpf (rangex 60 5000 $ perlin2With (cosine*2) (sine*2)) 
 # lpq 0.3
@
will generate a smooth random cutoff pattern that repeats every cycle without
any reversals or discontinuities (because the 2D path is a circle).
`perlin2` only needs one input because it uses the cycle count as the
second input.
-}
perlin2With :: Pattern Double -> Pattern Double -> Pattern Double
perlin2With x y = (/2) . (+1) $ interp2 <$> xfrac <*> yfrac <*> dota <*> dotb <*> dotc <*> dotd where
  fl = fmap ((fromIntegral :: Int -> Double) . floor)
  ce = fmap ((fromIntegral :: Int -> Double) . (+1) . floor)
  xfrac = x - fl x
  yfrac = y - fl y
  randAngle a b = 2 * pi * timeToRand (a + 0.0001 * b)
  pcos x' y' = cos $ randAngle <$> x' <*> y'
  psin x' y' = sin $ randAngle <$> x' <*> y'
  dota = pcos (fl x) (fl y) * xfrac       + psin (fl x) (fl y) * yfrac
  dotb = pcos (ce x) (fl y) * (xfrac - 1) + psin (ce x) (fl y) * yfrac
  dotc = pcos (fl x) (ce y) * xfrac       + psin (fl x) (ce y) * (yfrac - 1)
  dotd = pcos (ce x) (ce y) * (xfrac - 1) + psin (ce x) (ce y) * (yfrac - 1)
  interp2 x' y' a b c d = (1.0 - s x') * (1.0 - s y') * a  +  s x' * (1.0 - s y') * b
                          + (1.0 - s x') * s y' * c  +  s x' * s y' * d
  s x' = 6.0 * x'**5 - 15.0 * x'**4 + 10.0 * x'**3

perlin2 :: Pattern Double -> Pattern Double
perlin2 = perlin2With (sig fromRational)

{- | Randomly picks an element from the given list

@
sound "superpiano(3,8)" # note (choose ["a", "e", "g", "c"])
@

plays a melody randomly choosing one of the four notes \"a\", \"e\", \"g\", \"c\".
-}
choose :: [a] -> Pattern a
choose = chooseBy rand

chooseBy :: Pattern Double -> [a] -> Pattern a
chooseBy _ [] = silence
chooseBy f xs = ((xs !!) . floor) <$> (range 0 (fromIntegral $ length xs) f)

{- | Like @choose@, but works on an a list of tuples of values and weights

@
sound "superpiano(3,8)" # note (choose [("a",1), ("e",0.5), ("g",2), ("c",1)])
@

In the above example, the "a" and "c" notes are twice as likely to
play as the "e" note, and half as likely to play as the "g" note.

-}
wchoose :: [(a,Double)] -> Pattern a
wchoose = wchooseBy rand

wchooseBy :: Pattern Double -> [(a,Double)] -> Pattern a
wchooseBy pat pairs = match <$> pat
  where
    match r = values !! (head (findIndices (> (r*total)) cweights))
    cweights = scanl1 (+) (map snd pairs)
    values = map fst pairs
    total = sum $ map snd pairs

{- |
Similar to `degrade` `degradeBy` allows you to control the percentage of events that
are removed. For example, to remove events 90% of the time:

@
d1 $ slow 2 $ degradeBy 0.9 $ sound "[[[feel:5*8,feel*3] feel:3*8], feel*4]"
   # accelerate "-6"
   # speed "2"
@

-}

degradeBy :: Pattern Double -> Pattern a -> Pattern a
degradeBy = tParam _degradeBy

_degradeBy :: Double -> Pattern a -> Pattern a
_degradeBy x p = fmap fst $ filterValues ((> x) . snd) $ (,) <$> p <*> rand

unDegradeBy :: Pattern Double -> Pattern a -> Pattern a
unDegradeBy = tParam _unDegradeBy

_unDegradeBy :: Double -> Pattern a -> Pattern a
_unDegradeBy x p = fmap fst $ filterValues ((<= x) . snd) $ (,) <$> p <*> rand

degradeOverBy :: Int -> Pattern Double -> Pattern a -> Pattern a
degradeOverBy i tx p = unwrap $ (\x -> (fmap fst $ filterValues ((> x) . snd) $ (,) <$> p <*> fastRepeatCycles i rand)) <$> (slow (fromIntegral i) tx)


{- | Use @sometimesBy@ to apply a given function "sometimes". For example, the
following code results in `density 2` being applied about 25% of the time:

@
d1 $ sometimesBy 0.25 (density 2) $ sound "bd*8"
@

There are some aliases as well:

@
sometimes = sometimesBy 0.5
often = sometimesBy 0.75
rarely = sometimesBy 0.25
almostNever = sometimesBy 0.1
almostAlways = sometimesBy 0.9
@
-}
sometimesBy :: Pattern Double -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
sometimesBy x f p = overlay (degradeBy x p) (f $ unDegradeBy x p)

-- | @sometimes@ is an alias for sometimesBy 0.5.
sometimes :: (Pattern a -> Pattern a) -> Pattern a -> Pattern a
sometimes = sometimesBy 0.5

-- | @often@ is an alias for sometimesBy 0.75.
often :: (Pattern a -> Pattern a) -> Pattern a -> Pattern a
often = sometimesBy 0.75

-- | @rarely@ is an alias for sometimesBy 0.25.
rarely :: (Pattern a -> Pattern a) -> Pattern a -> Pattern a
rarely = sometimesBy 0.25

-- | @almostNever@ is an alias for sometimesBy 0.1
almostNever :: (Pattern a -> Pattern a) -> Pattern a -> Pattern a
almostNever = sometimesBy 0.1

-- | @almostAlways@ is an alias for sometimesBy 0.9
almostAlways :: (Pattern a -> Pattern a) -> Pattern a -> Pattern a
almostAlways = sometimesBy 0.9

never :: (Pattern a -> Pattern a) -> Pattern a -> Pattern a
never = flip const

always :: (Pattern a -> Pattern a) -> Pattern a -> Pattern a
always = id

{- | @someCyclesBy@ is a cycle-by-cycle version of @sometimesBy@. It has a
`someCycles = someCyclesBy 0.5` alias -}
someCyclesBy :: Double -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
someCyclesBy x = when test
  where test c = (timeToRand (fromIntegral c :: Double)) < x

somecyclesBy :: Double -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
somecyclesBy = someCyclesBy

someCycles :: (Pattern a -> Pattern a) -> Pattern a -> Pattern a
someCycles = someCyclesBy 0.5

somecycles :: (Pattern a -> Pattern a) -> Pattern a -> Pattern a
somecycles = someCycles

{- | `degrade` randomly removes events from a pattern 50% of the time:

@
d1 $ slow 2 $ degrade $ sound "[[[feel:5*8,feel*3] feel:3*8], feel*4]"
   # accelerate "-6"
   # speed "2"
@

The shorthand syntax for `degrade` is a question mark: `?`. Using `?`
will allow you to randomly remove events from a portion of a pattern:

@
d1 $ slow 2 $ sound "bd ~ sn bd ~ bd? [sn bd?] ~"
@

You can also use `?` to randomly remove events from entire sub-patterns:

@
d1 $ slow 2 $ sound "[[[feel:5*8,feel*3] feel:3*8]?, feel*4]"
@
-}
degrade :: Pattern a -> Pattern a
degrade = _degradeBy 0.5



{- | (The above means that `brak` is a function from patterns of any type,
to a pattern of the same type.)

Make a pattern sound a bit like a breakbeat

Example:

@
d1 $ sound (brak "bd sn kurt")
@
-}
brak :: Pattern a -> Pattern a
brak = when ((== 1) . (`mod` 2)) (((1%4) `rotR`) . (\x -> fastcat [x, silence]))

{- | Divides a pattern into a given number of subdivisions, plays the subdivisions
in order, but increments the starting subdivision each cycle. The pattern
wraps to the first subdivision after the last subdivision is played.

Example:

@
d1 $ iter 4 $ sound "bd hh sn cp"
@

This will produce the following over four cycles:

@
bd hh sn cp
hh sn cp bd
sn cp bd hh
cp bd hh sn
@

There is also `iter'`, which shifts the pattern in the opposite direction.

-}
iter :: Pattern Int -> Pattern c -> Pattern c
iter = tParam _iter

_iter :: Int -> Pattern a -> Pattern a
_iter n p = slowcat $ map (\i -> ((fromIntegral i)%(fromIntegral n)) `rotL` p) [0 .. (n-1)]

-- | @iter'@ is the same as @iter@, but decrements the starting
-- subdivision instead of incrementing it.
iter' :: Pattern Int -> Pattern c -> Pattern c
iter' = tParam _iter'

_iter' :: Int -> Pattern a -> Pattern a
_iter' n p = slowcat $ map (\i -> ((fromIntegral i)%(fromIntegral n)) `rotR` p) [0 .. (n-1)]

-- | @palindrome p@ applies @rev@ to @p@ every other cycle, so that
-- the pattern alternates between forwards and backwards.
palindrome :: Pattern a -> Pattern a
palindrome p = slowAppend p (rev p)

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
seqP ps = stack $ map (\(s, e, p) -> playFor s e ((sam s) `rotR` p)) ps

-- | Degrades a pattern over the given time.
fadeOut :: Time -> Pattern a -> Pattern a
fadeOut dur p = do slope <- _slow dur envL
                   _degradeBy slope p

-- | Alternate version to @fadeOut@ where you can provide the time from which the fade starts
fadeOutFrom :: Time -> Time -> Pattern a -> Pattern a
fadeOutFrom from dur p = do slope <- (from `rotR` _slow dur envL)
                            _degradeBy slope p


-- | 'Undegrades' a pattern over the given time.
fadeIn :: Time -> Pattern a -> Pattern a
fadeIn dur p = do slope <- _slow dur ((1-) <$> envL)
                  _degradeBy slope p

-- | Alternate version to @fadeIn@ where you can provide the time from
-- which the fade in starts
fadeInFrom :: Time -> Time -> Pattern a -> Pattern a
fadeInFrom from dur p = do slope <- (from `rotR` _slow dur ((1-) <$> envL))
                           _degradeBy slope p


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
fastspread f xs p = fastcat $ map (\x -> f x p) xs

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

-- | @wedge t p p'@ combines patterns @p@ and @p'@ by squashing the
-- @p@ into the portion of each cycle given by @t@, and @p'@ into the
-- remainer of each cycle.
wedge :: Time -> Pattern a -> Pattern a -> Pattern a
wedge t p p' = overlay (_fastGap (1/t) p) (t `rotR` _fastGap (1/(1-t)) p')

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
whenmod :: Int -> Int -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
whenmod a b = Sound.Tidal.Core.when ((\t -> (t `mod` a) >= b ))

{- |
@
superimpose f p = stack [p, f p]
@

`superimpose` plays a modified version of a pattern at the same time as the original pattern,
resulting in two patterns being played at the same time.

@
d1 $ superimpose (density 2) $ sound "bd sn [cp ht] hh"
d1 $ superimpose ((# speed "2") . (0.125 <~)) $ sound "bd sn cp hh"
@

-}
superimpose :: (Pattern a -> Pattern a) -> Pattern a -> Pattern a
superimpose f p = stack [p, f p]

{- | @trunc@ truncates a pattern so that only a fraction of the pattern is played.
The following example plays only the first quarter of the pattern:

@
d1 $ trunc 0.25 $ sound "bd sn*2 cp hh*4 arpy bd*2 cp bd*2"
@
-}
trunc :: Pattern Time -> Pattern a -> Pattern a
trunc = tParam _trunc

_trunc :: Time -> Pattern a -> Pattern a
_trunc t = compress (0, t) . zoomArc (Arc 0 t)

{- | @linger@ is similar to `trunc` but the truncated part of the pattern loops until the end of the cycle

@
d1 $ linger 0.25 $ sound "bd sn*2 cp hh*4 arpy bd*2 cp bd*2"
@
-}
linger :: Pattern Time -> Pattern a -> Pattern a
linger = tParam _linger

_linger :: Time -> Pattern a -> Pattern a
_linger n p = _fast (1/n) $ zoomArc (Arc 0 n) p

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
                           filterWhen (\t -> not $ cyclePos t >= s && cyclePos t < e) $ p
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
  stack [ filterWhen (\t -> cyclePos t >= s && cyclePos t < e) $ compress a $ f $ zoom a $ p
        , filterWhen (\t -> not $ cyclePos t >= s && cyclePos t < e) $ p
        ]

revArc :: (Time, Time) -> Pattern a -> Pattern a
revArc a = within a rev

{- | You can use the @e@ function to apply a Euclidean algorithm over a
complex pattern, although the structure of that pattern will be lost:

@
d1 $ e 3 8 $ sound "bd*2 [sn cp]"
@

In the above, three sounds are picked from the pattern on the right according
to the structure given by the `e 3 8`. It ends up picking two `bd` sounds, a
`cp` and missing the `sn` entirely.

These types of sequences use "Bjorklund's algorithm", which wasn't made for
music but for an application in nuclear physics, which is exciting. More
exciting still is that it is very similar in structure to the one of the first
known algorithms written in Euclid's book of elements in 300 BC. You can read
more about this in the paper
[The Euclidean Algorithm Generates Traditional Musical Rhythms](http://cgm.cs.mcgill.ca/~godfried/publications/banff.pdf)
by Toussaint. Some examples from this paper are included below,
including rotation in some cases.

@
- (2,5) : A thirteenth century Persian rhythm called Khafif-e-ramal.
- (3,4) : The archetypal pattern of the Cumbia from Colombia, as well as a Calypso rhythm from Trinidad.
- (3,5,2) : Another thirteenth century Persian rhythm by the name of Khafif-e-ramal, as well as a Rumanian folk-dance rhythm.
- (3,7) : A Ruchenitza rhythm used in a Bulgarian folk-dance.
- (3,8) : The Cuban tresillo pattern.
- (4,7) : Another Ruchenitza Bulgarian folk-dance rhythm.
- (4,9) : The Aksak rhythm of Turkey.
- (4,11) : The metric pattern used by Frank Zappa in his piece titled Outside Now.
- (5,6) : Yields the York-Samai pattern, a popular Arab rhythm.
- (5,7) : The Nawakhat pattern, another popular Arab rhythm.
- (5,8) : The Cuban cinquillo pattern.
- (5,9) : A popular Arab rhythm called Agsag-Samai.
- (5,11) : The metric pattern used by Moussorgsky in Pictures at an Exhibition.
- (5,12) : The Venda clapping pattern of a South African children’s song.
- (5,16) : The Bossa-Nova rhythm necklace of Brazil.
- (7,8) : A typical rhythm played on the Bendir (frame drum).
- (7,12) : A common West African bell pattern.
- (7,16,14) : A Samba rhythm necklace from Brazil.
- (9,16) : A rhythm necklace used in the Central African Republic.
- (11,24,14) : A rhythm necklace of the Aka Pygmies of Central Africa.
- (13,24,5) : Another rhythm necklace of the Aka Pygmies of the upper Sangha.
@
-}
euclid :: Pattern Int -> Pattern Int -> Pattern a -> Pattern a
euclid = tParam2 _euclid

_euclid :: Int -> Int -> Pattern a -> Pattern a
_euclid n k p = (flip const) <$> (filterValues (== True) $ fastFromList $ bjorklund (n,k)) <*> p

{- | `euclidfull n k pa pb` stacks @e n k pa@ with @einv n k pb@ -}
euclidFull :: Pattern Int -> Pattern Int -> Pattern a -> Pattern a -> Pattern a
--euclidFull pn pk pa pb = innerJoin $ (\n k -> _euclidFull n k pa pb) <$> pn <*> pk
euclidFull n k pa pb = stack [ euclid n k pa, euclidInv n k pb ]

_euclidBool :: Int -> Int -> Pattern Bool
_euclidBool n k = fastFromList $ bjorklund (n,k)

_euclidFull :: Int -> Int -> Pattern a -> Pattern a -> Pattern a
_euclidFull n k p p' = pickbool <$> (_euclidBool n k) <*> p <*> p'
  where pickbool True a _ = a
        pickbool False _ b = b

-- euclid' :: Pattern Int -> Pattern Int -> Pattern a -> Pattern a
-- euclid' = tParam2 _euclidq'

_euclid' :: Int -> Int -> Pattern a -> Pattern a
_euclid' n k p = fastcat $ map (\x -> if x then p else silence) (bjorklund (n,k))

euclidOff :: Pattern Int -> Pattern Int -> Pattern Int -> Pattern a -> Pattern a
euclidOff = tParam3 _euclidOff

eoff :: Pattern Int -> Pattern Int -> Pattern Int -> Pattern a -> Pattern a
eoff = euclidOff

_euclidOff :: Int -> Int -> Int -> Pattern a -> Pattern a
_euclidOff _ 0 _ _ = silence
_euclidOff n k s p = (((fromIntegral s)%(fromIntegral k)) `rotL`) (_euclid n k p)

euclidOffBool :: Pattern Int -> Pattern Int -> Pattern Int -> Pattern Bool -> Pattern Bool
euclidOffBool = tParam3 _euclidOffBool

_euclidOffBool :: Int -> Int -> Int -> Pattern Bool -> Pattern Bool
_euclidOffBool _ 0 _ _ = silence
_euclidOffBool n k s p = (((fromIntegral s)%(fromIntegral k)) `rotL`) ((\a b -> if b then a else not a) <$> _euclidBool n k <*> p)

distrib :: [Pattern Int] -> Pattern a -> Pattern a
distrib ps p = do p' <- sequence ps
                  _distrib p' p

_distrib :: [Int] -> Pattern a -> Pattern a
_distrib xs p = boolsToPat (foldr (distrib') (replicate (last xs) True) (reverse $ layers xs)) p
  where
    distrib' :: [Bool] -> [Bool] -> [Bool]
    distrib' [] _ = []
    distrib' (_:a) [] = False:(distrib' a [])
    distrib' (True:a) (x:b) = x:(distrib' a b)
    distrib' (False:a) (b) = False:(distrib' a b)
    layers = map bjorklund . (zip<*>tail)
    boolsToPat a b' = (flip const) <$> (filterValues (== True) $ fastFromList $ a) <*> b'

{- | `euclidInv` fills in the blanks left by `e`
 -
 @e 3 8 "x"@ -> @"x ~ ~ x ~ ~ x ~"@

 @euclidInv 3 8 "x"@ -> @"~ x x ~ x x ~ x"@
-}
euclidInv :: Pattern Int -> Pattern Int -> Pattern a -> Pattern a
euclidInv = tParam2 _euclidInv

_euclidInv :: Int -> Int -> Pattern a -> Pattern a
_euclidInv n k p = (flip const) <$> (filterValues (== False) $ fastFromList $ bjorklund (n,k)) <*> p

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

-- | @rot n p@ rotates the values in a pattern @p@ by @n@ beats to the left.
-- Example: @d1 $ every 4 (rot 2) $ slow 2 $ sound "bd hh hh hh"@
rot :: Ord a => Pattern Int -> Pattern a -> Pattern a
rot = tParam _rot

-- Calculates a whole cycle, rotates it, then constrains events to the original query arc
_rot :: Ord a => Int -> Pattern a -> Pattern a
_rot i pat = splitQueries $ pat {query = \st -> f st (query pat (st {arc = wholeCycle (arc st)}))}
  where -- TODO maybe events with the same arc (part+whole) should be
        -- grouped together in the rotation?
        f st es = constrainEvents (arc st) $ shiftValues $ sort $ defragParts es
        shiftValues es | i >= 0 =
                         zipWith (\(Event w p _) s -> Event w p s) es
                         (drop i $ cycle $ map value es)
                       | otherwise =
                         zipWith (\(Event w p _) s -> Event w p s) es
                         (drop ((length es) - (abs i)) $ cycle $ map value es)
        wholeCycle (Arc s _) = Arc (sam s) (nextSam s)
        constrainEvents :: Arc -> [Event a] -> [Event a]
        constrainEvents a es = catMaybes $ map (constrainEvent a) es
        constrainEvent :: Arc -> Event a -> Maybe (Event a)
        constrainEvent a (Event w p v) =
          do
            p' <- subArc p a
            return (Event w p' v)

-- | @segment n p@: 'samples' the pattern @p@ at a rate of @n@
-- events per cycle. Useful for turning a continuous pattern into a
-- discrete one.
segment :: Pattern Time -> Pattern a -> Pattern a
segment = tParam _segment

_segment :: Time -> Pattern a -> Pattern a
_segment n p = (_fast n $ pure (id)) <*| p

-- | @discretise@: the old (deprecated) name for 'segment'
discretise :: Pattern Time -> Pattern a -> Pattern a
discretise = segment

-- | @randcat ps@: does a @slowcat@ on the list of patterns @ps@ but
-- randomises the order in which they are played.
randcat :: [Pattern a] -> Pattern a
randcat ps = spread' (rotL) (_segment 1 $ ((%1) . fromIntegral) <$> (irand (length ps) :: Pattern Int)) (slowcat ps)

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
fit :: Int -> [a] -> Pattern Int -> Pattern a
fit perCycle xs p = (xs !!!) <$> (p {query = \st -> map ((\e -> (fmap (+ (pos e)) e))) (query p st)})
  where pos e = perCycle * (floor $ start $ part e)

permstep :: RealFrac b => Int -> [a] -> Pattern b -> Pattern a
permstep nSteps things p = unwrap $ (\n -> fastFromList $ concatMap (\x -> replicate (fst x) (snd x)) $ zip (ps !! (floor (n * (fromIntegral $ (length ps - 1))))) things) <$> (_segment 1 p)
      where ps = permsort (length things) nSteps
            deviance avg xs = sum $ map (abs . (avg-) . fromIntegral) xs
            permsort n total = map fst $ sortBy (comparing snd) $ map (\x -> (x,deviance (fromIntegral total / (fromIntegral n :: Double)) x)) $ perms n total
            perms 0 _ = []
            perms 1 n = [[n]]
            perms n total = concatMap (\x -> map (x:) $ perms (n-1) (total-x)) [1 .. (total-(n-1))]

-- | @struct a b@: structures pattern @b@ in terms of the pattern of
-- boolean values @a@. Only @True@ values in the boolean pattern are
-- used.
struct :: Pattern Bool -> Pattern a -> Pattern a
struct ps pv = filterJust $ (\a b -> if a then Just b else Nothing ) <$> ps <*| pv

-- | @substruct a b@: similar to @struct@, but each event in pattern @a@ gets replaced with pattern @b@, compressed to fit the timespan of the event.
substruct :: Pattern String -> Pattern b -> Pattern b
substruct s p = p {query = f}
  where f st =
          concatMap (\a' -> queryArc (compressArcTo a' p) a') $ (map whole $ query s st)

randArcs :: Int -> Pattern [Arc]
randArcs n =
  do rs <- mapM (\x -> (pure $ (toRational x)/(toRational n)) <~ choose [1 :: Int,2,3]) [0 .. (n-1)]
     let rats = map toRational rs
         total = sum rats
         pairs = pairUp $ accumulate $ map ((/total)) rats
     return $ pairs
       where pairUp [] = []
             pairUp xs = (Arc 0 (head xs)):(pairUp' xs)
             pairUp' [] = []
             pairUp' (_:[]) = []
             pairUp' (a:_:[]) = [Arc a 1]
             pairUp' (a:b:xs) = (Arc a b):(pairUp' (b:xs))

-- TODO - what does this do? Something for @stripe@ ..
randStruct :: Int -> Pattern Int
randStruct n = splitQueries $ Pattern {nature = Digital, query = f}
  where f st = map (\(a,b,c) -> (Event a (fromJust b) c)) $ filter (\(_,x,_) -> isJust x) $ as
          where as = map (\(i, (Arc s' e')) ->
                    (((Arc (s' + sam s) (e' + sam s)),
                       subArc (Arc s e) (Arc (s' + sam s) (e' + sam s)), i))) $
                      enumerate $ value $ head $
                      queryArc (randArcs n) (Arc (sam s) (nextSam s))
                (Arc s e) = arc st

-- TODO - what does this do?
substruct' :: Pattern Int -> Pattern a -> Pattern a
substruct' s p = p {query = \st -> concatMap (\(Event a' _ i) -> queryArc (compressArcTo a' (inside (pure $ 1/toRational(length (queryArc s (Arc (sam (start $ arc st)) (nextSam (start $ arc st)))))) (rotR (toRational i)) p)) a') (query s st)}

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
lindenmayer 1 r (c:cs) = (fromMaybe [c] $ lookup c $ parseLMRule' r)
                         ++ (lindenmayer 1 r cs)
lindenmayer n r s = iterate (lindenmayer 1 r) s !! n

{- | @lindenmayerI@ converts the resulting string into a a list of integers
with @fromIntegral@ applied (so they can be used seamlessly where floats or
rationals are required) -}
lindenmayerI :: Num b => Int -> String -> String -> [b]
lindenmayerI n r s = fmap fromIntegral $ fmap digitToInt $ lindenmayer n r s

-- support for fit'
unwrap' :: Pattern (Pattern a) -> Pattern a
unwrap' pp = pp {query = \st -> query (stack $ map scalep (query pp st)) st}
  where scalep ev = compressArc (whole ev) $ value ev

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
mask maskpat pat = filterJust $ toMaybe <$> pat'
  where pat' = matchManyToOne (flip const) maskpat pat
        toMaybe (True, a) = Just a
        toMaybe (False, _) = Nothing

{-
mask :: Pattern Bool -> Pattern b -> Pattern b
-- TODO - should that be part or whole?
mask pa pb = pb {query = \st -> concat [filterOns (subArc (arc st) $ part i) (query pb st) | i <- query pa st]}
     where filterOns Nothing _ = []
           filterOns (Just a) es = filter (onsetIn a) es
-}

-- | TODO: refactor towards union
enclosingArc :: [Arc] -> Arc
enclosingArc [] = (Arc 0 1)
enclosingArc as = Arc (minimum (map start as)) (maximum (map stop as))

stretch :: Pattern a -> Pattern a
-- TODO - should that be whole or part?
stretch p = splitQueries $ p {query = q}
  where q st = query (zoomArc (enclosingArc $ map whole $ query p (st {arc = (Arc (sam s) (nextSam s))})) p) st
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
fit' cyc n from to p = unwrap' $ fit n mapMasks to
  where mapMasks = [stretch $ mask (const True <$> filterValues (== i) from') p'
                     | i <- [0..n-1]]
        p' = density cyc $ p
        from' = density cyc $ from

{-| @chunk n f p@ treats the given pattern @p@ as having @n@ chunks, and applies the function @f@ to one of those sections per cycle, running from left to right.

@
d1 $ chunk 4 (density 4) $ sound "cp sn arpy [mt lt]"
@
-}
chunk :: Int -> (Pattern b -> Pattern b) -> Pattern b -> Pattern b
chunk n f p = cat [withinArc (Arc (i%(fromIntegral n)) ((i+1)%(fromIntegral n))) f p | i <- [0..(fromIntegral n)-1]]

{-
chunk n f p = do i <- _slow (toRational n) $ run (fromIntegral n)
                 within (i%(fromIntegral n),(i+)1%(fromIntegral n)) f p
-}

-- deprecated (renamed to chunk)
runWith :: Int -> (Pattern b -> Pattern b) -> Pattern b -> Pattern b
runWith = chunk

{-| @chunk'@ works much the same as `chunk`, but runs from right to left.
-}
chunk' :: Integral a => a -> (Pattern b -> Pattern b) -> Pattern b -> Pattern b
chunk' n f p = do i <- _slow (toRational n) $ rev $ run (fromIntegral n)
                  withinArc (Arc (i%(fromIntegral n)) ((i+)1%(fromIntegral n))) f p

-- deprecated (renamed to chunk')
runWith' :: Integral a => a -> (Pattern b -> Pattern b) -> Pattern b -> Pattern b
runWith' = chunk'

inside :: Pattern Time -> (Pattern a1 -> Pattern a) -> Pattern a1 -> Pattern a
inside n f p = density n $ f (slow n p)

outside :: Pattern Time -> (Pattern a1 -> Pattern a) -> Pattern a1 -> Pattern a
outside n = inside (1/n)

loopFirst :: Pattern a -> Pattern a
loopFirst p = splitQueries $ p {query = f}
  where f st = map
          (\(Event w p' v) ->
             (Event (plus w) (plus p') v)) $
          query p (st {arc = minus $ arc st})
          where minus = fmap (subtract (sam s))
                plus = fmap (+ (sam s))
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
toScale' o s = fmap noteInScale
  where octave x = x `div` length s
        noteInScale x = (s !!! x) + (fromIntegral $ o * octave x)

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
cycleChoose::[a] -> Pattern a
cycleChoose xs = Pattern {nature = Digital, query = q}
  where q (State {arc = Arc s e}) = [Event (Arc s e) (Arc s e) (xs!!(floor $ dlen*(ctrand s)))]
        dlen = fromIntegral $ length xs
        ctrand s = (timeToRand :: Time -> Double) $ fromIntegral $ (floor :: Time -> Int) $ sam s

{- | `shuffle n p` evenly divides one cycle of the pattern `p` into `n` parts,
and returns a random permutation of the parts each cycle.  For example,
`shuffle 3 "a b c"` could return `"a b c"`, `"a c b"`, `"b a c"`, `"b c a"`,
`"c a b"`, or `"c b a"`.  But it will **never** return `"a a a"`, because that
is not a permutation of the parts.
-}
shuffle::Int -> Pattern a -> Pattern a
shuffle n = fit' 1 n (_run n) randpat
  where randpat = Pattern {nature = Digital,
                           query = \(State {arc = Arc s e}) -> queryArc (p $ sam s) (Arc s e)
                          }
        p c = fastFromList $ map snd $ sort $ zip
              [timeToRand (c+i/n') | i <- [0..n'-1]] [0..n-1]
        n' :: Time
        n' = fromIntegral n

{- | `scramble n p` is like `shuffle` but randomly selects from the parts
of `p` instead of making permutations.
For example, `scramble 3 "a b c"` will randomly select 3 parts from
`"a"` `"b"` and `"c"`, possibly repeating a single part.
-}
scramble::Int -> Pattern a -> Pattern a
scramble n = fit' 1 n (_run n) (_fast (fromIntegral n) $
  liftA2 (+) (pure 0) $ irand n)

ur :: Time -> Pattern String -> [(String, Pattern a)] -> [(String, Pattern a -> Pattern a)] -> Pattern a
ur t outer_p ps fs = _slow t $ unwrap $ adjust <$> (timedValues $ (getPat . split) <$> outer_p)
  where split s = wordsBy (==':') s
        getPat (s:xs) = (match s, transform xs)
        -- TODO - check this really can't happen..
        getPat _ = error "can't happen?"
        match s = fromMaybe silence $ lookup s ps'
        ps' = map (fmap (_fast t)) ps
        adjust (a, (p, f)) = f a p
        transform (x:_) a = transform' x a
        transform _ _ = id
        transform' str (Arc s e) p = s `rotR` (inside (pure $ 1/(e-s)) (matchF str) p)
        matchF str = fromMaybe id $ lookup str fs
        timedValues = withEvent (\(Event a a' v) -> Event a a' (a,v))

inhabit :: [(String, Pattern a)] -> Pattern String -> Pattern a
inhabit ps p = unwrap' $ (\s -> fromMaybe silence $ lookup s ps) <$> p

{- | @spaceOut xs p@ repeats a pattern @p@ at different durations given by the list of time values in @xs@ -}
spaceOut :: [Time] -> Pattern a -> Pattern a
spaceOut xs p = _slow (toRational $ sum xs) $ stack $ map (\a -> compressArc a p) $ spaceArcs
  where markOut :: Time -> [Time] -> [Arc]
        markOut _ [] = []
        markOut offset (x:xs') = (Arc offset (offset+x)):(markOut (offset+x) xs')
        spaceArcs = map (\(Arc a b) -> (Arc (a/s) (b/s))) $ markOut 0 xs
        s = sum xs

-- | @flatpat@ takes a Pattern of lists and pulls the list elements as
-- separate Events
flatpat :: Pattern [a] -> Pattern a
flatpat p = p {query = \st -> (concatMap (\(Event b b' xs) -> map (\x -> (Event b b' x)) xs) $ query p st)}

-- | @layer@ takes a Pattern of lists and pulls the list elements as
-- separate Events
layer :: [a -> Pattern b] -> a -> Pattern b
layer fs p = stack $ map ($ p) fs

-- | @arpeggiate@ finds events that share the same timespan, and spreads
-- them out during that timespan, so for example @arpeggiate "[bd,sn]"@
-- gets turned into @"bd sn"@. Useful for creating arpeggios/broken chords.
arpeggiate :: Pattern a -> Pattern a
arpeggiate p = withEvents munge p
  where munge es = concatMap spreadOut (groupBy (\a b -> whole a == whole b) es)
        spreadOut xs = mapMaybe (\(n, x) -> shiftIt n (length xs) x) $ enumerate xs
        shiftIt n d (Event (Arc s e) a' v) =
          do
            a'' <- subArc (Arc newS newE) a'
            return (Event (Arc newS newE) a'' v)
          where newS = s + (dur*(fromIntegral n))
                newE = newS + dur
                dur = (e - s) / (fromIntegral d)

-- | Shorthand alias for arpeggiate
arpg :: Pattern a -> Pattern a
arpg = arpeggiate

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
ply :: Pattern Int -> Pattern a -> Pattern a
ply = tParam _ply

_ply :: Int -> Pattern a -> Pattern a
_ply n p = arpeggiate $ stack (replicate n p)

-- Uses the first (binary) pattern to switch between the following two
-- patterns.
sew :: Pattern Bool -> Pattern a -> Pattern a -> Pattern a
sew stitch p1 p2 = overlay (const <$> p1 <*| a) (const <$> p2 <*| b)
  where a = filterValues (id) stitch
        b = filterValues (not . id) stitch


stutter :: Integral i => i -> Time -> Pattern a -> Pattern a
stutter n t p = stack $ map (\i -> (t * (fromIntegral i)) `rotR` p) [0 .. (n-1)]

echo, triple, quad, double :: Time -> Pattern a -> Pattern a
echo   = stutter (2 :: Int)
triple = stutter (3 :: Int)
quad   = stutter (4 :: Int)
double = echo

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
  :: (Pattern ControlMap -> Pattern ControlMap)
     -> Pattern ControlMap -> Pattern ControlMap
jux = juxBy 1
juxcut
  :: (Pattern ControlMap -> Pattern ControlMap)
     -> Pattern ControlMap -> Pattern ControlMap
juxcut f p = stack [p     # P.pan (pure 0) # P.cut (pure (-1)),
                    f $ p # P.pan (pure 1) # P.cut (pure (-2))
                   ]

juxcut' :: [t -> Pattern ControlMap] -> t -> Pattern ControlMap
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
jux' :: [t -> Pattern ControlMap] -> t -> Pattern ControlMap
jux' fs p = stack $ map (\n -> ((fs !! n) p) |+ P.pan (pure $ fromIntegral n / fromIntegral l)) [0 .. l-1]
  where l = length fs

-- | Multichannel variant of `jux`, _not sure what it does_
jux4
  :: (Pattern ControlMap -> Pattern ControlMap)
     -> Pattern ControlMap -> Pattern ControlMap
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
     -> (Pattern ControlMap -> Pattern ControlMap)
     -> Pattern ControlMap
     -> Pattern ControlMap
juxBy n f p = stack [p |+ P.pan 0.5 |- P.pan (n/2), f $ p |+ P.pan 0.5 |+ P.pan (n/2)]

pick :: String -> Int -> String
pick name n = name ++ ":" ++ (show n)

-- samples "jvbass [~ latibro] [jvbass [latibro jvbass]]" ((1%2) `rotL` slow 6 "[1 6 8 7 3]")

samples :: Applicative f => f String -> f Int -> f String
samples p p' = pick <$> p <*> p'

samples' :: Applicative f => f String -> f Int -> f String
samples' p p' = (flip pick) <$> p' <*> p

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
               | otherwise = stack $ map (\(i, p') -> p' # (((fromIntegral i) % l) `rotL` p)) (zip [0::Int ..] ps)
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
range fromP toP p = do
  from <- fromP
  to <- toP
  _range from to p

_range :: (Functor f, Num b) => b -> b -> f b -> f b
_range from to p = ((+ from) . (* (to-from))) <$> p

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
steps = stack . map (\(a,b) -> step a b)

-- | like `step`, but allows you to specify an array of strings to use for 0,1,2...
step' :: [String] -> String -> Pattern String
step' ss cs = fastcat $ map f cs
    where f c | c == 'x' = pure $ head ss
              | isDigit c = pure $ ss!!(digitToInt c)
              | otherwise = silence


ghost'' :: Time -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
ghost'' a f p = superimpose (((a*2.5) `rotR`) . f) $ superimpose (((a*1.5) `rotR`) . f) $ p

ghost' :: Time -> Pattern ControlMap -> Pattern ControlMap
ghost' a p = ghost'' a ((|*| P.gain (pure 0.7)) . (|> P.end (pure 0.2)) . (|*| P.speed (pure 1.25))) p

ghost :: Pattern ControlMap -> Pattern ControlMap
ghost p = ghost' 0.125 p

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
    weft = concatMap (\_ -> [[0..n-1],(reverse [0..n-1])]) [0 .. (n `div` 2) - 1]
    warp = transpose weft
    thread xs p'' = _slow (n%1) $ fastcat $ map (\i -> zoomArc (Arc (i%n) ((i+1)%n)) p'') (concat xs)
    weftP = thread weft p'
    warpP = thread warp p
    maskedWeft = mask (every 2 rev $ _fast ((n)%2) $ fastCat [silence, pure True]) weftP
    maskedWarp = mask (every 2 rev $ _fast ((n)%2) $ fastCat [pure True, silence]) warpP

_select :: Double -> [Pattern a] -> Pattern a
_select f ps =  ps !! (floor $ (max 0 $ min 1 f) * (fromIntegral $ length ps - 1))

-- | chooses between a list of patterns, using a pattern of floats (from 0-1)
select :: Pattern Double -> [Pattern a] -> Pattern a
select = tParam _select


-- | @contrast p f f' p'@ splits controlpattern @p'@ in two, applying
-- the function @f@ to one and @f'@ to the other. This depends on
-- whether events in it contains values matching with those in @p@.
-- For example in @contrast (n "1") (# crush 3) (# vowel "a") $ n "0 1" # s "bd sn" # speed 3@,
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
            f (VS s, VS e) (VS v) = v == s && v == e
            f _ _ = False

-- | Like @contrast@, but one function is given, and applied to events with matching controls.
fix :: (ControlPattern -> ControlPattern) -> ControlPattern -> ControlPattern -> ControlPattern
fix f = contrast f id

-- | Like @contrast@, but one function is given, and applied to events
-- with controls which don't match.
unfix :: (ControlPattern -> ControlPattern) -> ControlPattern -> ControlPattern -> ControlPattern
unfix f = contrast id f

fixRange :: (ControlPattern -> Pattern ControlMap)
            -> Pattern (Map.Map String (Value, Value))
            -> ControlPattern
            -> Pattern ControlMap
fixRange f = contrastRange f id

unfixRange :: (ControlPattern -> Pattern ControlMap)
              -> Pattern (Map.Map String (Value, Value))
              -> ControlPattern
              -> Pattern ControlMap
unfixRange f = contrastRange id f

-- | limit values in a Pattern (or other Functor) to n equally spaced
-- divisions of 1.
quantise :: (Functor f, RealFrac b) => b -> f b -> f b
quantise n = fmap ((/n) . (fromIntegral :: RealFrac b => Int -> b) . floor . (*n))

-- | Inverts all the values in a boolean pattern
inv :: Functor f => f Bool -> f Bool
inv = (not <$>)

-- | Serialises a pattern so there's only one event playing at any one
-- time, making it 'monophonic'. Events which start/end earlier are given priority.
mono :: Pattern a -> Pattern a
mono p = Pattern Digital $ \(State a cm) -> flatten $ (query p) (State a cm) where
  flatten :: [Event a] -> [Event a]
  flatten = catMaybes . map constrainPart . truncateOverlaps . sortBy (comparing whole)
  truncateOverlaps [] = []
  truncateOverlaps (e:es) = e:(truncateOverlaps $ catMaybes $ map (snip e) es)
  snip a b | (start $ whole b) >= (stop $ whole a) = Just b
           | (stop $ whole b) <= (stop $ whole a) = Nothing
           | otherwise = Just b {whole = Arc (stop $ whole a) (stop $ whole b)}
  constrainPart :: Event a -> Maybe (Event a)
  constrainPart e = do a <- subArc (whole e) (part e)
                       return $ e {part = a}

-- serialize the given pattern
-- find the middle of the query's arc and use that to query the serialized pattern. We should get either no events or a single event back
-- if we don't get any events, return nothing
-- if we get an event, get the stop of its arc, and use that to query the serialized pattern, to see if there's an adjoining event
-- if there isn't, return the event as-is.
-- if there is, check where we are in the 'whole' of the event, and use that to tween between the values of the event and the next event
-- smooth :: Pattern Double -> Pattern Double

smooth :: Fractional a => Pattern a -> Pattern a
smooth p = Pattern Analog $ \st@(State a cm) -> tween st a $ query monoP (State (midArc a) cm)
  where
    midArc a = Arc (mid (start a, stop a)) (mid (start a, stop a))
    tween _ _ [] = []
    tween st queryA (e:_) = maybe [e {whole = queryA, part = queryA}] (tween' queryA) (nextV st)
      where aStop = Arc (wholeStop e) (wholeStop e)
            nextEs st' = query monoP (st' {arc = aStop})
            nextV st' | null (nextEs st') = Nothing
                      | otherwise = Just $ value (head (nextEs st'))
            tween' queryA' v =
              [ Event
                { whole = queryA'
                , part = queryA'
                , value = value e + ((v - value e) * pc)}
              ]
            pc | (delta' $ whole e) == 0 = 0
               | otherwise = fromRational $ (eventPartStart e - wholeStart e) / (delta' $ whole e)
            delta' a = stop a - start a
    monoP = mono p
