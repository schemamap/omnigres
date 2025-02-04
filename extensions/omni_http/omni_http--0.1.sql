create type http_method as enum ('GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'CONNECT', 'OPTIONS', 'TRACE', 'PATCH');

create type http_header as
(
    name  text,
    value text
);

create domain http_headers as http_header[];

create function http_header(name text, value text) returns http_header as
$$
select row (name, value) as result;
$$
    language sql;

create function http_header_get_all(headers http_headers, header_name text) returns setof text
    strict immutable
as
$$
select
    header.value
from
    unnest(headers) header(name, value)
where
    lower(header.name) = lower(header_name)
$$
    language sql;

create function http_header_get(headers http_headers, name text) returns text
    strict immutable
as
$$
select
    http_header_get_all
from
    http_header_get_all(headers, name)
limit 1
$$
    set search_path to '@extschema@'
    language sql;

create type http_request as
(
    method       http_method,
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