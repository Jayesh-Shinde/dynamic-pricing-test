# One shared pool of Redis connections for the whole app.
# Puma serves requests on several threads, and a single Redis connection
# must not be used by two threads at once, so each thread checks one out.
#
# Short timeouts: if Redis is down we want to fail fast (503), not hang.
# Tests use database 1 so running them never wipes development data in database 0.
redis_options = {
  url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
  connect_timeout: 0.5,
  read_timeout: 0.5,
  write_timeout: 0.5
}
redis_options[:db] = 1 if Rails.env.test?

REDIS_POOL = ConnectionPool.new(size: ENV.fetch("RAILS_MAX_THREADS", 5).to_i, timeout: 1) do
  Redis.new(**redis_options)
end
