defmodule Bonfire.Classify.RuntimeConfig do
  use Bonfire.Common.Localise

  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  @doc """
  NOTE: you can override this default config in your app's `runtime.exs`, by placing similarly-named config keys below the `Bonfire.Common.Config.LoadExtensionsConfig.load_configs()` line
  """
  def config do
    import Config

    # config :bonfire_classify,
    #   modularity: :disabled

    config :bonfire, :ui,
      activity_preview: [],
      object_preview: [
        {:topic, Bonfire.Classify.Web.Preview.CategoryLive},
        {Bonfire.Classify.Category, Bonfire.Classify.Web.Preview.CategoryLive}
      ],
      object_actions: [
        {Bonfire.Classify.Category, Bonfire.Classify.Web.CategoryActionsLive}
      ]
  end
end
