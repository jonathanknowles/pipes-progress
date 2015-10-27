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

type BufferSpecification a = P.Buffer a

newtype Buffer a = Buffer (P.Output a, P.Input a, STM ())

bufferWrite :: Buffer a -> a -> STM Bool
bufferWrite (Buffer (o, i, k)) = P.send o

bufferRead :: Buffer a -> STM (Maybe a)
bufferRead (Buffer (o, i, k)) = P.recv i

fromBuffer :: MonadIO m => Buffer a -> Producer a m ()
fromBuffer (Buffer (o, i, k)) = P.fromInput i

toBuffer :: MonadIO m => Buffer a -> Consumer a m ()
toBuffer (Buffer (o, i, k)) = P.toOutput o

createBuffer :: BufferSpecification a -> IO (Buffer a)
createBuffer s = Buffer <$> P.spawn' s

sealBuffer :: Buffer a -> IO ()
sealBuffer (Buffer (o, i, k)) = P.atomically k

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
    countBuffer <- liftIO $ createBuffer $ P.latest counterStart
    eventBuffer <- liftIO $ createBuffer $ P.bounded 1
    notifyAction <- liftIO $ async $ runEffect $
        fromBuffer eventBuffer >-> monitor
    updateAction <- liftIO $ async $ runEffect $
        fromBuffer countBuffer
            >-> yieldPeriodically monitorPeriod
            >-> P.map ProgressUpdateEvent
            >-> toBuffer eventBuffer
    mainAction <- liftIO $ async $ runAction $
        tee $ counter >-> toBuffer countBuffer
    waitCatch mainAction >>= \case
        Left exception -> do
            atomically $
                bufferWrite eventBuffer ProgressInterruptedEvent
            sealBuffer eventBuffer
            sealBuffer countBuffer
            throwIO exception
        Right result -> do
            atomically $
                bufferRead countBuffer
                    >>= bufferWrite eventBuffer
                        . ProgressUpdateEvent
                        . fromMaybe counterStart
            atomically $
                bufferWrite eventBuffer ProgressCompletedEvent
            pure result

asyncWithGC :: IO a -> IO (Async a)
asyncWithGC a = async $ do
    r <- a
    P.performGC
    return r

