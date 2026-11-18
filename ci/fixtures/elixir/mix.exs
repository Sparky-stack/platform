defmodule CiSelftest.MixProject do
  use Mix.Project

  def project do
    [
      app: :ci_selftest,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [ci_selftest: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {CiSelftest.Application, []}
    ]
  end

  # credo and mix_audit are present so elixir.yaml exercises them; sobelow is
  # deliberately absent (no Phoenix) so its step must skip cleanly.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end
end
