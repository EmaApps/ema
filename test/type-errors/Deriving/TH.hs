{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

module Deriving.TH (
  routeSpec,
  niceRoute,
  badRoute,
) where

import Data.Char (isAlphaNum, toUpper)
import Data.List
import Ema.Route.Class
import Ema.Route.Generic
import GHC.Generics qualified as GHC
import Generics.SOP qualified as SOP
import Language.Haskell.TH

-- ** Constructor generators

{- | "Nice" like how we use the term in a mathematical sense; a well-formed set of route
 constructors.

 > data R = _1 () | _2 ()
-}
niceRoute :: Name -> Name -> Name -> [Con]
niceRoute r1 r2 = trivialCtors [[r1], [r2]]

{- | A malformed set of route constructors

 > data R = _1 r1 r2 | _2 r1
-}
badRoute :: Name -> Name -> Name -> [Con]
badRoute r1 r2 = trivialCtors [[r1, r2], [r1]]

{- | Trivial constructors of form @C a b c...@; no unpackednesss/strictness/etc.

 Constructors are named name_1, name_2, ... in order.
-}
trivialCtors :: [[Name]] -> Name -> [Con]
trivialCtors ctors name = do
  flip fmap (zip [1 ..] ctors) $ \(i, fields) ->
    NormalC (mkName (show name <> "_" <> show i)) $ (noBang,) . ConT <$> fields
  where
    noBang = Bang NoSourceUnpackedness NoSourceStrictness

{- | @routespec desc ctorGen opts errs@ generates a route data declaration
 with constructors generated by ctorGen (given the route name) and
 GenericRoute options @opts@.

 We use deriving clauses instead of relying on existing standalone deriving TH
 to ensure type errors still display in spite of GHC's more "relaxed" inference
 of deriving-via instance head contexts; i.e., that the @~ (() :: Constraint)@
 hack still works.
-}
routeSpec :: String -> (Name -> [Con]) -> Q Type -> String -> Q [Dec]
routeSpec desc ctorGen opts _ = do
  opts' <- genericRoute
  pure $
    singleton $
      DataD
        []
        routeName
        []
        Nothing
        (ctorGen routeName)
        [ DerivClause
            (Just StockStrategy)
            [ConT ''GHC.Generic]
        , DerivClause (Just AnyclassStrategy) $
            ConT <$> [''SOP.Generic, ''SOP.HasDatatypeInfo]
        , DerivClause (Just $ ViaStrategy opts') $
            ConT <$> [''HasSubRoutes, ''HasSubModels, ''IsRoute]
        ]
  where
    routeName =
      mkName $
        ("RouteSpec_" <>)
          . intercalate ""
          . fmap (capitalize . filter isAlphaNum)
          . words
          $ desc

    genericRoute = do
      opts' <- opts
      pure $
        ConT ''GenericRoute
          `AppT` ConT routeName
          `AppT` opts'

    capitalize (n : ns) = toUpper n : ns
    capitalize _ = []
