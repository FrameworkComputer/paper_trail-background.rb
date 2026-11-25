# frozen_string_literal: true

require "spec_helper"

WithData = Struct.new(:data)
WithVersionClass = Struct.new(:version_class)

class SuperDummyClass
  def record_create
    @record = 1
  end

  def record_update(record)
    @record = record
  end

  def record_destroy(record)
    @record = record
  end

  def record_update_columns(record)
    @record = record
  end
end

class DummyClass < SuperDummyClass
  include PaperTrail::Background

  def initialize(options: {}, record: nil)
    @options = options
    @record = record
    super()
  end

  def enabled?
    @options[:enabled]
  end

  def data_for_create
    {}
  end

  def data_for_destroy
    {}
  end

  def data_for_update
    { source: :data_for_update }
  end

  def data_for_update_columns
    { source: :data_for_update_columns }
  end
end

class VersionJob
  def self.perform_later(*args); end
end

RSpec.describe PaperTrail::Background do
  before do
    allow(VersionJob).to receive(:perform_later)
  end

  describe "#record_create" do
    it "does not trigger a write if not enabled" do
      DummyClass.new(options: { enabled: false }).record_create

      expect(VersionJob).not_to have_received(:perform_later)
    end

    context "when enabled and opt_in config is enabled" do
      let(:record) { double("SomeRecord") }

      before do
        PaperTrail::Background::Config.configure do |config|
          config.opt_in = true
        end
      end

      it "does not trigger a write if record is opted in but async is blank" do
        allow(record).to receive(:paper_trail_event).and_return(async: nil)
        allow(record).to receive(:paper_trail_options).and_return(async: nil)
        allow(record.class).to receive(:paper_trail).and_return(WithVersionClass.new(Class))

        DummyClass.new(options: { enabled: true }, record:).record_create

        expect(VersionJob).not_to have_received(:perform_later)
      end

      it "triggers a write if record is opted in and async is true" do
        allow(record).to receive(:paper_trail_options).and_return(async: true)
        allow(PaperTrail::Events::Create).to receive(:new).and_return(WithData.new({}))
        allow(record.class).to receive_messages(current_transaction: ActiveRecord::Transaction::NULL_TRANSACTION, paper_trail: WithVersionClass.new(Class))

        DummyClass.new(options: { enabled: true }, record:).record_create

        expect(VersionJob).to have_received(:perform_later)
      end

      it "returns nil instead of the enqueued job, so paper_trail-association_tracking finds no version" do
        allow(VersionJob).to receive(:perform_later).and_return(VersionJob.new)
        allow(record).to receive(:paper_trail_options).and_return(async: true)
        allow(PaperTrail::Events::Create).to receive(:new).and_return(WithData.new({}))
        allow(record.class).to receive_messages(current_transaction: ActiveRecord::Transaction::NULL_TRANSACTION, paper_trail: WithVersionClass.new(Class))

        expect(DummyClass.new(options: { enabled: true }, record:).record_create).to be_nil
      end
    end
  end

  describe "#record_destroy" do
    it "does not trigger a write if not enabled" do
      DummyClass.new(options: { enabled: false }).record_destroy("after")

      expect(VersionJob).not_to have_received(:perform_later)
    end

    context "when enabled and opt_in config is enabled" do
      let(:record) { double("SomeRecord") }

      before do
        PaperTrail::Background::Config.configure do |config|
          config.opt_in = true
        end
      end

      it "does not trigger a write if record is opted in but async is blank" do
        allow(record).to receive(:paper_trail_options).and_return(async: nil)

        DummyClass.new(options: { enabled: true }, record:).record_destroy("after")

        expect(VersionJob).not_to have_received(:perform_later)
      end

      it "does not trigger a write if record is new" do
        allow(record).to receive_messages(paper_trail_options: { async: true }, new_record?: true)

        DummyClass.new(options: { enabled: true }, record:).record_destroy("after")

        expect(VersionJob).not_to have_received(:perform_later)
      end

      it "triggers a write if record is opted in and async is true" do
        allow(record).to receive_messages(paper_trail_options: { async: true }, new_record?: false)
        allow(PaperTrail::Events::Destroy).to receive(:new).and_return(WithData.new({}))
        allow(record.class).to receive_messages(current_transaction: ActiveRecord::Transaction::NULL_TRANSACTION, paper_trail: WithVersionClass.new(Class))

        DummyClass.new(options: { enabled: true }, record:).record_destroy("after")

        expect(VersionJob).to have_received(:perform_later)
      end
    end
  end

  describe "#record_update" do
    it "does not trigger a write if not enabled" do
      DummyClass.new(options: { enabled: false }).record_update(force: true, in_after_callback: true, is_touch: false)

      expect(VersionJob).not_to have_received(:perform_later)
    end

    context "when enabled and opt_in config is enabled" do
      let(:record) { double("SomeRecord") }

      before do
        PaperTrail::Background::Config.configure do |config|
          config.opt_in = true
        end
      end

      it "does not trigger a write if record is opted in but async is blank" do
        allow(record).to receive(:paper_trail_options).and_return(async: nil)

        DummyClass.new(options: { enabled: true }, record:).record_update(force: true, in_after_callback: true, is_touch: false)

        expect(VersionJob).not_to have_received(:perform_later)
      end

      it "triggers a write if record is opted in and async is true" do
        allow(record).to receive_messages(paper_trail_options: { async: true }, new_record?: false)
        allow(PaperTrail::Events::Update).to receive(:new).and_return(WithData.new({}))
        allow(record.class).to receive_messages(current_transaction: ActiveRecord::Transaction::NULL_TRANSACTION, paper_trail: WithVersionClass.new(Class))

        DummyClass.new(options: { enabled: true }, record:).record_update(force: true, in_after_callback: true, is_touch: false)

        expect(VersionJob).to have_received(:perform_later)
      end

      it "merges data_for_update into the job payload" do
        allow(record).to receive_messages(paper_trail_options: { async: true }, new_record?: false)
        allow(PaperTrail::Events::Update).to receive(:new).and_return(WithData.new({}))
        allow(record.class).to receive_messages(current_transaction: ActiveRecord::Transaction::NULL_TRANSACTION, paper_trail: WithVersionClass.new(Class))

        DummyClass.new(options: { enabled: true }, record:).record_update(force: true, in_after_callback: true, is_touch: false)

        expect(VersionJob).to have_received(:perform_later).with("Class", hash_including(source: :data_for_update), :update)
      end
    end
  end

  describe "#record_update_columns" do
    it "does not trigger a write if not enabled" do
      DummyClass.new(options: { enabled: false }).record_update_columns({})

      expect(VersionJob).not_to have_received(:perform_later)
    end

    context "when enabled and opt_in config is enabled" do
      let(:record) { double("SomeRecord") }

      before do
        PaperTrail::Background::Config.configure do |config|
          config.opt_in = true
        end
      end

      it "does not trigger a write if record is opted in but async is blank" do
        allow(record).to receive(:paper_trail_options).and_return(async: nil)

        DummyClass.new(options: { enabled: true }, record:).record_update_columns({})

        expect(VersionJob).not_to have_received(:perform_later)
      end

      it "triggers a write if record is opted in and async is true" do
        allow(record).to receive_messages(paper_trail_options: { async: true }, new_record?: false)
        allow(PaperTrail::Events::Update).to receive(:new).and_return(WithData.new({}))
        allow(record.class).to receive_messages(current_transaction: ActiveRecord::Transaction::NULL_TRANSACTION, paper_trail: WithVersionClass.new(Class))

        DummyClass.new(options: { enabled: true }, record:).record_update_columns({})

        expect(VersionJob).to have_received(:perform_later)
      end

      it "merges data_for_update_columns into the job payload" do
        allow(record).to receive_messages(paper_trail_options: { async: true }, new_record?: false)
        allow(PaperTrail::Events::Update).to receive(:new).and_return(WithData.new({}))
        allow(record.class).to receive_messages(current_transaction: ActiveRecord::Transaction::NULL_TRANSACTION, paper_trail: WithVersionClass.new(Class))

        DummyClass.new(options: { enabled: true }, record:).record_update_columns({})

        expect(VersionJob).to have_received(:perform_later).with("Class", hash_including(source: :data_for_update_columns), :update)
      end
    end
  end
end
