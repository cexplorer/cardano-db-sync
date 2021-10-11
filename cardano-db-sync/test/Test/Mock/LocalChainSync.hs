
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}


module Test.Mock.LocalChainSync
  ( ChainAction (..)
  , playChainFragment
  ) where

import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadSTM.Strict

import           Network.TypedProtocol.Proofs (connectPipelined)

import           Ouroboros.Network.Block (HasHeader (..), HeaderHash, Tip (..), castPoint, castTip,
                   genesisPoint)
import           Ouroboros.Network.MockChain.Chain (Chain (..), ChainUpdate (..), Point (..))
import qualified Ouroboros.Network.MockChain.Chain as Chain
import           Ouroboros.Network.MockChain.ProducerState (ChainProducerState (..), FollowerId)
import qualified Ouroboros.Network.MockChain.ProducerState as ChainProducerState
import           Ouroboros.Network.Protocol.ChainSync.ClientPipelined (ChainSyncClientPipelined,
                   chainSyncClientPeerPipelined)
import           Ouroboros.Network.Protocol.ChainSync.Server (ChainSyncServer (..),
                   ServerStIdle (..), ServerStIntersect (..), ServerStNext (..),
                   chainSyncServerPeer)



data ChainAction blk
  = RollForward !blk
  | RollBackward !(Point blk)
  deriving (Eq, Show)

playChainFragment
    :: forall blk m a. (MonadAsync m, HasHeader blk)
    => [ChainAction blk] -> ChainSyncClientPipelined blk (Point blk) (Tip blk) m a
    -> m a
playChainFragment chainActions0 targetChainSyncClient = do
    cpsvar <- newTVarIO (ChainProducerState.initChainProducerState Genesis)
    snd <$>
      serverDriver cpsvar chainActions0
      `concurrently`
      (fst3 <$>
        -- run the client against server without any network in between,
        -- like a consumer stream against a producer.
        connectPipelined []
          (chainSyncClientPeerPipelined targetChainSyncClient)
          (chainSyncServerPeer (mockChainSyncServer () cpsvar)))
  where
    serverDriver :: StrictTVar m (ChainProducerState blk) -> [ChainAction blk] -> m ()
    serverDriver _cpsvar [] = pure ()

    serverDriver  cpsvar (RollForward block : chainActions) = do
      atomically $ do
        cps <- readTVar cpsvar
        writeTVar cpsvar (ChainProducerState.addBlock block cps)
      serverDriver cpsvar chainActions

    serverDriver  cpsvar (RollBackward point : chainActions) = do
      atomically $ do
        cps <- readTVar cpsvar
        case ChainProducerState.rollback (point :: Point blk) cps of
              Just cps' -> writeTVar cpsvar cps'
              Nothing   -> error "serverDriver: impossible happened"
      serverDriver cpsvar chainActions

fst3 :: (a, b, c) -> a
fst3 (a, _, _) = a

mockChainSyncServer
    :: forall blk header m a.
        (HasHeader header , MonadSTM m , HeaderHash header ~ HeaderHash blk)
    => a -> StrictTVar m (ChainProducerState header)
    -> ChainSyncServer header (Point blk) (Tip blk) m a
mockChainSyncServer recvDoneClient chainvar =
    ChainSyncServer $ idle <$> newFollower
  where
    idle :: FollowerId -> ServerStIdle header (Point blk) (Tip blk) m a
    idle fid =
      ServerStIdle
        { recvMsgRequestNext = handleRequestNext fid
        , recvMsgFindIntersect = handleFindIntersect fid
        , recvMsgDoneClient = pure recvDoneClient
        }

    idleNext :: FollowerId -> ChainSyncServer header (Point blk) (Tip blk) m a
    idleNext = ChainSyncServer . pure . idle

    handleRequestNext
        :: FollowerId
        -> m (Either (ServerStNext header (Point blk) (Tip blk) m a) (m (ServerStNext header (Point blk) (Tip blk) m a)))
    handleRequestNext r = do
      mupdate <- tryReadChainUpdate r
      case mupdate of
        Just update -> pure (Left (sendNext r update))
        Nothing     -> pure (Right (sendNext r <$> readChainUpdate r))
                       -- Follower is at the head, have to block and wait for
                       -- the producer's state to change.

    sendNext
        :: FollowerId -> (Tip blk, ChainUpdate header header)
        -> ServerStNext header (Point blk) (Tip blk) m a
    sendNext r (tip, AddBlock b) = SendMsgRollForward  b tip (idleNext r)
    sendNext r (tip, RollBack p) = SendMsgRollBackward (castPoint p) tip (idleNext r)

    handleFindIntersect
        :: FollowerId -> [Point blk]
        -> m (ServerStIntersect header (Point blk) (Tip blk) m a)
    handleFindIntersect r points = do
      -- TODO: guard number of points
      -- Find the first point that is on our chain
      changed <- improveReadPoint r points
      case changed of
        (Just pt, tip) -> pure $ SendMsgIntersectFound pt tip (idleNext r)
        (Nothing, tip) -> pure $ SendMsgIntersectNotFound tip (idleNext r)

    newFollower :: m FollowerId
    newFollower =
      atomically $ do
        cps <- readTVar chainvar
        let (cps', rid) = ChainProducerState.initFollower genesisPoint cps
        writeTVar chainvar cps'
        pure rid

    improveReadPoint :: FollowerId -> [Point blk] -> m (Maybe (Point blk), Tip blk)
    improveReadPoint rid points =
      atomically $ do
        cps <- readTVar chainvar
        case ChainProducerState.findFirstPoint (map castPoint points) cps of
          Nothing -> let chain = ChainProducerState.chainState cps in
                        pure (Nothing, castTip (Chain.headTip chain))
          Just ipoint -> do
            let !cps' = ChainProducerState.updateFollower rid ipoint cps
            writeTVar chainvar cps'
            let chain = ChainProducerState.chainState cps'
            pure (Just (castPoint ipoint), castTip (Chain.headTip chain))

    tryReadChainUpdate :: FollowerId -> m (Maybe (Tip blk, ChainUpdate header header))
    tryReadChainUpdate rid =
      atomically $ do
        cps <- readTVar chainvar
        case ChainProducerState.followerInstruction rid cps of
          Nothing -> pure Nothing
          Just (u, cps') -> do
            writeTVar chainvar cps'
            let chain = ChainProducerState.chainState cps'
            pure $ Just (castTip (Chain.headTip chain), u)

    readChainUpdate :: FollowerId -> m (Tip blk, ChainUpdate header header)
    readChainUpdate rid =
      atomically $ do
        cps <- readTVar chainvar
        case ChainProducerState.followerInstruction rid cps of
          Nothing -> retry
          Just (u, cps') -> do
            writeTVar chainvar cps'
            let chain = ChainProducerState.chainState cps'
            pure (castTip (Chain.headTip chain), u)