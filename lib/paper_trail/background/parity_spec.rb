# frozen_string_literal: true

require "spec_helper"
require "active_support/all"
require "active_support/testing/time_helpers"
require "active_job"

RSpec.describe PaperTrail::Background, "parity" do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do # rubocop:disable RSpec/BeforeAfterAll -- one in-memory sqlite schema for the whole group
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table(:widgets) do |t|
        t.string :name
        t.timestamps
      end
      create_table(:versions) do |t|
        t.string :item_type, null: false
        t.bigint :item_id, null: false
        t.string :event, null: false
        t.string :whodunnit
        t.json :object
        t.json :object_changes
        t.datetime :created_at
      end
    end
    ActiveJob::Base.logger = nil
  end

  after(:all) { ActiveRecord::Base.remove_connection } # rubocop:disable RSpec/BeforeAfterAll -- drops the connection the before(:all) opened

  let(:async_widget) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "widgets"
      has_paper_trail async: true
    end
  end
  let(:plain_widget) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "widgets"
      has_paper_trail
    end
  end
  let(:sync_widget) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "widgets"
      has_paper_trail async: false
    end
  end
  let(:purging_widget) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "widgets"
      has_paper_trail async: true, on: %i[create update], versions: { dependent: :destroy }
    end
  end
  let(:renamed_widget) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "widgets"
      has_paper_trail async: true

      def self.polymorphic_name = "Gadget"
    end
  end
  let(:unsynchronized_widget) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "widgets"
      has_paper_trail async: true, synchronize_version_creation_timestamp: false
    end
  end
  let(:jobs) { ActiveJob::Base.queue_adapter.enqueued_jobs }

  before do
    stub_const("AsyncWidget", async_widget)
    stub_const("PlainWidget", plain_widget)
    stub_const("PurgingWidget", purging_widget)
    stub_const("RenamedWidget", renamed_widget)
    stub_const("SyncWidget", sync_widget)
    stub_const("UnsynchronizedWidget", unsynchronized_widget)
    stub_const("VersionJob", Class.new(ActiveJob::Base) { include PaperTrail::Background::Job })
    ActiveJob::Base.queue_adapter = :test
    PaperTrail::Background::Config.configure { |config| config.opt_in = true }
    PaperTrail::Version.delete_all
  end

  def perform_jobs
    jobs.shift(jobs.size).each { |job| ActiveJob::Base.execute(job) }
  end

  def created_widget
    AsyncWidget.create!(name: "a").tap { perform_jobs }
  end

  it "writes the create version from the job" do
    widget = AsyncWidget.create!(name: "a")

    expect { perform_jobs }.to change { widget.versions.pluck(:event, :created_at) }
      .from([]).to([["create", widget.updated_at]])
  end

  it "still writes the version when the record is gone before the job runs" do
    widget = AsyncWidget.create!(name: "a")
    AsyncWidget.where(id: widget.id).delete_all

    perform_jobs

    expect(PaperTrail::Version.where(item_type: "AsyncWidget", item_id: widget.id).count).to eq(1)
  end

  it "writes nothing when the record and its versions are destroyed before the job runs" do
    widget = PurgingWidget.create!(name: "a").tap { perform_jobs }
    widget.update!(name: "b")
    widget.destroy!

    perform_jobs

    expect(PaperTrail::Version.where(item_type: "PurgingWidget", item_id: widget.id)).to be_empty
  end

  it "still writes the version of a live record that its default scope hides from the job" do
    stub_const("ScopedPurgingWidget", Class.new(ActiveRecord::Base) do
      self.table_name = "widgets"
      default_scope { where(name: "visible") }
      has_paper_trail async: true, versions: { dependent: :destroy }
    end)
    widget = ScopedPurgingWidget.create!(name: "visible").tap { perform_jobs }
    widget.update!(name: "hidden")

    perform_jobs

    expect(PaperTrail::Version.where(item_type: "ScopedPurgingWidget", item_id: widget.id).pluck(:event))
      .to eq(%w[create update])
  end

  it "writes the version of a job queued by 1.x, whose payload carries the record instead of item_type" do
    widget = created_widget

    expect { VersionJob.perform_now("PaperTrail::Version", { item: widget, event: "update" }, "update") }
      .to change { widget.versions.pluck(:event) }.from(%w[create]).to(%w[create update])
  end

  it "stamps an update version with the record's updated_at, however late the job runs" do
    widget = created_widget
    widget.update!(name: "b")

    travel(1.hour) { perform_jobs }

    expect(widget.versions.last).to have_attributes(event: "update", created_at: widget.updated_at)
  end

  it "stamps an update version with the time of the write when the creation timestamp is not synchronized" do
    widget = UnsynchronizedWidget.create!(name: "a")
    written_at = Time.current
    widget.update!(name: "b", updated_at: 1.day.ago)

    travel(1.hour) { perform_jobs }

    expect(widget.versions.find_by(event: "update").created_at).to be_within(60).of(written_at)
  end

  it "records the changes of paper_trail.update_columns" do
    widget = created_widget
    widget.paper_trail.update_columns(name: "c")

    perform_jobs

    expect(widget.versions.last.object_changes).to eq("name" => %w[a c])
  end

  it "stamps a destroy version with the time of the destroy, not of the job" do
    widget = created_widget
    destroyed_at = Time.current
    widget.destroy!

    travel(1.hour) { perform_jobs }

    expect(PaperTrail::Version.find_by(event: "destroy").created_at).to be_within(60).of(destroyed_at)
  end

  it "enqueues only after the outermost transaction commits" do
    AsyncWidget.transaction do
      AsyncWidget.create!(name: "a")
      expect(jobs).to be_empty
    end

    expect(jobs.size).to eq(1)
  end

  it "enqueues nothing for a rolled back savepoint" do
    AsyncWidget.transaction do
      AsyncWidget.transaction(requires_new: true) do
        AsyncWidget.create!(name: "a")
        raise ActiveRecord::Rollback
      end
    end

    expect(jobs).to be_empty
  end

  it "enqueues once the record's database commits, even when another database rolls back" do
    stub_const("OtherDatabaseRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    OtherDatabaseRecord.establish_connection(adapter: "sqlite3", database: ":memory:")

    OtherDatabaseRecord.transaction do
      AsyncWidget.create!(name: "a")
      raise ActiveRecord::Rollback
    end

    expect(jobs.size).to eq(1)
  ensure
    OtherDatabaseRecord.remove_connection
  end

  it "enqueues once the record's database commits, even when the job defers enqueuing to every transaction's commit" do
    stub_const("VersionJob", Class.new(ActiveJob::Base) do
      include ActiveJob::EnqueueAfterTransactionCommit

      self.enqueue_after_transaction_commit = true
      include PaperTrail::Background::Job
    end)
    stub_const("OtherDatabaseRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    OtherDatabaseRecord.establish_connection(adapter: "sqlite3", database: ":memory:")

    OtherDatabaseRecord.transaction do
      AsyncWidget.create!(name: "a")
      raise ActiveRecord::Rollback
    end

    expect(jobs.size).to eq(1)
  ensure
    OtherDatabaseRecord.remove_connection
  end

  it "enqueues inside a non-joinable transaction, as transactional tests open" do
    AsyncWidget.lease_connection.transaction(joinable: false) do
      AsyncWidget.create!(name: "a")
      expect(jobs.size).to eq(1)
    end
  end

  it "writes synchronously for a model without async when opt_in is on" do
    expect { PlainWidget.create!(name: "a") }.to change(PaperTrail::Version, :count).by(1)
    expect(jobs).to be_empty
  end

  it "goes through the job for every model when opt_in is off" do
    PaperTrail::Background::Config.configure { |config| config.opt_in = false }

    widget = PlainWidget.create!(name: "a")
    widget.destroy!

    expect(jobs.size).to eq(2)
    expect { perform_jobs }.to change { widget.versions.pluck(:event) }.from([]).to(%w[create destroy])
  end

  it "writes every event synchronously for a model with async: false when opt_in is off" do
    PaperTrail::Background::Config.configure { |config| config.opt_in = false }

    widget = SyncWidget.create!(name: "a")
    widget.update!(name: "b")
    widget.paper_trail.update_columns(name: "c")
    widget.destroy!

    expect(jobs).to be_empty
    expect(widget.versions.pluck(:event)).to eq(%w[create update update destroy])
  end

  it "files the version under the model's polymorphic name" do
    stub_const("Gadget", RenamedWidget)
    widget = RenamedWidget.create!(name: "a")

    expect { perform_jobs }.to change { widget.versions.count }.from(0).to(1)
  end
end
