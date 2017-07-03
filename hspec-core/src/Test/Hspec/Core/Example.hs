{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Test.Hspec.Core.Example (
  Example (..)
, Params (..)
, defaultParams
, ActionWith
, Progress
, ProgressCallback
, Result (..)
, Location (..)
, FailureReason (..)
, safeEvaluateExample
) where

import qualified Test.HUnit.Lang as HUnit

#if MIN_VERSION_HUnit(1,4,0)
import           Data.CallStack
#endif

import           Control.Exception
import           Control.DeepSeq
import           Data.Typeable (Typeable)
import qualified Test.QuickCheck as QC
import           Test.Hspec.Expectations (Expectation)

import qualified Test.QuickCheck.State as QC (numSuccessTests, maxSuccessTests)
import qualified Test.QuickCheck.Property as QCP

import           Test.Hspec.Core.QuickCheckUtil
import           Test.Hspec.Core.Util
import           Test.Hspec.Core.Compat
import           Test.Hspec.Core.Example.Location

-- | A type class for examples
class Example e where
  type Arg e
  type Arg e = ()
  evaluateExample :: e -> Params -> (ActionWith (Arg e) -> IO ()) -> ProgressCallback -> IO Result

data Params = Params {
  paramsQuickCheckArgs  :: QC.Args
, paramsSmallCheckDepth :: Int
} deriving (Show)

defaultParams :: Params
defaultParams = Params {
  paramsQuickCheckArgs = QC.stdArgs
, paramsSmallCheckDepth = 5
}

type Progress = (Int, Int)
type ProgressCallback = Progress -> IO ()

-- | An `IO` action that expects an argument of type @a@
type ActionWith a = a -> IO ()

-- | The result of running an example
data Result =
    Success String
  | Pending (Maybe Location) (Maybe String)
  | Failure (Maybe Location) FailureReason
  deriving (Show, Typeable)

data FailureReason =
    NoReason
  | Reason String
  | ExpectedButGot (Maybe String) String String
  | Error (Maybe String) SomeException
  deriving (Show, Typeable)

instance NFData FailureReason where
  rnf reason = case reason of
    NoReason -> ()
    Reason r -> r `deepseq` ()
    ExpectedButGot p e a  -> p `deepseq` e `deepseq` a `deepseq` ()
    Error m e -> m `deepseq` e `seq` ()

instance Exception Result

safeEvaluateExample :: Example e => e -> Params -> (ActionWith (Arg e) -> IO ()) -> ProgressCallback -> IO Result
safeEvaluateExample example params around progress = do
  r <- safeTry $ forceResult <$> evaluateExample example params around progress
  return $ case r of
    Left e | Just result <- fromException e -> result
    Left e | Just hunit <- fromException e -> hunitFailureToResult Nothing hunit
    Left e -> Failure (extractLocation e) $ Error Nothing e
    Right result -> result
  where
    forceResult :: Result -> Result
    forceResult r = case r of
      Success s -> s `deepseq` r
      Pending _ m -> m `deepseq` r
      Failure _ m -> m `deepseq` r

instance Example Result where
  type Arg Result = ()
  evaluateExample e = evaluateExample (\() -> e)

instance Example (a -> Result) where
  type Arg (a -> Result) = a
  evaluateExample example _params action _callback = do
    ref <- newIORef (Success "")
    action (writeIORef ref . example)
    readIORef ref

instance Example Bool where
  type Arg Bool = ()
  evaluateExample e = evaluateExample (\() -> e)

instance Example (a -> Bool) where
  type Arg (a -> Bool) = a
  evaluateExample p _params action _callback = do
    ref <- newIORef (Success "")
    action $ \a -> example a >>= writeIORef ref
    readIORef ref
    where
      example a
        | p a = return (Success "")
        | otherwise = return (Failure Nothing NoReason)

instance Example Expectation where
  type Arg Expectation = ()
  evaluateExample e = evaluateExample (\() -> e)

hunitFailureToResult :: Maybe String -> HUnit.HUnitFailure -> Result
hunitFailureToResult pre e = case e of
#if MIN_VERSION_HUnit(1,3,0)
  HUnit.HUnitFailure mLoc err ->
#if MIN_VERSION_HUnit(1,5,0)
      case err of
        HUnit.Reason reason -> Failure location (Reason $ addPre reason)
        HUnit.ExpectedButGot preface expected actual -> Failure location (ExpectedButGot (addPreMaybe preface) expected actual)
          where
            addPreMaybe :: Maybe String -> Maybe String
            addPreMaybe xs = case (pre, xs) of
              (Just x, Just y) -> Just (x ++ "\n" ++ y)
              _ -> pre <|> xs
#else
      Failure location (Reason $ addPre err)
#endif
    where
      location = case mLoc of
        Nothing -> Nothing
#if MIN_VERSION_HUnit(1,4,0)
        Just loc -> Just $ Location (srcLocFile loc) (srcLocStartLine loc) (srcLocStartCol loc)
#else
        Just loc -> Just $ Location (HUnit.locationFile loc) (HUnit.locationLine loc) (HUnit.locationColumn loc)
#endif
#else
  HUnit.HUnitFailure err -> Failure Nothing (Reason $ addPre err)
#endif
  where
    addPre :: String -> String
    addPre xs = case pre of
      Just x -> x ++ "\n" ++ xs
      Nothing -> xs

instance Example (a -> Expectation) where
  type Arg (a -> Expectation) = a
  evaluateExample e _ action _ = action e >> return (Success "")

instance Example QC.Property where
  type Arg QC.Property = ()
  evaluateExample e = evaluateExample (\() -> e)

instance Example (a -> QC.Property) where
  type Arg (a -> QC.Property) = a
  evaluateExample p c action progressCallback = do
    r <- QC.quickCheckWithResult (paramsQuickCheckArgs c) {QC.chatty = False} (QCP.callback qcProgressCallback $ aroundProperty action p)
    return $ fromQuickCheckResult r
    where
      qcProgressCallback = QCP.PostTest QCP.NotCounterexample $
        \st _ -> progressCallback (QC.numSuccessTests st, QC.maxSuccessTests st)

fromQuickCheckResult :: QC.Result -> Result
fromQuickCheckResult r = case parseQuickCheckResult r of
  QuickCheckResult _ (QuickCheckOtherFailure err) -> Failure Nothing (Reason err)
  QuickCheckResult _ (QuickCheckSuccess s) -> Success s
  QuickCheckResult n (QuickCheckFailure QCFailure{..}) -> case quickCheckFailureException of
    Just e | Just result <- fromException e -> result
    Just e | Just hunit <- fromException e -> hunitFailureToResult (Just hunitAssertion) hunit
    Just e -> failure (uncaughtException e)
    Nothing -> failure falsifiable
    where
      failure = Failure Nothing . Reason

      numbers = formatNumbers n quickCheckFailureNumShrinks

      hunitAssertion :: String
      hunitAssertion = intercalate "\n" [
          "Falsifiable " ++ numbers ++ ":"
        , indent quickCheckFailureCounterexample
        ]

      uncaughtException e = intercalate "\n" [
          "uncaught exception: " ++ formatException e
        , numbers
        , indent quickCheckFailureCounterexample
        ]

      falsifiable = intercalate "\n" [
          quickCheckFailureReason ++ " " ++ numbers ++ ":"
        , indent quickCheckFailureCounterexample
        ]

indent :: String -> String
indent = intercalate "\n" . map ("  " ++) . lines
