module Mutation.BulkCreateGroups exposing (Response(..), request)

import GraphQL exposing (Document)
import Group
import Json.Decode as Decode
import Json.Encode as Encode
import Session exposing (Session)
import Task exposing (Task)
import ValidationFields


type Response
    = Success


document : Document
document =
    GraphQL.toDocument
        """
        mutation BulkCreateGroups(
          $spaceId: ID!,
          $names: [String]!
        ) {
          bulkCreateGroups(
            spaceId: $spaceId,
            names: $names
          ) {
            payloads {
              ...ValidationFields
              group {
                ...GroupFields
              }
              args {
                name
              }
            }
          }
        }
        """
        [ Group.fragment
        , ValidationFields.fragment
        ]


variables : String -> List String -> Maybe Encode.Value
variables spaceId names =
    Just <|
        Encode.object
            [ ( "spaceId", Encode.string spaceId )
            , ( "names", Encode.list Encode.string names )
            ]


decoder : Decode.Decoder Response
decoder =
    -- For now, we aren't bothering to parse the result here since we don't
    -- expect there to be validation errors with controlled input in the
    -- onboarding phase. If we start allowing user-supplied input, we should
    -- actually decode the result.
    Decode.succeed Success


request : String -> List String -> Session -> Task Session.Error ( Session, Response )
request spaceId names session =
    Session.request session <|
        GraphQL.request document (variables spaceId names) decoder
