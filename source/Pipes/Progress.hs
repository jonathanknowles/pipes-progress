{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
--{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleInstances #-}

module Pipes.Progress where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async.Lifted (wait, withAsync)
import Control.Monad (forever, join)
import Control.Monad.Trans (MonadIO, liftIO)
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Maybe (fromMaybe)
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Pipes (Consumer, Pipe, Producer, await, runEffect, yield, (>->))
import Pipes.Buffer (Buffer)
import Pipes.Concurrent (atomically)
import Pipes.Termination (Terminated (..))
import Pipes.Safe (MonadSafe)

import qualified Pipes            as P
import qualified Pipes.Buffer     as B
import qualified Pipes.Concurrent as P
import qualified Pipes.Prelude    as P
import qualified Pipes.Safe       as PS

data MonitorableEffect s m r = MonitorableEffect
    { effectStatusUpdates :: Producer s m r
    , effectStatusInitial :: s }

data Monitor s m = Monitor
    { monitorTarget :: Consumer (Terminated s) m ()
    , monitorPeriod :: TimePeriod }

newtype TimePeriod = TimePeriod NominalDiffTime
    deriving (Enum, Eq, Fractional, Num, Ord, Real, RealFrac, Show)

-- | periods: │<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│
-- |  inputs:    i i i i i i     i i i i i i i         i i i i i     i i i
-- | outputs: o  │    o       o       o       o       o       o       o  │o
-- |          │  │                                                       ││
-- |    first─┘  └─first                                           final─┘└─last
-- |   output      input                                           input    output

runMonitoredEffect :: (MonadBaseControl IO m, MonadIO m)
    => Monitor s m -> MonitorableEffect s m r -> m r
runMonitoredEffect Monitor {..} MonitorableEffect {..} = do
    b0 <- B.create $ P.latest $ Just effectStatusInitial
    b1 <- B.create $ P.bounded 1
    let e0 = effectStatusUpdates >-> P.map Just
                                 >-> (B.write b0 >> forever await)
    let e1 = B.read b0 >-> yieldPeriodically monitorPeriod
                       >-> P.concat >-> P.map Value
                       >-> B.write b1
    let e2 = B.read b1 >-> monitorTarget
    withAsync (runEffect e2) $ \a -> do
        result <- withAsync (runEffect e1) $ const $ do
            result <- runEffect e0
            liftIO $ do
                atomically $ do
                    v <- B.readOnce b0
                    B.writeOnce b0 Nothing
                    B.writeOnce b1 $ Value $
                        fromMaybe effectStatusInitial $ join v
                atomically $
                    B.writeOnce b1 End
                B.seal b0
                B.seal b1
                wait a
            pure result
        pure result

runUnmonitoredEffect :: (MonadBaseControl IO m, MonadIO m)
    => MonitorableEffect s m r -> m r
runUnmonitoredEffect MonitorableEffect {..} =
    P.runEffect (effectStatusUpdates >-> P.drain)

runSafeMonitoredEffect :: (MonadBaseControl IO m, PS.MonadMask m, MonadIO m)
    => Monitor s (PS.SafeT m) -> MonitorableEffect s (PS.SafeT m) r -> m r
runSafeMonitoredEffect = (PS.runSafeT .) . runMonitoredEffect

runSafeUnmonitoredEffect :: (MonadBaseControl IO m, PS.MonadMask m, MonadIO m)
    => MonitorableEffect s (PS.SafeT m) r -> m r
runSafeUnmonitoredEffect MonitorableEffect {..} =
    PS.runSafeT $ P.runEffect (effectStatusUpdates >-> P.drain)

yieldPeriodically :: MonadIO m => TimePeriod -> Pipe a a m r
yieldPeriodically (TimePeriod p)=
    loop =<< liftIO getCurrentTime where
        loop next = do
            liftIO $ pauseThreadUntil next
            await >>= yield
            loop $ addUTCTime p next

pauseThreadUntil :: UTCTime -> IO ()
pauseThreadUntil t = do
    now <- getCurrentTime
    case compare now t of
        LT -> threadDelay $ truncate $ diffUTCTime t now * 1000000
        _  -> return ()

