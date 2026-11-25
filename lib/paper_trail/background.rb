# frozen_string_literal: true

require "paper_trail/record_trail"

module PaperTrail
  require_relative "background/config"
  require_relative "background/version"
  require_relative "background/job"

  module Background
    # @api private
    def record_create
      return unless enabled?
      return super unless async?

      event = PaperTrail::Events::Create.new(@record, true)

      # Merge data from `Event` with data from PT-AT. We no longer use
      # `data_for_create` but PT-AT still does.
      data = event.data.merge(data_for_create)

      trigger_write(@record, data, :create)
    end

    # `recording_order` is "after" or "before". See ModelConfig#on_destroy.
    #
    # @api private
    def record_destroy(recording_order)
      return unless enabled?
      return super unless async?
      return if @record.new_record?

      in_after_callback = recording_order == "after"

      event = PaperTrail::Events::Destroy.new(@record, in_after_callback)

      # Merge data from `Event` with data from PT-AT. We no longer use
      # `data_for_destroy` but PT-AT still does.
      data = event.data.merge(data_for_destroy)

      trigger_write(@record, data, :destroy)
    end

    # @api private
    def record_update(force:, in_after_callback:, is_touch:)
      return unless enabled?
      return super unless async?

      event = PaperTrail::Events::Update.new(@record, in_after_callback, is_touch, nil)

      return unless force || event.changed_notably?

      data = event.data

      # Same rule as `RecordTrail#build_version_on_update`.
      if @record.respond_to?(:updated_at) &&
         @record.paper_trail_options[:synchronize_version_creation_timestamp] != false
        data[:created_at] = @record.updated_at
      end

      # Merge data from `Event` with data from PT-AT. We no longer use
      # `data_for_update` but PT-AT still does.
      data.merge!(data_for_update)

      trigger_write(@record, data, :update)
    end

    # @api private
    def record_update_columns(changes)
      return unless enabled?
      return super unless async?

      event = PaperTrail::Events::Update.new(@record, false, false, changes)

      # Merge data from `Event` with data from PT-AT. We no longer use
      # `data_for_update_columns` but PT-AT still does.
      data = event.data.merge(data_for_update_columns)

      trigger_write(@record, data, :update)
    end

    private def async?
      @record.paper_trail_options.fetch(:async) { !Config.configuration.opt_in }.present?
    end

    private def trigger_write(record, data, event)
      item = data.delete(:item)
      if item
        data[:item_id] = item.id
        data[:item_type] = item.class.polymorphic_name
      end
      data[:created_at] ||= Time.current
      version_class_name = record.class.paper_trail.version_class.name

      record.class.current_transaction.after_commit do
        VersionJob.perform_later(version_class_name, data, event)
      end

      nil
    end
  end
end

PaperTrail::RecordTrail.prepend(PaperTrail::Background)
