require "./icecast_server"

module Lurcast
  VERSION = "0.2.0"

  def self.configure_execution_context(maximum = Fiber::ExecutionContext.default_workers_count)
    Fiber::ExecutionContext.default.resize(maximum)
  end
end
