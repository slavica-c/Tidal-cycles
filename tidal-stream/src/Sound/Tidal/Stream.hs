{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# OPTIONS_GHC -fno-warn-missing-fields #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE StandaloneDeriving         #-}

module Sound.Tidal.Stream (module Sound.Tidal.Stream) where

{-
    Stream.hs - Tidal's thingie for turning patterns into OSC streams
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

import           Control.Applicative     ((<|>))
import           Control.Concurrent
import qualified Control.Exception       as E
import           Control.Monad           (forM_, when)
import           Data.Coerce             (coerce)
import qualified Data.Map.Strict         as Map
import           Data.Maybe              (catMaybes, fromJust, fromMaybe,
                                          isJust)
import           Foreign
import           Foreign.C.Types
import           GHC.Stack
import           System.IO               (hPutStrLn, stderr)

import qualified Network.Socket          as N
import qualified Sound.Osc.Fd            as O
import qualified Sound.Osc.Time.Timeout  as O

import           Sound.Tidal.Config
-- import           Sound.Tidal.Core (stack, silence, (#))
import           Data.List               (sortOn)
import           Sound.Tidal             (eventHasOnset, pS, resolveState,
                                          wholeOrActive, (!!!))
import           Sound.Tidal.Compose     ((#))
import           Sound.Tidal.ID
import qualified Sound.Tidal.Link        as Link
import           Sound.Tidal.Show        ()
import           Sound.Tidal.Signal
import qualified Sound.Tidal.Tempo       as T
import           Sound.Tidal.Types
import           Sound.Tidal.Value
import           System.Random           (getStdRandom, randomR)

import           Sound.Tidal             (tidal_status_string)

import           Sound.Tidal.StreamTypes as Sound.Tidal.Stream

data Stream = Stream {sConfig    :: Config,
                      sStateMV   :: MVar ValueMap,
                      -- sOutput :: MVar Signal ValueMap,
                      sLink      :: Link.AbletonLink,
                      sListen    :: Maybe O.Udp,
                      sPMapMV    :: MVar PlayMap,
                      sActionsMV :: MVar [T.TempoAction],
                      sGlobalFMV :: MVar (Signal ValueMap -> Signal ValueMap),
                      sCxs       :: [Cx]
                     }

data Cx = Cx {cxTarget  :: Target,
              cxUDP     :: O.Udp,
              cxOSCs    :: [OSC],
              cxAddr    :: N.AddrInfo,
              cxBusAddr :: Maybe N.AddrInfo,
              cxBusses  :: Maybe (MVar [Int])
             }

data StampStyle = BundleStamp
                | MessageStamp
  deriving (Eq, Show)

data Schedule = Pre StampStyle
              | Live
  deriving (Eq, Show)

data Target = Target {oName      :: String,
                      oAddress   :: String,
                      oPort      :: Int,
                      oBusPort   :: Maybe Int,
                      oLatency   :: Double,
                      oWindow    :: Maybe Span,
                      oSchedule  :: Schedule,
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

data ProcessedEvent =
  ProcessedEvent {
    peHasOnset         :: Bool,
    peEvent            :: Event ValueMap,
    peCps              :: Link.BPM,
    peDelta            :: Link.Micros,
    peCycle            :: Time,
    peOnWholeOrPart    :: Link.Micros,
    peOnWholeOrPartOsc :: O.Time,
    peOnPart           :: Link.Micros,
    peOnPartOsc        :: O.Time
  }

sDefault :: String -> Maybe Value
sDefault x = Just $ VS x
fDefault :: Double -> Maybe Value
fDefault x = Just $ VF x
rDefault :: Rational -> Maybe Value
rDefault x = Just $ VR x
iDefault :: Int -> Maybe Value
iDefault x = Just $ VI x
bDefault :: Bool -> Maybe Value
bDefault x = Just $ VB x
xDefault :: [Word8] -> Maybe Value
xDefault x = Just $ VX x

required :: Maybe Value
required = Nothing

superdirtTarget :: Target
superdirtTarget = Target {oName = "SuperDirt",
                          oAddress = "127.0.0.1",
                          oPort = 57120,
                          oBusPort = Just 57110,
                          oLatency = 0.2,
                          oWindow = Nothing,
                          oSchedule = Pre BundleStamp,
                          oHandshake = True
                         }

superdirtShape :: OSC
superdirtShape = OSC "/dirt/play" $ Named {requiredArgs = ["s"]}

dirtTarget :: Target
dirtTarget = Target {oName = "Dirt",
                     oAddress = "127.0.0.1",
                     oPort = 7771,
                     oBusPort = Nothing,
                     oLatency = 0.02,
                     oWindow = Nothing,
                     oSchedule = Pre MessageStamp,
                     oHandshake = False
                    }

dirtShape :: OSC
dirtShape = OSC "/play" $ ArgList [("cps", fDefault 0),
                                   ("s", required),
                                   ("offset", fDefault 0),
                                   ("begin", fDefault 0),
                                   ("end", fDefault 1),
                                   ("speed", fDefault 1),
                                   ("pan", fDefault 0.5),
                                   ("velocity", fDefault 0.5),
                                   ("vowel", sDefault ""),
                                   ("cutoff", fDefault 0),
                                   ("resonance", fDefault 0),
                                   ("accelerate", fDefault 0),
                                   ("shape", fDefault 0),
                                   ("kriole", iDefault 0),
                                   ("gain", fDefault 1),
                                   ("cut", iDefault 0),
                                   ("delay", fDefault 0),
                                   ("delaytime", fDefault (-1)),
                                   ("delayfeedback", fDefault (-1)),
                                   ("crush", fDefault 0),
                                   ("coarse", iDefault 0),
                                   ("hcutoff", fDefault 0),
                                   ("hresonance", fDefault 0),
                                   ("bandf", fDefault 0),
                                   ("bandq", fDefault 0),
                                   ("unit", sDefault "rate"),
                                   ("loop", fDefault 0),
                                   ("n", fDefault 0),
                                   ("attack", fDefault (-1)),
                                   ("hold", fDefault 0),
                                   ("release", fDefault (-1)),
                                   ("orbit", iDefault 0) -- ,
                                   -- ("id", iDefault 0)
                                  ]

defaultCps :: O.Time
defaultCps = 0.5625

-- Start an instance of Tidal
-- Spawns a thread within Tempo that acts as the clock
-- Spawns a thread that listens to and acts on OSC control messages
startStream :: Config -> [(Target, [OSC])] -> IO Stream
startStream config oscmap
  = do sMapMV <- newMVar Map.empty
       pMapMV <- newMVar Map.empty
       globalFMV <- newMVar id
       actionsMV <- newEmptyMVar

       tidal_status_string >>= verbose config
       verbose config $ "Listening for external controls on " ++ cCtrlAddr config ++ ":" ++ show (cCtrlPort config)
       listen <- openListener config

       cxs <- mapM (\(target, os) -> do remote_addr <- resolve (oAddress target) (oPort target)
                                        remote_bus_addr <- sequence (resolve (oAddress target) <$> (oBusPort target))
                                        remote_busses <- sequence (oBusPort target >> (Just $ newMVar []))
                                        let broadcast = if cCtrlBroadcast config then 1 else 0
                                        u <- O.udp_socket (\sock _ -> do N.setSocketOption sock N.Broadcast broadcast
                                                                                -- N.connect sock sockaddr
                                                          ) (oAddress target) (oPort target)
                                        let cx = Cx {cxUDP = u, cxAddr = remote_addr, cxBusAddr = remote_bus_addr, cxBusses = remote_busses, cxTarget = target, cxOSCs = os}
                                        _ <- forkIO $ handshake cx config
                                        return cx
                   ) oscmap
       let bpm = (coerce defaultCps) * 60 * (cBeatsPerCycle config)
       abletonLink <- Link.create bpm
       let stream = Stream {sConfig = config,
                            sStateMV  = sMapMV,
                            sLink = abletonLink,
                            sListen = listen,
                            sPMapMV = pMapMV,
                            sActionsMV = actionsMV,
                            sGlobalFMV = globalFMV,
                            sCxs = cxs
                           }
       let ac = T.ActionHandler {
         T.onTick = onTick stream,
         T.onSingleTick = onSingleTick stream,
         T.updatePattern = updatePattern stream
         }
       -- Spawn a thread that acts as the clock
       _ <- T.clocked config sMapMV pMapMV actionsMV ac abletonLink
       -- Spawn a thread to handle OSC control messages
       _ <- forkIO $ ctrlResponder config stream
       return stream

handshake :: Cx -> Config -> IO ()
handshake Cx { cxUDP = udp, cxBusses = Just bussesMV, cxAddr = addr } c = sendHandshake >> listen 0
  where
    sendHandshake :: IO ()
    sendHandshake = O.sendTo udp (O.Packet_Message $ O.Message "/dirt/handshake" []) (N.addrAddress addr)
    listen :: Int -> IO ()
    listen waits = do ms <- recvMessagesTimeout 2 udp
                      if (null ms)
                      then do checkHandshake waits -- there was a timeout, check handshake
                              listen (waits+1)
                      else do mapM_ respond ms
                              listen 0
    checkHandshake :: Int -> IO ()
    checkHandshake waits = do busses <- readMVar bussesMV
                              when (null busses) $ do when (waits == 0) $ verbose c $ "Waiting for SuperDirt (v.1.7.2 or higher).."
                                                      sendHandshake
    respond :: O.Message -> IO ()
    respond (O.Message "/dirt/hello" _) = sendHandshake
    respond (O.Message "/dirt/handshake/reply" xs) = do prev <- swapMVar bussesMV $ bufferIndices xs
                                                        -- Only report the first time..
                                                        when (null prev) $ verbose c $ "Connected to SuperDirt."
                                                        return ()
    respond _ = return ()
    bufferIndices :: [O.Datum] -> [Int]
    bufferIndices [] = []
    bufferIndices (x:xs') | x == (O.AsciiString $ O.ascii "&controlBusIndices") = catMaybes $ takeWhile isJust $ map O.datum_integral xs'
                          | otherwise = bufferIndices xs'
handshake _ _ = return ()

sendO :: Bool -> Cx -> O.Message -> IO ()
sendO isBusMsg cx msg = O.sendTo (cxUDP cx) (O.Packet_Message msg) (N.addrAddress addr)
  where addr | isBusMsg && isJust (cxBusAddr cx) = fromJust $ cxBusAddr cx
             | otherwise = cxAddr cx

sendBndl :: Bool -> Cx -> O.Bundle -> IO ()
sendBndl isBusMsg cx bndl = O.sendTo (cxUDP cx) (O.Packet_Bundle bndl) (N.addrAddress addr)
  where addr | isBusMsg && isJust (cxBusAddr cx) = fromJust $ cxBusAddr cx
             | otherwise = cxAddr cx

resolve :: String -> Int -> IO N.AddrInfo
resolve host port = do let hints = N.defaultHints { N.addrSocketType = N.Stream }
                       addr:_ <- N.getAddrInfo (Just hints) (Just host) (Just $ show port)
                       return addr

-- Start an instance of Tidal with superdirt OSC
startTidal :: Target -> Config -> IO Stream
startTidal target config = startStream config [(target, [superdirtShape])]

startMulti :: [Target] -> Config -> IO ()
startMulti _ _ = hPutStrLn stderr $ "startMulti has been removed, please check the latest documentation on tidalcycles.org"

toDatum :: Value -> O.Datum
toDatum (VF x)     = O.float x
toDatum (VN x)     = O.float x
toDatum (VI x)     = O.int32 x
toDatum (VS x)     = O.string x
toDatum (VR x)     = O.float $ ((fromRational x) :: Double)
toDatum (VB True)  = O.int32 (1 :: Int)
toDatum (VB False) = O.int32 (0 :: Int)
toDatum (VX xs)    = O.Blob $ O.blob_pack xs
toDatum _          = error "toDatum: unhandled value"

toData :: OSC -> Event ValueMap -> Maybe [O.Datum]
toData (OSC {args = ArgList as}) e = fmap (fmap (toDatum)) $ sequence $ map (\(n,v) -> Map.lookup n (value e) <|> v) as
toData (OSC {args = Named rqrd}) e
  | hasRequired rqrd = Just $ concatMap (\(n,v) -> [O.string n, toDatum v]) $ Map.toList $ value e
  | otherwise = Nothing
  where hasRequired [] = True
        hasRequired xs = null $ filter (not . (`elem` ks)) xs
        ks = Map.keys (value e)
toData _ _ = Nothing

substitutePath :: String -> ValueMap -> Maybe String
substitutePath str cm = parse str
  where parse [] = Just []
        parse ('{':xs) = parseWord xs
        parse (x:xs) = do xs' <- parse xs
                          return (x:xs')
        parseWord xs | b == [] = getString cm a
                     | otherwise = do v <- getString cm a
                                      xs' <- parse (tail b)
                                      return $ v ++ xs'
          where (a,b) = break (== '}') xs

getString :: ValueMap -> String -> Maybe String
getString cm s = (simpleShow <$> Map.lookup param cm) <|> defaultValue dflt
                      where (param, dflt) = break (== '=') s
                            simpleShow :: Value -> String
                            simpleShow (VS str)    = str
                            simpleShow (VI i)      = show i
                            simpleShow (VF f)      = show f
                            simpleShow (VN n)      = show n
                            simpleShow (VR r)      = show r
                            simpleShow (VB b)      = show b
                            simpleShow (VX xs)     = show xs
                            simpleShow (VState _)  = show "<stateful>"
                            simpleShow (VSignal _) = show "<signal>"
                            simpleShow (VList _)   = show "<list>"
                            defaultValue :: String -> Maybe String
                            defaultValue ('=':dfltVal) = Just dfltVal
                            defaultValue _             = Nothing

playStack :: PlayMap -> Signal ValueMap
playStack pMap = stack $ map pattern activeStates
  where activeStates = filter (\pState -> if hasSolo pMap
                                          then solo pState
                                          else not (mute pState)
                              ) $ Map.elems pMap

toOSC :: Maybe [Int] -> ProcessedEvent -> OSC -> [(Double, Bool, O.Message)]
toOSC maybeBusses pe osc@(OSC _ _)
  = catMaybes (playmsg:busmsgs)
      -- playmap is a ValueMap where the keys don't start with ^ and are not ""
      -- busmap is a ValueMap containing the rest of the keys from the event value
      -- The partition is performed in order to have special handling of bus ids.
      where
        (playmap, busmap) = Map.partitionWithKey (\k _ -> null k || head k /= '^') $ val pe
        -- Map in bus ids where needed.
        --
        -- Bus ids are integers
        -- If busses is empty, the ids to send are directly contained in the the values of the busmap.
        -- Otherwise, the ids to send are contained in busses at the indices of the values of the busmap.
        -- Both cases require that the values of the busmap are only ever integers,
        -- that is, they are Values with constructor VI
        -- (but perhaps we should explicitly crash with an error message if it contains something else?).
        -- Map.mapKeys tail is used to remove ^ from the keys.
        -- In case (value e) has the key "", we will get a crash here.
        playmap' = Map.union (Map.mapKeys tail $ Map.map (\v -> VS ('c':(show $ toBus $ fromMaybe 0 $ getI v))) busmap) playmap
        val = value . peEvent
        -- Only events that start within the current nowSpan are included
        playmsg | peHasOnset pe = do
                  -- If there is already cps in the event, the union will preserve that.
                  let extra = Map.fromList [("cps", (VF (coerce $! peCps pe))),
                                          ("delta", VF (T.addMicrosToOsc (peDelta pe) 0)),
                                          ("cycle", VF (fromRational (peCycle pe)))
                                        ]
                      addExtra = Map.union playmap' extra
                      ts = (peOnWholeOrPartOsc pe) + nudge -- + latency
                  vs <- toData osc ((peEvent pe) {value = addExtra})
                  mungedPath <- substitutePath (path osc) playmap'
                  return (ts,
                          False, -- bus message ?
                          O.Message mungedPath vs
                          )
                | otherwise = Nothing
        toBus n | Just busses <- maybeBusses, (not . null) busses = busses !!! n
                | otherwise = n
        busmsgs = map f $ Map.toList busmap
          where
            f (('^':k), (VI b)) = do v <- Map.lookup k playmap
                                     return $ (tsPart,
                                               True, -- bus message ?
                                               O.Message "/c_set" [O.int32 b, toDatum v]
                                              )
            f _ = Nothing
            tsPart = (peOnPartOsc pe) + nudge -- + latency
        nudge = fromJust $ getF $ fromMaybe (VF 0) $ Map.lookup "nudge" $ playmap
toOSC _ pe (OSCContext oscpath)
  = map cToM $ metaSrcPos $ eventMetadata $ peEvent pe
  where cToM :: ((Int,Int),(Int,Int)) -> (Double, Bool, O.Message)
        cToM ((x, y), (x',y')) = (ts,
                                  False, -- bus message ?
                                  O.Message oscpath $ (O.string ident):(O.float (peDelta pe)):(O.float cyc):(map O.int32 [x,y,x',y'])
                                 )
        cyc :: Double
        cyc = fromRational $ peCycle pe
        nudge = fromMaybe 0 $ Map.lookup "nudge" (value $ peEvent pe) >>= getF
        ident = fromMaybe "unknown" $ Map.lookup "_id_" (value $ peEvent pe) >>= getS
        ts = (peOnWholeOrPartOsc pe) + nudge -- + latency

patternTimeID :: String
patternTimeID = "_t_pattern"

-- Used for Tempo callback
updatePattern :: Stream -> ID -> Time -> Signal ValueMap -> IO ()
updatePattern stream k !t pat = do
  let x = querySpan pat (Span 0 0)
  pMap <- seq x $ takeMVar (sPMapMV stream)
  let playState = updatePS $ Map.lookup (fromID k) pMap
  putMVar (sPMapMV stream) $ Map.insert (fromID k) playState pMap
  where updatePS (Just playState) = do playState {pattern = pat', history = pat:(history playState)}
        updatePS Nothing = PlayState pat' False False [pat']
        patControls = Map.singleton patternTimeID (VR t)
        pat' = withQueryControls (Map.union patControls)
                 $ pat # pS "_id_" (pure $ fromID k)

processCps :: T.LinkOperations -> [Event ValueMap] -> IO [ProcessedEvent]
processCps ops = mapM processEvent
  where
    processEvent ::  Event ValueMap  -> IO ProcessedEvent
    processEvent e = do
      let wope = wholeOrActive e
          partStartCycle = aBegin $ active e
          partStartBeat = (T.cyclesToBeat ops) (realToFrac partStartCycle)
          onCycle = aBegin wope
          onBeat = (T.cyclesToBeat ops) (realToFrac onCycle)
          offCycle = aEnd wope
          offBeat = (T.cyclesToBeat ops) (realToFrac offCycle)
      onT <- (T.timeAtBeat ops) onBeat
      onPart <- (T.timeAtBeat ops) partStartBeat
      when (eventHasOnset e) (do
        let cps' = Map.lookup "cps" (value e) >>= getF
        maybe (return ()) (\newCps -> (T.setTempo ops) ((T.cyclesToBeat ops) (newCps * 60)) onT) $ coerce cps'
        )
      offT <- (T.timeAtBeat ops) offBeat
      bpm <- (T.getTempo ops)
      let cps = ((T.beatToCycles ops) bpm) / 60
      let delta = offT - onT
      return $! ProcessedEvent {
          peHasOnset = eventHasOnset e,
          peEvent = e,
          peCps = cps,
          peDelta = delta,
          peCycle = onCycle,
          peOnWholeOrPart = onT,
          peOnWholeOrPartOsc = (T.linkToOscTime ops) onT,
          peOnPart = onPart,
          peOnPartOsc = (T.linkToOscTime ops) onPart
        }


-- streamFirst but with random cycle instead of always first cicle
streamOnce :: Stream -> Signal ValueMap -> IO ()
streamOnce st p = do i <- getStdRandom $ randomR (0, 8192)
                     streamFirst st $ _early (toRational (i :: Int)) p

-- here let's do modifyMVar_ on actions
streamFirst :: Stream -> Signal ValueMap -> IO ()
streamFirst stream pat = modifyMVar_ (sActionsMV stream) (\actions -> return $ (T.SingleTick pat) : actions)

-- Used for Tempo callback
onTick :: Stream -> TickState -> T.LinkOperations -> ValueMap -> IO ValueMap
onTick stream st ops s
  = doTick stream st ops s

-- Used for Tempo callback
-- Tempo changes will be applied.
-- However, since the full span is processed at once and since Link does not support
-- scheduling, tempo change may affect scheduling of events that happen earlier
-- in the normal stream (the one handled by onTick).
onSingleTick :: Stream -> T.LinkOperations -> ValueMap -> Signal ValueMap -> IO ValueMap
onSingleTick stream ops s pat = do
  pMapMV <- newMVar $ Map.singleton "fake"
          (PlayState {pattern = pat,
                      mute = False,
                      solo = False,
                      history = []
                      }
          )

  -- The nowSpan is a full cycle
  let state = TickState {tickSpan = (Span 0 1), tickNudge = 0}
  doTick (stream {sPMapMV = pMapMV}) state ops s


-- | Query the current pattern (contained in argument @stream :: Stream@)
-- for the events in the current span (contained in argument @st :: T.State@),
-- translate them to OSC messages, and send these.
--
-- If an exception occurs during sending,
-- this functions prints a warning and continues, because
-- the likely reason is that the backend (supercollider) isn't running.
--
-- If any exception occurs before or outside sending
-- (e.g., while querying the pattern, while computing a message),
-- this function prints a warning and resets the current pattern
-- to the previous one (or to silence if there isn't one) and continues,
-- because the likely reason is that something is wrong with the current pattern.
doTick :: HasCallStack => Stream -> TickState -> T.LinkOperations -> ValueMap -> IO ValueMap
doTick stream st ops sMap =
  E.handle (\ (e :: E.SomeException) -> do
    hPutStrLn stderr $ "Failed to Stream.doTick: " ++ show e ++ " // " ++ prettyCallStack callStack
    hPutStrLn stderr $ "Return to previous pattern."
    setPreviousPatternOrSilence stream
    return sMap) (do
      pMap <- readMVar (sPMapMV stream)
      sGlobalF <- readMVar (sGlobalFMV stream)
      bpm <- (T.getTempo ops)
      let
        cxs = sCxs stream
        patstack = sGlobalF $ playStack pMap
        cps = ((T.beatToCycles ops) bpm) / 60
        sMap' = Map.insert "_cps" (VF $ coerce cps) sMap
        extraLatency = tickNudge st
        -- First the state is used to query the pattern
        es = sortOn (aBegin . active) $ query patstack (State {sSpan = tickSpan st,
                                                               sControls = sMap'
                                                              }
                                                       )
         -- Then it's passed through the events
        (sMap'', es') = resolveState sMap' es
      tes <- processCps ops es'
      -- For each OSC target
      forM_ cxs $ \cx@(Cx target _ oscs _ _ bussesMV) -> do
        busses <- mapM readMVar bussesMV
        -- Latency is configurable per target.
        -- Latency is only used when sending events live.
        let latency = oLatency target
            ms = concatMap (\e ->  concatMap (toOSC busses e) oscs) tes
        -- send the events to the OSC target
        forM_ ms $ \ m -> (do
          send cx latency extraLatency m) `E.catch` \ (e :: E.SomeException) -> do
          hPutStrLn stderr $ "Failed to send. Is the '" ++ oName target ++ "' target running? " ++ show e
      sMap'' `seq` return sMap'')

setPreviousPatternOrSilence :: Stream -> IO ()
setPreviousPatternOrSilence stream =
  modifyMVar_ (sPMapMV stream) $ return
    . Map.map ( \ pMap -> case history pMap of
      _:p:ps -> pMap { pattern = p, history = p:ps }
      _      -> pMap { pattern = silence, history = [silence] }
              )

-- send has three modes:
-- Send events early using timestamp in the OSC bundle - used by Superdirt
-- Send events early by adding timestamp to the OSC message - used by Dirt
-- Send events live by delaying the thread
send :: Cx -> Double -> Double -> (Double, Bool, O.Message) -> IO ()
send cx latency extraLatency (time, isBusMsg, m)
  | oSchedule target == Pre BundleStamp = sendBndl isBusMsg cx $ O.Bundle timeWithLatency [m]
  | oSchedule target == Pre MessageStamp = sendO isBusMsg cx $ addtime m
  | otherwise = do _ <- forkOS $ do now <- O.time
                                    threadDelay $ floor $ (timeWithLatency - now) * 1000000
                                    sendO isBusMsg cx m
                   return ()
    where addtime (O.Message mpath params) = O.Message mpath ((O.int32 sec):((O.int32 usec):params))
          ut = O.ntpr_to_posix timeWithLatency
          sec :: Int
          sec = floor ut
          usec :: Int
          usec = floor $ 1000000 * (ut - (fromIntegral sec))
          target = cxTarget cx
          timeWithLatency = time - latency + extraLatency

-- Interaction

streamNudgeAll :: Stream -> Double -> IO ()
streamNudgeAll s nudge = T.setNudge (sActionsMV s) nudge

streamResetCycles :: Stream -> IO ()
streamResetCycles s = streamSetCycle s 0

streamSetCycle :: Stream -> Time -> IO ()
streamSetCycle s cyc = T.setCycle cyc (sActionsMV s)

hasSolo :: Map.Map k PlayState -> Bool
hasSolo = (>= 1) . length . filter solo . Map.elems

streamList :: Stream -> IO ()
streamList s = do pMap <- readMVar (sPMapMV s)
                  let hs = hasSolo pMap
                  putStrLn $ concatMap (showKV hs) $ Map.toList pMap
  where showKV :: Bool -> (PatId, PlayState) -> String
        showKV True  (k, (PlayState {solo = True}))  = k ++ " - solo\n"
        showKV True  (k, _)                          = "(" ++ k ++ ")\n"
        showKV False (k, (PlayState {solo = False})) = k ++ "\n"
        showKV False (k, _)                          = "(" ++ k ++ ") - muted\n"

-- Evaluation of pat is forced so exceptions are picked up here, before replacing the existing pattern.

streamReplace :: Stream -> ID -> Signal ValueMap -> IO ()
streamReplace s k !pat
  = modifyMVar_ (sActionsMV s) (\actions -> return $ (T.StreamReplace k pat) : actions)

streamMute :: Stream -> ID -> IO ()
streamMute s k = withPatIds s [k] (\x -> x {mute = True})

streamMutes :: Stream -> [ID] -> IO ()
streamMutes s ks = withPatIds s ks (\x -> x {mute = True})

streamUnmute :: Stream -> ID -> IO ()
streamUnmute s k = withPatIds s [k] (\x -> x {mute = False})

streamSolo :: Stream -> ID -> IO ()
streamSolo s k = withPatIds s [k] (\x -> x {solo = True})

streamUnsolo :: Stream -> ID -> IO ()
streamUnsolo s k = withPatIds s [k] (\x -> x {solo = False})

withPatIds :: Stream -> [ID] -> (PlayState -> PlayState) -> IO ()
withPatIds s ks f
  = do playMap <- takeMVar $ sPMapMV s
       let pMap' = foldr (Map.update (\x -> Just $ f x)) playMap (map fromID ks)
       putMVar (sPMapMV s) pMap'
       return ()

-- TODO - is there a race condition here?
streamMuteAll :: Stream -> IO ()
streamMuteAll s = modifyMVar_ (sPMapMV s) $ return . fmap (\x -> x {mute = True})

streamHush :: Stream -> IO ()
streamHush s = modifyMVar_ (sPMapMV s) $ return . fmap (\x -> x {pattern = silence, history = silence:history x})

streamUnmuteAll :: Stream -> IO ()
streamUnmuteAll s = modifyMVar_ (sPMapMV s) $ return . fmap (\x -> x {mute = False})

streamUnsoloAll :: Stream -> IO ()
streamUnsoloAll s = modifyMVar_ (sPMapMV s) $ return . fmap (\x -> x {solo = False})

streamSilence :: Stream -> ID -> IO ()
streamSilence s k = withPatIds s [k] (\x -> x {pattern = silence, history = silence:history x})

streamAll :: Stream -> (Signal ValueMap -> Signal ValueMap) -> IO ()
streamAll s f = do _ <- swapMVar (sGlobalFMV s) f
                   return ()

streamGet :: Stream -> String -> IO (Maybe Value)
streamGet s k = Map.lookup k <$> readMVar (sStateMV s)

streamSet :: Valuable a => Stream -> String -> Signal a -> IO ()
streamSet s k pat = do sMap <- takeMVar $ sStateMV s
                       let pat' = toValue <$> pat
                           sMap' = Map.insert k (VSignal pat') sMap
                       putMVar (sStateMV s) $ sMap'

streamSetI :: Stream -> String -> Signal Int -> IO ()
streamSetI = streamSet

streamSetF :: Stream -> String -> Signal Double -> IO ()
streamSetF = streamSet

streamSetS :: Stream -> String -> Signal String -> IO ()
streamSetS = streamSet

streamSetB :: Stream -> String -> Signal Bool -> IO ()
streamSetB = streamSet

streamSetR :: Stream -> String -> Signal Rational -> IO ()
streamSetR = streamSet

openListener :: Config -> IO (Maybe O.Udp)
openListener c
  | cCtrlListen c = catchAny run (\_ -> do verbose c "That port isn't available, perhaps another Tidal instance is already listening on that port?"
                                           return Nothing
                                 )
  | otherwise  = return Nothing
  where
        run = do sock <- O.udpServer (cCtrlAddr c) (cCtrlPort c)
                 when (cCtrlBroadcast c) $ N.setSocketOption (O.udpSocket sock) N.Broadcast 1
                 return $ Just sock
        catchAny :: IO a -> (E.SomeException -> IO a) -> IO a
        catchAny = E.catch

-- Listen to and act on OSC control messages
ctrlResponder :: Config -> Stream -> IO ()
ctrlResponder _ (stream@(Stream {sListen = Just sock})) = loop
  where
    loop :: IO ()
    loop = do O.recvMessages sock >>= mapM_ act
              loop
    -- External controller commands
    act :: O.Message -> IO ()
    act (O.Message "/ctrl" (O.Int32 k:v:[]))
      = act (O.Message "/ctrl" [O.string $ show k,v])
    act (O.Message "/ctrl" (O.AsciiString k:v@(O.Float _):[]))
      = add (O.ascii_to_string k) (VF (fromJust $ O.datum_floating v))
    act (O.Message "/ctrl" (O.AsciiString k:O.AsciiString v:[]))
      = add (O.ascii_to_string k) (VS (O.ascii_to_string v))
    act (O.Message "/ctrl" (O.AsciiString k:O.Int32 v:[]))
      = add (O.ascii_to_string k) (VI (fromIntegral v))
    -- Stream playback commands
    act (O.Message "/mute" (k:[]))
      = withID k $ streamMute stream
    act (O.Message "/unmute" (k:[]))
      = withID k $ streamUnmute stream
    act (O.Message "/solo" (k:[]))
      = withID k $ streamSolo stream
    act (O.Message "/unsolo" (k:[]))
      = withID k $ streamUnsolo stream
    act (O.Message "/muteAll" [])
      = streamMuteAll stream
    act (O.Message "/unmuteAll" [])
      = streamUnmuteAll stream
    act (O.Message "/unsoloAll" [])
      = streamUnsoloAll stream
    act (O.Message "/hush" [])
      = streamHush stream
    act (O.Message "/silence" (k:[]))
      = withID k $ streamSilence stream
    act m = hPutStrLn stderr $ "Unhandled OSC: " ++ show m
    add :: String -> Value -> IO ()
    add k v = do sMap <- takeMVar (sStateMV stream)
                 putMVar (sStateMV stream) $ Map.insert k v sMap
                 return ()
    withID :: O.Datum -> (ID -> IO ()) -> IO ()
    withID (O.AsciiString k) func = func $ (ID . O.ascii_to_string) k
    withID (O.Int32 k) func       = func $ (ID . show) k
    withID _ _                    = return ()
ctrlResponder _ _ = return ()

verbose :: Config -> String -> IO ()
verbose c s = when (cVerbose c) $ putStrLn s

recvMessagesTimeout :: (O.Transport t) => Double -> t -> IO [O.Message]
recvMessagesTimeout n sock = fmap (maybe [] O.packetMessages) $ O.recvPacketTimeout n sock

streamGetcps :: Stream -> IO Double
streamGetcps s = do
  let config = sConfig s
  ss <- Link.createAndCaptureAppSessionState (sLink s)
  bpm <- Link.getTempo ss
  return $! coerce $ bpm / (cBeatsPerCycle config) / 60

streamGetnow :: Stream -> IO Double
streamGetnow s = do
  let config = sConfig s
  ss <- Link.createAndCaptureAppSessionState (sLink s)
  now <- Link.clock (sLink s)
  beat <- Link.beatAtTime ss now (cQuantum config)
  return $! coerce $ beat / (cBeatsPerCycle config)
