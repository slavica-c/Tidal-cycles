module Sound.Tidal.Stream.Types where

import           Control.Concurrent.MVar
import qualified Data.Map.Strict as Map
import Sound.Tidal.Pattern
import Sound.Tidal.Show ()

import qualified Sound.Osc.Fd as O
import qualified Network.Socket          as N

import qualified Sound.Tidal.Clock as Clock

import Sound.Tidal.Stream.Config

data Stream = Stream {sConfig :: Config,
                      sStateMV :: MVar ValueMap,
                      -- sOutput :: MVar ControlPattern,
                      sClockRef :: Clock.ClockRef,
                      sListen :: Maybe O.Udp,
                      sPMapMV :: MVar PlayMap,
                      sGlobalFMV :: MVar (ControlPattern -> ControlPattern),
                      sCxs :: [Cx]
                     }

data Cx = Cx {cxTarget :: Target,
              cxUDP :: O.Udp,
              cxOSCs :: [OSC],
              cxAddr :: N.AddrInfo,
              cxBusAddr :: Maybe N.AddrInfo,
              cxBusses :: Maybe (MVar [Int])
             }

data StampStyle = BundleStamp
                | MessageStamp
  deriving (Eq, Show)

data Schedule = Pre StampStyle
              | Live
  deriving (Eq, Show)

data Target = Target {oName :: String,
                      oAddress :: String,
                      oPort :: Int,
                      oBusPort :: Maybe Int,
                      oLatency :: Double,
                      oWindow :: Maybe Arc,
                      oSchedule :: Schedule,
                      oHandshake :: Bool
                     }
                 deriving Show

data Args = Named {requiredArgs :: [String]}
          | ArgList [(String, Maybe Value)]
         deriving Show

data OSC = OSC {path :: String,
                args :: Args
               }
         | OSCContext {path :: String}
         deriving Show

data PlayState = PlayState {pattern :: ControlPattern,
                            mute :: Bool,
                            solo :: Bool,
                            history :: [ControlPattern]
                           }
               deriving Show

type PatId = String
type PlayMap = Map.Map PatId PlayState

-- data TickState = TickState {
--                     tickArc   :: Arc,
--                     tickNudge :: Double
--                    }
--   deriving Show

patternTimeID :: String
patternTimeID = "_t_pattern"
