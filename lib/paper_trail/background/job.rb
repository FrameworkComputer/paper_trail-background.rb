# frozen_string_literal: true

module PaperTrail
  module Background
    module Job
      PURGING_DEPENDENTS = %i[destroy delete_all destroy_async].freeze

      def self.included(base)
        return unless base.respond_to?(:enqueue_after_transaction_commit=)

        base.enqueue_after_transaction_commit = false
      end

      def perform(version_class, attributes, event)
        return if purged_with_item?(attributes, event)

        version_class.constantize.create!(attributes)
      end

      private def purged_with_item?(attributes, event)
        return false if event.to_s == "destroy"
        return false unless (item_class = attributes[:item_type]&.safe_constantize)
        return false unless purges_versions?(item_class)

        !item_class.unscoped.exists?(attributes[:item_id])
      end

      private def purges_versions?(item_class)
        return false unless item_class.respond_to?(:versions_association_name)

        dependent = item_class.reflect_on_association(item_class.versions_association_name).options[:dependent]
        PURGING_DEPENDENTS.include?(dependent)
      end
    end
  end
end
