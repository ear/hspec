{-# LANGUAGE CPP #-}
module Test.Hspec.Core.SpecSpec (spec) where

import           Prelude ()
import           Helper

import           Test.Hspec.Core.Spec (Item(..), Result(..))
import qualified Test.Hspec.Core.Runner as H
import           Test.Hspec.Core.Spec (Tree(..), runSpecM)

import qualified Test.Hspec.Core.Spec as H

runSpec :: H.Spec -> IO [String]
runSpec = captureLines . H.hspecResult

spec :: Spec
spec = do
  describe "describe" $ do
    it "can be nested" $ do
      [Node foo [Node bar [Leaf _]]] <- runSpecM $ do
        H.describe "foo" $ do
          H.describe "bar" $ do
            H.it "baz" True
      (foo, bar) `shouldBe` ("foo", "bar")

    context "when no description is given" $ do
      it "uses a default description" $ do
        [Node d _] <- runSpecM (H.describe "" (pure ()))
        d `shouldBe` "(no description given)"

  describe "xdescribe" $ do
    it "creates a tree of pending spec items" $ do
      [Node _ [Leaf item]] <- runSpecM (H.xdescribe "" $ H.it "whatever" True)
      Right r <- itemExample item defaultParams ($ ()) noOpProgressCallback
      r `shouldBe` Pending Nothing Nothing

  describe "it" $ do
    it "takes a description of a desired behavior" $ do
      [Leaf item] <- runSpecM (H.it "whatever" True)
      itemRequirement item `shouldBe` "whatever"

    it "takes an example of that behavior" $ do
      [Leaf item] <- runSpecM (H.it "whatever" True)
      Right r <- itemExample item defaultParams ($ ()) noOpProgressCallback
      r `shouldBe` Success ""

    it "adds source locations" $ do
      [Leaf item] <- runSpecM (H.it "foo" True)
      let location =
#if MIN_VERSION_base(4,8,1)
            Just $ H.Location __FILE__ (__LINE__ - 3) 32
#else
            Nothing
#endif
      itemLocation item `shouldBe` location

    context "when no description is given" $ do
      it "uses a default description" $ do
        [Leaf item] <- runSpecM (H.it "" True)
        itemRequirement item `shouldBe` "(unspecified behavior)"

  describe "xit" $ do
    it "creates a pending spec item" $ do
      [Leaf item] <- runSpecM (H.xit "whatever" True)
      Right r <- itemExample item defaultParams ($ ()) noOpProgressCallback
      r `shouldBe` Pending Nothing Nothing

  describe "pending" $ do
    it "specifies a pending example" $ do
      r <- runSpec $ do
        H.it "foo" H.pending
      r `shouldSatisfy` any (== "     # PENDING: No reason given")

  describe "pendingWith" $ do
    it "specifies a pending example with a reason for why it's pending" $ do
      r <- runSpec $ do
        H.it "foo" $ do
          H.pendingWith "for some reason"
      r `shouldSatisfy` any (== "     # PENDING: for some reason")

  describe "parallel" $ do
    it "marks examples for parallel execution" $ do
      [Leaf item] <- runSpecM . H.parallel $ H.it "whatever" H.pending
      itemIsParallelizable item `shouldBe` Just True

    it "is applied recursively" $ do
      [Node _ [Node _ [Leaf item]]] <- runSpecM . H.parallel $ do
        H.describe "foo" $ do
          H.describe "bar" $ do
            H.it "baz" H.pending
      itemIsParallelizable item `shouldBe` Just True

  describe "sequential" $ do
    it "marks examples for sequential execution" $ do
      [Leaf item] <- runSpecM . H.sequential $ H.it "whatever" H.pending
      itemIsParallelizable item `shouldBe` Just False

    it "takes precedence over a later `parallel`" $ do
      [Leaf item] <- runSpecM . H.parallel . H.sequential $ H.it "whatever" H.pending
      itemIsParallelizable item `shouldBe` Just False
