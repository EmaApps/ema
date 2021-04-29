{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeApplications #-}

-- | Use Tailwind CSS with blaze-html? Try this module for rapid prototyping of
-- websites in Ema.
module Ema.Helper.Tailwind
  ( -- * Main functions
    layout,
    layoutWith,

    -- * Tailwind shims
    twindShimCdn,
    twindShimOfficial,
    twindShimUnofficial,
  )
where

import qualified Ema.CLI
import NeatInterpolation (text)
import qualified Text.Blaze.Html.Renderer.Utf8 as RU
import Text.Blaze.Html5 ((!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

-- | A simple and off-the-shelf layout using Tailwind CSS
layout :: Ema.CLI.Action -> H.Html -> H.Html -> LByteString
layout action =
  layoutWith "en" "UTF-8" $ case action of
    Ema.CLI.Generate _ ->
      twindShimUnofficial
    _ ->
      -- Twind shim doesn't reliably work in dev server mode. Let's just use the
      -- tailwind CDN.
      twindShimCdn

-- | Like @layout@, but pick your own language, encoding and tailwind shim.
layoutWith :: H.AttributeValue -> H.AttributeValue -> H.Html -> H.Html -> H.Html -> LByteString
layoutWith lang encoding twindShim appHead appBody = RU.renderHtml $ do
  H.docType
  H.html ! A.lang lang $ do
    H.head $ do
      H.meta ! A.charset encoding
      -- This makes the site mobile friendly by default.
      H.meta ! A.name "viewport" ! A.content "width=device-width, initial-scale=1"
      twindShim
      appHead
    -- The "overflow-y-scroll" makes the scrollbar visible always, so as to
    -- avoid janky shifts when switching to routes with suddenly scrollable content.
    H.body ! A.class_ "overflow-y-scroll" $ do
      appBody

-- | Loads full tailwind CSS from CDN (not good for production)
twindShimCdn :: H.Html
twindShimCdn =
  H.unsafeByteString . encodeUtf8 $
    [text|
    <link href="https://unpkg.com/tailwindcss@2.1.1/dist/tailwind.min.css" rel="stylesheet" type="text/css">
    |]

-- | This shim may not work with hot reload.
twindShimOfficial :: H.Html
twindShimOfficial =
  H.unsafeByteString . encodeUtf8 $
    [text|
    <script type="module" src="https://cdn.skypack.dev/twind/shim"></script>
    |]

-- | This shim does work with hot reload, but it spams console with warnings.
twindShimUnofficial :: H.Html
twindShimUnofficial = do
  H.script
    ! A.type_ "text/javascript"
    ! A.src "https://cdn.jsdelivr.net/combine/npm/twind/twind.umd.min.js,npm/twind/observe/observe.umd.min.js"
    $ ""
  H.script ! A.type_ "text/javascript" $ twindShimUnofficialEval
  where
    twindShimUnofficialEval :: H.Html
    twindShimUnofficialEval =
      H.unsafeByteString . encodeUtf8 $
        [text|
        twind.setup({})
        twindObserve.observe(document.documentElement)
        |]
