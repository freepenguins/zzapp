## Documents generating.
### Data
Document consists of data related to:
- account;
- reseller;
- carrier, if applicable (sometimes reseller == carrier);
- services usage.

Services usage being calculated in fees.erl by folding daily_fees docs of particular month. 

Account/Reseller information is located in account's db "onbill" doc and could be retrieved/edited over cb_onbill_customers/reseller crossbar module.

Carriers information is located in onbill_carrier.{ CARRIER_NAME } docs and could be retrieved/edited over cb_onbill_carriers crossbar module

### Templates
Templates are stored in carriers docs.

Templates format - ErlyDTL (Django templates for Erlang).
 
Each carrier can have multiple templates, e.g. invoice, act, calls_report ...

### Documents
Documents generating being processed in docs.erl

Documents are stored in account's modbs.

### Documents numbering - docs_numbering.erl
Currently documents are issued on monthly basis.

So Account can have one document of each type per month.

Ex.: one invoice + one act of work completion + one monthly calls report + etc..

Numbering information is stored in databases separately for each reseller/year.

Numbering could be couninious if all existing documents of particular document type should be numbered sequentially throughout or can be started from #1 every beginning of the year (kz_json:is_true(<<"continious_doc_numbering">>, CarrierDoc))
