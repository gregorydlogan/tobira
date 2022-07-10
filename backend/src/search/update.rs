use std::{
    collections::HashSet,
    future::Future,
    time::Instant,
};

use crate::{
    db::{DbConnection, types::Key, util::select},
    prelude::*,
    util::Never,
};

use super::{
    Client, Event, IndexItemKind, Realm, IndexItem, SearchId,
    writer::{self, MeiliWriter},
};


/// Calls `update_index` roughly every `config.update_interval` and never returns.
pub(crate) async fn update_index_daemon(meili: &Client, db: &mut DbConnection) -> Result<Never> {
    loop {
        let loop_started_at = Instant::now();

        update_index(meili, db).await?;

        let next_update_in = meili.config.update_interval.saturating_sub(loop_started_at.elapsed());
        trace!("Cleared search index queue: waiting for {:.1?}", next_update_in);
        tokio::time::sleep(next_update_in).await;
    }
}

/// Processes the "search index queue" in the DB by dequeuing some items and
/// sending them to the search index. Stops once the queue is empty.
pub(crate) async fn update_index(meili: &Client, db: &mut DbConnection) -> Result<()> {
    const CHUNK_SIZE: u32 = 5000;

    loop {
        let done = writer::with_write_lock(db, meili, move |tx, meili| Box::pin(async move {
            // First, we retrieve a list of items that need updating.
            let (selection, mapping) = select!(item_id, kind);
            let query = format!("select {selection} \
                from search_index_queue \
                order by id \
                limit {CHUNK_SIZE}");

            let row_stream = tx.query_raw(&query, dbargs![]).await
                .context("failed to load IDs from search index queue")?;

            let mut event_ids = Vec::new();
            let mut realm_ids = Vec::new();
            futures::pin_mut!(row_stream);
            while let Some(row) = row_stream.try_next().await? {
                let key: Key = mapping.item_id.of(&row);
                let kind: IndexItemKind = mapping.kind.of(&row);
                match kind {
                    IndexItemKind::Realm => realm_ids.push(key),
                    IndexItemKind::Event => event_ids.push(key),
                }
            }

            let count = event_ids.len() + realm_ids.len();
            if count == 0 {
                trace!("No index update queued -> doing nothing");
                return Ok(true);
            }

            trace!("Loaded {} IDs from search index queue", count);


            // Load items from DB and push them into the index.
            meili.update(&realm_ids, || Realm::load_by_ids(&**tx, &realm_ids)).await
                .context("failed to send realms to search index")?;
            meili.update(&event_ids, || Event::load_by_ids(&**tx, &event_ids)).await
                .context("failed to send events to search index")?;

            // Delete all items that we have sent to the search index already.
            let sql = "delete from search_index_queue \
                where item_id = any($1) and kind = 'realm' \
                or item_id = any($2) and kind = 'event'";
            let affected = tx.execute(sql, &[&realm_ids, &event_ids]).await
                .context("failed to remove items from search index queue")?;
            debug!("Removed {affected} items from the search index queue");

            if affected != count as u64 {
                warn!("Wanted to delete {count} items from search index queue, \
                    but deleted {affected}");
            }

            Ok(count < CHUNK_SIZE as usize)
        })).await?;


        if done {
            break;
        }
    }

    Ok(())
}

impl MeiliWriter<'_> {
    /// Loads items from the DB with the given loader and then adds them to
    /// Meili. All items that were not returned by `loader` but are present in
    /// `ids` are deleted from the index.
    pub(crate) async fn update<L, F, T>(&self, ids: &[Key], loader: L) -> Result<()>
    where
        L: FnOnce() -> F,
        F: Future<Output = Result<Vec<T>>>,
        T: IndexItem,
    {
        let kind = T::KIND;

        if ids.is_empty() {
            trace!("No {} in need of a search index update", kind.plural_name());
            return Ok(());
        }

        // Load all new items from the DB.
        let items = loader().await?;
        debug!(
            "Loaded {} {} from DB to be added to search index",
            items.len(),
            kind.plural_name(),
        );

        // Figure out which ones were deleted
        let existing_item_ids = items.iter().map(|r| r.id().0).collect::<HashSet<_>>();
        let deleted_items = ids.iter()
            .copied()
            .filter(|id| !existing_item_ids.contains(id))
            .map(SearchId)
            .collect::<Vec<_>>();

        // Obtain the correct index.
        let index = match kind {
            IndexItemKind::Realm => &self.realm_index,
            IndexItemKind::Event => &self.event_index,
        };

        // Actually update documents in Meili.
        if !deleted_items.is_empty() {
            index.delete_documents(&deleted_items).await?;
            debug!("Started deletion of {} {} in Meili", deleted_items.len(), kind.plural_name());
        }

        if !items.is_empty() {
            index.add_documents(&items, None).await?;
            debug!("Sent {} {} to Meili for indexing", items.len(), kind.plural_name());
        }

        Ok(())
    }
}
