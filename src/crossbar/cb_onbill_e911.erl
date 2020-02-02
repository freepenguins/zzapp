%%%-----------------------------------------------------------
%%%
%%% Manage uploaded E911 proof of address information
%%%
%%%-----------------------------------------------------------

-module(cb_onbill_e911).

-export([init/0
         ,allowed_methods/0,allowed_methods/1,allowed_methods/2
         ,resource_exists/0,resource_exists/1,resource_exists/2
         ,validate/1,validate/2,validate/3
         ,content_types_provided/3
         ,content_types_accepted/3


         ,acceptable_content_types/0
        ]).

-include("/opt/kazoo/applications/crossbar/src/crossbar.hrl").

-define(CB_E911_ADDRESSES, <<"onbill_e911/addresses">>).
-define(BIN_DATA, <<"raw">>).
-define(CONFIRM_ADDRESS, <<"confirm">>).

-define(ATTACHMENT_MIME_TYPES, ?PDF_CONTENT_TYPES ++ ?IMAGE_CONTENT_TYPES).

-spec init() -> 'ok'.
init() ->
    _ = crossbar_bindings:bind(<<"*.allowed_methods.onbill_e911">>, ?MODULE, 'allowed_methods'),
    _ = crossbar_bindings:bind(<<"*.resource_exists.onbill_e911">>, ?MODULE, 'resource_exists'),
    _ = crossbar_bindings:bind(<<"*.content_types_provided.onbill_e911">>, ?MODULE, 'content_types_provided'),
    _ = crossbar_bindings:bind(<<"*.content_types_accepted.onbill_e911">>, ?MODULE, 'content_types_accepted'),
    _ = crossbar_bindings:bind(<<"*.validate.onbill_e911">>, ?MODULE, 'validate').

-spec allowed_methods() -> http_methods().
-spec allowed_methods(path_token()) -> http_methods().
-spec allowed_methods(path_token(), path_token()) -> http_methods().
allowed_methods() ->
    [?HTTP_GET, ?HTTP_PUT].
allowed_methods(_Id) ->
    [?HTTP_GET, ?HTTP_POST, ?HTTP_DELETE].
allowed_methods(_Id, ?BIN_DATA) ->
    [?HTTP_GET, ?HTTP_POST];
allowed_methods(_Id, ?CONFIRM_ADDRESS) ->
    [?HTTP_POST].

-spec resource_exists() -> 'true'.
-spec resource_exists(path_token()) -> 'true'.
-spec resource_exists(path_token(), path_token()) -> 'true'.
resource_exists() -> 'true'.
resource_exists(_) -> 'true'.
resource_exists(_, ?BIN_DATA) -> 'true';
resource_exists(_, ?CONFIRM_ADDRESS) -> 'true'.

-spec acceptable_content_types() -> kz_term:proplist().
acceptable_content_types() ->
    ?ATTACHMENT_MIME_TYPES.

-spec content_types_provided(cb_context:context(), path_token(), path_token()) ->
                                    cb_context:context().
-spec content_types_provided_for_attachment(cb_context:context(), path_token(), path_token(), http_method()) ->
                                              cb_context:context().
content_types_provided(Context, Id, ?BIN_DATA) ->
    content_types_provided_for_attachment(Context, kz_http_util:urlencode(Id), ?BIN_DATA, cb_context:req_verb(Context)).

content_types_provided_for_attachment(Context, Id, ?BIN_DATA, ?HTTP_GET) ->
    Context1 = crossbar_doc:load(Id, Context, ?TYPE_CHECK_OPTION(<<"e911_address">>)),
    case cb_context:resp_status(Context1) of
        'success' ->
            JObj = cb_context:doc(Context1),
            case kz_doc:attachment_names(JObj) of
                [] -> Context1;
                [Attachment|_] ->
                    CT = kz_doc:attachment_content_type(JObj, Attachment),
                    [Type, SubType] = binary:split(CT, <<"/">>),
                    cb_context:set_content_types_provided(Context, [{'to_binary', [{Type, SubType}]}])
            end;
        _Status -> Context1
    end;
content_types_provided_for_attachment(Context, _Id, ?BIN_DATA, _Verb) ->
    Context.

-spec content_types_accepted(cb_context:context(), path_token(), path_token()) ->
                                    cb_context:context().
-spec content_types_accepted_for_upload(cb_context:context(), http_method()) ->
                                               cb_context:context().
content_types_accepted(Context, _Id, ?BIN_DATA) ->
    content_types_accepted_for_upload(Context, cb_context:req_verb(Context)).

content_types_accepted_for_upload(Context, ?HTTP_POST) ->
    CTA = [{'from_binary', ?ATTACHMENT_MIME_TYPES}],
    cb_context:set_content_types_accepted(Context, CTA);
content_types_accepted_for_upload(Context, _Verb) ->
    Context.

-spec validate(cb_context:context()) -> cb_context:context().
-spec validate(cb_context:context(), path_token()) -> cb_context:context().
-spec validate(cb_context:context(), path_token(), path_token()) -> cb_context:context().
validate(Context) ->
    validate_e911(Context, cb_context:req_verb(Context)).

validate(Context, Id) ->
    validate_e911_doc(Context, Id, cb_context:req_verb(Context)).

validate(Context, Id, ?CONFIRM_ADDRESS) ->
    confirm_address(Context, Id, cb_context:req_verb(Context));
validate(Context, Id, ?BIN_DATA) ->
    validate_attachment_binary(Context, kz_http_util:urlencode(Id), cb_context:req_verb(Context), cb_context:req_files(Context)).

-spec validate_e911(cb_context:context(), http_method()) -> cb_context:context().
validate_e911(Context, ?HTTP_GET) ->
    e911_addresses_summary(Context);
validate_e911(Context, ?HTTP_PUT) ->
    save_e911_doc(Context).

-spec validate_e911_doc(cb_context:context(), kz_term:ne_binary(), path_token()) -> cb_context:context().
validate_e911_doc(Context, Id, ?HTTP_GET) ->
    crossbar_doc:load(Id, Context, ?TYPE_CHECK_OPTION(<<"e911_address">>));
validate_e911_doc(Context, Id, ?HTTP_POST) ->
    save_e911_doc(Context, Id);
validate_e911_doc(Context, Id, ?HTTP_DELETE) ->
    case maybe_valid_relationship(Context) of
        'true' -> delete_e911_doc(Context, Id);
        'false' ->  cb_context:add_system_error('forbidden', Context)
    end.

-spec e911_addresses_summary(cb_context:context()) -> cb_context:context().
e911_addresses_summary(Context) ->
    AccountId = cb_context:account_id(Context),
    DbName = kz_util:format_account_id(AccountId,'encoded'),
    zz_util:maybe_add_design_doc(DbName, <<"onbill_e911">>),
    crossbar_doc:load_view(?CB_E911_ADDRESSES, [], Context, fun zz_util:normalize_view_results/2).

-spec save_e911_doc(cb_context:context()) -> cb_context:context().
-spec save_e911_doc(cb_context:context(), kz_term:ne_binary()) -> cb_context:context().
save_e911_doc(Context) ->
    save_e911_doc(Context, kz_datamgr:get_uuid()).
save_e911_doc(Context, Id) ->
    AccountId = cb_context:account_id(Context),
    ReqData = cb_context:req_data(Context),
    Db = kz_util:format_account_id(AccountId, 'encoded'),
    InitialValues = [{<<"_id">>, Id}
                    ,{<<"pvt_type">>, <<"e911_address">>}
                    ],
    Doc = case kz_datamgr:open_doc(Db, Id) of
              {'ok', JObj} -> JObj;
              _ -> kz_json:set_values(InitialValues, kz_json:new())
          end,
    NewDoc = kz_json:merge_recursive(Doc, ReqData),
    crossbar_doc:save(cb_context:set_doc(Context, NewDoc)).

-spec validate_attachment_binary(cb_context:context(), kz_term:ne_binary(), http_method(), kz_term:proplist()) -> cb_context:context().
validate_attachment_binary(Context0, Id, ?HTTP_GET, _Files) ->
    lager:debug("fetch contents for '~s'", [Id]),
    Context = crossbar_doc:load(Id, Context0, ?TYPE_CHECK_OPTION(<<"e911_address">>)),
    case kz_doc:attachment_names(cb_context:doc(Context)) of
        [] ->
            cb_context:add_system_error('no_attachment_found', Context);
        [AttachmentId|_] ->
            cb_context:add_resp_headers(
                crossbar_doc:load_attachment(Id, AttachmentId, ?TYPE_CHECK_OPTION(<<"e911_address">>), Context)
               ,[{<<"Content-Disposition">>, <<"attachment; filename=", AttachmentId/binary>>}]
               )
    end;
validate_attachment_binary(Context, _Id, ?HTTP_POST, []) ->
    cb_context:add_validation_error(<<"file">>
                                   ,<<"required">>
                                   ,kz_json:from_list([{<<"message">>, <<"Please provide a file">>}])
                                   ,Context
     );
validate_attachment_binary(Context, Id, ?HTTP_POST, [{_, _}]) ->
    Context1 = crossbar_doc:load(Id, Context, ?TYPE_CHECK_OPTION(<<"e911_address">>)),
    lager:debug("loaded meta for '~s'", [Id]),
    case cb_context:resp_status(Context1) of
        'success' ->
            update_attachment_binary(Context, Id);
        _Status -> Context1
    end;
validate_attachment_binary(Context, _Id, ?HTTP_POST, _Files) ->
    cb_context:add_validation_error(<<"file">>
                                   ,<<"maxItems">>
                                   ,kz_json:from_list([{<<"message">>, <<"Please provide a single file">>}])
                                   ,Context
     ).

-spec update_attachment_binary(cb_context:context(), path_token()) ->
                                 cb_context:context().
-spec update_attachment_binary(cb_context:context(), path_token(), req_files()) ->
                                 cb_context:context().
update_attachment_binary(Context, Id) ->
    update_attachment_binary(crossbar_util:maybe_remove_attachments(Context)
                            ,Id
                            ,cb_context:req_files(Context)
                            ).

update_attachment_binary(Context, _Id, []) -> Context;
update_attachment_binary(Context, Id, [{Filename, FileObj}|Files]) ->
    CT = kz_json:get_value([<<"headers">>, <<"content_type">>], FileObj),
    lager:debug("file content type: ~s", [CT]),
    update_attachment_binary(crossbar_doc:save_attachment(Id
                                                         ,cb_modules_util:attachment_name(Filename, CT)
                                                         ,kz_json:get_value(<<"contents">>, FileObj)
                                                         ,Context
                                                         ,[{'content_type', CT} | ?TYPE_CHECK_OPTION_ANY]
                                                         )
                            ,Id
                            ,Files
                            ).

-spec maybe_valid_relationship(cb_context:context()) -> boolean().
maybe_valid_relationship(Context) ->
    AccountId = cb_context:account_id(Context),
    AuthAccountId = cb_context:auth_account_id(Context),
    zz_util:validate_relationship(AccountId, AuthAccountId) orelse cb_context:is_superduper_admin(AuthAccountId).

-spec delete_e911_doc(cb_context:context(), kz_term:ne_binary()) -> cb_context:context().
delete_e911_doc(Context0, Id) ->
    Context = crossbar_doc:load(Id, Context0, ?TYPE_CHECK_OPTION(<<"e911_address">>)),
    case cb_context:resp_status(Context) of
        'success' ->
            NewDoc = kz_json:set_value(<<"deleted_by_user">>, 'true', cb_context:doc(Context)),
            crossbar_doc:save(cb_context:set_doc(Context, NewDoc), ?TYPE_CHECK_OPTION(<<"e911_address">>));
        _Status ->
            Context
   end.

confirm_address(Context0, Id, ?HTTP_POST) ->
    ReqData = cb_context:req_data(Context0),
    Context = crossbar_doc:load(Id, Context0, ?TYPE_CHECK_OPTION(<<"e911_address">>)),
    Doc = cb_context:doc(Context),
    NewDoc = kz_json:set_value(<<"pvt_address_confirmed">>, kz_json:get_value(<<"address_confirmed">>, ReqData), Doc),
    crossbar_doc:save(cb_context:set_doc(Context, NewDoc), ?TYPE_CHECK_OPTION(<<"e911_address">>));
confirm_address(Context, _Id, _) ->
    Context.
