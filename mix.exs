defmodule MingaAdversarial.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jsmestad/minga-adversarial"

  def project do
    [
      app: :minga_adversarial,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      description: "Adversarial pair programmer: challenges the assumptions in your code",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE)
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:minga_sdk, "~> 0.1.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
