module Sound.Tidal.Span where

import           Sound.Tidal.Time
import           Sound.Tidal.Types

-- | Intersection of two arcs
sect :: Span -> Span -> Span
sect (Span b e) (Span b' e') = Span (max b b') (min e e')

-- | Intersection of two arcs, returns Nothing if they don't intersect
-- The definition is a bit fiddly as results might be zero-width, but
-- not at the end of an non-zero-width arc - e.g. (0,1) and (1,2) do
-- not intersect, but (1,1) (1,1) does.
maybeSect :: Span -> Span -> Maybe Span
maybeSect a@(Span s e) b@(Span s' e')
  | and [s'' == e'', s'' == e, s < e] = Nothing
  | and [s'' == e'', s'' == e', s' < e'] = Nothing
  | s'' <= e'' = Just (Span s'' e'')
  | otherwise = Nothing
  where (Span s'' e'') = sect a b

-- | Returns the whole cycle arc that the given time is in
timeToCycle :: Time -> Span
timeToCycle t = Span (sam t) (nextSam t)

-- | Splits a timespan at cycle boundaries
splitSpans :: Span -> [Span]
splitSpans (Span s e) | s == e = [Span s e] -- support zero-width arcs
                      | otherwise = splitSpans' (Span s e) -- otherwise, recurse
  where splitSpans' (Span s' e') | e' <= s' = []
                                 | sam s' == sam e' = [Span s' e']
                                 | otherwise = Span s' (nextSam s') : splitSpans' (Span (nextSam s') e')

-- | Similar to 'fmap' but time is relative to the cycle (i.e. the
-- sam of the start of the arc)
mapCycle :: (Time -> Time) -> Span -> Span
mapCycle f (Span s e) = Span (sam' + f (s - sam')) (sam' + f (e - sam'))
         where sam' = sam s

-- | @isIn a t@ is @True@ if @t@ is inside
-- the span represented by @a@.
isIn :: Span -> Time -> Bool
isIn (Span s e) t = t >= s && t < e

withSpanTime :: (Time -> Time) -> Span -> Span
withSpanTime timef (Span b e) = Span (timef b) (timef e)

-- | convex hull union
hull :: Span -> Span -> Span
hull (Span s e) (Span s' e') = Span (min s s') (max e e')
