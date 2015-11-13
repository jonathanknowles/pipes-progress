{-# LANGUAGE BangPatterns #-}

module Pipes.Termination where

import Control.Monad (forever)
import Pipes ((>->), Consumer, Pipe, Producer, await, yield)

import qualified Pipes         as P
import qualified Pipes.Prelude as P

data Terminated a = Value !a | End

instance Foldable Terminated where

    foldMap _ (End    ) = mempty
    foldMap f (Value x) = f x

    foldr _ y (End    ) =     y
    foldr f y (Value x) = f x y

    length (End    ) = 0
    length (Value _) = 1

    null (End    ) = True
    null (Value _) = False

terminated :: b -> (a -> b) -> Terminated a -> b
terminated e _ (End    ) = e
terminated _ f (Value v) = f v
{-# INLINABLE terminated #-}

signalLast :: Monad m => Producer a m r -> Producer (Terminated a) m s
signalLast p = (p >-> P.map Value) >> forever (yield End)
{-# INLINABLE signalLast #-}

unsignalLast :: Monad m => Pipe (Terminated a) a m s
unsignalLast = P.concat
{-# INLINABLE unsignalLast #-}

foldReturn :: Monad m
    => (x -> a -> x) -> x -> (x -> b)
    -> Producer a m r
    -> Producer a m b
foldReturn step begin done p =
    signalLast p
    >-> P.tee (foldReturnLast step begin done)
    >-> unsignalLast
{-# INLINABLE foldReturn #-}

foldReturnLast:: Monad m
    => (x -> a -> x) -> x -> (x -> b)
    -> Consumer (Terminated a) m b
foldReturnLast step begin done = loop begin where
    loop !x = await >>= terminated
        (pure $ done x)
        (loop . step x)
{-# INLINABLE foldReturnLast #-}

returnLastConsumed :: Monad m => a -> Consumer (Terminated a) m a
returnLastConsumed last = await >>= terminated (pure last) returnLastConsumed
{-# INLINABLE returnLastConsumed #-}

returnLastProduced :: Monad m => a -> Producer a m r -> Producer a m a
returnLastProduced last producer =
    signalLast producer
    >-> P.tee (returnLastConsumed last)
    >-> unsignalLast

