-- All types of items that can cause the need for reindexing.
create type search_index_item_kind as enum ('realm', 'event');


-- This table is used to push records that need to updated in the search index.
create table search_index_queue (
    -- Auto-incrementing integer to sort by (for queue semantics).
    id bigint primary key generated always as identity,

    -- The ID of the realm, event, ... $type.
    item_id bigint not null,

    -- The type of the item referenced here
    kind search_index_item_kind not null,


    -- Every item should be in the queue only once.
    constraint id_type_unique unique(item_id, kind)
);


-- Triggers that automatically queue items for reindex.

-- Some triggers (and surrounding infrastructure) to automatically queue
-- events for reindexing when they become (un-)listed by a change to
-- the block (and indirectly realm) structure. These changes lead to
-- a change in the host realms of the corresponding events, which the
-- index needs to pick up. This is simpler than doing it in application code.

create function queue_block_for_reindex(block blocks)
   returns void
   language sql
as $$
    with listed_events as (
        select id from events where id = block.video_id
        union all select id from events where series = block.series_id
    )
    insert into search_index_queue (item_id, kind)
    select id, 'event' from listed_events
    on conflict do nothing;
$$;

create function queue_blocks_for_reindex()
   returns trigger
   language plpgsql
as $$
begin
    if tg_op <> 'INSERT' then
        perform queue_block_for_reindex(old);
    end if;
    if tg_op <> 'DELETE' then
        perform queue_block_for_reindex(new);
    end if;
    return null;
end;
$$;

create trigger queue_blocks_for_reindex
after insert or delete or update of video_id, series_id
on blocks
for each row
execute procedure queue_blocks_for_reindex();


-- Triggers to queue realms.

create function queue_realm_for_reindex(realm realms) returns void language sql as $$
    insert into search_index_queue (item_id, kind)
    values (realm.id, 'realm')
    on conflict do nothing
$$;

create function queue_touched_realm_for_reindex()
   returns trigger
   language plpgsql
as $$
begin
    if tg_op <> 'INSERT' then
        perform queue_realm_for_reindex(old);
    end if;
    if tg_op <> 'DELETE' then
        perform queue_realm_for_reindex(new);
    end if;

    if tg_op = 'UPDATE' and (
        old.name is distinct from new.name or
        old.name_from_block is distinct from new.name_from_block
    ) then
        insert into search_index_queue (item_id, kind)
        select id, 'realm'
        from realms
        where full_path like new.full_path || '/%'
        on conflict do nothing;
    end if;
    return null;
end;
$$;

create trigger queue_touched_realm_for_reindex
after insert or delete or update of id, parent, full_path, name, name_from_block
on realms
for each row
execute procedure queue_touched_realm_for_reindex();


create function queue_realm_on_updated_title() returns trigger language plpgsql as $$
begin
    insert into search_index_queue (item_id, kind)
    select affected.id, 'realm'
    from blocks
    inner join realms on blocks.realm_id = realms.id
    inner join realms affected on affected.full_path like realms.full_path || '%'
    -- Ho ho ho, this is interesting. To deduplicate some code, we use this
    -- function with both, events and series. And we don't even care which kind
    -- this function is called with. We just accept both. This is fine
    -- because: (a) a series and event having the same ID is exceeeeedingly
    -- rare, and (b) if this virtually impossible case actually arises, we just
    -- unnecessarily queue some events -> no harm done.
    where blocks.series_id = new.id or blocks.video_id = new.id
    on conflict do nothing;

    return null;
end;
$$;

create trigger queue_realm_on_updated_series_title
after update of title
on series
for each row
execute procedure queue_realm_on_updated_title();

create trigger queue_realm_on_updated_event_title
after update of title
on events
for each row
execute procedure queue_realm_on_updated_title();
