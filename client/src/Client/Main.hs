module Client.Main where

import Annotate.Common hiding (div)
import Client.Common

import qualified Data.Text as T
import qualified Data.Map as M
import qualified Data.Set as S

import Text.Printf 

import Data.Default
import Data.Monoid

import Control.Monad.Reader
import Control.Lens (notNullOf)

import Scene.Viewport
import Scene.View
import Scene.Types
import Scene.Events

import Input.Events (inputs)
import Scene.Events

import Reflex.Classes
import Builder.Html
import qualified Builder.Html as Html

import Input.Window

import Client.Widgets
import qualified Client.Dialog as Dialog

import Annotate.Types
import Annotate.Document

import Language.Javascript.JSaddle
import qualified Reflex.Dom.Main as Main

import qualified Web.KeyCode as Key


main :: JSM ()
main = Main.mainWidgetWithHead' (const headWidget, bodyWidget)


orLocal :: Text -> Text
orLocal url = if url == "" then "localhost:3000" else url

headWidget :: GhcjsBuilder t m => m Text
headWidget = do

   -- host <- orLocal <$> getLocationHost
   -- base_ [href_ =: "http://" <> host]

   let host = "localhost:3000"
       css file = stylesheet ("http://" <> host <> "/css/" <> file)

   css "bootstrap.min.css"
   css "materialdesignicons.min.css"
   css "style.css"

   return host

  where
    stylesheet url = link_ [href_ =: url, rel_ =: ["stylesheet"], crossorigin_ =: "anonymous"]
    --css = decodeUtf8 $(embedFile "style.css")

nonEmpty :: [a] -> Maybe [a]
nonEmpty = \case
  [] -> Nothing
  xs -> Just xs


viewControls :: GhcjsBuilder t m => Event t AppCommand -> DocInfo -> m (Dynamic t Viewport)
viewControls cmds info = mdo
  windowDim  <- windowDimensions

  controls <- holdDyn  (1, V2 0 0) (updateView <$> viewCmds <#> current viewport)
  let viewport = makeViewport <$> controls <*> pure (info ^. #imageSize) <*> windowDim

  return viewport

  where
    viewCmds = preview _ViewCmd <?> cmds

    updateView cmd vp = getControls $ case cmd of
      ZoomView zoom pos -> zoomView zoom pos vp
      PanView localOrign page -> panView localOrign page vp

    getControls (Viewport _ _ pan zoom) = (zoom, pan)
    makeViewport (zoom, pan) image window =
        Viewport (fromDim image) (fromDim window) pan zoom

errorDialog :: Builder t m => ErrCode -> m (Event t ())
errorDialog err = Dialog.ok title (Dialog.iconText ("text-danger", "alert-circle") msg)
  where  (title, msg) = errorMessage err

errorMessage :: ErrCode -> (Text, Text)
errorMessage (ErrDecode msg) = ("Decode error", msg)
errorMessage (ErrNotFound doc) = ("File not found", "File \"" <> doc <> "\" not found on server.")
errorMessage ErrNotRunning = ("Trainer error", "Trainer process not started.")
errorMessage (ErrTrainer msg) = ("Trainer error", msg)



network :: GhcjsBuilder t m => Text -> Event t ClientMsg -> m (Event t (), Event t (Maybe Text), Event t ServerMsg, Event t ErrCode)
network host send = do
  socket <- webSocket ("ws://" <> host <> "/clients") $ def
    & webSocketConfig_send  .~ (pure . encode <$> send)

  let (errs, decoded) = splitEither (eitherDecodeStrict <$> socket ^. webSocket_recv) 
      errors = leftmost
        [ ErrDecode . fromString <$>  errs
        , preview _ServerError <?> decoded
        ]

  performEvent_ (liftIO . print <$> send)
  performEvent_ (liftIO . print <$> decoded)

  return
    ( socket ^. webSocket_open
    , close <$> socket ^. webSocket_close
    , decoded
    , errors)


  where
    close (True,  _, _)       = Nothing
    close (False, _, reason)  = Just reason


handleHistory :: GhcjsBuilder t m => Event t DocName -> m (Event t DocName)
handleHistory loaded = mdo

  currentFile <- hold Nothing (Just <$> leftmost [loaded, changes])

  let update     = id <?> (updateHistory <$> current history <*> currentFile <@> loaded)
      changes    = uriDocument <$> updated history

  history <- manageHistory update
  return $ new <?> (currentFile `attach` changes)

   where
     new (Nothing, k)       = Just k
     new (Just previous, k) = k <$ guard (previous /= k)

     uriDocument = T.pack . drop 1 . view #uriFragment . _historyItem_uri

     updateHistory item Nothing k = Just $ HistoryCommand_ReplaceState $ update item k
     updateHistory item (Just previous) k
        | previous /= k = Just $ HistoryCommand_PushState $ update item k
        | otherwise       = Nothing

     update (HistoryItem state uri) k = HistoryStateUpdate
        { _historyStateUpdate_state = state
        , _historyStateUpdate_title = ""
        , _historyStateUpdate_uri   = Just $ uri & #uriFragment .~ T.unpack ("#" <> k)
        }


sceneWidget :: forall t m. (GhcjsAppBuilder t m)
            => Event t AppCommand -> Document -> m (Dynamic t Action, Dynamic t (Maybe Document))
sceneWidget cmds loaded  = mdo

  document <- holdDyn loaded (snd <$> modified)
  let modified = attachWithMaybe (flip applyCmd') (current document) docCmd
      clearCmd = (clearAnnotations <$> current document) <@ (_ClearCmd ?> cmds)
      docCmd = leftmost [_DocCmd ?> cmds, clearCmd]

  viewport <- viewControls cmds (loaded ^. #info)
  input <- holdInputs (current viewport) hover =<< inputs element

  -- Keep track of next id to use for new annotations
  let initialId = maybe 0 (+1) (maxId loaded)
      addNew = _DocEdit . _Add ?> docCmd
  nextId <- foldDyn (const (+1)) initialId addNew

  -- Set selection to the last added annotations (including undo/redo etc.)
  let latestEdit = fst . fst <$> modified
      latestAdd = fmap (S.fromList . fmap fst) . preview _Add <?> latestEdit
  selection <- holdDyn S.empty $
    leftmost [latestAdd, _SelectCmd ?> cmds]
    
  env <- ask

  (element, (action, hover)) <- sceneView $ Scene
    { image    = ("images/" <> loaded ^. #name, loaded ^. #info . #imageSize)
    , viewport = viewport
    , input    = input
    , document = document

    , selection = selection
    , annotations = Patched annotations0 (PatchMap . editPatch <$> modified)

    , nextId = nextId
    , currentClass = view #currentClass env
    , config = view #config env
    }

  return (action, (Just <$> document))
    where annotations0 = loaded ^. #annotations


bodyWidget :: forall t m. GhcjsBuilder t m => Text -> m ()
bodyWidget host = mdo
  (opened, closed, serverMsg, serverErrors) <- network host clientMsg

  let disconnected = Workflow $ do
        Dialog.connecting
        return (("disconnected", never), connected <$ opened)

      connected = Workflow $ do
        return (("connected", never), ready <$> hello)

      ready _ = Workflow $ do
        
        needsLoad <- filterMaybe <$>
          postCurrent (preview _Nothing <$> current document)

        return (("ready", ClientNext Nothing <$ needsLoad), never)

  (state, clientMsgs) <- split <$> (workflow $
    commonTransition (disconnected <$ closed) disconnected)

  runWithClose (errorDialog <$> serverErrors)

  let clientMsg = leftmost
        [ switchPrompt clientMsgs
        , ClientOpen <$> urlSelected
        , preview _RemoteCmd <?> cmds
        ]


  urlSelected <- handleHistory (view #name <$> loaded)
  setTitle $ ffor document $ \doc ->
    "Annotate - " <> fromMaybe ("no document") (view #name <$> doc)

  let hello   = preview _ServerHello <?> serverMsg
      (loaded :: Event t Document)  = preview _ServerDocument <?> serverMsg
      env = AppEnv 
        { basePath = "http://" <> host
        , document = document
        , commands = cmds
        , config = config
        , currentClass = currentClass
        }
  
  config <- holdDyn defaultConfig $ leftmost [view _2 <$> hello, preview _ServerConfig <?> serverMsg]
  currentClass <- holdDyn 0 never

  ((action, document), cmds) <- flip runReaderT env $ runEventWriterT $ 
    cursorLock action $ do
      div [class_ =: "scene expand"] $ do
        state <- replaceHold 
            (pure (def, pure Nothing)) 
            (sceneWidget cmds <$> loaded)
        overlay document
        return state
        
  return ()



cursorLock :: Builder t m => Dynamic t Action -> m a -> m a
cursorLock action child =
  div [class_ =: "expand", draggable_ =: False, style_ ~: cursorStyle <$> action] $
    div [classes_ ~: lockClass <$> action] child
  where
    cursorStyle Action{..} = [("cursor", cursor)]
    lockClass Action{..} = ["expand"] <> ["cursor-lock" | lock]




data SideTab = ClassesTab | ImagesTab | DetectionTab
  deriving (Show, Ord, Eq, Generic)

type Selectable t m = Dynamic t Bool -> m (Event t ()) 

tab :: Builder t m => Text -> Text -> Selectable t m
tab iconName t = \active -> 
  li [class_ =: "nav-item"] $ do
    e <- a_ [classList ["nav-link", "active" `gated` active], href_ =: "#"] $ 
      iconTextH t (def & #name .~ pure iconName)
    return (domEvent Click e)
    


tabs :: (Builder t m) => Int -> [(m (), Selectable t m)] -> m ()
tabs initial items = column "expand" $ mdo    
    click <- ul [class_ =: "nav nav-tabs background-light enable-cursor "] $     
      selectable openTab (pure (enumerate header))
      
    openTab <- holdDyn initial click
    tabContent openTab (enumerate content)
  where
    (content, header) = split items
    
enumerate :: (Enum k, Num k) => [a] -> [(k, a)]
enumerate = zip [0..]

selectable :: (Ord k, Builder t m) => Dynamic t k -> Active t [(k, Selectable t m)] -> m (Event t k)
selectable selected items = active (fmap leftmost . traverse f <$> items) 
    where 
      f (k, item) = fmap (const k) <$> item (isOpen k)
      isOpen = fanDyn selected
  
tabContent :: (Ord k, Builder t m) =>  Dynamic t k -> [(k, m ())] -> m ()
tabContent selected items = void $ div_ [class_ =: "tab-content p-2 grow"] $ traverse_ item items
  where 
    item (k, m) = div_ [classList ["tab-pane h-100", "active" `gated` isOpen k]] m
    isOpen = fanDyn selected



selectTable :: (Ord k, Builder t m) =>  Dynamic t k -> Active t [(k, m ())] -> m (Event t k)
selectTable selected items = table [class_ =: "table table-hover"] $ do
  tbody [] $ selectable selected (fmap (over _2 row) <$> items)
  
  where
    row item = \active -> domEvent Click <$> 
      tr_ [class_ ~: gated "table-active" active] item
  
  
labelled :: Builder t m => Text -> m a -> m a 
labelled t inner = row "align-items-stretch" $ do
  Html.label [class_ =: "grow-1"] $ text t
  div [class_ =: "grow-2"] inner
  
    
classesTab :: forall t m. AppBuilder t m => m ()
classesTab = column "h-100 p-2 v-spacing-2" $ mdo 
  classes   <- fmap (view #classes) <$> view #config
  selected <- holdDyn 0 (leftmost [userSelect, added])
  let selectedClass = M.lookup <$>  selected <*> classes
  
  (added, removed) <- row "" $ buttonGroup $ do
    add <- toolButton' "Add" "plus-box" "Add new class"
    remove  <- toolButton (isJust <$> selectedClass) "Remove" "minus-box" "Remove selected class"

    return (nextClass <$> current classes `tag` add, current selected `tag` remove)
      
  
  userSelect <- div [class_ =: "grow-1 border"] $ do
    selectTable selected (Dyn (M.toList . fmap showClass <$> classes))
   
  (updated :: Event t ClassConfig) <- switchHold never =<< dyn (editClass <$> selectedClass) 
  
  remoteCommand id $ leftmost
    [ newClassCmd    <$> added
    , removeClassCmd <$> removed
    , attachWith updateClassCmd (current selected) updated 
    ]    
  
  
  return ()
    where
      nextClass classes = fromMaybe 0 ((+1) . fst <$> M.lookupMax classes)
      
      newClassCmd k           = ClientClass k (Just $ newClass k)
      removeClassCmd k        = ClientClass k Nothing
      updateClassCmd k update = ClientClass k (Just update)
      
      
      editClass :: Maybe ClassConfig -> m (Event t ClassConfig)
      editClass conf = do  
        column "v-spacing-2 p-2 border" $ do        
          name <- labelled "Name" $ inputElem  [class_ =: "form-control", disable] $ def & 
            inputElementConfig_initialValue .~ fromMaybe "" (view #name <$> conf)
            
          shape <- labelled "Type" $ selectElem_ [class_ =: "form-control", disable] selectConf $ 
              forM_ (M.keys shapeTypes) $ \k -> option [value_ =: k] $ text k

          labelled "Colour" $ div_ [class_ =: "border expand", bgColour (view #colour <$> conf), disable] blank
          update <- row "" $ do 
            spacer 
            iconButton (pure $ isJust conf) "Update" "content-save" "Update class changes"
          
          let value = liftA3 ClassConfig 
                <$> fmap Just (current (_inputElement_value name))
                <*> fmap fromDesc (current (_selectElement_value shape))
                <*> pure (view #colour <$> conf)
            
          return $ filterMaybe (value `tag` update)
            
            where selectConf = def & selectElementConfig_initialValue .~ 
                    fromMaybe "" (shapeDesc . view #shape <$> conf)
                    
                  disable = disabled_ =: isNothing conf
                  
      showClass :: ClassConfig -> m ()
      showClass ClassConfig{shape, colour, name} = 
        void $ row "align-items-center spacing-2 p-1" $ do
          span [] $ text name
          spacer
          div [bgColour (Just colour)] $
            icon $ def & #name .~ pure (shapeIcon shape)
                
      bgColour (Just colour) = style_ =: [("background-color", showColour colour)]
      bgColour Nothing = style_ =: []
      
      shapeIcon BoxConfig = "vector-rectangle"
      shapeIcon PolygonConfig = "vector-polygon"
      shapeIcon LineConfig = "vector-line"

      shapeDesc BoxConfig = "Box"
      shapeDesc PolygonConfig = "Polygon"
      shapeDesc LineConfig = "Line"
      
      fromDesc = flip M.lookup shapeTypes
      
      shapeTypes = M.fromList
        [ ("Box", BoxConfig) 
        , ("Polygon", PolygonConfig)
        , ("Line", LineConfig)
        ]

      

showColour = T.pack . printf "#%06X" 

imagesTab :: AppBuilder t m => m ()
imagesTab = text "images"

detectionTab :: AppBuilder t m => m ()
detectionTab = text "detection"
  
sidebar :: AppBuilder t m => m ()
sidebar = mdo 
  
  isOpen <- div [classList ["enable-cursor sidebar bg-white p-2", swapping ("closed", "open") isOpen]] $ do
    isOpen <- toggler

    tabs 0 
      [ (classesTab,    tab "tag-multiple"   "Classes") 
      , (imagesTab,     tab "folder-multiple-image" "Images")
      , (detectionTab,  tab "auto-fix"  "Detection")
      ]
      
    return isOpen
  return ()

    where
      toggler = mdo 
        e <- a_ [href_ =: "#", class_ =: "toggler p-2"] $ 
            icon (def & #name .~ Dyn (swapping ("chevron-right", "chevron-left") isOpen))
        isOpen <- toggle False (domEvent Click e)
        return isOpen




-- Main interface



overlay :: AppBuilder t m =>  Dynamic t (Maybe Document) -> m ()
overlay document = row "expand  disable-cursor" $ do
   sidebar
   column "expand" $ 
    sequence_ [header, spacer, footer]
  
  where
    header = buttonRow $ do 
      
      spacer
      buttonGroup $ do
        docCommand  (const DocUndo)  =<< toolButton canUndo "Undo" "undo" "Undo last edit"
        docCommand  (const DocRedo)  =<< toolButton canRedo "Redo" "redo" "Re-do last undo"
        command     (const ClearCmd) =<< toolButton' "Clear" "eraser" "Clear all annotations"

      detect <- toolButton docOpen "Detect" "auto-fix" "Detect annotations using current trained model"
      remoteCommand id (withDocument (ClientDetect . view #name) detect)
      
    canUndo = fromDocument False (not . null . view #undos)
    canRedo = fromDocument False (not . null . view #redos)
            
    footer = buttonRow $ do
      spacer
      buttonGroup $ do
        discard <- toolButton docOpen "Discard" "delete-empty" "Discard image from the collection"
        submit  <- toolButton docOpen "Submit" "content-save" "Submit image for training"

        remoteCommand id $ leftmost
          [ withDocument (ClientDiscard . view #name) discard
          , withDocument ClientSubmit submit
          ]
    
    buttonRow = row "p-2 spacing-4"
    nonEmpty label = notNullOf (_Just . label . traverse)
    
    fromDocument a f = fromMaybe a . fmap f <$> document
    withDocument f e = fmap f <?> (current document `tag` e)
    docOpen = isJust <$> document    
    