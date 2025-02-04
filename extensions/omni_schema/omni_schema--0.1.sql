create table languages
(
    id             integer primary key generated always as identity,
    file_extension text not null unique,
    language       name        not null,
    extension      name
);

insert
into
    languages (file_extension, language, extension)
values
    ('sql', 'sql', null),
    ('pl', 'plperlu', 'plperlu'),
    ('trusted.pl', 'plperl', 'plperl'),
    ('py', 'plpython3u', 'plpython3u'),
    ('tcl', 'pltclu', 'pltclu'),
    ('trusted.tcl', 'pltcl', 'pltcl'),
    ('rs', 'plrust', 'plrust');

select pg_catalog.pg_extension_config_dump('languages', '');

create table procs as
    select *
    from
        pg_proc
    limit 0;

create table policies as
    select *
    from
        pg_policy
    limit 0;

create table class as
    select *
    from
        pg_class
    limit 0;

create function load_from_fs(fs anyelement, path text default '') returns setof text
    language plpgsql
as
$$
declare
    rec record;
begin
    -- Procs
    if not exists(select
                  from
                      pg_class
                  where
                      relname = '_omni_schema_pg_proc' and
                      relkind = 'r' and
                      relpersistence = 't') then
        create temporary table if not exists _omni_schema_pg_proc on commit drop as
            select * from pg_proc;
    end if;
    for rec in select * from omni_schema.procs
        loop
            execute format('drop function if exists %s', rec.oid::regprocedure);
        end loop;
    delete from omni_schema.procs;
    -- Policies
    if not exists(select
                  from
                      pg_class
                  where
                      relname = '_omni_schema_pg_policy' and
                      relkind = 'r' and
                      relpersistence = 't') then
        create temporary table if not exists _omni_schema_pg_policy on commit drop as
            select * from pg_policy;
    end if;
    for rec in select
                   policies.*,
                   pg_class.relname
               from
                   omni_schema.policies
                   inner join pg_class on pg_class.oid = policies.polrelid
        loop
            execute format('drop policy if exists %I on %I', rec.polname, rec.relname);
        end loop;
    delete from omni_schema.policies;
    -- Supported relations
    if not exists(select
                  from
                      pg_class
                  where
                      relname = '_omni_schema_pg_class' and
                      relkind = 'r' and
                      relpersistence = 't') then
        create temporary table if not exists _omni_schema_pg_class on commit drop as
            select * from pg_class;
    end if;
    for rec in select
                   class.*,
                   pg_namespace.nspname
               from
                   omni_schema.class
                   inner join pg_namespace on pg_namespace.oid = class.relnamespace
        loop
            if rec.relkind = 'v' then
                execute format('drop view if exists %I.%I cascade', rec.nspname, rec.relname);
            end if;
        end loop;
    delete from omni_schema.class;
    -- Execute
    for rec in select
                   case when path = '' then '' else path || '/' end || name      as name,
                   convert_from(omni_vfs.read(fs, path || '/' || name), 'utf-8') as code,
                   language,
                   extension
               from
                   omni_vfs.list_recursively(fs, path, max => 10000) files
                   join omni_schema.languages on files.name like concat('%', languages.file_extension)
        loop
            if rec.language = 'sql' then
                execute rec.code;
            else
                -- Check if the language is available
                if not exists(select from pg_extension where extname = rec.extension) then
                    raise notice 'Extension % required for language % (required for %) is not installed', rec.extension, rec.language, rec.name;
                    -- Don't include it in the list of loaded files
                    continue;
                else
                    -- Prepare and execute the SQL create function construct
                    declare
                        sql_snippet text;
                    begin
                        if rec.code ~ 'SQL\[\[.*\]\]' then
                            sql_snippet := format('%s language %I as %L',
                                                  substring(rec.code from 'SQL\[\[(.*?)\]\]'), rec.language,
                                                  rec.code);
                            execute sql_snippet;
                        end if;
                    end;
                end if;
            end if;
            return next rec.name;
        end loop;
    -- New procs
    insert
    into
        omni_schema.procs (select * from pg_proc except select * from _omni_schema_pg_proc);
    -- New policies
    insert
    into
        omni_schema.policies (select * from pg_policy except select * from _omni_schema_pg_policy);
    -- New supported relations
    insert
    into
        omni_schema.class (select * from pg_class except select * from _omni_schema_pg_class);
    return;
end ;
$$;

--- Migrations
create table migrations
(
    id         integer primary key generated always as identity,
    name       text      not null,
    migration  text      not null,
    applied_at timestamp not null default now()
);

select pg_catalog.pg_extension_config_dump('migrations', '');
select pg_catalog.pg_extension_config_dump('migrations_id_seq', '');

create function migrate_from_fs(fs anyelement, path text default '') returns setof text
    language plpgsql
as
$$
declare
    rec record;
begin
    for rec in select
                   case when path = '' then '' else path || '/' end || files.name      as name,
                   convert_from(omni_vfs.read(fs, path || '/' || files.name), 'utf-8') as code
               from
                   omni_vfs.list_recursively(fs, path, max => 10000) as files
                   left join omni_schema.migrations
                             on migrations.name = (case when path = '' then '' else path || '/' end || files.name)
               where
                   files.name like '%.sql' and
                   migrations.name is null
               order by files.name asc
        loop
            execute rec.code;
            return next rec.name;
            insert
            into
                omni_schema.migrations (name, migration)
            values (rec.name, rec.code);
        end loop;
    return;
end;
$$;