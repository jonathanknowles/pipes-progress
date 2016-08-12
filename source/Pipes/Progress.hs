{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards            #-}

{-|
    Module      : Pipes.Progress
    Description : Provides primitives for monitoring the progress of streaming computations.
    Stability   : experimental
    Portability : portable
-}

module Pipes.Progress
    (
    -- * Introduction
    -- $introduction

    -- * Types
      Monitor (..)
    , MonitorableEffect (..)
    , TimePeriod

    -- * Functions

    -- ** Running a 'MonitorableEffect'
    , runMonitoredEffect
    , runSafeMonitoredEffect

    -- ** Running a 'MonitorableEffect' without a 'Monitor'
    , runUnmonitoredEffect
    , runSafeUnmonitoredEffect
    )
where

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

{- $introduction

    When performing a streaming computation, it's often desirable to have some
    way of monitoring the progress of that computation. This is especially the
    case for computations initiated through a user interface, where it's
    important to give the user an idea of how much progress has been made, and
    how much work is left.

    This module provides convenient primitives for building both monitorable
    computations (represented by values of the 'MonitorableEffect' type) and
    monitors (represented by values of the 'Monitor' type).

    Furthermore, this module provides functions that connect computations and
    monitors together, so that:

    * progress can be reported on a regular basis, even in situations where
      the underlying computation has stalled;

    * concurrency issues created by reading the changing state of a computation
      are handled correctly and safely;

    * termination is handled automatically: when the underlying computation
      terminates, the monitor is notified immediately with the final status of
      the computation.
-}

{-| An object capable of monitoring the progress of a streaming computation
    encapsulated by a 'MonitorableEffect'.
-}
data Monitor status m = Monitor
    { -- | a consumer capable of receiving status updates (or a termination signal).
      monitorStatusUpdates :: Consumer (Terminated status) m ()
    , -- | the period of time required between consecutive status updates.
      monitorStatusPeriod  :: TimePeriod
    }

{-| Encapsulates a streaming computation whose progress can be monitored
    by a 'Monitor'.
-}
data MonitorableEffect status m result = MonitorableEffect
    { -- | a producer capable of producing status updates as the result of
      --   an underlying computation.
      effectStatusUpdates :: Producer status m result
    , -- | specifies a starting state, to be reported when the computation
      --   has yet to begin making progress, and the first status update
      --   has yet to be produced.
      effectStatusInitial :: status }

newtype TimePeriod = TimePeriod NominalDiffTime
    deriving (Enum, Eq, Fractional, Num, Ord, Real, RealFrac, Show)

-- | Runs the computation encapsulated by the specified 'MonitorableEffect' argument,
--   passing status updates at regular intervals to the specified 'Monitor'.
--
--   Computations proceed in three phases:
--
--   1. /Before the underlying computation is initiated/, a single progress update is sent
--   to the monitor with the initial state of the computation.
--
--   1. /After the underlying computation is initiated/, progress updates are sent at
--   regular, fixed intervals to the monitor. These updates continue to be sent /even if/
--   the underlying computation has stalled or otherwise not made progress during a given
--   interval.
--
--   1. /Immediately after the underlying computation has completed/, a single progress
--   update is sent to the monitor with the final state of the computation, followed by
--   an 'End' signal to notify the monitor that it will receive no more status updates.
--
--   The following diagram depicts an example computation:
--
-- >        flow of time: |------>|------>|------>|--- ··· --->|------>|------>|------>|
-- >                      t       t       t       t    ···     t       t       t       t
-- >                      0       1       2       3    ···   (n−3)   (n−2)   (n−1)     n
-- >                      │       │       │       │            │       │       │
-- >   updates generated  │       │       │       │            │       │       │
-- >  by the computation: │    u u│u u u  │       │    ···     │u u u u│u     u│u u
-- >                      │    │  │       │       │            │       │       │  │
-- >        updates sent  │    │  │       │       │            │       │       │  │
-- >      to the monitor: v    │  v       v       v    ···     v       v       v  │ve
-- >                      │    │                                                  │││
-- >                      │    │                                                  ││╰─ END signal
-- >                      │    │                                                  ││
-- >        first status ─╯    ╰─ first status                       last status ─╯╰── last status
-- >         update sent          update generated              update generated       update sent
-- >      to the monitor          by the computation          by the computation       to the monitor
-- >    (STARTING STATE)                                                               (FINAL STATE)
--
--   Notes for the above diagram:
--
--   1. An update is sent to the monitor at time @t0@ (with the starting state),
--      even though no progress is made until some time after @t0@ and before @t1@.
--
--   1. An update is sent to the monitor at time @t3@, even though no progress
--      at all is made between time @t2@ and @t3@.
--
--   1. An update is sent to the monitor immediately after the computation
--      terminates (which occurs between time @t(n−1)@ and @tn@), which is then
--      followed by an immediate 'End' signal.
--
runMonitoredEffect :: (MonadBaseControl IO m, MonadIO m)
                   => Monitor s m -- ^ the monitor
                   -> MonitorableEffect s m r -- ^ the computation to be monitored
                   -> m r -- ^ the result
runMonitoredEffect Monitor {..} MonitorableEffect {..} = do
    b0 <- B.create $ P.latest $ Just effectStatusInitial
    b1 <- B.create $ P.bounded 1
    let e0 = effectStatusUpdates >-> P.map Just
                                 >-> (B.write b0 >> forever await)
    let e1 = B.read b0 >-> yieldPeriodically monitorStatusPeriod
                       >-> P.concat >-> P.map Value
                       >-> B.write b1
    let e2 = B.read b1 >-> monitorStatusUpdates
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

{-| Runs a /safe/ computation encapsulated by the specified 'MonitorableEffect'
    argument, passing progress status updates at regular intervals to the
    specified 'Monitor'.

    See 'runMonitoredEffect' for details of how this function is evaluated.
-}
runSafeMonitoredEffect :: (MonadBaseControl IO m, PS.MonadMask m, MonadIO m)
                       => Monitor s (PS.SafeT m) -- ^ the monitor
                       -> MonitorableEffect s (PS.SafeT m) r -- ^ the computation to be monitored
                       -> m r -- ^ the result
runSafeMonitoredEffect = (PS.runSafeT .) . runMonitoredEffect

{-| Runs the computation encapsulated by the specified 'MonitorableEffect'
    argument /silently/, and /without monitoring/.
-}
runUnmonitoredEffect :: (MonadBaseControl IO m, MonadIO m)
                     => MonitorableEffect s m r -- ^ the computation to run without monitoring
                     -> m r -- ^ the result
runUnmonitoredEffect MonitorableEffect {..} =
    P.runEffect (effectStatusUpdates >-> P.drain)

{-| Runs a /safe/ computation encapsulated by the specified 'MonitorableEffect'
    argument /silently/, and /without monitoring/.
-}
runSafeUnmonitoredEffect :: (MonadBaseControl IO m, PS.MonadMask m, MonadIO m)
                         => MonitorableEffect s (PS.SafeT m) r -- ^ the computation to run without monitoring
                         -> m r -- ^ the result
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

