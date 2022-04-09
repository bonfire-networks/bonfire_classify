Code.eval_file("mess.exs")
defmodule Bonfire.Classify.MixProject do

  use Mix.Project

  def project do
    [
      app: :bonfire_classify,
      version: "0.1.0",
      elixir: "~> 1.10",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:phoenix, :gettext] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: Mess.deps [
        {:floki, ">= 0.0.0", only: [:dev, :test]},
        {:bonfire_api_graphql, git: "https://github.com/bonfire-networks/bonfire_api_graphql", branch: "main", optional: true},
        {:bonfire_search, git: "https://github.com/bonfire-networks/bonfire_search", branch: "main", optional: true},
        {:bonfire_tag, git: "https://github.com/bonfire-networks/bonfire_tag", branch: "main", optional: true},
        {:bonfire_me, git: "https://github.com/bonfire-networks/bonfire_me", branch: "main", optional: true}
      ]
    ]
  end

  def application do
    [
      # mod: {Bonfire.Classify.FallbackApplication, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]



  defp aliases do
    [
      "hex.setup": ["local.hex --force"],
      "rebar.setup": ["local.rebar --force"],
      "js.deps.get": ["cmd npm install --prefix assets"],
      "ecto.seeds": ["run priv/repo/seeds.exs"],
      setup: ["hex.setup", "rebar.setup", "deps.get", "ecto.setup", "js.deps.get"],
      updates: ["deps.get", "ecto.migrate", "js.deps.get"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "ecto.seeds"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

end
