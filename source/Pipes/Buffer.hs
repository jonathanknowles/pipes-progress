module Pipes.Buffer where

import Control.Monad (forever, when)
import Control.Monad.Trans (MonadIO, liftIO)
import Pipes (Consumer, Producer, await)
import Pipes.Concurrent (atomically, STM)
import Pipes.Safe (MonadSafe)

import qualified Pipes.Concurrent as PC
import qualified Pipes.Safe       as PS

newtype Buffer a = Buffer (PC.Output a, PC.Input a, STM ())

type Specification a = PC.Buffer a

create :: MonadIO m => Specification a -> m (Buffer a)
create s = liftIO $ Buffer <$> PC.spawn' s

seal :: MonadIO m => Buffer a -> m ()
seal (Buffer (o, i, k)) = liftIO $ PC.atomically k

read :: MonadIO m => Buffer a -> Producer a m ()
read (Buffer (o, i, k)) = PC.fromInput i

write :: MonadIO m => Buffer a -> Consumer a m ()
write (Buffer (o, i, k)) = PC.toOutput o

readOnce :: Buffer a -> STM (Maybe a)
readOnce (Buffer (o, i, k)) = PC.recv i

writeOnce :: Buffer a -> a -> STM Bool
writeOnce (Buffer (o, i, k)) = PC.send o

