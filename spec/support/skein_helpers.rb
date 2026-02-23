# frozen_string_literal: true

require 'skein/db'

module SkeinHelpers
  def create_test_db(vec: false)
    Skein::DB.new(':memory:', vec: vec)
  end
end
