module Sound.Tidal.OscStream where

import qualified Data.Map as Map
import Data.Maybe
import Sound.Tidal.Tempo (Tempo, cps)
import Sound.Tidal.Stream
import Sound.Tidal.Utils
import GHC.Float (float2Double, double2Float)
import Sound.OSC.FD
import Sound.OSC.Datum
import Sound.Tidal.Params

data TimeStamp = BundleStamp | MessageStamp | NoStamp
 deriving Eq

data OscSlang = OscSlang {path :: String,
                          timestamp :: TimeStamp,
                          namedParams :: Bool,
                          preamble :: [Datum]
                         }

type OscMap = Map.Map Param (Maybe Datum)

toOscDatum :: Value -> Maybe Datum
toOscDatum (VF x) = Just $ float x
toOscDatum (VI x) = Just $ int32 x
toOscDatum (VS x) = Just $ string x

toOscMap :: ParamMap -> OscMap
toOscMap m = Map.map (toOscDatum) (Map.mapMaybe (id) m)


-- constructs and sends an Osc Message according to the given slang
-- and other params - this is essentially the same as the former
-- toMessage in Stream.hs
send s slang shape change tick (o, m) = osc
    where
      osc | timestamp slang == BundleStamp = sendOSC s $ Bundle (ut_to_ntpr logicalOnset) [Message (path slang) oscdata]
          | timestamp slang == MessageStamp = sendOSC s $ Message (path slang) ((int32 sec):(int32 usec):oscdata)
          | otherwise = doAt logicalOnset $ sendOSC s $ Message (path slang) oscdata
      oscPreamble = cpsPrefix ++ preamble slang
      oscdata | namedParams slang = oscPreamble ++ (concatMap (\(k, Just v) -> [string (name k), v] )
                                                    $ filter (isJust . snd) $ Map.assocs (fixSound m))
              | otherwise = oscPreamble ++ (catMaybes $ mapMaybe (\x -> Map.lookup x m) (params shape))
      cpsPrefix | cpsStamp shape && namedParams slang = [string "cps", float (cps change)]
                | cpsStamp shape = [float (cps change)]
                | otherwise = []
      parameterise ds = mergelists (map (string . name) (params shape)) ds
      usec = floor $ 1000000 * (logicalOnset - (fromIntegral sec))
      sec = floor logicalOnset
      logicalOnset = logicalOnset' change tick o ((latency shape) + nudge)
      nudge = maybe 0 (toF) (Map.lookup nudge_p m)
      toF (Just (Float f)) = float2Double f
      toF _ = 0
      fixSound :: OscMap -> OscMap
      fixSound m | Map.lookup sound_p m == Nothing = makeSound m
                 | otherwise = m
      makeSound :: OscMap -> OscMap
      makeSound m | s' == Nothing = m
                  | n' == Nothing = Map.union m (Map.singleton sound_p (fromJust s'))
                  -- omg
                  | otherwise = Map.union m (Map.singleton sound_p (Just $ string $ (fromJust $ datum_string $ fromJust $ fromJust s') ++ (':':(show $ fromJust $ datum_int32 $ fromJust $ fromJust n'))))
        where s' = Map.lookup s_p m
              n' = Map.lookup n_p m

-- type OscMap = Map.Map Param (Maybe Datum)
              
-- Returns a function that will convert a generic ParamMap into a specific Osc message and send it over UDP to the supplied server
-- messages will be built according to the given OscSlang
makeConnection :: String -> Int -> OscSlang -> IO (ToMessageFunc)
makeConnection address port slang = do
  s <- openUDP address port
  return (\ shape change tick (o,m) -> do
             let m' = if (namedParams slang) then (Just m) else (applyShape' shape m)
             -- this might result in Nothing, make sure we do this first
             m'' <- fmap (toOscMap) m'
             -- to allow us to simplify `send` (no `do`)
             return $ send s slang shape change tick (o,m'')
         )
