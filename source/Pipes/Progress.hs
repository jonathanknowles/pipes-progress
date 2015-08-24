{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards            #-}

module Pipes.Progress where

import Control.Applicative
import Control.Concurrent       hiding (yield)
import Control.Concurrent.Async
import Control.Monad
import Data.Time.Clock
import Pipes
import Pipes.Concurrent
import Pipes.Prelude
import Prelude                  hiding (map, take, takeWhile)

newtype Period = Period NominalDiffTime
    deriving (Enum, Eq, Fractional, Num, Ord, Real, RealFrac, Show)

accumulate :: (Monad m, Num i) => i -> Pipe i i m r
accumulate c = yield c >> await >>= accumulate . (c +)

asyncWithGC :: IO a -> IO (Async a)
asyncWithGC a = async $ do
    r <- a
    performGC
    return r

yieldUntil :: (a -> Bool) -> Pipe a a IO ()
yieldUntil isFinal = loop where
    loop = do
        v <- await
        yield v
        unless (isFinal v) loop

yieldPeriodically :: Period -> Pipe a a IO ()
yieldPeriodically = yieldPeriodicallyUntil $ const False

every :: Period -> Pipe (Update a) (Update a) IO ()
every = yieldPeriodicallyUntil isFinal

yieldPeriodicallyUntil :: (a -> Bool) -> Period -> Pipe a a IO ()
yieldPeriodicallyUntil isFinal (Period p) =
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

type Monitor a = Consumer (Update a) IO ()

data Update a = Update a | FinalUpdate a

isFinal (     Update _) = False
isFinal (FinalUpdate _) = True

value (     Update v) = v
value (FinalUpdate v) = v

instance Functor Update where
    fmap f (     Update v) =      Update $ f v
    fmap f (FinalUpdate v) = FinalUpdate $ f v

nullMonitor :: Monitor a
nullMonitor = yieldPeriodicallyUntil isFinal 0.1 >-> forever await

data Counter chunk count m = Counter
    { counterStart :: count
    , counterPipe  :: Pipe chunk count m () }

-- | periods: │<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│<--p-->│
-- |  chunks:    c c c c c c     c c c c c c c         c c c c c     c c c c
-- | updates: u  │    u       u       u       u       u       u       u    │  u
-- |          │  │                                                         │  │
-- |    first─┘  └─first                                             final─┘  └─last
-- |   update      chunk                                             chunk      update
-- |
withMonitor
    :: MonadIO m
    => Monitor count
    -> Counter chunk count m
    -> (Pipe chunk chunk m () -> m a)
    -> m a
withMonitor monitor Counter {..} run = do
    (o, i) <- liftIO $ spawn $ latest $ Update counterStart
    e <- liftIO $ asyncWithGC $
        runEffect $
            (yield (Update counterStart) >> fromInput i)
            >-> yieldUntil isFinal
            >-> monitor
    result <- run $ tee $ counterPipe >-> map Update >-> toOutput o
    liftIO $ do
        atomically $ recv i >>= send o . FinalUpdate . maybe counterStart value
        wait e
    return result

