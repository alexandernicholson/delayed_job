# frozen_string_literal: true

if defined?(ActiveRecord::Base)
  class Story < ActiveRecord::Base
    default_scope { where(scoped: true) }

    def tell
      text
    end

    def whatever(count, _)
      tell * count
    end
    handle_asynchronously :whatever
  end
else
  class Story
    include GlobalID::Identification

    class RecordNotFound < StandardError; end

    cattr_accessor :rows, default: {}
    cattr_accessor :sequence, default: 0

    attr_accessor :id, :text, :scoped

    def self.create(attributes = {})
      new(attributes).tap(&:save!)
    end

    def self.find(id)
      row = rows.fetch(id.to_s) { raise RecordNotFound, "Couldn't find Story with 'id'=#{id}" }
      new(row.merge(id: id.to_s))
    end

    def self.primary_key
      "id"
    end

    def initialize(attributes = {})
      @scoped = true
      attributes.each { |name, value| public_send("#{name}=", value) }
    end

    def save!
      self.id ||= (self.class.sequence += 1).to_s
      rows[id] = { text: text, scoped: scoped }
      true
    end
    alias_method :save, :save!

    def persisted?
      id.present? && rows.key?(id)
    end

    def destroy
      rows.delete(id)
      self
    end

    def tell
      text
    end

    def whatever(count, _)
      tell * count
    end
    handle_asynchronously :whatever
  end
end
