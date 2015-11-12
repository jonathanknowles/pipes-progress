{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}

module Pipes.Progress
    where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, waitCatch)
import Control.Concurrent.Async.Lifted (Async, async, wait, withAsync)
import Control.Exception (throwIO)
import Control.Monad (forever, unless)
import Control.Monad.Trans (MonadIO, liftIO)
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Maybe (fromMaybe)
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
    => TimePeriod
    -> a
    -> Producer a m r
    -> Consumer a m ()
    -> m r
runMonitoredEffect period start source target = do
    b0 <- B.create $ P.latest start
    b1 <- B.create $ P.bounded 1
    let e0 = source >-> (B.write b0 >> forever await)
    let e1 = B.read b0 >-> yieldPeriodically period >-> B.write b1
    let e2 = B.read b1 >-> target
    withAsync (runEffect e2) $ \a -> do
        result <- withAsync (runEffect e1) $ const (runEffect e0)
        liftIO $ do
            atomically $
                B.writeOnce b1 . fromMaybe start =<< B.readOnce b0
            wait a
        pure result

asyncWithGC :: IO a -> IO (Async a)
asyncWithGC a = async $ do
    r <- a
    P.performGC
    return r

