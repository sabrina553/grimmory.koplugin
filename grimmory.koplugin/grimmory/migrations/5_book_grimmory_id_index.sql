-- Books are looked up by Grimmory ID once per book on every full sync,
-- which scanned the whole table without this index.
-- Keep semicolons out of comments, as exec splits on every one.
CREATE INDEX IF NOT EXISTS book_grimmory_id ON book (grimmory_id);
