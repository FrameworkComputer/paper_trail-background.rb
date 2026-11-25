# paper_trail-background

Allows you to enqueue version creation/deletion as a background job to avoid having business logic blocked by changelog writing.


## Using

First you'll need to setup a job for processing versions:

``` ruby
# The class MUST be named this
class VersionJob < ApplicationJob
  queue_as :default

  # This wires up the background job
  include PaperTrail::Background::Job
end
```

`include PaperTrail::Background::Job` sets `enqueue_after_transaction_commit = false` on `VersionJob`, even when `ApplicationJob` turns it on. The gem already enqueues the job once the record's transaction commits. With the setting on, Active Job would also wait for every open transaction on every database, and a rollback on another database would drop the job.

## Configuration
In an initializer, you can specify whether you want to opt into this behavior on a per-model basis:

``` ruby
PaperTrail::Background::Config.configure do |config|
  config.opt_in = true
end
```

If opt-in behavior is set to `true`, you can enable async paper trails by specifying `async: true` in a given model's paper trail options:

``` ruby
class SomeModel < ActiveRecord::Base
  has_paper_trail async: true
end
```

An explicit `async:` option takes precedence over `opt_in`. A model with `has_paper_trail async: false` stays synchronous even when `opt_in` is unset.

Async versions don't record [paper_trail-association_tracking](https://github.com/westonganger/paper_trail-association_tracking) associations. Keep a model synchronous with `async: false` if you need them.

Version jobs for the same record can run out of order, on parallel workers or when a job is retried. Each version keeps the time of its event in `created_at`, so `record.versions` stays in event order. Ids follow the order the jobs ran in, and `Version#previous`, `#next` and `#index` go by id. Run `VersionJob` on a single-threaded queue if you rely on them.

Pending jobs honour `has_paper_trail versions: { dependent: }` only for `:destroy`, `:delete_all` and `:destroy_async`. A create or update job that runs after such a record is gone writes nothing, because destroying the record purged its versions. Keep a model on `async: false` in four other setups. With `dependent: :nullify`, a pending version keeps the destroyed record's `item_id` and `item_type`. With `:restrict_with_error` or `:restrict_with_exception`, a record whose create version is still queued has no versions yet, so it can be destroyed. On a horizontal shard, the job runs on the worker's current shard, so it can write the version to the wrong shard, or drop it on a model that purges its versions. With `ActiveRecord::Base.store_full_class_name = false`, `item_type` drops the namespace, so the job can check the wrong class and drop a live record's version.

## Installing

Run this command in your project:

    $ bundle add paper_trail-background

Or install it yourself with:

    $ gem install paper_trail-background


## Contributing

  1. Read the [Code of Conduct](/CONDUCT)
  2. Fork it
  3. Create your feature branch (`git checkout -b my-new-feature`)
  4. Commit your changes (`git commit -am 'Add some feature'`)
  5. Push to the branch (`git push origin my-new-feature`)
  6. Create new Pull Request


## Todo

  - Support other job types
  - Allow for configuring the job class name
