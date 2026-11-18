# frozen_string_literal: true

# Tiny Rack app used by the koorikla/ci ruby.yaml self-test.
module Greeter
  def self.greet(name = nil)
    "hello, #{name.to_s.empty? ? 'world' : name}"
  end

  # Rack endpoint.
  class App
    def call(env)
      return [200, { "content-type" => "text/plain" }, ["ok"]] if env["PATH_INFO"] == "/healthz"

      [200, { "content-type" => "text/plain" }, [Greeter.greet]]
    end
  end
end
