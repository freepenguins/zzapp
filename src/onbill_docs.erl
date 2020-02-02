-module(onbill_docs).

-export([generate_docs/2
        ,generate_docs/3
        ,generate_docs/4
        ,save_pdf/6
        ,per_minute_reports/2
        ,per_minute_reports/3
        ,create_modb_doc/3
        ,create_modb_doc/7
        ,add_onbill_pdf/3
        ]).

-include("onbill.hrl").

-spec generate_docs(kz_term:ne_binary(), integer()) -> ok.
generate_docs(AccountId, Timestamp) ->
    {{Year, Month, Day}, _} = calendar:gregorian_seconds_to_datetime(Timestamp),
    generate_docs(AccountId, Year, Month, Day).

-spec generate_docs(kz_term:ne_binary(), kz_time:year(), kz_time:month()) -> ok.
generate_docs(AccountId, Year, Month) ->
    generate_docs(AccountId, Year, Month, 1).

-spec generate_docs(kz_term:ne_binary(), kz_time:year(), kz_time:month(), kz_time:day()) -> ok.
generate_docs(AccountId, Year, Month, Day) ->
    Carriers = zz_util:account_carriers_list(AccountId),
    _ = [generate_docs(AccountId, Year, Month, Day, Carrier) || Carrier <- Carriers],
    maybe_aggregate_invoice(AccountId, Year, Month, Day, Carriers).

generate_docs(AccountId, Year, Month, Day, Carrier) ->
    VatUpdatedFeesList = onbill_fees:shape_fees(AccountId, Year, Month, Day, Carrier),
    Totals = lists:foldl(fun(X, {TN_Acc, VAT_Acc, TB_Acc}) ->
                                                        {TN_Acc + props:get_value(<<"discounted_cost_netto">>, X)
                                                         ,VAT_Acc + props:get_value(<<"vat_line_discounted_total">>, X)
                                                         ,TB_Acc + props:get_value(<<"discounted_cost_brutto">>, X)
                                                        }
                                                      end
                                                      ,{0,0,0}
                                                      ,VatUpdatedFeesList
                                                     ),
    generate_docs(AccountId, Year, Month, Day, Carrier, VatUpdatedFeesList, Totals).

generate_docs(_, _, _, _, Carrier, _, {TotalNetto, TotalVAT, TotalBrutto})
    when TotalNetto =< 0.0
    orelse TotalBrutto =< 0.0
->
    lager:debug("Skipping generate_docs for ~p because of zero usage: TotalNetto: ~p, TotalVAT: ~p, TotalBrutto: ~p"
               ,[Carrier, TotalNetto, TotalVAT, TotalBrutto]);
generate_docs(AccountId, Year, Month, Day, Carrier, VatUpdatedFeesList, {TotalNetto, TotalVAT, TotalBrutto}) ->
    {SYear, SMonth, SDay} = zz_util:period_start_date(AccountId, Year, Month, Day),
    {EYear, EMonth, EDay} = zz_util:period_end_date(AccountId, Year, Month, Day),
    CarrierDoc = zz_util:carrier_doc(Carrier, AccountId),
    ResellerVars = zz_util:reseller_vars(AccountId),
    {TotalBruttoDiv, TotalBruttoRem} = total_to_words(TotalBrutto),
    {TotalVatDiv, TotalVatRem} = total_to_words(TotalVAT),
    AccountOnbillDoc = zz_util:account_vars(AccountId),
    Vars = [{<<"monthly_fees">>, VatUpdatedFeesList}
           ,{<<"account_addr">>, address_to_line(AccountOnbillDoc)}
           ,{<<"total_netto">>, zz_util:price_round(TotalNetto)}
           ,{<<"total_vat">>, zz_util:price_round(TotalVAT)}
           ,{<<"total_vat_div">>, TotalVatDiv}
           ,{<<"total_vat_rem">>, TotalVatRem}
           ,{<<"total_brutto">>, zz_util:price_round(TotalBrutto)}
           ,{<<"total_brutto_div">>, TotalBruttoDiv}
           ,{<<"total_brutto_rem">>, TotalBruttoRem}
           ,{<<"vat_rate">>, kz_json:get_value(<<"vat_rate">>, ResellerVars, 0.0)}
           ,{<<"currency_short">>, kz_json:get_value(<<"currency_short">>, ResellerVars)}
           ,{<<"currency_sign">>, kz_json:get_value(<<"currency_sign">>, ResellerVars)}
           ,{<<"agrm_num">>, kz_json:get_value([<<"agrm">>, Carrier, <<"number">>], AccountOnbillDoc)}
           ,{<<"agrm_date">>, kz_json:get_value([<<"agrm">>, Carrier, <<"date">>], AccountOnbillDoc)}
           ,{<<"start_date">>, ?DATE_STRING(SYear, SMonth, SDay)}
           ,{<<"end_date">>, ?DATE_STRING(EYear, EMonth, EDay)}
           ,{<<"doc_date">>, ?DATE_STRING(EYear, EMonth, EDay)}
           ,{<<"doc_date_json">>, zz_util:date_json(EYear, EMonth, EDay)}
           ,{<<"period_start">>, zz_util:date_json(SYear, SMonth, SDay)}
           ,{<<"period_end">>, zz_util:date_json(EYear, EMonth, EDay)}
           ,{<<"reseller_vars">>, pack_vars(ResellerVars)}
           ,{<<"carrier_vars">>, pack_vars(CarrierDoc)}
           ,{<<"account_vars">>, pack_vars(AccountOnbillDoc)}
           ], 
    %%  delete next two lines after adopting templates to carrier_vars and account_vars
    %%       ++ [{Key, kz_json:get_value(Key, CarrierDoc)} || Key <- kz_json:get_keys(CarrierDoc), filter_vars(Key)]
    %%       ++ [{Key, kz_json:get_value(Key, AccountOnbillDoc)} || Key <- kz_json:get_keys(AccountOnbillDoc), filter_vars(Key)],
    _ = [save_pdf(Vars
                    ++ [{<<"onbill_doc_type">>, DocType}]
                    ++ [{<<"doc_number">>, onbill_docs_numbering:get_binary_number(AccountId, Carrier, DocType, Year, Month)}]
                 ,DocType
                 ,Carrier
                 ,AccountId
                 ,Year
                 ,Month
                 )
         || DocType <- kz_json:get_value(<<"onbill_doc_types">>, CarrierDoc)
        ].

get_template(TemplateId, Carrier, AccountId) ->
    ResellerId = zz_util:find_reseller_id(AccountId),
    CountryOfResidence = zz_util:reseller_country_of_residence(AccountId),
    DbName = kz_util:format_account_id(ResellerId,'encoded'),
    case kz_datamgr:fetch_attachment(DbName, ?CARRIER_DOC(Carrier), <<(?DOC_NAME_FORMAT(Carrier, TemplateId))/binary, ".tpl">>) of
        {'ok', Template} -> Template;
        {error, not_found} ->
            Template = default_template(TemplateId, Carrier, CountryOfResidence),
            case kz_datamgr:open_doc(DbName, ?CARRIER_DOC(Carrier)) of
                {'ok', _} ->
                    'ok';
                {'error', 'not_found'} ->
                    NewDoc = kz_json:set_values([{<<"_id">>, ?CARRIER_DOC(Carrier)}
                                                 ,{<<"called_number_regex">>,<<"^\\d*$">>}
                                                 ,{<<"callee_number_regex">>,<<"^\\d*$">>}
                                                ]
                                                ,kz_json:new()),
                    kz_datamgr:ensure_saved(DbName, NewDoc)
            end,
            kz_datamgr:put_attachment(DbName
                                     ,?CARRIER_DOC(Carrier)
                                     ,<<(?DOC_NAME_FORMAT(Carrier, TemplateId))/binary, ".tpl">>
                                     ,Template
                                     ,[{'content_type', <<"text/html">>}]
                                    ),
            Template
    end.

default_template(TemplateId, Carrier, CountryOfResidence) ->
    CarrierFilePath = <<"applications/onbill/priv/templates/"
                       ,CountryOfResidence/binary
                       ,"/"
                       ,(?DOC_NAME_FORMAT(Carrier, TemplateId))/binary
                       ,".tpl">>,
    case file:read_file(CarrierFilePath) of
        {'ok', CarrierData} -> CarrierData;
        _ ->
            FilePath = <<"applications/"
                        ,?ZZ_APP_NAME/binary
                        ,"/priv/templates/"
                        ,CountryOfResidence/binary
                        ,"/"
                        ,TemplateId/binary
                        ,".tpl">>,
            lager:debug("default_template FilePath: ~p",[FilePath]),
            {'ok', Data} = file:read_file(FilePath),
            lager:debug("default_template Data: ~p",[Data]),
            Data
    end.

prepare_tpl(Vars, TemplateId, Carrier, AccountId) ->
  lager:debug("prepare_tpl Vars: ~p",[Vars]),
  lager:debug("prepare_tpl TemplateId: ~p",[TemplateId]),
  lager:debug("prepare_tpl Carrier: ~p",[Carrier]),
  lager:debug("prepare_tpl AccountId: ~p",[AccountId]),
  lager:debug("prepare_tpl DOC_NAME_FORMAT(Carrier, TemplateId): ~p",[?DOC_NAME_FORMAT(Carrier, TemplateId)]),
  lager:debug("prepare_tpl get_template(TemplateId, Carrier, AccountId): ~p",[get_template(TemplateId, Carrier, AccountId)]),
    ErlyMod = erlang:binary_to_atom(?DOC_NAME_FORMAT(Carrier, TemplateId), 'latin1'),
  lager:debug("prepare_tpl ErlyMod: ~p",[ErlyMod]),
    try erlydtl:compile_template(get_template(TemplateId, Carrier, AccountId), ErlyMod
                                ,[{libraries, [{onbill_dtl, onbill_dtl_lib}]}
                                 ,{'out_dir', 'false'}
                                 ,'return'
                                 ]
                                )
    of
        {ok, ErlyMod} -> render_tpl(ErlyMod, Vars);
        {ok, ErlyMod,[]} -> render_tpl(ErlyMod, Vars); 
        {'ok', ErlyMod, Warnings} ->
            lager:debug("compiling template ~p produced warnings: ~p", [TemplateId, Warnings]),
            render_tpl(ErlyMod, Vars)
    catch
        _E:_R ->
            lager:debug("exception compiling ~p template: ~s: ~p", [TemplateId, _E, _R]),
            <<"Error template compilation">>
    end.

render_tpl(ErlyMod, Vars) ->
    {'ok', IoList} = ErlyMod:render(Vars),
    code:purge(ErlyMod),
    code:delete(ErlyMod),
    erlang:iolist_to_binary(IoList).

create_pdf(Vars, TemplateId, Carrier, AccountId) ->
    Rand = kz_binary:rand_hex(5),
    Prefix = <<AccountId/binary, "-", (?DOC_NAME_FORMAT(Carrier, TemplateId))/binary, "-", Rand/binary>>,
    HTMLFile = filename:join([<<"/tmp">>, <<Prefix/binary, ".html">>]),
    PDFFile = filename:join([<<"/tmp">>, <<Prefix/binary, ".pdf">>]),
    HTMLTpl = prepare_tpl(Vars, TemplateId, Carrier, AccountId),
    file:write_file(HTMLFile, HTMLTpl),
    WkhtmlOptions = kz_json:get_value([?WKHTMLTOPDF, <<(?DOC_NAME_FORMAT(Carrier, TemplateId))/binary>>, <<"options">>]
                                     ,props:get_value(<<"carrier_vars">>,Vars, kz_json:new())
                                     ,<<>>),
    WkhtmlHeaderOption =
        case kz_json:get_value([?WKHTMLTOPDF, <<(?DOC_NAME_FORMAT(Carrier, TemplateId))/binary>>, <<"header_html">>]
                              ,props:get_value(<<"carrier_vars">>,Vars, kz_json:new())
                              ,'false')
        of
            'true' ->
                HTMLHeaderFile = filename:join([<<"/tmp">>, <<Prefix/binary, "_header.html">>]),
                HTMLHeaderTpl = prepare_tpl(Vars, <<"calls_report_header">>, Carrier, AccountId),
                file:write_file(HTMLHeaderFile, HTMLHeaderTpl),
                <<" --load-error-handling ignore --header-html ", HTMLHeaderFile/binary>>;
            _ -> <<>>
        end,        
    WkhtmlFooterOption =
        case kz_json:get_value([?WKHTMLTOPDF, <<(?DOC_NAME_FORMAT(Carrier, TemplateId))/binary>>, <<"footer_html">>]
                              ,props:get_value(<<"carrier_vars">>,Vars, kz_json:new())
                              ,'false')
        of
            'true' ->
                HTMLFooterFile = filename:join([<<"/tmp">>, <<Prefix/binary, "_footer.html">>]),
                HTMLFooterTpl = prepare_tpl(Vars, <<"calls_report_footer">>, Carrier, AccountId),
                file:write_file(HTMLFooterFile, HTMLFooterTpl),
                <<" --load-error-handling ignore --footer-html ", HTMLFooterFile/binary>>;
            _ -> <<>>
        end,        
    Cmd = <<?HTML_TO_PDF(<<WkhtmlOptions/binary, WkhtmlHeaderOption/binary, WkhtmlFooterOption/binary>>)/binary
           ," "
           ,HTMLFile/binary
           ," "
           ,PDFFile/binary>>,
    case os:cmd(kz_term:to_list(Cmd)) of
        [] ->
            file:read_file(PDFFile);
        "\n" ->
            file:read_file(PDFFile);
        _R ->
            lager:error("failed to exec ~s: ~s", [Cmd, _R]),
            {'error', _R}
    end.

-spec save_pdf(kz_term:ne_binary(), kz_term:ne_binary(), kz_term:proplist(), kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary()) -> ok.
save_pdf(DocId, DbName, Vars, TemplateId, Carrier, AccountId) when is_binary(DocId) ->
    {'ok', PDF_Data} = create_pdf(Vars, TemplateId, Carrier, AccountId),
    NewDoc = case kz_datamgr:open_doc(DbName, DocId) of
        {ok, Doc} ->
            kz_json:set_values(Vars, Doc);
        {'error', 'not_found'} ->
            kz_json:set_values(Vars ++ [{<<"_id">>, DocId}
                                       ,{<<"pvt_type">>, ?ONBILL_DOC}
                                       ]
                              ,kz_json:new()) 
    end,
    kz_datamgr:ensure_saved(DbName, NewDoc),
    Result = kz_datamgr:put_attachment(DbName
                                      ,DocId
                                      ,<<(?DOC_NAME_FORMAT(Carrier, TemplateId))/binary, ".pdf">>
                                      ,PDF_Data
                                      ,[{'content_type', <<"application/pdf">>}]
                                      ),
    kz_datamgr:flush_cache_doc(DbName, NewDoc),
    Result;

save_pdf(Vars, TemplateId, Carrier, AccountId, Year, Month) ->
    DocId = case props:get_value(<<"doc_number">>, Vars) of
                'undefined' ->
                    ?ONBILL_DOC_ID_FORMAT(Year, Month, Carrier, TemplateId);
                DocNumber ->
                    ?ONBILL_DOC_ID_FORMAT(Year, Month, DocNumber, Carrier, TemplateId)
            end,
    save_pdf(DocId, Vars, TemplateId, Carrier, AccountId, Year, Month).

save_pdf(DocId, Vars, TemplateId, Carrier, AccountId, Year, Month) ->
    Modb = kazoo_modb:get_modb(AccountId, Year, Month),
    save_pdf(DocId, Modb, Vars, TemplateId, Carrier, AccountId).

total_to_words(Total) ->
    [TotalDiv, TotalRem] = binary:split(float_to_binary(kz_term:to_float(Total),[{decimals,2}]), <<".">>),
    {unicode:characters_to_binary(amount_into_words:render(TotalDiv), unicode, utf8)
    ,unicode:characters_to_binary(amount_into_words:render(TotalRem), unicode, utf8)
    }.

pack_vars(Doc) ->
    kz_json:set_values([{Key, kz_json:get_value(Key, Doc)}
                        || Key <- kz_json:get_keys(Doc), filter_vars(Key)]
                      ,kz_json:new()).

filter_vars(<<"_", _/binary>>) -> 'false';
filter_vars(<<_/binary>>) -> 'true'.

address_to_line(JObj) ->
    BillingAddrLinnes = kz_json:get_value(<<"billing_address">>, JObj, kz_json:new()),
    {Keys, _} = kz_json:get_values(BillingAddrLinnes),
    address_join([Line || Line <- Keys, Line =/= <<>>], <<", ">>).

address_join([], _Sep) ->
  <<>>;
address_join([Part], _Sep) ->
  Part;
address_join([Head|Tail], Sep) ->
  lists:foldl(fun (Value, Acc) -> <<Acc/binary, Sep/binary, Value/binary>> end, Head, Tail).

maybe_aggregate_invoice(AccountId, Year, Month, Day, Carriers) ->
    ResellerVars = zz_util:reseller_vars(AccountId),
    case kz_json:get_value(<<"postpay_aggregate_invoice">>, ResellerVars) of
        'true' ->
            case zz_util:maybe_allow_postpay(AccountId) of
                'true' ->
                    aggregate_invoice(AccountId, Year, Month, Day, Carriers);
                _ ->
                    maybe_account_aggregate_invoice(AccountId, Year, Month, Day, Carriers)
            end;
        _ ->
            maybe_account_aggregate_invoice(AccountId, Year, Month, Day, Carriers)
    end.

maybe_account_aggregate_invoice(AccountId, Year, Month, Day, Carriers) ->
    AccountOnbillDoc = zz_util:account_vars(AccountId),
    case kz_json:get_value(<<"aggregate_invoice">>, AccountOnbillDoc) of
        'true' -> aggregate_invoice(AccountId, Year, Month, Day, Carriers);
        _ ->
          %  %% here is a dirty hack just for old to new billing transition
          %  OnNetDocNumber = kz_json:get_binary_value([<<"agrm">>,<<"onnet">>,<<"number">>], AccountOnbillDoc, <<>>),
          %  case re:run(OnNetDocNumber, <<"PRE">>) of
          %      'nomatch' -> aggregate_invoice(AccountId, Year, Month, Day, Carriers);
          %      _ -> 'ok'
          %  end
            'ok'
    end.

aggregate_invoice(AccountId, Year, Month, Day, Carriers) ->
    DocType = <<"aggregated_invoice">>,
    {SYear, SMonth, SDay} = zz_util:period_start_date(AccountId, Year, Month, Day),
    {EYear, EMonth, EDay} = zz_util:period_end_date(AccountId, Year, Month, Day),
    ResellerVars = zz_util:reseller_vars(AccountId),
    MainCarrier = zz_util:get_main_carrier(Carriers, AccountId),
    MainCarrierDoc = zz_util:carrier_doc(MainCarrier, AccountId),
    AccountOnbillDoc = zz_util:account_vars(AccountId),
    {AggregatedVars, TotalNetto, TotalVAT, TotalBrutto} =
        aggregate_data(AccountId, {SYear, SMonth, SDay}, {EYear, EMonth, EDay}),
    case TotalNetto > 0 of
        'true' ->
            {TotalBruttoDiv, TotalBruttoRem} = total_to_words(TotalBrutto),
            {TotalVatDiv, TotalVatRem} = total_to_words(TotalVAT),
            Vars = [{<<"aggregated_vars">>, AggregatedVars}
                   ,{<<"start_date">>, ?DATE_STRING(SYear, SMonth, SDay)}
                   ,{<<"end_date">>, ?DATE_STRING(EYear, EMonth, EDay)}
                   ,{<<"doc_date">>, ?DATE_STRING(EYear, EMonth, EDay)}
                   ,{<<"doc_date_json">>, zz_util:date_json(EYear, EMonth, EDay)}
                   ,{<<"period_start">>, zz_util:date_json(SYear, SMonth, SDay)}
                   ,{<<"period_end">>, zz_util:date_json(EYear, EMonth, EDay)}
                   ,{<<"total_netto">>, zz_util:price_round(TotalNetto)}
                   ,{<<"total_vat">>, zz_util:price_round(TotalVAT)}
                   ,{<<"total_brutto">>, zz_util:price_round(TotalBrutto)}
                   ,{<<"vat_rate">>, kz_json:get_value(<<"vat_rate">>, ResellerVars, 0.0)}
                   ,{<<"total_vat_div">>, TotalVatDiv}
                   ,{<<"total_vat_rem">>, TotalVatRem}
                   ,{<<"total_brutto_div">>, TotalBruttoDiv}
                   ,{<<"total_brutto_rem">>, TotalBruttoRem}
                   ,{<<"onbill_doc_type">>, DocType}
                   ,{<<"doc_number">>, onbill_docs_numbering:get_binary_number(AccountId, MainCarrier, DocType, Year, Month)}
                   ,{<<"reseller_vars">>, pack_vars(ResellerVars)}
                   ,{<<"carrier_vars">>, pack_vars(MainCarrierDoc)}
                   ,{<<"account_vars">>, pack_vars(AccountOnbillDoc)}
                   ],
            save_pdf(Vars, DocType, MainCarrier, AccountId, Year, Month);
        'false' ->
            'ok'
    end.

aggregate_data(AccountId, {SYear, SMonth, _}, {SYear, SMonth, _}) ->
    Modb = kazoo_modb:get_modb(AccountId, SYear, SMonth),
    _ = zz_util:maybe_add_design_doc(Modb, <<"onbills">>),
    case kz_datamgr:get_results(Modb, ?CB_LIST, ['include_docs']) of
        {'error', 'not_found'} ->
            lager:warning("unable to process aggregate_data calculaton for Modb: ~s, skipping", [Modb]),
            {[], 0, 0, 0};
        {'ok', JObjs } ->
            lists:foldl(fun(JObj, Acc) ->
                           aggregate_data(kz_json:get_value(<<"value">>, JObj, kz_json:new()), Acc)
                        end
                       ,{[], 0, 0, 0}
                       ,JObjs)
    end;
aggregate_data(AccountId, {_SYear, _SMonth, _SDay}, {_EYear, _EMonth, _EDay}) ->
    lager:warning("Invoice aggregation not implemented for cross month billing beriods yet. AccounId: ~p", [AccountId]),
    {[], 0, 0, 0}.

aggregate_data(InvoiceDoc, {AggrVars, TotalNetto, TotalVAT, TotalBrutto}) ->
    case kz_json:get_value(<<"type">>, InvoiceDoc) of
        <<"invoice">> ->
            {[[{Key, kz_json:get_value(Key, InvoiceDoc)} || Key <- kz_json:get_keys(InvoiceDoc), filter_vars(Key)]] ++ AggrVars
            ,kz_json:get_value(<<"total_netto">>, InvoiceDoc) + TotalNetto
            ,kz_json:get_value(<<"total_vat">>, InvoiceDoc) + TotalVAT
            ,kz_json:get_value(<<"total_brutto">>, InvoiceDoc) + TotalBrutto
            };
        _ ->
            {AggrVars, TotalNetto, TotalVAT, TotalBrutto} 
    end.
    
-spec per_minute_reports(kz_term:ne_binary(), integer()) -> 'ok'.
-spec per_minute_reports(kz_term:ne_binary(), integer(), integer()) -> 'ok'.
-spec per_minute_reports(kz_term:ne_binary(), integer(), integer(), integer()) -> 'ok'.
per_minute_reports(AccountId, Timestamp) ->
    {{Year, Month, Day}, _} = calendar:gregorian_seconds_to_datetime(Timestamp),
    per_minute_reports(AccountId, Year, Month, Day).

per_minute_reports(AccountId, Year, Month) ->
    per_minute_reports(AccountId, Year, Month, 1).

per_minute_reports(AccountId, Year, Month, Day) ->
    Carriers = zz_util:account_carriers_list(AccountId),
    _ = [maybe_per_minute_report(AccountId, Year, Month, Day, Carrier) || Carrier <- Carriers].

maybe_per_minute_report(AccountId, Year, Month, Day, Carrier) ->
    {CallsJObjs, CallsTotalSec, CallsTotalSumm} = onbill_fees:per_minute_calls(AccountId, Year, Month, Day, Carrier),
    per_minute_report(AccountId, Year, Month, Day, Carrier, CallsJObjs, CallsTotalSec, CallsTotalSumm).

per_minute_report(AccountId, Year, Month, Day, Carrier, CallsJObjs, CallsTotalSec, CallsTotalSumm) when CallsTotalSumm > 0.0 ->
    DocType = <<"calls_report">>,
    {SYear, SMonth, SDay} = zz_util:period_start_date(AccountId, Year, Month, Day),
    {EYear, EMonth, EDay} = zz_util:period_end_date(AccountId, Year, Month, Day),
    ResellerVars = zz_util:reseller_vars(AccountId),
    CarrierDoc = zz_util:carrier_doc(Carrier, AccountId),
    AccountOnbillDoc = zz_util:account_vars(AccountId),
    {CallsJObjs, CallsTotalSec, CallsTotalSumm} = onbill_fees:per_minute_calls(AccountId, Year, Month, 1, Carrier),
    Vars = [{<<"per_minute_calls">>, CallsJObjs}
           ,{<<"start_date">>, ?DATE_STRING(SYear, SMonth, SDay)}
           ,{<<"end_date">>, ?DATE_STRING(EYear, EMonth, EDay)}
           ,{<<"doc_date">>, ?DATE_STRING(EYear, EMonth, EDay)}
           ,{<<"doc_date_json">>, zz_util:date_json(EYear, EMonth, EDay)}
           ,{<<"period_start">>, zz_util:date_json(SYear, SMonth, SDay)}
           ,{<<"period_end">>, zz_util:date_json(EYear, EMonth, EDay)}
           ,{<<"agrm_num">>, kz_json:get_value([<<"agrm">>, Carrier, <<"number">>], AccountOnbillDoc)}
           ,{<<"agrm_date">>, kz_json:get_value([<<"agrm">>, Carrier, <<"date">>], AccountOnbillDoc)}
           ,{<<"onbill_doc_type">>, DocType}
           ,{<<"reseller_vars">>, pack_vars(ResellerVars)}
           ,{<<"carrier_vars">>, pack_vars(CarrierDoc)}
           ,{<<"account_vars">>, pack_vars(AccountOnbillDoc)}
           ]
           ++ onbill_fees:vatify_amount(<<"total">>, CallsTotalSumm, ResellerVars),
    save_pdf(Vars, DocType, Carrier, AccountId, Year, Month);
per_minute_report(_, _, _, _, _, _, _, _) ->
    'ok'.

-spec create_modb_doc(number(), kz_term:ne_binary(), kz_term:ne_binary()) -> any().
-spec create_modb_doc(number(), kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary(), kz_time:year(), kz_time:month(), kz_time:day()) -> any().
create_modb_doc(Amount, AccountId, DocVars) ->
    Carriers = zz_util:account_carriers_list(AccountId),
    MainCarrier = zz_util:get_main_carrier(Carriers, AccountId),
    DocType = kz_json:get_value(<<"document_type">>, DocVars),
    DocNumber = onbill_docs_numbering:get_new_binary_number(AccountId, MainCarrier, DocType),
    {Year, Month, Day} = erlang:date(),
    create_modb_doc(Amount, AccountId, DocVars, DocNumber, Year, Month, Day).

create_modb_doc(Amount, AccountId, DocVars, DocNumber, Year, Month, Day) ->
    DocType = kz_json:get_value(<<"document_type">>, DocVars),
    {SYear, SMonth, SDay} = zz_util:period_start_date(AccountId, Year, Month, Day),
    {EYear, EMonth, EDay} = zz_util:period_end_date(AccountId, Year, Month, Day),
    ResellerVars = zz_util:reseller_vars(AccountId),
    Carriers = zz_util:account_carriers_list(AccountId),
    MainCarrier = zz_util:get_main_carrier(Carriers, AccountId),
    MainCarrierDoc = zz_util:carrier_doc(MainCarrier, AccountId),
    AccountOnbillDoc = zz_util:account_vars(AccountId),
    VatifiedAmount = onbill_fees:vatify_amount(<<"total">>, kz_term:to_float(Amount), ResellerVars),
    {TotalBruttoDiv, TotalBruttoRem} = total_to_words(props:get_value(<<"total_brutto">>, VatifiedAmount)),
    {TotalVatDiv, TotalVatRem} = total_to_words(props:get_value(<<"total_vat">>, VatifiedAmount)),
    Vars = [{<<"doc_date_json">>, zz_util:date_json(Year, Month, Day)}
           ,{<<"doc_date">>, ?DATE_STRING(Year, Month, Day)}
           ,{<<"vat_rate">>, kz_json:get_value(<<"vat_rate">>, ResellerVars, 0.0)}
           ,{<<"total_vat_div">>, TotalVatDiv}
           ,{<<"total_vat_rem">>, TotalVatRem}
           ,{<<"total_brutto_div">>, TotalBruttoDiv}
           ,{<<"total_brutto_rem">>, TotalBruttoRem}
           ,{<<"document_vars">>, DocVars}
           ,{<<"onbill_doc_type">>, DocType}
           ,{<<"doc_number">>, DocNumber}
           ,{<<"period_start">>, zz_util:date_json(SYear, SMonth, SDay)}
           ,{<<"period_end">>, zz_util:date_json(EYear, EMonth, EDay)}
           ,{<<"currency_short">>, kz_json:get_value(<<"currency_short">>, ResellerVars)}
           ,{<<"currency_sign">>, kz_json:get_value(<<"currency_sign">>, ResellerVars)}
           ,{<<"reseller_vars">>, pack_vars(ResellerVars)}
           ,{<<"carrier_vars">>, pack_vars(MainCarrierDoc)}
           ,{<<"account_vars">>, pack_vars(AccountOnbillDoc)}
           ]
           ++ VatifiedAmount,
    save_pdf(Vars, DocType, MainCarrier, AccountId, Year, Month).

-spec add_onbill_pdf(kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary()) -> any().
add_onbill_pdf(TemplateId, Carrier, AccountId) ->
    DbName = kz_util:format_account_id(AccountId,'encoded'),
    ResellerVars = zz_util:reseller_vars(AccountId),
    AccountOnbillDoc = zz_util:account_vars(AccountId),
    CarrierDoc = zz_util:carrier_doc(Carrier, AccountId),
    Vars = [{<<"reseller_vars">>, pack_vars(ResellerVars)}
           ,{<<"account_vars">>, pack_vars(AccountOnbillDoc)}
           ,{<<"carrier_vars">>, pack_vars(CarrierDoc)}
           ,{<<"agrm">>, kz_json:get_value([<<"agrm">>, Carrier], AccountOnbillDoc)}
           ],
    {'ok', PDF_Data} = create_pdf(Vars, TemplateId, Carrier, AccountId),
    maybe_add_pdf_info(TemplateId, Carrier, DbName),
    kz_datamgr:put_attachment(DbName
                             ,?ONBILL_DOC
                             ,<<(?DOC_NAME_FORMAT(Carrier, TemplateId))/binary, ".pdf">>
                             ,PDF_Data
                             ,[{'content_type', <<"application/pdf">>}]
                             ).

maybe_add_pdf_info(<<"dog_", _/binary>> = TemplateId, Carrier, DbName) ->
    case kz_datamgr:open_doc(DbName, ?ONBILL_DOC) of
        {ok, Doc} ->
            NewDoc = kz_json:set_value([<<"agrm">>, Carrier, <<"att_name">>]
                                      ,<<(?DOC_NAME_FORMAT(Carrier, TemplateId))/binary, ".pdf">>
                                      ,Doc
                                      ),
            kz_datamgr:ensure_saved(DbName, NewDoc),
            timer:sleep(1000);
        {'error', 'not_found'} ->
            'ok'
    end;
maybe_add_pdf_info(_TemplateId, _Carrier, _AccountId) ->
    'ok'.
