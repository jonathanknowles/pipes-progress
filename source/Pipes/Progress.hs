{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}

module Pipes.Progress
    ( Monitor
    , TimePeriod (TimePeriod)
    , withMonitor ) where

import Control.Applicative
import Control.Concurrent       hiding (yield)
import Control.Concurrent.Async
import Control.Exception               (throwIO)
import Control.Foldl                   (Fold)
import Control.Monad
import Data.Maybe                      (fromMaybe)
import Data.Time.Clock
import Pipes                    hiding (every)
import Pipes.Concurrent                (atomically, STM)
import Pipes.Prelude
import Prelude                  hiding (map, take, takeWhile)

import qualified Control.Foldl    as F
import qualified Pipes            as P
import qualified Pipes.Buffer     as B
import qualified Pipes.Concurrent as P
import qualified Pipes.Prelude    as P

newtype TimePeriod = TimePeriod NominalDiffTime
    deriving (Enum, Eq, Fractional, Num, Ord, Real, RealFrac, Show)

yieldUntil :: (a -> Bool) -> Pipe a a IO ()
yieldUntil isFinal = loop where
    loop = do
        v <- await
        yield v
        unless (isFinal v) loop

yieldPeriodically :: MonadIO m => TimePeriod -> Pipe a a m ()
yieldPeriodically = yieldPeriodicallyUntil $ const False

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

data Action chunk m r = Action
    { runAction :: Pipe chunk chunk m () -> m r }

data Counter chunk count m = Counter
    { counter      :: Pipe chunk count m ()
    , counterStart :: count }

data Monitor count m = Monitor
    { monitor        :: Consumer (ProgressEvent count) m ()
    , monitorPeriod  :: TimePeriod }

catCounter :: Monad m => a -> Counter a a m
catCounter a = Counter
    { counter = P.cat
    , counterStart = a }

-- TODO: incorporate time into the events.
data ProgressEvent v
    = ProgressUpdateEvent v
    | ProgressCompletedEvent
    | ProgressInterruptedEvent

isFinal (ProgressUpdateEvent _) = False
isFinal ProgressCompletedEvent = True
isFinal ProgressInterruptedEvent = True

instance Functor ProgressEvent where
    fmap f (ProgressUpdateEvent v) = ProgressUpdateEvent $ f v
    fmap _ ProgressCompletedEvent = ProgressCompletedEvent
    fmap _ ProgressInterruptedEvent = ProgressInterruptedEvent

-- | periods: │<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│
-- |  chunks:    c c c c c c     c c c c c c c         c c c c c     c c c
-- | updates: u  │    u       u       u       u       u       u       u  │u
-- |          │  │                                                       ││
-- |    first─┘  └─first                                           final─┘└─last
-- |   update      chunk                                           chunk    update
-- |
withMonitor
    :: Action  chunk       IO r
    -> Counter chunk count IO
    -> Monitor       count IO
    ->                     IO r
withMonitor Action {..} Counter {..} Monitor {..} = do
    countBuffer <- liftIO $ B.create $ P.latest counterStart
    eventBuffer <- liftIO $ B.create $ P.bounded 1
    notifyAction <- liftIO $ async $ runEffect $
        B.read eventBuffer >-> monitor
    updateAction <- liftIO $ async $ runEffect $
        B.read countBuffer
            >-> yieldPeriodically monitorPeriod
            >-> P.map ProgressUpdateEvent
            >-> B.write eventBuffer
    mainAction <- liftIO $ async $ runAction $
        tee $ counter >-> B.write countBuffer
    waitCatch mainAction >>= \case
        Left exception -> do
            -- we should be cancelling actions here
            atomically $
                B.writeOnce eventBuffer ProgressInterruptedEvent
            B.seal eventBuffer
            B.seal countBuffer
            throwIO exception
        Right result -> do
            atomically $
                B.readOnce countBuffer
                    >>= B.writeOnce eventBuffer
                        . ProgressUpdateEvent
                        . fromMaybe counterStart
            atomically $
                B.writeOnce eventBuffer ProgressCompletedEvent
            pure result

asyncWithGC :: IO a -> IO (Async a)
asyncWithGC a = async $ do
    r <- a
    P.performGC
    return r

