# frozen_string_literal: true

if BACKEND == :active_record
  class OpsStory < ActiveRecord::Base
    self.table_name = "stories"

    def tell
      text
    end
  end
end
