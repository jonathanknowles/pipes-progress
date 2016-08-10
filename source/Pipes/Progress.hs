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

-- TODO: get rid of this: it should be a parameter.
class Start s where start :: s

newtype Start s => MonitorableEffect s m r = MonitorableEffect (Producer s m r)
    deriving (Functor, Applicative, Monad, MonadIO)

unbox :: Start s => MonitorableEffect s m r -> Producer s m r
unbox (MonitorableEffect e) = e

data Monitor s m = Monitor
    { monitor       :: Consumer (Terminated s) m ()
    , monitorPeriod :: TimePeriod }

newtype TimePeriod = TimePeriod NominalDiffTime
    deriving (Enum, Eq, Fractional, Num, Ord, Real, RealFrac, Show)

-- | periods: │<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│
-- |  inputs:    i i i i i i     i i i i i i i         i i i i i     i i i
-- | outputs: o  │    o       o       o       o       o       o       o  │o
-- |          │  │                                                       ││
-- |    first─┘  └─first                                           final─┘└─last
-- |   output      input                                           input    output
-- |

runMonitoredEffect :: (MonadBaseControl IO m, MonadIO m, Start s)
    => Monitor s m -> MonitorableEffect s m r -> m r
runMonitoredEffect Monitor {..} (MonitorableEffect effect) = do
    b0 <- B.create $ P.latest $ Just start
    b1 <- B.create $ P.bounded 1
    let e0 = effect >-> P.map Just
                    >-> (B.write b0 >> forever await)
    let e1 = B.read b0 >-> yieldPeriodically monitorPeriod
                       >-> P.concat >-> P.map Value
                       >-> B.write b1
    let e2 = B.read b1 >-> monitor
    withAsync (runEffect e2) $ \a -> do
        result <- withAsync (runEffect e1) $ const $ do
            result <- runEffect e0
            liftIO $ do
                atomically $ do
                    v <- B.readOnce b0
                    B.writeOnce b0 Nothing
                    B.writeOnce b1 $ Value $
                        fromMaybe start $ join v
                atomically $
                    B.writeOnce b1 End
                B.seal b0
                B.seal b1
                wait a
            pure result
        pure result

runUnmonitoredEffect :: (MonadBaseControl IO m, MonadIO m, Start s)
    => MonitorableEffect s m r -> m r
runUnmonitoredEffect (MonitorableEffect e) = P.runEffect (e >-> P.drain)

runSafeMonitoredEffect :: (MonadBaseControl IO m, PS.MonadMask m, MonadIO m, Start s)
    => Monitor s (PS.SafeT m) -> MonitorableEffect s (PS.SafeT m) r -> m r
runSafeMonitoredEffect = (PS.runSafeT .) . runMonitoredEffect

runSafeUnmonitoredEffect :: (MonadBaseControl IO m, PS.MonadMask m, MonadIO m, Start s)
    => MonitorableEffect s (PS.SafeT m) r -> m r
runSafeUnmonitoredEffect (MonitorableEffect e) = PS.runSafeT $ P.runEffect (e >-> P.drain)

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

{-
data ObservableEffect m a r = ObservableEffect
    { effect :: Producer a m r
    , effectDefault :: a }

instance Monad m => Functor (ObservableEffect m a) where
    fmap f e = e { effect = f <$> effect e }

instance Monad m => Applicative (ObservableEffect m a) where
    pf <*> px = ObservableEffect { effect = effect pf <*> effect px
                                 , effectDefault = effectDefault px
                                 }
    pure (r, a) = ObservableEffect { effect = pure r
                              , effectDefault = a}

newtype MonitorableEffect a m r = MonitorableEffect
    { effect :: Producer a m r }

instance Monad m => Functor (MonitorableEffect a m) where
    fmap f e = e { effect = f <$> effect e }

instance Monad m => Applicative (MonitorableEffect a m) where
    pf <*> px = MonitorableEffect { effect = effect pf <*> effect px }
    pure r = MonitorableEffect { effect = pure r }

instance Monad m => Monad (MonitorableEffect a m) where
    a >>= b = MonitorableEffect { effect = effect a >>= effect . b}
    return r = MonitorableEffect { effect = return r }

instance MonadIO m => MonadIO (MonitorableEffect a m) where
    liftIO x = MonitorableEffect { effect = liftIO x }
--}
