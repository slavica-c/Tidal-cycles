{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, OverloadedStrings #-}

module Sound.Tidal.Control where

import           Prelude hiding ((<*), (*>))

import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, fromJust)
import Data.Ratio

import Sound.Tidal.Pattern
import Sound.Tidal.Core
import Sound.Tidal.UI
import qualified Sound.Tidal.Params as P
import Sound.Tidal.Utils
import Sound.Tidal.ParseBP (Parseable, Enumerable, parseBP_E)

{- | `spin` will "spin" a layer up a pattern the given number of times,
with each successive layer offset in time by an additional `1/n` of a
cycle, and panned by an additional `1/n`. The result is a pattern that
seems to spin around. This function works best on multichannel
systems.

@
d1 $ slow 3 $ spin 4 $ sound "drum*3 tabla:4 [arpy:2 ~ arpy] [can:2 can:3]"
@
-}
spin :: Pattern Int -> ControlPattern -> ControlPattern
spin = tParam _spin

_spin :: Int -> ControlPattern -> ControlPattern
_spin copies p =
  stack $ map (\i -> let offset = toInteger i % toInteger copies in
                     offset `rotL` p
                     # P.pan (pure $ fromRational offset)
              )
          [0 .. (copies - 1)]



{- | `chop` granualizes every sample in place as it is played, turning a pattern of samples into a pattern of sample parts. Use an integer value to specify how many granules each sample is chopped into:

@
d1 $ chop 16 $ sound "arpy arp feel*4 arpy*4"
@

Different values of `chop` can yield very different results, depending
on the samples used:


@
d1 $ chop 16 $ sound (samples "arpy*8" (run 16))
d1 $ chop 32 $ sound (samples "arpy*8" (run 16))
d1 $ chop 256 $ sound "bd*4 [sn cp] [hh future]*2 [cp feel]"
@
-}

chop :: Pattern Int -> ControlPattern -> ControlPattern
chop = tParam _chop

chopArc :: Arc -> Int -> [Arc]
chopArc (Arc s e) n = map (\i -> (Arc (s + (e-s)*(fromIntegral i/fromIntegral n)) (s + (e-s)*((fromIntegral $ i+1)/fromIntegral n)))) [0 .. n-1]

_chop :: Int -> ControlPattern -> ControlPattern
_chop n p = withEvents (concatMap chopEvent) p
  where -- for each part,
        chopEvent :: Event ControlMap -> [Event ControlMap]
        chopEvent (Event w p' v) = map (\a -> chomp v (length $ chopArc w n) a) $ arcs w p'
        -- cut whole into n bits, and number them
        arcs w' p' = numberedArcs p' $ chopArc w' n
        -- each bit is a new whole, with part that's the intersection of old part and new whole
        -- (discard new parts that don't intersect with the old part)
        numberedArcs :: Arc -> [Arc] -> [(Int, (Arc, Arc))]
        numberedArcs p' as = map ((fromJust <$>) <$>) $ filter (isJust . snd . snd) $ enumerate $ map (\a -> (a, subArc p' a)) as
        -- begin set to i/n, end set to i+1/n
        -- if the old event had a begin and end, then multiply the new
        -- begin and end values by the old difference (end-begin), and
        -- add the old begin
        chomp :: ControlMap -> Int -> (Int, (Arc, Arc)) -> Event ControlMap
        chomp v n' (i, (w,p')) = Event w p' (Map.insert "begin" (VF b') $ Map.insert "end" (VF e') v)
          where b = fromMaybe 0 $ do v' <- Map.lookup "begin" v
                                     getF v'
                e = fromMaybe 1 $ do v' <- Map.lookup "end" v
                                     getF v'
                d = e-b
                b' = (((fromIntegral i)/(fromIntegral n')) * d) + b
                e' = (((fromIntegral $ i+1)/(fromIntegral n')) * d) + b

{-
-- A simpler definition than the above, but this version doesn't chop
-- with multiple chops, and only works with a single 'pure' event..
_chop' :: Int -> ControlPattern -> ControlPattern
_chop' n p = begin (fromList begins) # end (fromList ends) # p
  where step = 1/(fromIntegral n)
        begins = [0,step .. (1-step)]
        ends = (tail begins) ++ [1]
-}


{- | Striate is a kind of granulator, for example:

@
d1 $ striate 3 $ sound "ho ho:2 ho:3 hc"
@

This plays the loop the given number of times, but triggering
progressive portions of each sample. So in this case it plays the loop
three times, the first time playing the first third of each sample,
then the second time playing the second third of each sample, etc..
With the highhat samples in the above example it sounds a bit like
reverb, but it isn't really.

You can also use striate with very long samples, to cut it into short
chunks and pattern those chunks. This is where things get towards
granular synthesis. The following cuts a sample into 128 parts, plays
it over 8 cycles and manipulates those parts by reversing and rotating
the loops.

@
d1 $  slow 8 $ striate 128 $ sound "bev"
@
-}

striate :: Pattern Int -> ControlPattern -> ControlPattern
striate = tParam _striate

_striate :: Int -> ControlPattern -> ControlPattern
_striate n p = fastcat $ map (\i -> offset i) [0 .. n-1]
  where offset i = (mergePlayRange ((fromIntegral i / fromIntegral n), (fromIntegral (i+1) / fromIntegral n))) <$> p

mergePlayRange :: (Double, Double) -> ControlMap -> ControlMap
mergePlayRange (b,e) cm = Map.insert "begin" (VF $ (b*d')+b') $ Map.insert "end" (VF $ (e*d')+b') $ cm
  where b' = fromMaybe 0 $ Map.lookup "begin" cm >>= getF
        e' = fromMaybe 1 $ Map.lookup "end" cm >>= getF
        d' = e' - b'


{-|
The `striateBy` function is a variant of `striate` with an extra
parameter, which specifies the length of each part. The `striateBy`
function still scans across the sample over a single cycle, but if
each bit is longer, it creates a sort of stuttering effect. For
example the following will cut the bev sample into 32 parts, but each
will be 1/16th of a sample long:

@
d1 $ slow 32 $ striateBy 32 (1/16) $ sound "bev"
@

Note that `striate` uses the `begin` and `end` parameters
internally. This means that if you're using `striate` (or `striateBy`)
you probably shouldn't also specify `begin` or `end`. -}
striateBy :: Pattern Int -> Pattern Double -> ControlPattern -> ControlPattern
striateBy = tParam2 _striateBy

-- Old name for striateBy, here as a deprecated alias for now.
striate' :: Pattern Int -> Pattern Double -> ControlPattern -> ControlPattern
striate' = striateBy

_striateBy :: Int -> Double -> ControlPattern -> ControlPattern
_striateBy n f p = fastcat $ map (\i -> offset (fromIntegral i)) [0 .. n-1]
  where offset i = p # P.begin (pure (slot * i) :: Pattern Double) # P.end (pure ((slot * i) + f) :: Pattern Double)
        slot = (1 - f) / (fromIntegral n)



{- | `gap` is similar to `chop` in that it granualizes every sample in place as it is played,
but every other grain is silent. Use an integer value to specify how many granules
each sample is chopped into:

@
d1 $ gap 8 $ sound "jvbass"
d1 $ gap 16 $ sound "[jvbass drum:4]"
@-}

gap :: Pattern Int -> ControlPattern -> ControlPattern
gap = tParam _gap

_gap :: Int -> ControlPattern -> ControlPattern 
_gap n p = (_fast (toRational n) $ cat [pure 1, silence]) |>| ( _chop n p)

{- |
`weave` applies a function smoothly over an array of different patterns. It uses an `OscPattern` to
apply the function at different levels to each pattern, creating a weaving effect.

@
d1 $ weave 3 (shape $ sine1) [sound "bd [sn drum:2*2] bd*2 [sn drum:1]", sound "arpy*8 ~"]
@
-}
weave :: Time -> ControlPattern -> [ControlPattern] -> ControlPattern
weave t p ps = weave' t p (map (\x -> (x #)) ps)


{- | `weaveWith` is similar in that it blends functions at the same time at different amounts over a pattern:

@
d1 $ weaveWith 3 (sound "bd [sn drum:2*2] bd*2 [sn drum:1]") [density 2, (# speed "0.5"), chop 16]
@
-}
weaveWith :: Time -> Pattern a -> [Pattern a -> Pattern a] -> Pattern a
weaveWith t p fs | l == 0 = silence
              | otherwise = _slow t $ stack $ map (\(i, f) -> (fromIntegral i % l) `rotL` (_fast t $ f (_slow t p))) (zip [0 :: Int ..] fs)
  where l = fromIntegral $ length fs

weave' :: Time -> Pattern a -> [Pattern a -> Pattern a] -> Pattern a
weave' = weaveWith

{- |
(A function that takes two ControlPatterns, and blends them together into
a new ControlPattern. An ControlPattern is basically a pattern of messages to
a synthesiser.)

Shifts between the two given patterns, using distortion.

Example:

@
d1 $ interlace (sound  "bd sn kurt") (every 3 rev $ sound  "bd sn:2")
@
-}
interlace :: ControlPattern -> ControlPattern -> ControlPattern
interlace a b = weave 16 (P.shape $ (sine * 0.9)) [a, b]

{-
{- | Just like `striate`, but also loops each sample chunk a number of times specified in the second argument.
The primed version is just like `striateBy`, where the loop count is the third argument. For example:

@
d1 $ striateL' 3 0.125 4 $ sound "feel sn:2"
@

Like `striate`, these use the `begin` and `end` parameters internally, as well as the `loop` parameter for these versions.
-}
striateL :: Pattern Int -> Pattern Int -> ControlPattern -> ControlPattern
striateL = tParam2 _striateL

striateL' :: Pattern Int -> Pattern Double -> Pattern Int -> ControlPattern -> ControlPattern
striateL' = tParam3 _striateL'

_striateL :: Int -> Int -> ControlPattern -> ControlPattern
_striateL n l p = _striate n p # loop (pure $ fromIntegral l)
_striateL' n f l p = _striateBy n f p # loop (pure $ fromIntegral l)


en :: [(Int, Int)] -> Pattern String -> Pattern String
en ns p = stack $ map (\(i, (k, n)) -> _e k n (samples p (pure i))) $ enumerate ns

-}

slice :: Pattern Int -> Pattern Int -> ControlPattern -> ControlPattern
slice pN pI p = P.begin b # P.end e # p
  where b = (\i n -> (div' i n)) <$> pI <*| pN
        e = (\i n -> (div' i n) + (div' 1 n)) <$> pI <*| pN
        div' num den = fromIntegral (num `mod` den) / fromIntegral den

_slice :: Int -> Int -> ControlPattern -> ControlPattern
_slice n i p =
      p
      # P.begin (pure $ fromIntegral i / fromIntegral n)
      # P.end (pure $ fromIntegral (i+1) / fromIntegral n)

randslice :: Pattern Int -> ControlPattern -> ControlPattern
randslice = tParam $ \n p -> innerJoin $ (\i -> _slice n i p) <$> irand n

{- |
`loopAt` makes a sample fit the given number of cycles. Internally, it
works by setting the `unit` parameter to "c", changing the playback
speed of the sample with the `speed` parameter, and setting setting
the `density` of the pattern to match.

@
d1 $ loopAt 4 $ sound "breaks125"
d1 $ juxBy 0.6 (|* speed "2") $ slowspread (loopAt) [4,6,2,3] $ chop 12 $ sound "fm:14"
@
-}
loopAt :: Pattern Time -> ControlPattern -> ControlPattern
loopAt n p = slow n p |* P.speed (fromRational <$> (1/n)) # P.unit (pure "c")

hurry :: Pattern Rational -> ControlPattern -> ControlPattern
hurry x = (|* P.speed (fromRational <$> x)) . fast x

{- | Smash is a combination of `spread` and `striate` - it cuts the samples
into the given number of bits, and then cuts between playing the loop
at different speeds according to the values in the list.

So this:

@
d1 $ smash 3 [2,3,4] $ sound "ho ho:2 ho:3 hc"
@

Is a bit like this:

@
d1 $ spread (slow) [2,3,4] $ striate 3 $ sound "ho ho:2 ho:3 hc"
@

This is quite dancehall:

@
d1 $ (spread' slow "1%4 2 1 3" $ spread (striate) [2,3,4,1] $ sound
"sn:2 sid:3 cp sid:4")
  # speed "[1 2 1 1]/2"
@
-}

smash :: Pattern Int -> [Pattern Time] -> ControlPattern -> Pattern ControlMap
smash n xs p = slowcat $ map (\x -> slow x p') xs
  where p' = striate n p

{- | an altenative form to `smash` is `smash'` which will use `chop` instead of `striate`.
-}
smash' :: Int -> [Pattern Time] -> ControlPattern -> Pattern ControlMap
smash' n xs p = slowcat $ map (\x -> slow x p') xs
  where p' = _chop n p


{- | Stut applies a type of delay to a pattern. It has three parameters,
which could be called depth, feedback and time. Depth is an integer
and the others floating point. This adds a bit of echo:

@
d1 $ stut 4 0.5 0.2 $ sound "bd sn"
@

The above results in 4 echos, each one 50% quieter than the last,
with 1/5th of a cycle between them. It is possible to reverse the echo:

@
d1 $ stut 4 0.5 (-0.2) $ sound "bd sn"
@
-}

stut :: Pattern Integer -> Pattern Double -> Pattern Rational -> ControlPattern -> ControlPattern
stut = tParam3 _stut

_stut :: Integer -> Double -> Rational -> ControlPattern -> ControlPattern
_stut count feedback time p = stack (p:(map (\x -> (((x%count)*time) `rotR` (p |* P.gain (pure $ scalegain (fromIntegral x))))) [1..(count-1)]))
  where scalegain x
          = ((+feedback) . (*(1-feedback)) . (/(fromIntegral count)) . ((fromIntegral count)-)) x

{- | Instead of just decreasing volume to produce echoes, @stut'@ allows to apply a function for each step and overlays the result delayed by the given time.

@
d1 $ stut' 2 (1%3) (# vowel "{a e i o u}%2") $ sound "bd sn"
@

In this case there are two _overlays_ delayed by 1/3 of a cycle, where each has the @vowel@ filter applied.
-}
stutWith :: Pattern Int -> Pattern Time -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
stutWith n t f p = unwrap $ (\a b -> _stutWith a b f p) <$> n <*> t

_stutWith :: (Num n, Ord n) => n -> Time -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
_stutWith count steptime f p | count <= 0 = p
                          | otherwise = overlay (f (steptime `rotR` _stutWith (count-1) steptime f p)) p

-- | The old name for stutWith
stut' :: Pattern Int -> Pattern Time -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
stut' = stutWith

cI :: String -> Pattern Int
cI s = Pattern Analog $ \(State a m) -> maybe [] (f a) $ Map.lookup s m
  where f a (VI v) = [Event a a v]
        f a (VF v) = [Event a a (floor v)]
        f a (VS v) = maybe [] (\v' -> [Event a a v']) (readMaybe v)

_cX :: (Arc -> Value -> [Event a]) -> [a] -> String -> Pattern a
_cX f ds s = Pattern Analog $
               \(State a m) -> maybe (map (\d -> (Event a a d)) ds) (f a) $ Map.lookup s m

_cF :: [Double] -> String -> Pattern Double
_cF = _cX f
  where f a (VI v) = [Event a a (fromIntegral v)]
        f a (VF v) = [Event a a v]
        f a (VS v) = maybe [] (\v' -> [Event a a v']) (readMaybe v)

cF :: Double -> String -> Pattern Double
cF d = _cF [d]
cF0 :: String -> Pattern Double
cF0 = _cF [0]
cF_ :: String -> Pattern Double
cF_ = _cF []

cT :: Time -> String -> Pattern Time
cT d = (toRational <$>) . cF (fromRational d)
cT0 :: String -> Pattern Time
cT0 = (toRational <$>) . cF0
cT_ :: String -> Pattern Time
cT_ = (toRational <$>) . cF_


cR :: Time -> String -> Pattern Rational
cR = cT
cR0 :: String -> Pattern Time
cR0 = cT0
cR_ :: String -> Pattern Time
cR_ = cT_

_cS :: [String] -> String -> Pattern String
_cS = _cX f
  where f a (VI v) = [Event a a (show v)]
        f a (VF v) = [Event a a (show v)]
        f a (VS v) = [Event a a v]
cS :: String -> String -> Pattern String
cS d = _cS [d]
cS_ :: String -> Pattern String
cS_ = _cS []

_cP :: (Enumerable a, Parseable a) => [Pattern a] -> String -> Pattern a
_cP ds s = innerJoin $ _cX f ds s
  where f a (VI v) = [Event a a (parseBP_E $ show v)]
        f a (VF v) = [Event a a (parseBP_E $ show v)]
        f a (VS v) = [Event a a (parseBP_E $ v)]
cP :: (Enumerable a, Parseable a) => Pattern a -> String -> Pattern a
cP d = _cP [d]
cP_ :: (Enumerable a, Parseable a) => String -> Pattern a
cP_ = _cP []

-- Default controller inputs (for MIDI)
in0 :: Pattern Double
in0 = cF 0 "0"
in1 :: Pattern Double
in1 = cF 0 "1"
in2 :: Pattern Double
in2 = cF 0 "2"
in3 :: Pattern Double
in3 = cF 0 "3"
in4 :: Pattern Double
in4 = cF 0 "4"
in5 :: Pattern Double
in5 = cF 0 "5"
in6 :: Pattern Double
in6 = cF 0 "6"
in7 :: Pattern Double
in7 = cF 0 "7"
in8 :: Pattern Double
in8 = cF 0 "8"
in9 :: Pattern Double
in9 = cF 0 "9"
in10 :: Pattern Double
in10 = cF 0 "10"
in11 :: Pattern Double
in11 = cF 0 "11"
in12 :: Pattern Double
in12 = cF 0 "12"
in13 :: Pattern Double
in13 = cF 0 "13"
in14 :: Pattern Double
in14 = cF 0 "14"
in15 :: Pattern Double
in15 = cF 0 "15"
in16 :: Pattern Double
in16 = cF 0 "16"
in17 :: Pattern Double
in17 = cF 0 "17"
in18 :: Pattern Double
in18 = cF 0 "18"
in19 :: Pattern Double
in19 = cF 0 "19"
in20 :: Pattern Double
in20 = cF 0 "20"
in21 :: Pattern Double
in21 = cF 0 "21"
in22 :: Pattern Double
in22 = cF 0 "22"
in23 :: Pattern Double
in23 = cF 0 "23"
in24 :: Pattern Double
in24 = cF 0 "24"
in25 :: Pattern Double
in25 = cF 0 "25"
in26 :: Pattern Double
in26 = cF 0 "26"
in27 :: Pattern Double
in27 = cF 0 "27"
in28 :: Pattern Double
in28 = cF 0 "28"
in29 :: Pattern Double
in29 = cF 0 "29"
in30 :: Pattern Double
in30 = cF 0 "30"
in31 :: Pattern Double
in31 = cF 0 "31"
in32 :: Pattern Double
in32 = cF 0 "32"
in33 :: Pattern Double
in33 = cF 0 "33"
in34 :: Pattern Double
in34 = cF 0 "34"
in35 :: Pattern Double
in35 = cF 0 "35"
in36 :: Pattern Double
in36 = cF 0 "36"
in37 :: Pattern Double
in37 = cF 0 "37"
in38 :: Pattern Double
in38 = cF 0 "38"
in39 :: Pattern Double
in39 = cF 0 "39"
in40 :: Pattern Double
in40 = cF 0 "40"
in41 :: Pattern Double
in41 = cF 0 "41"
in42 :: Pattern Double
in42 = cF 0 "42"
in43 :: Pattern Double
in43 = cF 0 "43"
in44 :: Pattern Double
in44 = cF 0 "44"
in45 :: Pattern Double
in45 = cF 0 "45"
in46 :: Pattern Double
in46 = cF 0 "46"
in47 :: Pattern Double
in47 = cF 0 "47"
in48 :: Pattern Double
in48 = cF 0 "48"
in49 :: Pattern Double
in49 = cF 0 "49"
in50 :: Pattern Double
in50 = cF 0 "50"
in51 :: Pattern Double
in51 = cF 0 "51"
in52 :: Pattern Double
in52 = cF 0 "52"
in53 :: Pattern Double
in53 = cF 0 "53"
in54 :: Pattern Double
in54 = cF 0 "54"
in55 :: Pattern Double
in55 = cF 0 "55"
in56 :: Pattern Double
in56 = cF 0 "56"
in57 :: Pattern Double
in57 = cF 0 "57"
in58 :: Pattern Double
in58 = cF 0 "58"
in59 :: Pattern Double
in59 = cF 0 "59"
in60 :: Pattern Double
in60 = cF 0 "60"
in61 :: Pattern Double
in61 = cF 0 "61"
in62 :: Pattern Double
in62 = cF 0 "62"
in63 :: Pattern Double
in63 = cF 0 "63"
in64 :: Pattern Double
in64 = cF 0 "64"
in65 :: Pattern Double
in65 = cF 0 "65"
in66 :: Pattern Double
in66 = cF 0 "66"
in67 :: Pattern Double
in67 = cF 0 "67"
in68 :: Pattern Double
in68 = cF 0 "68"
in69 :: Pattern Double
in69 = cF 0 "69"
in70 :: Pattern Double
in70 = cF 0 "70"
in71 :: Pattern Double
in71 = cF 0 "71"
in72 :: Pattern Double
in72 = cF 0 "72"
in73 :: Pattern Double
in73 = cF 0 "73"
in74 :: Pattern Double
in74 = cF 0 "74"
in75 :: Pattern Double
in75 = cF 0 "75"
in76 :: Pattern Double
in76 = cF 0 "76"
in77 :: Pattern Double
in77 = cF 0 "77"
in78 :: Pattern Double
in78 = cF 0 "78"
in79 :: Pattern Double
in79 = cF 0 "79"
in80 :: Pattern Double
in80 = cF 0 "80"
in81 :: Pattern Double
in81 = cF 0 "81"
in82 :: Pattern Double
in82 = cF 0 "82"
in83 :: Pattern Double
in83 = cF 0 "83"
in84 :: Pattern Double
in84 = cF 0 "84"
in85 :: Pattern Double
in85 = cF 0 "85"
in86 :: Pattern Double
in86 = cF 0 "86"
in87 :: Pattern Double
in87 = cF 0 "87"
in88 :: Pattern Double
in88 = cF 0 "88"
in89 :: Pattern Double
in89 = cF 0 "89"
in90 :: Pattern Double
in90 = cF 0 "90"
in91 :: Pattern Double
in91 = cF 0 "91"
in92 :: Pattern Double
in92 = cF 0 "92"
in93 :: Pattern Double
in93 = cF 0 "93"
in94 :: Pattern Double
in94 = cF 0 "94"
in95 :: Pattern Double
in95 = cF 0 "95"
in96 :: Pattern Double
in96 = cF 0 "96"
in97 :: Pattern Double
in97 = cF 0 "97"
in98 :: Pattern Double
in98 = cF 0 "98"
in99 :: Pattern Double
in99 = cF 0 "99"
in100 :: Pattern Double
in100 = cF 0 "100"
in101 :: Pattern Double
in101 = cF 0 "101"
in102 :: Pattern Double
in102 = cF 0 "102"
in103 :: Pattern Double
in103 = cF 0 "103"
in104 :: Pattern Double
in104 = cF 0 "104"
in105 :: Pattern Double
in105 = cF 0 "105"
in106 :: Pattern Double
in106 = cF 0 "106"
in107 :: Pattern Double
in107 = cF 0 "107"
in108 :: Pattern Double
in108 = cF 0 "108"
in109 :: Pattern Double
in109 = cF 0 "109"
in110 :: Pattern Double
in110 = cF 0 "110"
in111 :: Pattern Double
in111 = cF 0 "111"
in112 :: Pattern Double
in112 = cF 0 "112"
in113 :: Pattern Double
in113 = cF 0 "113"
in114 :: Pattern Double
in114 = cF 0 "114"
in115 :: Pattern Double
in115 = cF 0 "115"
in116 :: Pattern Double
in116 = cF 0 "116"
in117 :: Pattern Double
in117 = cF 0 "117"
in118 :: Pattern Double
in118 = cF 0 "118"
in119 :: Pattern Double
in119 = cF 0 "119"
in120 :: Pattern Double
in120 = cF 0 "120"
in121 :: Pattern Double
in121 = cF 0 "121"
in122 :: Pattern Double
in122 = cF 0 "122"
in123 :: Pattern Double
in123 = cF 0 "123"
in124 :: Pattern Double
in124 = cF 0 "124"
in125 :: Pattern Double
in125 = cF 0 "125"
in126 :: Pattern Double
in126 = cF 0 "126"
in127 :: Pattern Double
in127 = cF 0 "127"
