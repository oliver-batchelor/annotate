{-# LANGUAGE OverloadedStrings #-}

import Common hiding (div)

import qualified Data.Text as T

import Data.Default
import Data.Monoid

import Scene.Viewport
import Scene.View
import Scene.Types
import Scene.Events

import Input.Events

import Reflex.Classes
import Builder.Html

import Input.Window

import Types




main :: IO ()
main = mainWidgetWithHead' (const headWidget, bodyWidget)


orLocal :: Text -> Text
orLocal url =  if url == "" then "localhost:3000" else url

headWidget :: GhcjsBuilder t m => m Text
headWidget = do

   host <- orLocal <$> getLocationHost
   base_ [href_ =: "http://" <> host]

   stylesheet "css/fontawesome-all.min.css"
   stylesheet "css/bootstrap.min.css"
   stylesheet "css/style.css"

   return host

  where
    stylesheet url = link_ [href_ =: url, rel_ =: ["stylesheet"]]
    --css = decodeUtf8 $(embedFile "style.css")

nonEmpty :: [a] -> Maybe [a]
nonEmpty = \case
  [] -> Nothing
  xs -> Just xs


cursorLock :: Builder t m => Dynamic t Action -> m a -> m a
cursorLock action child =
  div [draggable_ =: False, style_ ~: cursorStyle <$> action] $
    div [id_ =: "drawing", classes_ ~: lockClass <$> action] child
  where
    cursorStyle Action{..} = [("cursor", cursor)]
    lockClass Action{..} = ["expand"] <> ["cursor_lock" | lock]


viewControls :: GhcjsBuilder t m => Event t SceneCommand -> DocInfo -> m (Dynamic t Viewport)
viewControls cmds info = mdo
  windowDim  <- windowDimensions

  controls <- holdDyn  (1, V2 0 0) (updateView <$> viewCmds <#> current viewport)
  let viewport = makeViewport <$> controls <*> pure (info ^. #imageSize) <*> windowDim

  return viewport

  where
    viewCmds = preview _ViewCmd <?> cmds
    updateView cmd vp = getControls $ case cmd of
      ZoomCmd zoom pos -> zoomView zoom pos vp
      PanCmd localOrign page -> panView localOrign page vp

    getControls (Viewport _ _ pan zoom) = (zoom, pan)
    makeViewport (zoom, pan) image window =
        Viewport (fromDim image) (fromDim window) pan zoom


data Connection = Waiting | Error Text | Connected
  deriving (Show, Generic, Eq)

network :: GhcjsBuilder t m => Text -> Event t ClientMsg -> m (Event t (), Event t (Maybe Text), Event t ServerMsg)
network host send = do
  socket <- webSocket ("ws://" <> host <> "/ws") $ def
    & webSocketConfig_send  .~ (pure . encode <$> send)

  let recieved = decodeStrict <?> socket ^. webSocket_recv
  performEvent_ (liftIO . print <$> send)
  performEvent_ (liftIO . print <$> recieved)

  return
    ( socket ^. webSocket_open
    , close <$> socket ^. webSocket_close
    , recieved)


  where
    close (True,  _, _)       = Nothing
    close (False, _, reason)  = Just reason


-- network :: Text -> Event t Command ->
-- data ClientState = Connected
--   { clientId :: ClientId
--   , currentDoc  :: Maybe (DocName, DocInfo)
--
--   }



modal :: Builder t m => Dynamic t Bool -> m a -> m a
modal shown content = do
  r <- div [classes_ ~: (pure ["modal"] <> ["show"] `gated` shown), role_ =: "dialog", style_ ~: [("display", "block"), ("padding-right", "15px")] `gated` shown ] $
    div [class_ =: "modal-dialog modal-dialog-centered", role_ =: "document"] $
      div [class_ =: "modal-content"] $ content

  div [classes_ ~: (pure ["modal-backdrop"] <> ["show"] `gated` shown)] blank
  return r


connectingModal :: Builder t m => m ()
connectingModal = modal (pure True) $ do
  div [class_ =: "modal-header"] $ do
    h5 [class_ =:"modal-title"] $ text "Connecting..."





handleHistory :: GhcjsBuilder t m => Event t DocName -> m (Event t DocName)
handleHistory loaded = mdo

  currentDoc <- hold Nothing (Just <$> leftmost [loaded, changes])

  let update     = id <?> (updateHistory <$> current history <*> currentDoc <@> loaded)
      changes    = uriDocument <$> updated history

  history <- manageHistory update
  return $ new <?> (currentDoc `attach` changes)

   where
     new (Nothing, doc)       = Just doc
     new (Just previous, doc) = doc <$ guard (previous /= doc)

     uriDocument = T.pack . drop 1 . view #uriFragment . _historyItem_uri

     updateHistory item Nothing doc = Just $ HistoryCommand_ReplaceState $ update item doc
     updateHistory item (Just previous) doc
        | previous /= doc = Just $ HistoryCommand_PushState $ update item doc
        | otherwise       = Nothing

     update (HistoryItem state uri) doc = HistoryStateUpdate
        { _historyStateUpdate_state = state
        , _historyStateUpdate_title = "state"
        , _historyStateUpdate_uri   = Just $ uri & #uriFragment .~ T.unpack ("#" <> doc)
        }


sceneWidget :: GhcjsBuilder t m => (DocName, DocInfo, Document) -> m (Dynamic t Action, Event t SceneCommand)
sceneWidget (name, info, loaded) = mdo
  document <- holdDyn loaded never
  input    <- sceneInputs scene
  viewport <- viewControls cmds info

  let updates = never

  (scene, (action, cmds)) <- sceneView $ Scene
    { image    = ("images/" <> name, info ^. #imageSize)
    , viewport = viewport
    , input    = input
    , document = document
    , objects  = (initial, updates)
    }

  return (action, cmds)
    where initial = (def,) <$> (loaded ^. #instances)


bodyWidget :: forall t m. GhcjsBuilder t m => Text -> m ()
bodyWidget host = mdo

  (opened, closed, serverMsg) <- network host clientMsg

  let disconnected = Workflow $
        (("disconnected", never), connected <$ opened) <$ connectingModal

      connected = Workflow $ do
        return (("connected", never), ready <$> hello)

      ready (clientId, collection) = Workflow $ do
        nextCmd <- postCurrent $ ffor (current currentDoc) $ \case
          Nothing -> ClientNext Nothing
          Just name -> ClientOpen name -- If we were disconnected, load the previous document again

        return (("ready", nextCmd), never)

  (state, clientMsgs) <- split <$> (workflow $
    mapTransition (\e -> leftmost [disconnected <$ closed, e]) disconnected)

  let clientMsg = leftmost
        [ switchPrompt clientMsgs
        , ClientOpen <$> urlSelected
        ]

  urlSelected <- handleHistory (view _1 <$> loaded)
  currentDoc  <- holdDyn Nothing ((Just . view _1) <$> loaded)

  let hello   = preview _ServerHello <?> serverMsg
      loaded  = preview _ServerDocument <?> serverMsg

  (action, sceneCmds) <- cursorLock action $ do
    replaceHold (return (pure def, never)) (sceneWidget <$> loaded)

  return ()
