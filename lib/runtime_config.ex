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
      #
      # layer2_locked: lists which Layer 2 toggles cannot be changed for this preset.
      # :federate is listed in every preset's layer2_locked until groups federation ships.
      group_default_preset: "private_club",
      # Layer 2 toggle definitions — rendered in this order.
      layer2_toggles: [
        %{
          key: :discoverable,
          label: l("Discoverable in group listings"),
          help: l("Group shows in public lists and search.")
        },
        %{
          key: :federate,
          label: l("Federate to other instances"),
          help: l("Reachable from other fediverse servers.")
        },
        %{
          key: :approval_required,
          label: l("Require approval to join"),
          help: l("Moderators review each join request.")
        },
        %{
          key: :anyone_posts,
          label: l("Anyone can post"),
          help: l("Any eligible user can post, not just members.")
        }
      ],
      group_preset_order: [
        # "open_network",  # uncomment when groups federation is ready
        "public_local_community",
        "announcement_channel",
        "private_club"
        # "secret_group"  # uncomment when invite-only member management is ready
      ],
      group_presets: %{
        # Requires groups federation — disabled for now.
        # "open_network" => %{
        #   label: l("Open network"),
        #   description: l("Federated and open: anyone anywhere can find, join, and participate."),
        #   icon: "ph:globe-duotone",
        #   membership: "open",
        #   visibility: "global",
        #   participation: "anyone",
        #   default_content_visibility: "public",
        #   layer2_locked: [:discoverable, :approval_required, :anyone_posts, :federate]
        # },
        # Each preset declares its FINAL dimension slugs. Layer 2 toggle initial states
        # are derived from these by `Bonfire.UI.Groups.NewGroupFormLive.derive_layer2_state/2`.
        "public_local_community" => %{
          label: l("Public local community"),
          description:
            l("Visible to everyone. Users of this instance are free to join and participate."),
          icon: "ph:campfire-duotone",
          membership: "local:members",
          visibility: "nonfederated:discoverable",
          participation: "local:contributors",
          default_content_visibility: "nonfederated",
          layer2_locked: [:federate]
        },
        "announcement_channel" => %{
          label: l("Announcement channel"),
          description:
            l("Public channel where only moderators post, and anyone can follow and interact."),
          icon: "ph:megaphone-duotone",
          membership: "invite_only",
          visibility: "nonfederated:discoverable",
          # TODO: global:discoverable once federation is enabled
          participation: "moderators",
          default_content_visibility: "nonfederated",
          layer2_locked: [:federate, :anyone_posts]
        },
        "private_club" => %{
          label: l("Private club"),
          description:
            l(
              "Group is visible and discoverable, but content is for members-only. Anyone can request to join."
            ),
          icon: "ph:lock-duotone",
          membership: "on_request",
          visibility: "local:discoverable",
          # TODO: global:discoverable once federation is enabled
          participation: "group_members",
          default_content_visibility: "members:private",
          layer2_locked: [:federate, :anyone_posts]
        }
        # TODO: enable when we add a way for mods to add members
        # "secret_group" => %{
        #   label: l("Secret group"),
        #   description: l("Hidden from listings. Invite-only. Nothing leaves the group."),
        #   icon: "ph:eye-slash-duotone",
        #   membership: "invite_only",
        #   visibility: "members:private",
        #   participation: "group_members",
        #   default_content_visibility: "members:private",
        #   layer2_locked: [:federate, :discoverable, :approval_required, :anyone_posts]
        # }
      }
  end
end
