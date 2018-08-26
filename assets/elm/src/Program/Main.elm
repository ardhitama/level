module Program.Main exposing (main)

import Avatar exposing (personAvatar, thingAvatar)
import Browser exposing (Document, UrlRequest)
import Browser.Navigation as Nav
import Event exposing (Event)
import Group exposing (Group)
import Html exposing (..)
import Html.Attributes exposing (..)
import Json.Decode as Decode
import ListHelpers exposing (insertUniqueBy, removeBy)
import Page
import Page.Group
import Page.Groups
import Page.Inbox
import Page.NewGroup
import Page.Post
import Page.Setup.CreateGroups
import Page.Setup.InviteUsers
import Page.SpaceSettings
import Page.SpaceUsers
import Page.UserSettings
import Query.MainInit as MainInit
import Repo exposing (Repo)
import Route exposing (Route)
import Route.Groups
import Session exposing (Session)
import Socket
import Space exposing (Space)
import SpaceUser
import Subscription.SpaceSubscription as SpaceSubscription
import Subscription.SpaceUserSubscription as SpaceUserSubscription
import Task exposing (Task)
import Url exposing (Url)
import Util exposing (Lazy(..))
import View.Helpers exposing (displayName)
import View.Layout exposing (appLayout, spaceLayout)



-- PROGRAM


main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlRequest = UrlRequest
        , onUrlChange = UrlChange
        }



-- MODEL


type alias Model =
    { navKey : Nav.Key
    , session : Session
    , repo : Repo
    , page : Page
    , isTransitioning : Bool
    }


type alias Flags =
    { apiToken : String
    }



-- LIFECYCLE


init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url navKey =
    let
        ( model, navigateCmd ) =
            navigateTo (Route.fromUrl url) <|
                buildModel flags navKey

        initCmd =
            model.session
                |> MainInit.request
                |> Task.attempt AppInitialized
    in
    ( model, Cmd.batch [ navigateCmd, initCmd ] )


buildModel : Flags -> Nav.Key -> Model
buildModel flags navKey =
    Model navKey (Session.init flags.apiToken) Repo.init Blank True


setup : MainInit.Response -> Model -> Cmd Msg
setup { spaceIds, spaceUserIds } model =
    let
        spaceSubs =
            spaceIds
                |> List.map SpaceSubscription.subscribe

        spaceUserSubs =
            spaceUserIds
                |> List.map SpaceUserSubscription.subscribe
    in
    Cmd.batch (spaceSubs ++ spaceUserSubs)



-- UPDATE


type Msg
    = UrlChange Url
    | UrlRequest UrlRequest
    | AppInitialized (Result Session.Error ( Session, MainInit.Response ))
    | SessionRefreshed (Result Session.Error Session)
    | PageInitialized PageInit
    | SetupCreateGroupsMsg Page.Setup.CreateGroups.Msg
    | SetupInviteUsersMsg Page.Setup.InviteUsers.Msg
    | InboxMsg Page.Inbox.Msg
    | SpaceUsersMsg Page.SpaceUsers.Msg
    | GroupsMsg Page.Groups.Msg
    | GroupMsg Page.Group.Msg
    | NewGroupMsg Page.NewGroup.Msg
    | PostMsg Page.Post.Msg
    | UserSettingsMsg Page.UserSettings.Msg
    | SpaceSettingsMsg Page.SpaceSettings.Msg
    | SocketAbort Decode.Value
    | SocketStart Decode.Value
    | SocketResult Decode.Value
    | SocketError Decode.Value


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case ( msg, model.page ) of
        ( UrlChange url, _ ) ->
            navigateTo (Route.fromUrl url) model

        ( UrlRequest request, _ ) ->
            case request of
                Browser.Internal url ->
                    case url.path of
                        "/spaces" ->
                            ( model
                            , Nav.load (Url.toString url)
                            )

                        _ ->
                            ( model
                            , Nav.pushUrl model.navKey (Url.toString url)
                            )

                Browser.External href ->
                    ( model
                    , Nav.load href
                    )

        ( AppInitialized (Ok ( newSession, response )), _ ) ->
            ( { model | session = newSession }
            , setup response model
            )

        ( AppInitialized (Err Session.Expired), _ ) ->
            ( model, Route.toLogin )

        ( AppInitialized (Err _), _ ) ->
            ( model, Cmd.none )

        ( SessionRefreshed (Ok newSession), _ ) ->
            ( { model | session = newSession }, Session.propagateToken newSession )

        ( SessionRefreshed (Err Session.Expired), _ ) ->
            ( model, Route.toLogin )

        ( PageInitialized pageInit, _ ) ->
            let
                ( newModel, cmd ) =
                    setupPage pageInit model
            in
            ( newModel
            , Cmd.batch
                [ cmd
                , Page.setTitle (pageTitle newModel.repo newModel.page)
                ]
            )

        ( InboxMsg pageMsg, Inbox pageModel ) ->
            let
                ( ( newPageModel, cmd ), session ) =
                    Page.Inbox.update pageMsg model.session pageModel
            in
            ( { model
                | session = session
                , page = Inbox newPageModel
              }
            , Cmd.map InboxMsg cmd
            )

        ( SetupCreateGroupsMsg pageMsg, SetupCreateGroups pageModel ) ->
            let
                ( ( newPageModel, pageCmd ), session, externalMsg ) =
                    Page.Setup.CreateGroups.update pageMsg model.session pageModel

                ( newModel, cmd ) =
                    case externalMsg of
                        Page.Setup.CreateGroups.SetupStateChanged newState ->
                            ( model
                            , Route.pushUrl model.navKey (Space.setupRoute pageModel.space newState)
                            )

                        Page.Setup.CreateGroups.NoOp ->
                            ( model, Cmd.none )
            in
            ( { newModel
                | session = session
                , page = SetupCreateGroups newPageModel
              }
            , Cmd.batch
                [ Cmd.map SetupCreateGroupsMsg pageCmd
                , cmd
                ]
            )

        ( SetupInviteUsersMsg pageMsg, SetupInviteUsers pageModel ) ->
            let
                ( ( newPageModel, pageCmd ), session, externalMsg ) =
                    Page.Setup.InviteUsers.update pageMsg model.session pageModel

                ( newModel, cmd ) =
                    case externalMsg of
                        Page.Setup.InviteUsers.SetupStateChanged newState ->
                            ( model
                            , Route.pushUrl model.navKey (Space.setupRoute pageModel.space newState)
                            )

                        Page.Setup.InviteUsers.NoOp ->
                            ( model, Cmd.none )
            in
            ( { newModel
                | session = session
                , page = SetupInviteUsers newPageModel
              }
            , Cmd.batch
                [ Cmd.map SetupInviteUsersMsg pageCmd
                , cmd
                ]
            )

        ( SpaceUsersMsg pageMsg, SpaceUsers pageModel ) ->
            let
                ( ( newPageModel, cmd ), session ) =
                    Page.SpaceUsers.update pageMsg model.repo model.session pageModel
            in
            ( { model | session = session, page = SpaceUsers newPageModel }
            , Cmd.map SpaceUsersMsg cmd
            )

        ( GroupsMsg pageMsg, Groups pageModel ) ->
            let
                ( ( newPageModel, cmd ), session ) =
                    Page.Groups.update pageMsg model.repo model.session pageModel
            in
            ( { model | session = session, page = Groups newPageModel }
            , Cmd.map GroupsMsg cmd
            )

        ( GroupMsg pageMsg, Group pageModel ) ->
            let
                ( ( newPageModel, cmd ), session ) =
                    Page.Group.update pageMsg model.repo model.session pageModel
            in
            ( { model | session = session, page = Group newPageModel }
            , Cmd.map GroupMsg cmd
            )

        ( NewGroupMsg pageMsg, NewGroup pageModel ) ->
            let
                ( ( newPageModel, cmd ), session ) =
                    Page.NewGroup.update pageMsg model.session pageModel
            in
            ( { model | session = session, page = NewGroup newPageModel }
            , Cmd.map NewGroupMsg cmd
            )

        ( PostMsg pageMsg, Post pageModel ) ->
            let
                ( ( newPageModel, cmd ), session ) =
                    Page.Post.update pageMsg model.repo model.session pageModel
            in
            ( { model | session = session, page = Post newPageModel }
            , Cmd.map PostMsg cmd
            )

        ( UserSettingsMsg pageMsg, UserSettings pageModel ) ->
            let
                ( ( newPageModel, cmd ), session ) =
                    Page.UserSettings.update pageMsg model.session pageModel
            in
            ( { model | session = session, page = UserSettings newPageModel }
            , Cmd.map UserSettingsMsg cmd
            )

        ( SpaceSettingsMsg pageMsg, SpaceSettings pageModel ) ->
            let
                ( ( newPageModel, cmd ), session ) =
                    Page.SpaceSettings.update pageMsg model.session pageModel
            in
            ( { model | session = session, page = SpaceSettings newPageModel }
            , Cmd.map SpaceSettingsMsg cmd
            )

        ( SocketAbort value, _ ) ->
            ( model, Cmd.none )

        ( SocketStart value, _ ) ->
            ( model, Cmd.none )

        ( SocketResult value, page ) ->
            let
                event =
                    Event.decodeEvent value

                ( newModel, cmd ) =
                    consumeEvent event model

                ( newModel2, cmd2 ) =
                    sendEventToPage event newModel
            in
            ( newModel2, Cmd.batch [ cmd, cmd2 ] )

        ( SocketError value, _ ) ->
            let
                cmd =
                    model.session
                        |> Session.fetchNewToken
                        |> Task.attempt SessionRefreshed
            in
            ( model, cmd )

        ( _, _ ) ->
            -- Disregard incoming messages that arrived for the wrong page
            ( model, Cmd.none )



-- MUTATIONS


updateRepo : Repo -> Model -> ( Model, Cmd Msg )
updateRepo newRepo model =
    ( { model | repo = newRepo }, Cmd.none )



-- PAGES


type Page
    = Blank
    | NotFound
    | SetupCreateGroups Page.Setup.CreateGroups.Model
    | SetupInviteUsers Page.Setup.InviteUsers.Model
    | Inbox Page.Inbox.Model
    | SpaceUsers Page.SpaceUsers.Model
    | Groups Page.Groups.Model
    | Group Page.Group.Model
    | NewGroup Page.NewGroup.Model
    | Post Page.Post.Model
    | UserSettings Page.UserSettings.Model
    | SpaceSettings Page.SpaceSettings.Model


type PageInit
    = InboxInit (Result Session.Error ( Session, Page.Inbox.Model ))
    | SpaceUsersInit (Result Session.Error ( Session, Page.SpaceUsers.Model ))
    | GroupsInit (Result Session.Error ( Session, Page.Groups.Model ))
    | GroupInit String (Result Session.Error ( Session, Page.Group.Model ))
    | NewGroupInit (Result Session.Error ( Session, Page.NewGroup.Model ))
    | PostInit String (Result Session.Error ( Session, Page.Post.Model ))
    | UserSettingsInit (Result Session.Error ( Session, Page.UserSettings.Model ))
    | SpaceSettingsInit (Result Session.Error ( Session, Page.SpaceSettings.Model ))
    | SetupCreateGroupsInit (Result Session.Error ( Session, Page.Setup.CreateGroups.Model ))
    | SetupInviteUsersInit (Result Session.Error ( Session, Page.Setup.InviteUsers.Model ))


transition : Model -> (Result x a -> PageInit) -> Task x a -> ( Model, Cmd Msg )
transition model toMsg task =
    ( { model | isTransitioning = True }
    , Cmd.batch
        [ teardownPage model.page
        , Cmd.map PageInitialized <| Task.attempt toMsg task
        ]
    )


navigateTo : Maybe Route -> Model -> ( Model, Cmd Msg )
navigateTo maybeRoute model =
    case maybeRoute of
        Nothing ->
            ( { model | page = NotFound }, Cmd.none )

        Just (Route.Root spaceSlug) ->
            navigateTo (Just <| Route.Inbox spaceSlug) model

        Just (Route.SetupCreateGroups spaceSlug) ->
            model.session
                |> Page.Setup.CreateGroups.init spaceSlug
                |> transition model SetupCreateGroupsInit

        Just (Route.SetupInviteUsers spaceSlug) ->
            model.session
                |> Page.Setup.InviteUsers.init spaceSlug
                |> transition model SetupInviteUsersInit

        Just (Route.Inbox spaceSlug) ->
            model.session
                |> Page.Inbox.init spaceSlug
                |> transition model InboxInit

        Just (Route.SpaceUsers params) ->
            model.session
                |> Page.SpaceUsers.init params
                |> transition model SpaceUsersInit

        Just (Route.Groups params) ->
            model.session
                |> Page.Groups.init params
                |> transition model GroupsInit

        Just (Route.Group spaceSlug groupId) ->
            model.session
                |> Page.Group.init spaceSlug groupId
                |> transition model (GroupInit groupId)

        Just (Route.NewGroup spaceSlug) ->
            model.session
                |> Page.NewGroup.init spaceSlug
                |> transition model NewGroupInit

        Just (Route.Post spaceSlug postId) ->
            model.session
                |> Page.Post.init spaceSlug postId
                |> transition model (PostInit postId)

        Just (Route.SpaceSettings spaceSlug) ->
            model.session
                |> Page.SpaceSettings.init spaceSlug
                |> transition model SpaceSettingsInit

        Just Route.UserSettings ->
            model.session
                |> Page.UserSettings.init
                |> transition model UserSettingsInit


pageTitle : Repo -> Page -> String
pageTitle repo page =
    case page of
        Inbox _ ->
            Page.Inbox.title

        SpaceUsers _ ->
            Page.SpaceUsers.title

        Group pageModel ->
            Page.Group.title repo pageModel

        Groups _ ->
            Page.Groups.title

        NewGroup _ ->
            Page.NewGroup.title

        Post pageModel ->
            Page.Post.title repo pageModel

        SpaceSettings _ ->
            Page.SpaceSettings.title

        UserSettings _ ->
            Page.UserSettings.title

        SetupCreateGroups _ ->
            Page.Setup.CreateGroups.title

        SetupInviteUsers _ ->
            Page.Setup.InviteUsers.title

        NotFound ->
            "404"

        Blank ->
            "Level"


setupPage : PageInit -> Model -> ( Model, Cmd Msg )
setupPage pageInit model =
    case pageInit of
        InboxInit (Ok ( session, pageModel )) ->
            ( { model
                | page = Inbox pageModel
                , session = session
                , isTransitioning = False
              }
            , Page.Inbox.setup pageModel
                |> Cmd.map InboxMsg
            )

        InboxInit (Err Session.Expired) ->
            ( model, Route.toLogin )

        InboxInit (Err _) ->
            ( model, Cmd.none )

        SpaceUsersInit (Ok ( session, pageModel )) ->
            ( { model
                | page = SpaceUsers pageModel
                , session = session
                , isTransitioning = False
              }
            , Page.SpaceUsers.setup pageModel
                |> Cmd.map SpaceUsersMsg
            )

        SpaceUsersInit (Err Session.Expired) ->
            ( model, Route.toLogin )

        SpaceUsersInit (Err _) ->
            -- TODO: Handle other error modes
            ( model, Cmd.none )

        GroupsInit (Ok ( session, pageModel )) ->
            ( { model
                | page = Groups pageModel
                , session = session
                , isTransitioning = False
              }
            , Page.Groups.setup pageModel
                |> Cmd.map GroupsMsg
            )

        GroupsInit (Err Session.Expired) ->
            ( model, Route.toLogin )

        GroupsInit (Err _) ->
            -- TODO: Handle other error modes
            ( model, Cmd.none )

        GroupInit _ (Ok ( session, pageModel )) ->
            ( { model
                | page = Group pageModel
                , session = session
                , isTransitioning = False
              }
            , Page.Group.setup pageModel
                |> Cmd.map GroupMsg
            )

        GroupInit _ (Err Session.Expired) ->
            ( model, Route.toLogin )

        GroupInit _ (Err _) ->
            -- TODO: Handle other error modes
            ( model, Cmd.none )

        NewGroupInit (Ok ( session, pageModel )) ->
            ( { model
                | page = NewGroup pageModel
                , session = session
                , isTransitioning = False
              }
            , Page.NewGroup.setup pageModel
                |> Cmd.map NewGroupMsg
            )

        NewGroupInit (Err Session.Expired) ->
            ( model, Route.toLogin )

        NewGroupInit (Err _) ->
            -- TODO: Handle other error modes
            ( model, Cmd.none )

        PostInit _ (Ok ( session, pageModel )) ->
            ( { model
                | page = Post pageModel
                , session = session
                , isTransitioning = False
              }
            , Page.Post.setup session pageModel
                |> Cmd.map PostMsg
            )

        PostInit _ (Err Session.Expired) ->
            ( model, Route.toLogin )

        PostInit _ (Err _) ->
            -- TODO: Handle other error modes
            ( model, Cmd.none )

        UserSettingsInit (Ok ( session, pageModel )) ->
            ( { model
                | page = UserSettings pageModel
                , session = session
                , isTransitioning = False
              }
            , Page.UserSettings.setup pageModel
                |> Cmd.map UserSettingsMsg
            )

        UserSettingsInit (Err Session.Expired) ->
            ( model, Route.toLogin )

        UserSettingsInit (Err _) ->
            -- TODO: Handle other error modes
            ( model, Cmd.none )

        SpaceSettingsInit (Ok ( session, pageModel )) ->
            ( { model
                | page = SpaceSettings pageModel
                , session = session
                , isTransitioning = False
              }
            , Page.SpaceSettings.setup pageModel
                |> Cmd.map SpaceSettingsMsg
            )

        SpaceSettingsInit (Err Session.Expired) ->
            ( model, Route.toLogin )

        SpaceSettingsInit (Err _) ->
            -- TODO: Handle other error modes
            ( model, Cmd.none )

        SetupCreateGroupsInit (Ok ( session, pageModel )) ->
            ( { model
                | page = SetupCreateGroups pageModel
                , session = session
                , isTransitioning = False
              }
            , Page.Setup.CreateGroups.setup
                |> Cmd.map SetupCreateGroupsMsg
            )

        SetupCreateGroupsInit (Err Session.Expired) ->
            ( model, Route.toLogin )

        SetupCreateGroupsInit (Err _) ->
            -- TODO: Handle other error modes
            ( model, Cmd.none )

        SetupInviteUsersInit (Ok ( session, pageModel )) ->
            ( { model
                | page = SetupInviteUsers pageModel
                , session = session
                , isTransitioning = False
              }
            , Page.Setup.InviteUsers.setup
                |> Cmd.map SetupInviteUsersMsg
            )

        SetupInviteUsersInit (Err Session.Expired) ->
            ( model, Route.toLogin )

        SetupInviteUsersInit (Err _) ->
            -- TODO: Handle other error modes
            ( model, Cmd.none )


teardownPage : Page -> Cmd Msg
teardownPage page =
    case page of
        SpaceUsers pageModel ->
            Cmd.map SpaceUsersMsg (Page.SpaceUsers.teardown pageModel)

        Group pageModel ->
            Cmd.map GroupMsg (Page.Group.teardown pageModel)

        UserSettings pageModel ->
            Cmd.map UserSettingsMsg (Page.UserSettings.teardown pageModel)

        SpaceSettings pageModel ->
            Cmd.map SpaceSettingsMsg (Page.SpaceSettings.teardown pageModel)

        _ ->
            Cmd.none


pageSubscription : Page -> Sub Msg
pageSubscription page =
    case page of
        Inbox _ ->
            Sub.map InboxMsg Page.Inbox.subscriptions

        Group _ ->
            Sub.map GroupMsg Page.Group.subscriptions

        Post _ ->
            Sub.map PostMsg Page.Post.subscriptions

        UserSettings _ ->
            Sub.map UserSettingsMsg Page.UserSettings.subscriptions

        SpaceSettings _ ->
            Sub.map SpaceSettingsMsg Page.SpaceSettings.subscriptions

        _ ->
            Sub.none


routeFor : Page -> Maybe Route
routeFor page =
    case page of
        Inbox { space } ->
            Just <| Route.Inbox (Space.getSlug space)

        SetupCreateGroups { space } ->
            Just <| Route.SetupCreateGroups (Space.getSlug space)

        SetupInviteUsers { space } ->
            Just <| Route.SetupInviteUsers (Space.getSlug space)

        SpaceUsers { params } ->
            Just <| Route.SpaceUsers params

        Groups { params } ->
            Just <| Route.Groups params

        Group { space, group } ->
            Just <| Route.Group (Space.getSlug space) (Group.getId group)

        NewGroup { space } ->
            Just <| Route.NewGroup (Space.getSlug space)

        Post { space, post } ->
            Just <| Route.Post (Space.getSlug space) post.id

        UserSettings _ ->
            Just <| Route.UserSettings

        SpaceSettings { space } ->
            Just <| Route.SpaceSettings (Space.getSlug space)

        Blank ->
            Nothing

        NotFound ->
            Nothing


pageView : Repo -> Page -> Html Msg
pageView repo page =
    case page of
        SetupCreateGroups pageModel ->
            pageModel
                |> Page.Setup.CreateGroups.view repo (routeFor page)
                |> Html.map SetupCreateGroupsMsg

        SetupInviteUsers pageModel ->
            pageModel
                |> Page.Setup.InviteUsers.view repo (routeFor page)
                |> Html.map SetupInviteUsersMsg

        Inbox pageModel ->
            pageModel
                |> Page.Inbox.view repo (routeFor page)
                |> Html.map InboxMsg

        SpaceUsers pageModel ->
            pageModel
                |> Page.SpaceUsers.view repo (routeFor page)
                |> Html.map SpaceUsersMsg

        Groups pageModel ->
            pageModel
                |> Page.Groups.view repo (routeFor page)
                |> Html.map GroupsMsg

        Group pageModel ->
            pageModel
                |> Page.Group.view repo (routeFor page)
                |> Html.map GroupMsg

        NewGroup pageModel ->
            pageModel
                |> Page.NewGroup.view repo (routeFor page)
                |> Html.map NewGroupMsg

        Post pageModel ->
            pageModel
                |> Page.Post.view repo (routeFor page)
                |> Html.map PostMsg

        UserSettings pageModel ->
            pageModel
                |> Page.UserSettings.view repo
                |> Html.map UserSettingsMsg

        SpaceSettings pageModel ->
            pageModel
                |> Page.SpaceSettings.view repo (routeFor page)
                |> Html.map SpaceSettingsMsg

        Blank ->
            text ""

        NotFound ->
            text "404"



-- EVENTS


consumeEvent : Event -> Model -> ( Model, Cmd Msg )
consumeEvent event ({ page, repo } as model) =
    case event of
        Event.GroupBookmarked group ->
            updateRepo (Repo.setGroup model.repo group) model

        Event.GroupUnbookmarked group ->
            updateRepo (Repo.setGroup model.repo group) model

        Event.GroupMembershipUpdated group ->
            updateRepo (Repo.setGroup model.repo group) model

        Event.PostCreated ( post, replies ) ->
            updateRepo (Repo.setPost model.repo post) model

        Event.PostUpdated post ->
            updateRepo (Repo.setPost repo post) model

        Event.PostSubscribed post ->
            updateRepo (Repo.setPost repo post) model

        Event.PostUnsubscribed post ->
            updateRepo (Repo.setPost repo post) model

        Event.UserMentioned post ->
            updateRepo (Repo.setPost repo post) model

        Event.GroupUpdated group ->
            updateRepo (Repo.setGroup repo group) model

        Event.ReplyCreated reply ->
            ( model, Cmd.none )

        Event.MentionsDismissed post ->
            updateRepo (Repo.setPost repo post) model

        Event.SpaceUpdated space ->
            updateRepo (Repo.setSpace model.repo space) model

        Event.SpaceUserUpdated spaceUser ->
            updateRepo (Repo.setSpaceUser model.repo spaceUser) model

        Event.Unknown payload ->
            ( model, Cmd.none )


sendEventToPage : Event -> Model -> ( Model, Cmd Msg )
sendEventToPage event model =
    let
        updatePage toPage toPageMsg ( pageModel, pageCmd ) =
            ( { model | page = toPage pageModel }
            , Cmd.map toPageMsg pageCmd
            )
    in
    case model.page of
        SetupCreateGroups pageModel ->
            pageModel
                |> Page.Setup.CreateGroups.consumeEvent event
                |> updatePage SetupCreateGroups SetupCreateGroupsMsg

        SetupInviteUsers pageModel ->
            pageModel
                |> Page.Setup.InviteUsers.consumeEvent event
                |> updatePage SetupInviteUsers SetupInviteUsersMsg

        Inbox pageModel ->
            pageModel
                |> Page.Inbox.consumeEvent event
                |> updatePage Inbox InboxMsg

        SpaceUsers pageModel ->
            pageModel
                |> Page.SpaceUsers.consumeEvent event
                |> updatePage SpaceUsers SpaceUsersMsg

        Groups pageModel ->
            pageModel
                |> Page.Groups.consumeEvent event
                |> updatePage Groups GroupsMsg

        Group pageModel ->
            pageModel
                |> Page.Group.consumeEvent event model.session
                |> updatePage Group GroupMsg

        NewGroup pageModel ->
            pageModel
                |> Page.NewGroup.consumeEvent event
                |> updatePage NewGroup NewGroupMsg

        Post pageModel ->
            pageModel
                |> Page.Post.consumeEvent event
                |> updatePage Post PostMsg

        UserSettings pageModel ->
            pageModel
                |> Page.UserSettings.consumeEvent event
                |> updatePage UserSettings UserSettingsMsg

        SpaceSettings pageModel ->
            pageModel
                |> Page.SpaceSettings.consumeEvent event
                |> updatePage SpaceSettings SpaceSettingsMsg

        Blank ->
            ( model, Cmd.none )

        NotFound ->
            ( model, Cmd.none )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Socket.listen SocketAbort SocketStart SocketResult SocketError
        , pageSubscription model.page
        ]



-- VIEW


view : Model -> Document Msg
view model =
    Document (pageTitle model.repo model.page)
        [ pageView model.repo model.page
        ]
