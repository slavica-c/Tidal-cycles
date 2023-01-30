{-# LANGUAGE RecordWildCards #-}
module Sound.Tidal.Listener where

import Data.Default (def)

import Sound.Tidal.Stream (Target(..), streamGetcps)
import Sound.Tidal.ID
import qualified Sound.Tidal.Context as T
import Sound.Tidal.Hint
import Sound.Tidal.Listener.Config
import Sound.Osc.Fd as O
import Control.Concurrent
import Control.Concurrent.MVar
import qualified Network.Socket as N
import qualified Sound.Tidal.Tempo as Tempo
import System.Environment(lookupEnv)

{-
https://github.com/tidalcycles/tidal-listener/wiki
-}

data State = State {sIn :: MVar InterpreterMessage,
                    sOut :: MVar InterpreterResponse,
                    sLocal :: Udp,
                    sRemote :: N.SockAddr,
                    sStream :: T.Stream
                   }


-- | Start Haskell interpreter, with input and output mutable variables to
-- communicate with it
listen :: IO ()
listen = listenWithConfig def

-- | Configurable variant of @listen@
listenWithConfig :: ListenerConfig -> IO ()
listenWithConfig ListenerConfig{..} = do
            env <- lookupEnv "WITH_GHC"
            let mode = if env /= (Just "FALSE") then "with-ghc-mode" else "without-ghc-mode"
            -- listen
            (remote_addr:_) <- N.getAddrInfo Nothing (Just "127.0.0.1") Nothing
            local <- udpServer "127.0.0.1" listenPort
            putStrLn $ "Starting Tidal Listener in " ++ mode
            putStrLn $ "Listening for OSC commands on port " ++ show listenPort
            putStrLn $ "Sending replies to port " ++ show remotePort
            let remoteTarget = Target {oName = "editor",
                                       oAddress = "127.0.0.1",
                                       oPort = remotePort,
                                       oBusPort = Nothing,
                                       oLatency = 0.1,
                                       oWindow = Nothing,
                                       oSchedule = T.Live,
                                       oHandshake = False}
            stream <- T.startStream T.defaultConfig [(T.superdirtTarget {oLatency = 0.1},
                                                      [T.superdirtShape]
                                                     ),
                                                     (remoteTarget,
                                                      [T.OSCContext "/code/highlight"]
                                                     )
                                                    ]
            mIn <- newEmptyMVar
            mOut <- newEmptyMVar

            putStrLn "Starting tidal interpreter.. "
            forkIO $ startHintJob True stream mIn mOut

            let (N.SockAddrInet _ a) = N.addrAddress remote_addr
                remote  = N.SockAddrInet (fromIntegral remotePort) a
                st      = State mIn mOut local remote stream
            loop st
              where
                loop st =
                  do -- wait for, read and act on OSC message
                     m <- recvMessage (sLocal st)
                     st' <- act st m
                     loop st'


act :: State -> Maybe O.Message -> IO State

-- ask the interpreter to execute a statment: statments are expressions of type IO a or bindings/definitions,
-- in case of execution of an action of type IO a, the interpreter will try to show a and send it back
-- if a doesn't have a Show instance, an error is thrown
act st (Just (Message "/eval" [AsciiString statement])) =
  do putMVar (sIn st) (MStat $ ascii_to_string statement)
     r <- takeMVar (sOut st)
     case r of
       RStat (Just x) -> O.sendTo (sLocal st) (O.p_message "/eval/value" [string x]) (sRemote st)
       RStat Nothing -> O.sendTo (sLocal st) (O.p_message "/eval/ok" []) (sRemote st)
       RError e -> O.sendTo (sLocal st) (O.p_message "/eval/error" [string e]) (sRemote st)
     return st

-- ask the interpreter for the type of an expression
act st (Just (Message "/type" [AsciiString expression])) =
   do putMVar (sIn st) (MType $ ascii_to_string expression)
      r <- takeMVar (sOut st)
      case r of
        RType t -> O.sendTo (sLocal st) (O.p_message "/type/ok" [string t]) (sRemote st)
        RError e -> O.sendTo (sLocal st) (O.p_message "/type/error" [string e]) (sRemote st)
      return st

act st (Just (Message "/load" [AsciiString path])) =
   do putMVar (sIn st) (MLoad $ ascii_to_string path)
      r <- takeMVar (sOut st)
      case r of
        RStat (Just x) -> O.sendTo (sLocal st) (O.p_message "/load/value" [string x]) (sRemote st) --cannot happen
        RStat Nothing -> O.sendTo (sLocal st) (O.p_message "/load/ok" []) (sRemote st)
        RError e -> O.sendTo (sLocal st) (O.p_message "/load/error" [string e]) (sRemote st)
      return st

-- test if the listener is responsive
act st (Just (Message "/ping" [])) =
  do O.sendTo (sLocal st) (O.p_message "/pong" []) (sRemote st)
     return st

-- get the current cps of the running stream
act st (Just (Message "/cps" [])) =
  do cps <- streamGetcps (sStream st)
     O.sendTo (sLocal st) (O.p_message "/cps" [float cps]) (sRemote st)
     return st

act st Nothing = do putStrLn "Not a message?"
                    return st
act st (Just m) = do putStrLn $ "Unhandled message: " ++ show m
                     return st
