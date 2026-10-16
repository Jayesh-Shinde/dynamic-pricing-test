ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: 1)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Every test starts with an empty Redis. The guard makes sure we only ever
  # flush the test database (1), never development data (0).
  setup do
    REDIS_POOL.with do |redis|
      raise "Refusing to flush Redis db #{redis.connection[:db]}" unless redis.connection[:db] == 1
      redis.flushdb
    end
  end

  # Add more helper methods to be used by all tests here...
end
