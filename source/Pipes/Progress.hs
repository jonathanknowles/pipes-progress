{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Pipes.Progress
    ( Monitor
    , Period (Period)
    , Value (Value, FinalValue)
    , every
    , isFinal
    , silent
    , value
    , withMonitor ) where

import Control.Applicative
import Control.Concurrent       hiding (yield)
import Control.Concurrent.Async
import Control.Foldl                   (Fold)
import Control.Monad
import Data.Time.Clock
import Pipes                    hiding (every)
import Pipes.Concurrent
import Pipes.Prelude
import Prelude                  hiding (map, take, takeWhile)

import qualified Control.Foldl as F
import qualified Pipes.Prelude as P

newtype Period = Period NominalDiffTime
    deriving (Enum, Eq, Fractional, Num, Ord, Real, RealFrac, Show)

every :: Period -> Pipe (Value a) (Value a) IO ()
every = yieldPeriodicallyUntil isFinal

yieldUntil :: (a -> Bool) -> Pipe a a IO ()
yieldUntil isFinal = loop where
    loop = do
        v <- await
        yield v
        unless (isFinal v) loop

yieldPeriodically :: Period -> Pipe a a IO ()
yieldPeriodically = yieldPeriodicallyUntil $ const False

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

type Monitor a = Consumer (Value a) IO ()

data Value a = Value a | FinalValue a

isFinal (     Value _) = False
isFinal (FinalValue _) = True

value (     Value v) = v
value (FinalValue v) = v

instance Functor Value where
    fmap f (     Value v) =      Value $ f v
    fmap f (FinalValue v) = FinalValue $ f v

silent :: Monitor a
silent = yieldPeriodicallyUntil isFinal 0.1 >-> forever await

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
    -> count
    -> Pipe chunk count m () -- this should be a pipe
    -> (Pipe chunk chunk m () -> m a)
    -> m a
withMonitor monitor count counter run = do
    (o, i) <- liftIO $ spawn $ latest $ Value count
    e <- liftIO $ asyncWithGC $
        runEffect $
            (yield (Value count) >> fromInput i)
            -- >-> yieldUntil isFinal
            >-> monitor
    result <- run $ tee $ counter >-> map Value >-> toOutput o
    liftIO $ do
        atomically $ recv i >>= send o . FinalValue . maybe count value
        wait e
    return result

asyncWithGC :: IO a -> IO (Async a)
asyncWithGC a = async $ do
    r <- a
    performGC
    return r

