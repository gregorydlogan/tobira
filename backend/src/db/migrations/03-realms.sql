-- Creates the realms table, inserts the always-present root realm and adds
-- useful realm-related functions.

create type realm_order as enum ('by_index', 'alphabetic:asc', 'alphabetic:desc');

select prepare_randomized_ids('realm');

create table realms (
    id bigint primary key default randomized_id('realm'),
    parent bigint references realms on delete cascade,
    path_segment text not null,

    -- Also see `realm-names.sql`!
    name text,

    -- Index to define an order of this realm and all its siblings. It defaults
    -- to max int such that newly added realms appear after manually ordered
    -- ones.
    index int not null default 2147483647,

    -- Ordering of the children. If this is not 'by_index', the 'index' field of
    -- the children is ignored. We sort again in the frontend then.
    child_order realm_order not null default 'alphabetic:asc',

    -- This is calculated by DB triggers: operations never have to set this
    -- value. This is the empty string for the root realm. For non-root realms
    -- it starts with '/' and never ends with '/'.
    full_path text not null,

    -- We allow almost any Unicode character in path segments to keep
    -- the implementation simple and to accomodate the maximum number
    -- of cultural conventions about how to encode text.
    -- We only exclude control characters and some whitespace.
    --
    -- Note that we explicitly list all the codepoints we exclude
    -- to not rely on implementation details of Postgres and/or browsers,
    -- which might differ among each other and among different versions/environments/...
    --
    -- We make some exceptions to avoid conflicts with special routes:
    -- - We reserve some special characters in prefix position for constructions like `/~manage`,
    -- - and we ensure the path segment is at least two characters long because of things like `/v`
    --
    -- These checks are disabled for the root realm as it has an empty path
    -- segment.
    constraint valid_path check (id = 0 or (
        -- exclude control characters
        path_segment !~ '[\u0000-\u001F\u007F-\u009F]'
        -- exclude some whitespace characters
        and path_segment !~ '[\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]'
        -- exclude characters that are disallowed in URL paths or that have a
        -- semantic meaning there
        and path_segment !~ $$["<>[\\\]^`{|}#%/?]$$
        -- exclude reserved characters in leading position
        and path_segment !~ $$^[-+~@_!$&;:.,=*'()]$$
        -- ensure at least two bytes (we want to reserve single ASCII char segments
        -- for internal use)
        and octet_length(path_segment) >= 2
    )),
    constraint root_no_path check (id <> 0 or (parent is null and path_segment = '' and full_path = '')),
    constraint has_parent check (id = 0 or parent is not null),
    constraint no_empty_name check (name <> '')

    -- NOTE: the definition is expanded and adjusted in `realm-names.sql`!
);

-- Full path to realm lookups happen on nearly every page view. We specify
-- the 'opclass' as 'text_pattern_ops' here to allow for `LIKE` searches.
-- Without this, operators respect the locale of the DB and make it impossible
-- to do a prefix search with this index. Some docs:
--
-- - https://www.postgresql.org/docs/10/indexes-opclass.html
-- - https://dba.stackexchange.com/a/169140
create unique index idx_realm_path on realms (full_path text_pattern_ops);

-- To fetch all children of a realm, we filter by the `parent` column, so this
-- index speeds up those queries.
create index idx_realm_parent on realms (parent);

-- Insert the root realm. Since that realm has to have the ID=0, we have to
-- set the sequence to a specific value. We can just apply inverse xtea to 0
-- to get the value we have to set the sequence to.
select setval(
    '__realm_ids',
    xtea(0, (select key from __xtea_keys where entity = 'realm'), false),
    false
);
insert into realms (name, parent, path_segment, full_path) values (null, null, '', '');


-- Make sure the root realm is never deleted and its ID is never changed.
create function illegal_root_modification() returns trigger as $$
begin
    raise exception 'Deleting the root or changing its ID realm is not allowed';
end;
$$ language plpgsql;

create trigger prevent_root_deletion
    before delete on realms
    for each row
    when (old.id = 0)
    execute procedure illegal_root_modification();

create trigger prevent_root_id_change
    before update on realms
    for each row
    when (old.id = 0 and new.id <> 0)
    execute procedure illegal_root_modification();


-- Triggers to update `full_path` ---------------------------------------------------------
--
-- The `full_path` column is completely managed by triggers to always have the
-- correct values according to `path_segment` and `parent`. Doing this is a bit
-- tricky.

-- The `before insert` trigger is straight forward because we know that there
-- don't exist any children yet that have to be updated. We make sure that
-- insert operations do not try to specifcy the `full_path` already since that
-- would be overwritten anyway.
create function set_full_realm_path() returns trigger as $$
begin
    if NEW.full_path is not null then
        raise exception 'do not set the full path of a realm directly (for realm %)', NEW.id;
    end if;

    NEW.full_path := (select full_path from realms where id = NEW.parent) || '/' || NEW.path_segment;
    return NEW;
end;
$$ language plpgsql;

-- However, handling updates gets interesting since we potentially have to
-- update a large number of (indirect) children. To visit all descendents of a
-- realm, we could have a recursive function, for example. But: changing those
-- descendents via `update` would cause the another trigger to get triggered! I
-- don't think one can avoid that. But we can just use this to our advantage
-- since then we don't have to do recursion ourselves.
--
-- So the idea is to just set the `full_path` of all children to a dummy value,
-- causing this trigger to get fired for all children, fixing the full path.
-- However, since the "fixing" involves querying the full path of the parent,
-- the update of the parent must be finished already before the child triggers
-- can run. In order to achieve that, we install both, `before update` and
-- `after update` triggers. Both call this function, which distinguishes the
-- two cases with `TG_WHEN`.
create function update_full_realm_path() returns trigger as $$
begin
    -- If only the name changed, we don't need to update anything.
    if
        NEW.path_segment is not distinct from OLD.path_segment and
        NEW.parent is not distinct from OLD.parent and
        NEW.full_path is not distinct from OLD.full_path
    then
        return NEW;
    end if;

    if TG_WHEN = 'BEFORE' then
        -- If there was an attempt to change the full path directly and it wasn't
        -- us, we raise an exception.
        if NEW.full_path <> OLD.full_path and pg_trigger_depth() = 1 then
            raise exception 'do not change the full path directly (for realm %)', OLD.id;
        end if;

        -- If we are in the "before" handler, we set the correct full path.
        NEW.full_path := (select full_path from realms where id = NEW.parent)
            || '/' || NEW.path_segment;
        return NEW;
    else
        -- In the "after" handler, we update all children to recursively fire
        -- this trigger.
        update realms set full_path = '' where parent = NEW.id;
        return null;
    end if;
end;
$$ language plpgsql;

create trigger set_full_path_on_insert
    before insert on realms
    for each row
    execute procedure set_full_realm_path();

create trigger fix_full_path_before_update
    before update on realms
    for each row
    execute procedure update_full_realm_path();

create trigger fix_full_path_after_update
    after update on realms
    for each row
    execute procedure update_full_realm_path();


-- Useful functions ---------------------------------------------------------------------

-- Returns all ancestors of the given realm, including the root realm, excluding
-- the given realm itself. The first returned row is the root realm, followed
-- by a child of the root realm, ending with the parent of the given realm.
create function ancestors_of_realm(realm_id bigint)
    returns setof realms
    language 'sql'
as $$
with recursive ancestors as (
    select realms, 1 as height
    from realms
    where id = (select parent from realms where id = realm_id)
  union all
    select r, a.height + 1 as height
    from ancestors a
    join realms r on (a.realms).parent = r.id
    where (a.realms).id <> 0
)
SELECT (ancestors.realms).* FROM ancestors order by height desc
$$;
