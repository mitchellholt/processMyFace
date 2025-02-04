{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent
import Control.Monad.Except
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.State.Lazy
import Data.Aeson
import Data.ByteString.Lazy.Char8 (pack)
import Data.List (find, transpose)
import Data.Maybe (fromMaybe, isJust)
import System.Environment (getArgs)
import System.IO
import System.Process

data Task = Task
  { tName :: String,
    tCommand :: String,
    tCwd :: String
  }
  deriving (Show)

data RunningTask = RunningTask
  { rtName :: String,
    rtCommand :: String,
    rtCwd :: String,
    rtPh :: ProcessHandle,
    rtFp :: String
  }

data JsonTask = JsonTask
  { jtName :: String,
    jtCommand :: String,
    jtCwd :: Maybe String
  }

newtype JsonTasks = JsonTasks [JsonTask]

instance FromJSON JsonTask where
  parseJSON = withObject "JsonTask" $ \v -> do
    name <- v .: "name"
    command <- v .: "command"
    d <- v .:? "cwd"
    return $ JsonTask name command d

instance FromJSON JsonTasks where
  parseJSON = withObject "JsonTasks" $ \v -> do
    tasks <- v .: "tasks"
    return $ JsonTasks tasks

instance Show RunningTask where
  show = rtName

data Action = AddTask Task | LogTask String deriving (Show)

type ApplicationContext = StateT [RunningTask] IO

prettyTable :: [[String]] -> String
prettyTable ss =
  let ss' = transpose ss
      widths = (maximum . (length <$>) <$> ss')
      fixed = [[x ++ replicate (i + 4 - length x) ' ' | (x, i) <- zip y widths] | y <- ss]
   in unlines $ unwords <$> fixed

pTask :: String -> Either String Task
pTask s = case words s of
  [name, cmd, d] -> Right $ Task {tName = name, tCommand = cmd, tCwd = d}
  _ -> Left $ "Error parsing task: " ++ s

pAction :: String -> Either String Action
pAction s =
  case words s of
    ("add" : ws) -> do
      t <- pTask $ unwords ws
      return $ AddTask t
    -- better parse name here
    ("logs" : name : _) -> Right $ LogTask name
    _ -> Left "Invalid command"

promptText :: String
promptText =
  unlines
    [ "Available commands:",
      "======================",
      "- 'logs <TASK_NAME>', see the live tail of logs from <TASK_NAME>, press 'q' then to return to this menu",
      "",
      "",
      "Enter your command, then hit <ENTER>"
    ]

prompt :: IO Action
prompt =
  putStrLn promptText >> pAction <$> getLine >>= \case
    Right action -> return action
    Left str -> putStrLn str >> prompt

taskTableRow :: RunningTask -> [String]
taskTableRow (RunningTask name cmd d _ lp) = [name, cmd, d, lp]

taskTable :: [RunningTask] -> [[String]]
taskTable rts = ["Name:", "Command:", "Directory:", "Log file path"] : (taskTableRow <$> rts)

prettyMenu :: [RunningTask] -> String
prettyMenu ts =
  unlines
    [ "",
      "",
      "",
      "Running Tasks",
      "=============="
    ]
    ++ prettyTable (taskTable ts)

menu :: StateT [RunningTask] IO Action
menu = (get >>= lift . putStrLn . prettyMenu) >> lift prompt

validateTask :: Task -> [RunningTask] -> Either String ()
validateTask t ts =
  let name = tName t
      dup = any (\x -> name == rtName x) ts
   in when dup $ Left $ "Duplicate task name: " ++ name

validateTaskInCtx :: Task -> ExceptT String ApplicationContext ()
validateTaskInCtx t =
  lift get >>= \ts -> case validateTask t ts of
    Left err -> throwError err
    Right _ -> return ()

addTaskToCtx :: Task -> String -> ProcessHandle -> ApplicationContext ()
addTaskToCtx (Task name command d) fp ph =
  let rt = RunningTask {rtFp = fp, rtPh = ph, rtName = name, rtCommand = command, rtCwd = d}
   in get >>= put . (rt :)

addTask :: Task -> ExceptT String ApplicationContext String
addTask t =
  let doIO = lift . lift
      command = shell (tCommand t)
      filename = "/tmp/" ++ tName t
   in do
        _ <- validateTaskInCtx t
        hFile <- doIO $ openFile filename WriteMode
        -- dunno if I need to set the buffering mode
        (_, _, _, ph) <-
          doIO $
            createProcess
              command
                { cwd = Just $ tCwd t,
                  std_in = CreatePipe,
                  delegate_ctlc = False,
                  std_out = UseHandle hFile,
                  std_err = UseHandle hFile
                }
        _ <- lift $ addTaskToCtx t filename ph
        return $ "Added task: " ++ tName t

showLogs :: String -> ExceptT String ApplicationContext ()
showLogs n =
  let f x = rtName x == n
   in lift get >>= \ts -> case find f ts of
        Nothing -> throwError $ "No such task: " ++ n
        Just ts' -> lift . lift $ showLogForTask ts'

showLogForTask :: RunningTask -> IO ()
showLogForTask (RunningTask _ _ _ _ p) =
  let cmd = shell ("tail -f  -n +1 " ++ p)
   in do
        (_, Just mout, _, ph) <-
          createProcess
            cmd
              { std_out = CreatePipe,
                delegate_ctlc = False,
                std_in = CreatePipe
              }
        mVar <- newEmptyMVar
        _ <- forkIO $ waitForQ mVar
        _ <- logLoop mout mVar
        terminateProcess ph

waitForQ :: MVar Bool -> IO ()
waitForQ mVar =
  hSetBuffering stdin NoBuffering
    >> getChar
    >>= \c ->
      if c == 'q'
        then hSetBuffering stdin (BlockBuffering Nothing) >> putMVar mVar True
        else waitForQ mVar

logLoop :: Handle -> MVar Bool -> IO ()
logLoop h m =
  let quit = isJust <$> tryTakeMVar m
   in do
        quit' <- quit
        if quit'
          then return ()
          else do
            isReady <- hReady h
            threadDelay 100
            if isReady
              then recurse
              else logLoop h m
  where
    recurse = do
      line <- hGetLine h
      putStrLn line
      logLoop h m

runAction :: Action -> ApplicationContext ()
runAction (AddTask t) = do
  result <- runExceptT $ addTask t
  case result of
    Left s -> lift $ putStrLn s
    Right _ -> return ()
runAction (LogTask n) = do
  result <- runExceptT $ showLogs n
  case result of
    Left s -> lift $ putStrLn s
    Right _ -> return ()

parseJsonTasks :: String -> Either String JsonTasks
parseJsonTasks = eitherDecode . pack

getDefinedTasks :: String -> MaybeT IO JsonTasks
getDefinedTasks p = MaybeT $ do
  r <- parseJsonTasks <$> readFile p
  case r of
    Left str -> putStrLn str >> return Nothing
    Right ts -> return $ Just ts

tasksFromArg :: MaybeT IO JsonTasks
tasksFromArg = do
  args <- lift getArgs
  case args of
    (p : _) -> getDefinedTasks p
    _ -> MaybeT $ return Nothing

loop :: ApplicationContext ()
loop =
  menu >>= runAction >> loop

taskFromJsonTask :: JsonTask -> Task
taskFromJsonTask (JsonTask name cmd d) = Task name cmd $ fromMaybe "." d

app :: ApplicationContext ()
app =
  let handleResult x = case x of
        Left s -> putStrLn s
        Right _ -> return ()
   in do
        JsonTasks ts <- lift $ fromMaybe (JsonTasks []) <$> runMaybeT tasksFromArg
        result <- runExceptT $ traverse (addTask . taskFromJsonTask) ts
        _ <- lift $ handleResult result
        loop

main :: IO ()
main = void $ runStateT app []
