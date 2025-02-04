create domain port integer check (value >= 0 and value <= 65535);

create type http_request as
(
    method       omni_http.http_method,
    path         text,
    query_string text,
    body         bytea,
    headers      http_headers
);


create type http_response as
(
    body    bytea,
    status  smallint,
    headers http_headers
);

create type http_proxy as
(
    url           text,
    preserve_host boolean
);

create domain abort as omni_types.unit;

select omni_types.sum_type('http_outcome', 'http_response', 'abort', 'http_proxy');

create function abort() returns http_outcome as
$$
select omni_httpd.http_outcome_from_abort(omni_types.unit())
$$ language sql;

create function http_proxy(url text, preserve_host boolean default true) returns http_outcome as
$$
select omni_httpd.http_outcome_from_http_proxy(row (url, preserve_host))
$$ language sql;


create function http_response(
    body anycompatible default null,
    status int default 200,
    headers http_headers default null
)
    returns http_outcome
as
'MODULE_PATHNAME',
'http_response'
    language c;

create type http_protocol as enum ('http', 'https');

create table listeners
(
    id             integer primary key generated always as identity,
    address        inet          not null default '127.0.0.1',
    port           port          not null default 80,
    effective_port port          not null default 0,
    protocol       http_protocol not null default 'http'
);

create function check_if_role_accessible_to_current_user(role name) returns boolean
as
$$
declare
    username name;
begin
    select current_user into username;
    begin
        execute format('set role %I', role);
    exception
        when others then
            return false;
    end;

    execute format('set role %I', username);
    return true;
end;

$$ language plpgsql;

create table handlers
(
    id        integer primary key generated always as identity,
    query     text not null,
    role_name name not null default current_user check (check_if_role_accessible_to_current_user(role_name))
);

create function handlers_query_validity_trigger() returns trigger
as
'MODULE_PATHNAME',
'handlers_query_validity_trigger' language c;

create constraint trigger handlers_query_validity_trigger
    after insert or update
    on handlers
    deferrable initially deferred
    for each row
execute function handlers_query_validity_trigger();

create table listeners_handlers
(
    listener_id integer not null references listeners (id),
    handler_id  integer not null references handlers (id)
);
create index listeners_handlers_index on listeners_handlers (listener_id, handler_id);

create table configuration_reloads
(
    id          integer primary key generated always as identity,
    happened_at timestamp not null default now()
);

-- Wait for the number of configuration reloads to be `n` or greater
-- Useful for testing
create procedure wait_for_configuration_reloads(n int) as
$$
declare
    c  int = 0;
    n_ int = n;
begin
    loop
        with
            reloads as (select
                            id
                        from
                            omni_httpd.configuration_reloads
                        order by happened_at asc
                        limit n_)
        delete
        from
            omni_httpd.configuration_reloads
        where
            id in (select id from reloads);
        declare
            rowc int;
        begin
            get diagnostics rowc = row_count;
            n_ = n_ - rowc;
            c = c + rowc;
        end;
        exit when c >= n;
    end loop;
end;
$$ language plpgsql;

create function reload_configuration_trigger() returns trigger
as
'MODULE_PATHNAME',
'reload_configuration'
    language c;

create function reload_configuration() returns bool
as
'MODULE_PATHNAME',
'reload_configuration'
    language c;

create trigger listeners_updated
    after update or delete or insert
    on listeners
execute function reload_configuration_trigger();

create trigger handlers_updated
    after update or delete or insert
    on handlers
execute function reload_configuration_trigger();

create trigger listeners_handlers_updated
    after update or delete or insert
    on listeners_handlers
execute function reload_configuration_trigger();

create function cascading_query_reduce(internal, name text, query text) returns internal
as
'MODULE_PATHNAME',
'cascading_query_reduce' language c;

create function cascading_query_final(internal) returns text
as
'MODULE_PATHNAME',
'cascading_query_final' language c;

create aggregate cascading_query (name text, query text) (
    sfunc = cascading_query_reduce,
    finalfunc = cascading_query_final,
    stype = internal
    );

create function default_page(request http_request) returns setof http_outcome as
$$
begin
    return query (with
                      stats as (select * from pg_catalog.pg_stat_database where datname = current_database())
                  select *
                  from
                      omni_httpd.http_response(headers => array [omni_http.http_header('content-type', 'text/html')],
                                               body => $html$
       <!DOCTYPE html>
       <html>
         <head>
           <title>Omnigres</title>
           <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bulma@0.9.4/css/bulma.min.css">
           <meta name="viewport" content="width=device-width, initial-scale=1">
         </head>
         <body class="container">
         <section class="section">
           <div class="container">
             <h1 class="title">Omnigres</h1>

             <div class="tile is-ancestor">
                <div class="tile is-parent is-8">
                 <article class="tile is-child notification is-primary">
                   <div class="content">
                     <p class="title">Welcome!</p>
                     <p class="subtitle">What's next?</p>
                     <div class="content">
                     <p>You can update the query in the <code>omni_httpd.handlers</code> table to change this default page.</p>

                     <p><a href="https://docs.omnigres.org">Documentation</a></p>
                     </div>
                   </div>
                 </article>
               </div>
               <div class="tile is-vertical">
                 <div class="tile">
                   <div class="tile is-parent is-vertical">
                     <article class="tile is-child notification is-grey-lighter">
                       <p class="title">Database</p>
                       <p class="subtitle"><strong>$html$ || current_database() || $html$</strong></p>
                       <p> <strong>Backends</strong>: $html$ || (select numbackends from stats) || $html$ </p>
                       <p> <strong>Transactions committed</strong>: $html$ || (select xact_commit from stats) || $html$ </p>
                     </article>
                   </div>
                 </div>
               </div>
             </div>

             <p class="is-size-7">
               Running on <strong> $html$ || version() || $html$ </strong>
             </p>
           </div>
         </section>
         </body>
       </html>
       $html$));
end;
$$ language plpgsql;

-- Initialization
with
    config as
        (select
             coalesce(not current_setting('omni_httpd.no_init', true)::bool, true)     as should_init,
             coalesce(current_setting('omni_httpd.init_listen_address', true),
                      '0.0.0.0')::inet                                                 as init_listen_address,
             coalesce(current_setting('omni_httpd.init_port', true)::port, 8080::port) as init_port),
    listener as (insert into listeners (address, port) select init_listen_address, init_port from config returning id),
    handler as (insert into handlers (query) values
                                                 ($$
       SELECT omni_httpd.default_page(request.*::omni_httpd.http_request) FROM request $$) returning id)
insert
into
    listeners_handlers (listener_id, handler_id)
select
    listener.id,
    handler.id
from
    config,
    listener,
    handler
where
    config.should_init;