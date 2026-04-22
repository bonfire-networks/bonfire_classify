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

    # Register the group_members circle stereotype used for group membership tracking
    config :bonfire_boundaries,
      circles: [
        group_members: %{
          id: "6R0VPMEMBERS1NACJRC1EN0W00",
          name: l("Group members"),
          stereotype: true,
          icon: "ph:users-three-duotone"
        },
        group_moderators: %{
          id: "3GR0VPM0DERAT0RSEMP0WERED2",
          name: l("Group moderators"),
          stereotype: true,
          icon: "ph:shield-duotone"
        }
      ]

    config :bonfire, :ui,
      activity_preview: [],
      object_preview: [
        {:topic, Bonfire.Classify.Web.Preview.CategoryLive},
        {Bonfire.Classify.Category, Bonfire.Classify.Web.Preview.CategoryLive}
      ],
      object_actions: [
        {Bonfire.Classify.Category, Bonfire.Classify.Web.CategoryActionsLive}
      ]

    config :bonfire_classify,
      # Layer 1 presets for group creation. Each maps intent-named audience shapes onto the
      # four underlying boundary dimensions, plus default states for the Layer 2 toggles.
      # Picking one yields a complete, working group — users can stop at Layer 1 and ship.
      group_preset_order: [
        "local_community",
        "public_community",
        "invite_only_team",
        "private_club"
      ],
      group_presets: %{
        "local_community" => %{
          label: l("Local group"),
          description: l("Anyone on this instance can find, join, and post."),
          icon: "ph:campfire-duotone",
          membership: "local:members",
          visibility: "local",
          participation: "local:contributors",
          default_content_visibility: "local",
          layer2_defaults: %{
            discoverable: true,
            federate: false,
            approval_required: false,
            anyone_posts: true
          }
        },
        "public_community" => %{
          label: l("Public group"),
          description: l("Open to the fediverse: anyone can find, join, and post."),
          icon: "ph:globe-duotone",
          membership: "local:members",
          visibility: "nonfederated",
          participation: "local:contributors",
          default_content_visibility: "nonfederated",
          layer2_defaults: %{
            discoverable: true,
            federate: false,
            approval_required: false,
            anyone_posts: true
          }
        },
        "invite_only_team" => %{
          label: l("Invite-only group"),
          description: l("Moderators invite members. Only members can see or post."),
          icon: "heroicons-solid:lock-closed",
          membership: "invite_only",
          visibility: "members:private",
          participation: "group_members",
          default_content_visibility: "members:private",
          layer2_defaults: %{
            discoverable: false,
            federate: false,
            approval_required: false,
            anyone_posts: false
          }
        },
        "private_club" => %{
          label: l("Private group"),
          description: l("Hidden from listings. Invite-only. Nothing leaves the group."),
          icon: "ph:eye-closed-duotone",
          membership: "invite_only",
          visibility: "members:private",
          participation: "group_members",
          default_content_visibility: "members:private",
          layer2_defaults: %{
            discoverable: false,
            federate: false,
            approval_required: false,
            anyone_posts: false
          }
        }
      }
  end
end
