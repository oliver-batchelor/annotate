module Scene.Canvas where

import Reflex.Classes
import Builder.Element (ElemType)

import qualified GHCJS.DOM as DOM
import qualified GHCJS.DOM.Types as DOM
import qualified GHCJS.DOM.EventM as DOM
import qualified GHCJS.DOM.Element as DOM
import qualified GHCJS.DOM.DOMRectReadOnly as DOM

import qualified GHCJS.DOM.HTMLElement as DOM
import qualified GHCJS.DOM.HTMLImageElement as DOM (getComplete)
import qualified GHCJS.DOM.HTMLCanvasElement as DOM
import GHCJS.DOM.Types (CanvasStyle(..), CanvasRenderingContext2D(..), toJSString, RenderingContext)

import Language.Javascript.JSaddle
       (jsg, js, js1, jss, fun, valToNumber, syncPoint)

import Scene.Viewport
import Scene.Controller
import Scene.Types
import Scene.Events

import Client.Common
import Client.Widgets

import Annotate.Common
import Annotate.Geometry
import Builder.Html

import Annotate.Prelude

import GHCJS.DOM.CanvasPath               as C
import GHCJS.DOM.CanvasRenderingContext2D as C

import  Data.Coerce  (coerce)


rawCanvas :: (DomBuilder t m, DomBuilderSpace m ~ GhcjsDomSpace) => ElemType t m -> m DOM.HTMLCanvasElement
rawCanvas e = return $ coerce (_element_raw e)


getContext2d ::  (DOM.MonadJSM m) =>  DOM.HTMLCanvasElement -> m CanvasRenderingContext2D
getContext2d e =  coerce <$> DOM.getContextUnchecked e ("2d" :: Text) ([] :: [DOM.JSVal])


type DrawState = (Viewport, Action, Maybe Editor)


transformView :: DOM.MonadJSM m => CanvasRenderingContext2D -> Viewport ->  m ()
transformView context vp = do 
  C.translate context tx ty
  C.scale context zoom zoom 
    where
      (V2 tx ty) = localOffset vp
      zoom = vp ^. #zoom


drawCircle :: DOM.MonadJSM m => CanvasRenderingContext2D -> Circle -> m ()
drawCircle context (Circle (V2 x y) r) = do
    C.beginPath context
    C.arc context (realToFrac x) (realToFrac y) (realToFrac r) 0 (2 * pi) False
    C.stroke context


drawAnnotation :: DOM.MonadJSM m => CanvasRenderingContext2D -> Annotation -> m ()
drawAnnotation context Annotation{shape} = case shape of
  (ShapeCircle c) -> drawCircle context c
  (ShapeBox b) -> error "not implemented"
  (ShapeLine l) -> error "not implemented"
  (ShapePolygon p) -> error "not implemented"


withContext :: DOM.MonadJSM m => DOM.HTMLCanvasElement -> (CanvasRenderingContext2D -> m a) -> m a
withContext canvas f = do
  context <- getContext canvas
  f context

getSize :: DOM.HTMLCanvasElement -> m (Int, Int)
getSize canvas = liftA2 (,) (DOM.getWidth canvas) (DOM.getHeight canvas)

setSize :: (DOM.MonadJSM m) => DOM.HTMLCanvasElement -> (Int, Int) -> m ()
setSize e (V2 w h) =  DOM.setWidth e w >> DOM.setHeight e h



withContextOffscreen :: MonadDOM m => DOM.HTMLCanvasElement -> (CanvasRenderingContext2D -> m ()) -> m ()
withContextOffscreen canvas f = void $ do
  doc <- currentDocumentUnchecked

  (w, h) <- getSize canvas
  offScreen <- jsg2 "OffscreenCanvas" w h

  getContext offScreen >>= paint



drawScene :: DOM.MonadJSM m => DOM.HTMLCanvasElement -> DOM.HTMLImageElement -> DrawState -> m ()
drawScene canvas image (vp, action, doc)   = do
  setSize (floor w, floor h)
  withContext canvas $ \context -> do
    C.resetTransform context
    C.clearRect context 0 0 w h

    transformView context vp   

    complete <- DOM.getComplete image
    when complete $
      C.drawImage context (DOM.toCanvasImageSource image) 0 0
      
    C.setLineWidth context (2 / zoom)

    forM_ doc $ \Editor{annotations} ->    
      traverse (drawAnnotation context) annotations

  where 

    zoom = vp ^. #zoom
    (V2 w h) = vp ^. #window
  

loadImage :: (AppBuilder t m) => Dynamic t Text -> m DOM.HTMLImageElement 
loadImage file =  do
  e <- preload file
  return $ coerce (_element_raw e)



sceneCanvas :: forall t m. (GhcjsAppBuilder t m)
  => Dynamic t Viewport
  -> Dynamic t Action
  -> Dynamic t (Maybe Editor)
  -> m (Event t ())
sceneCanvas viewport action mDoc = do 
  
  e <- canvas_ [class_ =: "expand"]

  image <- loadImage (pure "CamB_1755.jpg")--(fromMaybe "" . fmap (view #name) <$> mDoc)
  canvas <- rawCanvas e

  vp <- sample viewport
  DOM.liftJSM $ setDim canvas (vp ^. #window)
  
  
  render <- requestDomAction (drawScene canvas image <$> updated state)
  return render
  

    where state = liftA3 (,,) viewport action mDoc


