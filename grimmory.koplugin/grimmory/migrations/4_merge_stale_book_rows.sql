-- Merge book rows that share a path into the newest one.
--
-- The partial_md5 of a row must match the file now on disk: progress is
-- pushed by that hash, and the server rejects hashes of earlier versions.
--
-- Runs on every start like the other migrations, and with no duplicates
-- it changes nothing.
--
-- No semicolons in comments: lua-ljsqlite3 exec splits the file on every
-- semicolon, and a fragment holding only a comment fails with misuse.

BEGIN;

CREATE TEMP TABLE IF NOT EXISTS book_merge AS
    SELECT stale.id AS stale_id, keep.keep_id
    FROM book AS stale
    JOIN (
        SELECT book_path, MAX(id) AS keep_id
        FROM book
        GROUP BY book_path
        HAVING COUNT(*) > 1
    ) AS keep ON keep.book_path = stale.book_path
    WHERE stale.id <> keep.keep_id;

-- Keep the latest sync time per type, so nothing is pushed twice.
INSERT OR REPLACE INTO book_sync_status (book_id, sync_type, last_synced_at)
    SELECT keep_ids.keep_id, status.sync_type, MAX(status.last_synced_at)
    FROM (
        SELECT DISTINCT keep_id, keep_id AS member_id FROM book_merge
        UNION ALL
        SELECT keep_id, stale_id FROM book_merge
    ) AS keep_ids
    JOIN book_sync_status AS status ON status.book_id = keep_ids.member_id
    GROUP BY keep_ids.keep_id, status.sync_type;

UPDATE book
SET grimmory_id = (
    SELECT older.grimmory_id
    FROM book_merge
    JOIN book AS older ON older.id = book_merge.stale_id
    WHERE book_merge.keep_id = book.id AND older.grimmory_id IS NOT NULL
    ORDER BY older.id DESC
    LIMIT 1
)
WHERE grimmory_id IS NULL
    AND id IN (SELECT keep_id FROM book_merge);

UPDATE book_session
SET book_id = (
    SELECT keep_id FROM book_merge WHERE stale_id = book_session.book_id
)
WHERE book_id IN (SELECT stale_id FROM book_merge);

DELETE FROM book_sync_status WHERE book_id IN (SELECT stale_id FROM book_merge);
DELETE FROM book WHERE id IN (SELECT stale_id FROM book_merge);

DROP TABLE book_merge;

COMMIT;
