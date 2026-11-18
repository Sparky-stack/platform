# frozen_string_literal: true

require "rack/test"
require_relative "../lib/greeter"

RSpec.describe Greeter do
  include Rack::Test::Methods

  def app
    Greeter::App.new
  end

  it "greets by name" do
    expect(described_class.greet("koorikla")).to eq("hello, koorikla")
  end

  it "serves /healthz" do
    get "/healthz"
    expect(last_response.body).to eq("ok")
  end
end
