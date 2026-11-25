# Changelog

## 2.0.0

  - Requires paper_trail 17
  - Replaces ar_after_transaction with an `after_commit` on the record's current transaction, so only a rollback on the record's own database drops the job. Remove any `ActiveRecord::Base.normally_open_transactions` setup; `with_versioning` no longer takes `expected_open_transactions:`
  - `PaperTrail::Background::Job` sets `enqueue_after_transaction_commit = false` on the class that includes it. With the setting on, Active Job would wait for every open transaction on every database, and a rollback on another database would drop the job
  - A record created inside a savepoint that rolls back no longer enqueues a version job
  - Inside `transaction(joinable: false)` the gem enqueues the job when the record's savepoint is released, the same moment Rails runs `after_commit` callbacks. If the outer transaction then rolls back, the job still writes a version for a row that never committed. 1.x waited for the outer commit
  - `paper_trail.update_columns` on an async model no longer raises `NameError`
  - Update versions take `created_at` from the record's `updated_at`, as create versions already did. Destroy and `update_columns` versions take it from the time the job is enqueued
  - `record_update` merges `data_for_update` instead of `data_for_update_columns`
  - The job payload carries `item_id` and `item_type` instead of the record, so a version is still written when the record is deleted before the job runs
  - A model with `versions: { dependent: :destroy }`, `:delete_all` or `:destroy_async` gets no create or update version from a job that runs after the record is gone, because destroying the record purges its versions. Destroy versions are still written
  - Known gap: the purge check is best effort. A create or update job that runs before the destroy transaction commits finds the record and writes a version that outlives the purge. 1.x had the same window
  - Known gap: the purge check reads the `versions: { dependent: }` option from the class in `item_type`, which for STI is the base class. When only a subclass purges its versions, or base and subclass set different options, the job follows the base class. A late create or update job can then write a version for a subclass record whose versions were purged
  - Known gap: on a model that purges its versions, `record.delete` and `Model.delete_all` skip the purge, yet the job still reads the missing row as purged and drops the record's pending create and update versions. Sync paper_trail 17 keeps them, and 1.x lost them as well
  - Known gap: when version jobs run out of order, on parallel workers or after a retry, a later event can get a lower id. `record.versions` orders by `created_at`, while `Version#previous`, `#next` and `#index` go by id, so the two disagree. Run `VersionJob` on a single-threaded queue if that matters
  - Known gap: a per-model `has_paper_trail limit:` does not apply to an async version whose record is gone when the job runs, which includes every async destroy version. paper_trail then falls back to the global `PaperTrail.config.version_limit`, so without a global limit the older versions of a destroyed record are never pruned. Sync paper_trail 17 prunes them
  - Known gap: pending jobs honour `versions: { dependent: }` only for `:destroy`, `:delete_all` and `:destroy_async`. `dependent: :nullify`, `:restrict_with_error`, `:restrict_with_exception`, horizontally sharded models and `store_full_class_name = false` are unsupported. Keep those models on `async: false` (see the README)
  - With `opt_in` unset, create and destroy go through the job too, as update already did
  - An explicit `async:` on `has_paper_trail` wins over `opt_in`. With `async: false` a model stays synchronous even when `opt_in` is unset, updates included
  - Async versions take `item_type` from `polymorphic_name`, as sync versions do, so a model that overrides it finds them in `record.versions`

## 1.2.0

  - When async is false we want to fall back to the original logic (#11 thanks @erf530)
  - ar_after_transaction got updated for 7.1 Rails support (#10 thanks @caelanpthomas and @jeanpauldejong)
  - Introduced a ton of standardization with rubocop

## 1.1.0

I forgot to put any details here

## 1.0.1

I have no idea, I'll find out

## 1.0.0

  - Initial release
