{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE RecordWildCards            #-}

module Pipes.Progress
    where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async.Lifted (Async, async, cancel, wait, withAsync)
import Control.Monad (forever, unless)
import Control.Monad.Trans (MonadIO, liftIO)
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Pipes (Consumer, Effect (..), Pipe, Producer, await, runEffect, yield, (>->))
import Pipes.Buffer (Buffer)
import Pipes.Concurrent (STM, atomically)
import Pipes.Termination (Terminated (..))
import Pipes.Safe (MonadSafe, SafeT)

import qualified Control.Foldl     as F
import qualified Pipes             as P
import qualified Pipes.Buffer      as B
import qualified Pipes.Concurrent  as P
import qualified Pipes.Prelude     as P
import qualified Pipes.Safe        as PS

newtype TimePeriod = TimePeriod NominalDiffTime
    deriving (Enum, Eq, Fractional, Num, Ord, Real, RealFrac, Show)

yieldUntil :: (a -> Bool) -> Pipe a a IO ()
yieldUntil isFinal = loop where
    loop = do
        v <- await
        yield v
        unless (isFinal v) loop

yieldPeriodically :: MonadIO m => TimePeriod -> Pipe a a m r
yieldPeriodically (TimePeriod p)=
    loop =<< liftIO getCurrentTime where
        loop next = do
            liftIO $ pauseThreadUntil next
            await >>= yield
            loop $ addUTCTime p next

yieldPeriodicallyUntil :: MonadIO m => (a -> Bool) -> TimePeriod -> Pipe a a m ()
yieldPeriodicallyUntil isFinal (TimePeriod p) =
    t =<< liftIO getCurrentTime where
        t next = do
            liftIO $ pauseThreadUntil next
            v <- await
            yield v
            unless (isFinal v) (t $ addUTCTime p next)

pauseThreadUntil :: UTCTime -> IO ()
pauseThreadUntil t = do
    now <- getCurrentTime
    case compare now t of
        LT -> threadDelay $ truncate $ diffUTCTime t now * 1000000
        _  -> return ()

data Signal a m r = Signal
    { signal        :: Producer a m r
    , signalDefault :: a }

data Monitor a m = Monitor
    { monitor       :: Consumer (Terminated a) m ()
    , monitorPeriod :: TimePeriod }

-- | periods: │<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│
-- |  chunks:    c c c c c c     c c c c c c c         c c c c c     c c c
-- | updates: u  │    u       u       u       u       u       u       u  │u
-- |          │  │                                                       ││
-- |    first─┘  └─first                                           final─┘└─last
-- |   update      chunk                                           chunk    update
-- |
runMonitoredEffect :: (MonadBaseControl IO m, MonadIO m)
    => Signal a m r -> Monitor a m -> m r
runMonitoredEffect Signal {..} Monitor {..} = do
    b0 <- B.create $ P.latest $ Just signalDefault
    b1 <- B.create $ P.bounded 1
    let e0 = signal >-> P.map Just >-> (B.write b0 >> forever await)
    let e1 = B.read b0 >-> yieldPeriodically monitorPeriod >-> P.concat >-> P.map Value >-> B.write b1
    let e2 = B.read b1 >-> monitor
    withAsync (runEffect e2) $ \a2 -> do
        result <- withAsync (runEffect e1) $ \a1 -> do
            result <- runEffect e0
            liftIO $ do
                atomically $ B.writeOnce b1 . Value . fromMaybe signalDefault . (>>= id) =<< B.readOnce b0
                atomically $ B.writeOnce b0 Nothing
                atomically $ B.writeOnce b1 End
                B.seal b1
                wait a2
            pure result
        pure result

asyncWithGC :: IO a -> IO (Async a)
asyncWithGC a = async $ do
    r <- a
    P.performGC
    return r

