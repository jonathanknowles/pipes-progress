Pipes Progress
----------------

An experimental library that provides primitives for monitoring the progress of streaming computations, compatible with the [Haskell Pipes](https://github.com/Gabriel439/Haskell-Pipes-Library) ecosystem.

Please note that this library is still **experimental** and in development. Using it may corrupt all the files on your hard disk or even cause your car to catch fire (although it probably won't).

Introduction
------------

When performing a streaming computation, it's often desirable to have some way of monitoring the progress of that computation. This is especially the case for computations initiated through a user interface, where it's important to give the user an idea of how much progress has been made, and how much work is left.

This package provides convenient primitives for building both monitorable computations and monitors, as well as providing functions that connect computations and monitors together, so that:

* progress can be reported on a regular basis, even in situations where the underlying computation has stalled;

* concurrency issues created by reading the changing state of a computation are handled correctly and safely;

* termination is handled automatically: when the underlying computation terminates, the monitor is notified immediately with the final status of the computation.

Documentation
-------------

For more details, take a look at the [`Pipes.Progress`](https://github.com/jonathanknowles/pipes-progress/blob/master/source/Pipes/Progress.hs) module, which contains a detailed description of the evaluation model.

