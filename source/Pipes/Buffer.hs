module Pipes.Buffer where

import Control.Monad.Trans (MonadIO)
import Pipes (Consumer, Producer)
import Pipes.Concurrent (atomically, STM)

import qualified Pipes.Concurrent as PC

type Specification a = PC.Buffer a

newtype Buffer a = Buffer (PC.Output a, PC.Input a, STM ())

writeOnce :: Buffer a -> a -> STM Bool
writeOnce (Buffer (o, i, k)) = PC.send o

readOnce :: Buffer a -> STM (Maybe a)
readOnce (Buffer (o, i, k)) = PC.recv i

read :: MonadIO m => Buffer a -> Producer a m ()
read (Buffer (o, i, k)) = PC.fromInput i

write :: MonadIO m => Buffer a -> Consumer a m ()
write (Buffer (o, i, k)) = PC.toOutput o

create :: Specification a -> IO (Buffer a)
create s = Buffer <$> PC.spawn' s

seal :: Buffer a -> IO ()
seal (Buffer (o, i, k)) = PC.atomically k

