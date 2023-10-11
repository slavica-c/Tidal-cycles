module Sound.Tidal.Config where

import Data.Int(Int64)
import Foreign.C.Types (CDouble)

{-
    Config.hs - For default Tidal configuration values.
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

data Config = Config {cCtrlListen :: Bool,
                      cCtrlAddr :: String,
                      cCtrlPort :: Int,
                      cCtrlBroadcast :: Bool,
                      cFrameTimespan :: Double,
                      cEnableLink :: Bool,
                      cProcessAhead :: Double,
                      cSkipTicks :: Int64,
                      cVerbose :: Bool,
                      cQuantum :: CDouble,
                      cBeatsPerCycle :: CDouble
                     }

defaultConfig :: Config
defaultConfig = Config {cCtrlListen = True,
                        cCtrlAddr ="127.0.0.1",
                        cCtrlPort = 6010,
                        cCtrlBroadcast = False,
                        cFrameTimespan = 1/20,
                        cEnableLink = True,
                        cProcessAhead = 3/10,
                        cSkipTicks = 10,
                        cVerbose = True,
                        cQuantum = 4,
                        cBeatsPerCycle = 4
                       }
