{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

module Ema.Site
  ( Site (..),

    -- * Creating sites
    singlePageSite,
    constModal,

    -- * Combinators
    mountUnder,
    mergeSite,
    (+:),
  )
where

import Control.Monad.Logger
import Data.LVar (LVar)
import Data.LVar qualified as LVar
import Data.Some (Some)
import Data.Text qualified as T
import Ema.Asset (Asset (AssetGenerated), Format (Html))
import Ema.CLI qualified as CLI
import Ema.Route
  ( RouteEncoder,
    allRoutes,
    decodeRoute,
    encodeRoute,
  )
import System.FilePath ((</>))
import Text.Show (Show (show))
import UnliftIO (MonadUnliftIO, race, race_)
import UnliftIO.Concurrent (threadDelay)

-- | A self-contained Ema site.
data Site a r = Site
  { siteName :: Text,
    siteRender ::
      Some CLI.Action ->
      RouteEncoder a r ->
      a ->
      r ->
      Asset LByteString,
    -- | Thread that will patch the model over time.
    siteModelPatcher ::
      forall m b.
      (MonadIO m, MonadUnliftIO m, MonadLoggerIO m) =>
      Some CLI.Action ->
      -- Sets the initial mode, and takes a continuation to patch it.
      --
      -- The continuation will be called only on live server mode.
      -- TODO: Should we simplify this?
      (a -> (LVar a -> m ()) -> m b) ->
      m b,
    siteRouteEncoder ::
      RouteEncoder a r
  }

-- | Create a site with a single 'index.html' route, whose contents is specified
-- by the given function.
--
-- TODO: pass enc anyway.
singlePageSite :: Text -> (Some CLI.Action -> LByteString) -> Site () ()
singlePageSite name render =
  Site
    { siteName = name,
      siteRender =
        \act _enc () () -> AssetGenerated Html $ render act,
      siteModelPatcher =
        constModal (),
      siteRouteEncoder =
        ( \() () -> "index.html",
          \() fp -> guard (fp == "index.html"),
          \() -> [()]
        )
    }

constModal ::
  forall m a b.
  (MonadIO m, MonadUnliftIO m, MonadLoggerIO m) =>
  a ->
  (Some CLI.Action -> (a -> (LVar a -> m ()) -> m b) -> m b)
constModal x _ startModel = do
  startModel x $ \_ ->
    -- TODO: log it
    pure ()

-- TODO: Using (Generic r)
-- simpleSite :: forall r enc. (enc -> r -> LByteString) -> Site r ()
-- simpleSite render = undefined

(+:) :: forall r1 r2 a1 a2. Site a1 r1 -> Site a2 r2 -> Site (a1, a2) (Either r1 r2)
(+:) = mergeSite

-- | Merge two sites to produce a single site.
-- TODO: Avoid unnecessary updates site1 webpage when only site2 changes (eg:
-- basic shouldn't refresh when clock changes)
mergeSite :: forall r1 r2 a1 a2. Site a1 r1 -> Site a2 r2 -> Site (a1, a2) (Either r1 r2)
mergeSite site1 site2 =
  Site name render patch enc
  where
    name = siteName site1 <> "+" <> siteName site2
    render cliAct _ x = \case
      Left r -> siteRender site1 cliAct (siteRouteEncoder site1) (fst x) r
      Right r -> siteRender site2 cliAct (siteRouteEncoder site2) (snd x) r
    enc =
      ( \(a, b) -> \case
          Left r -> encodeRoute (siteRouteEncoder site1) a r
          Right r -> encodeRoute (siteRouteEncoder site2) b r,
        \(a, b) fp ->
          fmap Left (decodeRoute (siteRouteEncoder site1) a fp)
            <|> fmap Right (decodeRoute (siteRouteEncoder site2) b fp),
        \(a, b) ->
          fmap Left (allRoutes (siteRouteEncoder site1) a)
            <> fmap Right (allRoutes (siteRouteEncoder site2) b)
      )
    patch ::
      forall m b.
      (MonadIO m, MonadUnliftIO m, MonadLoggerIO m) =>
      Some CLI.Action ->
      ((a1, a2) -> (LVar (a1, a2) -> m ()) -> m b) ->
      m b
    patch cliAct f = do
      siteModelPatcher site1 cliAct $ \v1 k1 -> do
        l1 <- LVar.empty
        LVar.set l1 v1
        siteModelPatcher site2 cliAct $ \v2 k2 -> do
          l2 <- LVar.empty
          LVar.set l2 v2
          f (v1, v2) $ \lvar -> do
            let keepAlive src = do
                  -- TODO: DRY with App.hs
                  logWarnNS src "modelPatcher exited; no more model updates."
                  threadDelay maxBound
            race_
              (race_ (k1 l1 >> keepAlive (siteName site1)) (k2 l2 >> keepAlive (siteName site2)))
              ( do
                  sub1 <- LVar.addListener l1
                  sub2 <- LVar.addListener l2
                  forever $ do
                    x <-
                      race
                        (LVar.listenNext l1 sub1)
                        (LVar.listenNext l2 sub2)
                    case x of
                      Left a -> LVar.modify lvar $ \(_, b) -> (a, b)
                      Right b -> LVar.modify lvar $ \(a, _) -> (a, b)
              )

-- | Transform the given site such that all of its routes are encoded to be
-- under the given prefix.
mountUnder :: forall r a. String -> Site a r -> Site a (PrefixedRoute r)
mountUnder prefix Site {..} =
  Site siteName siteRender' siteModelPatcher routeEncoder
  where
    siteRender' cliAct rEnc model (PrefixedRoute _ r) =
      siteRender cliAct (conv rEnc) model r
    conv ::
      RouteEncoder a (PrefixedRoute r) ->
      RouteEncoder a r
    conv (to, from, enum) =
      ( \m r -> to m (PrefixedRoute prefix r),
        \m fp -> _prefixedRouteRoute <$> from m fp,
        \m -> _prefixedRouteRoute <$> enum m
      )
    routeEncoder :: RouteEncoder a (PrefixedRoute r)
    routeEncoder =
      let (to, from, all_) = siteRouteEncoder
       in ( \m r -> prefix </> to m (_prefixedRouteRoute r),
            \m fp -> do
              fp' <- fmap toString $ T.stripPrefix (toText $ prefix <> "/") $ toText fp
              fmap (PrefixedRoute prefix) . from m $ fp',
            fmap (PrefixedRoute prefix) . all_
          )

-- | A route that is prefixed at some URL prefix
data PrefixedRoute r = PrefixedRoute
  { _prefixedRoutePrefix :: String,
    _prefixedRouteRoute :: r
  }
  deriving stock (Eq, Ord)

instance (Show r) => Show (PrefixedRoute r) where
  show (PrefixedRoute p r) = p <> ":" <> Text.Show.show r
