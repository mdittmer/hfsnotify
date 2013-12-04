--
-- Copyright (c) 2012 Mark Dittmer - http://www.markdittmer.org
-- Developed for a Google Summer of Code project - http://gsoc2012.markdittmer.org
--
{-# LANGUAGE CPP, ScopedTypeVariables, ExistentialQuantification #-}

-- | cross-platform file watching.

module System.FSNotify
       (
       
       -- * Events
         Event(..)
       , EventChannel
       , eventTime
       , eventPath
       , Action
       , ActionPredicate

       -- * Starting/Stopping
       , WatchManager
       , withManager
       , startManager
       , stopManager
       , defaultConfig
       , WatchConfig(..)
       , withManagerConf
       , startManagerConf
       , StopListening

       -- * Watching
       , watchDir
       , watchDirChan
       , watchTree
       , watchTreeChan
       ) where

import Prelude hiding (FilePath, catch)

import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception
import Control.Applicative
import Control.Monad
import Filesystem.Path.CurrentOS
import System.FSNotify.Polling
import System.FSNotify.Types

import System.FSNotify.Listener (StopListening)

#ifdef OS_Linux
import System.FSNotify.Linux
#else
#  ifdef OS_Win32
import System.FSNotify.Win32
#  else
#    ifdef OS_Mac
import System.FSNotify.OSX
#    else
type NativeManager = PollManager
#    endif
#  endif
#endif

data WatchManager
  =  forall manager . FileListener manager
  => WatchManager WatchConfig manager
defaultConfig :: WatchConfig
defaultConfig = DebounceDefault

-- | Perform an IO action with a WatchManager in place.
-- Tear down the WatchManager after the action is complete.
withManager :: (WatchManager -> IO a) -> IO a
withManager  = withManagerConf defaultConfig

-- | Start a file watch manager.
-- Directories can only be watched when they are managed by a started watch
-- watch manager.
-- When finished watching. you must release resources via 'stopManager'.
-- It is preferrable if possible to use 'withManager' to handle this
-- automatically.
startManager :: IO WatchManager
startManager = startManagerConf defaultConfig

-- | Stop a file watch manager.
-- Stopping a watch manager will immediately stop
-- watching for files and free resources.
stopManager :: WatchManager -> IO ()
stopManager (WatchManager _ wm) = killSession wm

withManagerConf :: WatchConfig -> (WatchManager -> IO a) -> IO a
withManagerConf debounce = bracket (startManagerConf debounce) stopManager

startManagerConf :: WatchConfig -> IO WatchManager
startManagerConf debounce = initSession >>= createManager
  where
    createManager :: Maybe NativeManager -> IO WatchManager
    createManager (Just nativeManager) = return (WatchManager debounce nativeManager)
    createManager Nothing = WatchManager debounce <$> createPollManager

-- | Watch the immediate contents of a directory by streaming events to a Chan.
-- Watching the immediate contents of a directory will only report events
-- associated with files within the specified directory, and not files
-- within its subdirectories.
watchDirChan :: WatchManager -> FilePath -> ActionPredicate -> EventChannel -> IO StopListening
watchDirChan (WatchManager db wm) = listen db wm

-- | Watch all the contents of a directory by streaming events to a Chan.
-- Watching all the contents of a directory will report events associated with
-- files within the specified directory and its subdirectories.
watchTreeChan :: WatchManager -> FilePath -> ActionPredicate -> EventChannel -> IO StopListening
watchTreeChan (WatchManager db wm) = listenRecursive db wm

-- | Watch the immediate contents of a directory by committing an Action for each event.
-- Watching the immediate contents of a directory will only report events
-- associated with files within the specified directory, and not files
-- within its subdirectories. No two events pertaining to the same FilePath will
-- be executed concurrently.
watchDir :: WatchManager -> FilePath -> ActionPredicate -> Action -> IO StopListening
watchDir (WatchManager db wm) = threadChan (listen db) wm

-- | Watch all the contents of a directory by committing an Action for each event.
-- Watching all the contents of a directory will report events associated with
-- files within the specified directory and its subdirectories. No two events
-- pertaining to the same FilePath will be executed concurrently.
watchTree :: WatchManager -> FilePath -> ActionPredicate -> Action -> IO StopListening
watchTree (WatchManager db wm) = threadChan (listenRecursive db) wm

threadChan
  :: FileListener manager
  => (manager -> FilePath -> ActionPredicate -> Chan Event -> IO b)
  ->  manager -> FilePath -> ActionPredicate -> Action -> IO b
threadChan listener iface path actPred action = do
  chan <- newChan
  withAsync (readEvents chan action) $ \asy -> do
    link asy
    listener iface path actPred chan

readEvents :: EventChannel -> Action -> IO ()
readEvents chan action = forever $ do
  event <- readChan chan
  us <- myThreadId
  -- Execute the event handler in a separate thread, but throw any
  -- exceptions back to us.
  --
  -- Note that there's a possibility that we may miss some exceptions, if
  -- an event handler finishes after the listen is cancelled (and so this
  -- thread is dead). How bad is that? The alternative is to kill the
  -- handler anyway when we're cancelling.
  forkFinally (action event) $ either (throwTo us) (const $ return ())
