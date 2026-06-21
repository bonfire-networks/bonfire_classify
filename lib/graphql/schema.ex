# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Classify.GraphQL.ClassifySchema do
    use Absinthe.Schema.Notation
    use Bonfire.Common.E

    alias Bonfire.Classify
    # alias Bonfire.Web.GraphQL.UsersResolver
    alias Bonfire.Classify.GraphQL.CategoryResolver

    object :classify_queries do
      @desc "Get list of categories we know about"
      field :categories, non_null(:categories_page) do
        arg(:limit, :integer)
        arg(:before, list_of(non_null(:cursor)))
        arg(:after, list_of(non_null(:cursor)))
        resolve(&CategoryResolver.categories/2)
      end

      @desc "Get a category by ID "
      field :category, :category do
        arg(:category_id, :id)
        # arg :find, :category_find
        resolve(&CategoryResolver.category/2)
      end

      @desc "List pending join requests for a group (admin only)"
      field :group_join_requests, :group_members_page do
        arg(:group_id, non_null(:id))
        arg(:limit, :integer)
        resolve(&CategoryResolver.group_join_requests/2)
      end
    end

    # Returned by join_group/leave_group/add_member mutations.
    # Parent is %{user: user, group: group, member: bool, role: role_string | nil}.
    object :group_relationship do
      field :member, non_null(:boolean) do
        resolve(fn %{member: member}, _, _ -> {:ok, member} end)
      end

      field :role, :string do
        resolve(fn %{role: role}, _, _ -> {:ok, role} end)
      end

      field :following, :boolean do
        resolve(fn %{user: user, group: group}, _, _ ->
          {:ok, Bonfire.Social.Graph.Follows.following?(user, group)}
        end)
      end

      field :requested, :boolean do
        resolve(fn %{user: user, group: group}, _, _ ->
          {:ok, Bonfire.Social.Graph.Follows.requested?(user, group)}
        end)
      end
    end

    # Each entry in category.members
    object :group_member_entry do
      field(:request_id, :id)
      field(:account, :user)
      # %{user: member, group: group} — GroupRelationship per-field resolvers apply
      field(:relationship, :group_relationship)
    end

    object :group_members_page do
      field(:entries, list_of(:group_member_entry))
      field(:page_info, :page_info)
    end

    object :classify_mutations do
      @desc "Join a group"
      field :join_group, :group_relationship do
        arg(:group_id, non_null(:id))
        resolve(&CategoryResolver.join_group/2)
      end

      @desc "Leave a group"
      field :leave_group, :group_relationship do
        arg(:group_id, non_null(:id))
        resolve(&CategoryResolver.leave_group/2)
      end

      @desc "Add a member to a group (admin only)"
      field :add_member, :group_relationship do
        arg(:group_id, non_null(:id))
        arg(:account_id, non_null(:id))
        resolve(&CategoryResolver.add_member/2)
      end

      @desc "Remove a member from a group (admin only)"
      field :remove_member, :boolean do
        arg(:group_id, non_null(:id))
        arg(:account_id, non_null(:id))
        resolve(&CategoryResolver.remove_member/2)
      end

      @desc "Accept a pending join request (admin only)"
      field :accept_join_request, :group_relationship do
        arg(:request_id, non_null(:id))
        resolve(&CategoryResolver.accept_join_request/2)
      end

      @desc "Create a new Category"
      field :create_category, :category do
        arg(:category, :category_input)

        # arg(:profile, :profile_input)
        # arg(:character, :character_input)

        resolve(&CategoryResolver.create_category/2)
      end

      @desc "Update a category"
      field :update_category, :category do
        arg(:category_id, :id)

        arg(:category, :category_input)

        # arg(:profile, :profile_input)
        # arg(:character, :character_input)

        resolve(&CategoryResolver.update_category/2)
      end
    end

    @desc "A category (eg. tag in a taxonomy)"
    object :category do
      @desc "The numeric primary key of the category"
      field(:id, :id)

      # field(:name, :string)
      field(:name, :string) do
        resolve(&CategoryResolver.name/3)
      end

      # field(:summary, :string)
      field(:summary, :string) do
        resolve(&CategoryResolver.summary/3)
      end

      # field(:parent_category_id, :string)

      @desc "The parent category (in a tree-based taxonomy)"
      field :parent_category, :category do
        resolve(&CategoryResolver.parent_category/3)
      end

      @desc "List of child categories (in a tree-based taxonomy)"
      field :sub_categories, list_of(:categories_page) do
        resolve(&CategoryResolver.category_children/3)
      end

      # @desc "The caretaker of this category, if any"
      # field :caretaker, :any_context do
      #   # resolve(&Bonfire.API.GraphQL.CommonResolver.context_edge/3)
      # end

      @desc "A JSON document containing more info beyond the default fields"
      # TODO: hook up with resolver to use mixin
      field(:extra_info, :json)

      @desc "The character (handle/username) that represents this category in feeds and federation"
      field :character, :character do
        resolve(Absinthe.Resolution.Helpers.dataloader(Needle.Pointer))
      end

      @desc "The profile (name/summary/icon) that represents this category"
      field :profile, :profile do
        resolve(Absinthe.Resolution.Helpers.dataloader(Needle.Pointer))
      end

      field(:type, :string, resolve: fn cat, _, _ -> {:ok, to_string(e(cat, :type, "group"))} end)

      field(:members_count, :integer, resolve: &CategoryResolver.members_count/3)

      field(:is_disabled, :boolean,
        resolve: fn cat, _, _ -> {:ok, e(cat, :is_disabled, false) == true} end
      )

      field(:parent_category_id, :id,
        resolve: fn cat, _, _ ->
          {:ok, e(cat, :tree, :parent_id, nil) || e(cat, :parent_category_id, nil)}
        end
      )

      @desc "Resolved boundary dimensions with display metadata (membership, visibility, participation, default_content_visibility)"
      field(:boundaries, list_of(:boundary_dimension_value),
        resolve: &CategoryResolver.boundaries/3
      )

      @desc "Members of this group (only populated when category type is :group)"
      field :members, :group_members_page do
        arg(:role, :string)
        arg(:limit, :integer)
        arg(:after, :string)
        resolve(&CategoryResolver.members/3)
      end

      # @desc "The user who created the character"
      # TODO: hook up with created mixin
      # field :creator, :user do
      #   resolve(&UsersResolver.creator_edge/3)
      # end
    end

    object :categories_page do
      field(:page_info, non_null(:page_info))
      field(:edges, non_null(list_of(non_null(:category))))
      field(:total_count, non_null(:integer))
    end

    input_object :category_find do
      field(:name, non_null(:string))
      field(:parent_category_name, non_null(:string))
    end

    input_object :category_input do
      field(:parent_category, :id)
      field(:also_known_as, :id)

      field(:name, :string)
      field(:summary, :string)
      field(:type, :string)

      @desc "Boundary settings: preset, layer-2 overrides, and/or explicit dimension slugs"
      field(:boundary, :boundary_dimensions_input)

      @desc "A JSON document containing more info beyond the default fields"
      field(:extra_info, :json)
    end

    #  @desc "A category is a grouping mechanism for categories"
    #   object :category_category do
    #     @desc "An instance-local UUID identifying the category"
    #     field :id, :string
    #     @desc "A url for the category, may be to a remote instance"
    #     field :canonical_url, :string

    #     @desc "The name of the category category"
    #     field :name, :string

    #     @desc "Whether the like is local to the instance"
    #     field :is_local, :boolean
    #     @desc "Whether the like is public"
    #     field :is_public, :boolean

    #     @desc "When the like was created"
    #     field :created_at, :string do
    #       resolve &CommonResolver.created_at/3
    #     end

    #     # @desc "The current user's follow of the category, if any"
    #     # field :my_follow, :follow do
    #     #   resolve &CommonResolver.my_follow/3
    #     # end

    #     @desc "The categories in the category, most recently created first"
    #     field :categories, :categories_edges do
    #       arg :limit, :integer
    #       arg :before, :string
    #       arg :after, :string
    #       resolve &CommonResolver.category_categories/3
    #     end

    #   end

    # @desc "A category is a grouping mechanism for categories"
    # object :category_category do
    #   @desc "An instance-local UUID identifying the category"
    #   field :id, :string
    #   @desc "A url for the category, may be to a remote instance"
    #   field :canonical_url, :string

    #   @desc "The name of the category category"
    #   field :name, :string

    #   @desc "Whether the like is local to the instance"
    #   field :is_local, :boolean
    #   @desc "Whether the like is public"
    #   field :is_public, :boolean

    #   @desc "When the like was created"
    # field :created_at, :string do
    #   resolve &CommonResolver.created_at/3
    # end

    #   # @desc "The current user's follow of the category, if any"
    #   # field :my_follow, :follow do
    #   #   resolve &CommonResolver.my_follow/3
    #   # end

    #   @desc "The categories in the category, most recently created first"
    #   field :categories, :categories_edges do
    #     arg :limit, :integer
    #     arg :before, :string
    #     arg :after, :string
    #     resolve &CommonResolver.category_categories/3
    #   end

    # end
  end
end
