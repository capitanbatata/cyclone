-- | State of a node, plus operations on this state.
--
-- The state includes an in memory list of peers.
--
module Cyclone.State
    ( -- * State
      State
    , mkState
      -- * Peers
    , setPeers
    , removePeer
    , getPeers
    , thisPid
      -- * Message sending logic
    , startTalk
    , canTalk
    , stopTalk
    , acqTalk
    , relTalk
      -- * Inbound queue
    , appendNumber
    , getReceivedNumbers
    , getNumber
    , lastNumberOf
    , appendRepeatNumber
    )
where

import           Control.Concurrent.MVar     (MVar, modifyMVar, newMVar,
                                              putMVar, takeMVar)
import           Control.Concurrent.STM      (STM, atomically, retry)
import           Control.Concurrent.STM.TVar (TVar, modifyTVar', newTVarIO,
                                              readTVar, readTVarIO, writeTVar)
import           Control.Distributed.Process (ProcessId)
import           Control.Monad.IO.Class      (MonadIO, liftIO)
import           Data.Map.Strict             (Map)
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (maybeToList)
import           Data.Set                    (Set)
import qualified Data.Set                    as Set
import           System.Random               (StdGen, mkStdGen, randomR)

import           Cyclone.Messages            (Number, Repeat (Repeat), who)

data State = State
    { -- | List of peers known so far.
      _peers      :: TVar [ProcessId]
      -- | Process id of the current process (where the state was created).
    , thisPid     :: ProcessId
      -- | List of numbers received so far.
    , _inbound    :: TVar (Set Number)
      -- | Can messages be sent?
    , _talk       :: TVar Bool
    , -- | Random generator
      _rndGen     :: MVar StdGen
    , -- | Last values received by the peers
      _lastNumber :: TVar (Map ProcessId [Number])
    , -- | Lock to be acquired before start sending messages to peers, and
      -- released afterwards.
      _talkLock   :: MVar ()
    }

-- | Create a new state, setting the given process id as the current process,
-- and creating a random number generator with the given seed.
--
mkState :: MonadIO m => ProcessId -> Int -> m State
mkState pid seed = liftIO $
    State <$> newTVarIO []
          <*> pure pid
          <*> newTVarIO Set.empty
          <*> newTVarIO False -- Don't talk at the beginning.
          <*> newMVar (mkStdGen seed)
          <*> newTVarIO Map.empty
          <*> newMVar ()

-- | When a peer is set, the neighbor will be determined.
--
setPeers :: MonadIO m => State -> [ProcessId] -> m ()
setPeers st ps = liftIO $ atomically $ setPeersSTM st ps

setPeersSTM :: State -> [ProcessId] -> STM ()
setPeersSTM st = writeTVar (_peers st)

-- | Remove a peer from the list. If the process that was removed is the
-- neighbor of the current process, then the new neighbor is updated.
removePeer :: MonadIO m => State -> ProcessId -> m ()
removePeer st pid = liftIO $ atomically $ do
    oldPeers <- readTVar (_peers st)
    setPeersSTM st (filter (/= pid) oldPeers)

-- | Get the current list of peers (not including the current process id),
-- retrying if the list of peers is empty.
getPeers :: MonadIO m => State -> m [ProcessId]
getPeers st = liftIO $ atomically $ do
    ps <- readTVar (_peers st)
    if null ps
        then retry
        else return $ filter (/= thisPid st) ps

-- | Append a @Number@ to the list of numbers received so far.
--
-- If the number that is received in the set of messages awaiting
-- acknowledgment, then it is removed from it.
appendNumber :: MonadIO m => State -> Number -> m ()
appendNumber st n = liftIO $ atomically $ do
    modifyTVar' (_inbound st) (Set.insert n)
    modifyTVar' (_lastNumber st) (Map.insertWith f (who n) [n])
    where
      -- Add the number to the head of the list, while keeping always a
      -- constant number of elements (we are not interested in old messages).
      -- For now this number is not configurable.
      f [x] ys = x : take 10 ys
      f _ _    = undefined -- This cannot happen. Keeps the compiler happy.

-- | Retrieve all the numbers received so far.
getReceivedNumbers :: MonadIO m => State -> m [Number]
getReceivedNumbers st =
    fmap Set.toAscList . liftIO  . readTVarIO $ _inbound st

-- | Signal that a process can start talking.
startTalk :: MonadIO m => State -> m ()
startTalk st = liftIO $ atomically $ writeTVar (_talk st) True

-- | Can a process start talking?
canTalk :: MonadIO m => State -> m Bool
canTalk st = liftIO $ readTVarIO (_talk st)

-- | Signal that a process has to stop talking.
stopTalk :: MonadIO m => State -> m ()
stopTalk st = liftIO $ atomically $ writeTVar (_talk st) False

-- | Get a random number, updating the state of the generator.
getNumber :: MonadIO m => State -> m Double
getNumber st = liftIO $ modifyMVar (_rndGen st) genValidDouble
    where
        genValidDouble g = let (v, g') = randomR (0, 1) g in
            if v == 0 then genValidDouble g else return (g', v)

-- | Retrieve the last number (if any), what we received from the given peer.
lastNumberOf :: MonadIO m => State -> ProcessId -> m [Number]
lastNumberOf st pid = fmap (concat . maybeToList . Map.lookup pid )
                    . liftIO
                    . readTVarIO
                    $ _lastNumber st

acqTalk :: MonadIO m => State -> m ()
acqTalk st = liftIO $ takeMVar (_talkLock st)

relTalk :: MonadIO m => State -> m ()
relTalk st = liftIO $ putMVar (_talkLock st) ()

-- | Like append number, but without inserting the message in the list of
-- messages seen by a peer, since this is a repeated message sent when a peer
-- dies.
appendRepeatNumber :: MonadIO m => State -> Repeat -> m ()
appendRepeatNumber st (Repeat n) = liftIO $ atomically $
    modifyTVar' (_inbound st) (Set.insert n)
