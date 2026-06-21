# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Classify.GraphQL.CategoryResolver do
    @moduledoc "GraphQL tag/category queries"

    use Bonfire.Common.E
    import Bonfire.Common.Config, only: [repo: 0]
    require Bonfire.Common.Settings

    alias Bonfire.Common.Utils
    alias Bonfire.Common.Enums

    alias Bonfire.API.GraphQL
    alias Bonfire.API.GraphQL.Page
    alias Bonfire.API.GraphQL.FetchFields
    alias Bonfire.API.GraphQL.FetchPage
    # FetchPages,
    alias Bonfire.API.GraphQL.ResolveField
    alias Bonfire.API.GraphQL.ResolveFields
    # ResolvePage,
    alias Bonfire.API.GraphQL.ResolvePages
    alias Bonfire.API.GraphQL.ResolveRootPage

    alias Bonfire.Classify.Category
    alias Bonfire.Classify.Categories

    def cursor(), do: &[&1.id]
    def test_cursor(), do: &[&1["id"]]

    def categories(page_opts, info) do
      ResolveRootPage.run(%ResolveRootPage{
        module: __MODULE__,
        fetcher: :fetch_categories,
        page_opts: page_opts,
        info: info,
        # popularity
        cursor_validators: [
          &(is_integer(&1) and &1 >= 0),
          &Needle.UID.cast/1
        ]
      })
    end

    def fetch_categories(page_opts, info) do
      FetchPage.run(%FetchPage{
        queries: Category.Queries,
        query: Category,
        # cursor_fn: Tags.cursor,
        page_opts: page_opts,
        # base_filters: [user: GraphQL.current_user(info)],
        data_filters:
          Bonfire.API.GraphQL.fetch_data_filters(
            [:default, page: [desc: [id: page_opts]]],
            info
          )
      })
    end

    def categories_toplevel(page_opts, info) do
      ResolveRootPage.run(%ResolveRootPage{
        module: __MODULE__,
        fetcher: :fetch_categories_toplevel,
        page_opts: page_opts,
        info: info,
        # popularity
        cursor_validators: [
          &(is_integer(&1) and &1 >= 0),
          &Needle.UID.cast/1
        ]
      })
    end

    def fetch_categories_toplevel(page_opts, _info) do
      # TODO: boundaries queries
      FetchPage.run(%FetchPage{
        queries: Category.Queries,
        query: Category,
        # cursor_fn: Tags.cursor,
        page_opts: page_opts,
        # base_filters: [user: GraphQL.current_user(info)],
        data_filters: [:default, :toplevel, page: [desc: [id: page_opts]]]
      })
    end

    def category(%{category_id: id}, info) do
      ResolveField.run(%ResolveField{
        module: __MODULE__,
        fetcher: :fetch_category,
        context: id,
        info: info
      })
    end

    ## fetchers

    def fetch_category(info, id) do
      Categories.get(id, current_user: GraphQL.current_user(info))
    end

    def parent_category(%{parent_category: parent_category}, _, info) do
      ResolveFields.run(%ResolveFields{
        module: __MODULE__,
        fetcher: :fetch_parent_category,
        context: Enums.id(parent_category),
        info: info
      })
    end

    def parent_category(%{tree: %{parent: parent_category}}, _, info) do
      ResolveFields.run(%ResolveFields{
        module: __MODULE__,
        fetcher: :fetch_parent_category,
        context: Enums.id(parent_category),
        info: info
      })
    end

    def fetch_parent_category(_, ids) do
      FetchFields.run(%FetchFields{
        queries: Category.Queries,
        query: Category,
        group_fn: & &1.id,
        filters: [:default, id: ids]
      })
    end

    @doc "List child categories"
    def category_children(%{id: id}, %{} = page_opts, info) do
      ResolvePages.run(%ResolvePages{
        module: __MODULE__,
        fetcher: :fetch_categories_children,
        context: id,
        page_opts: page_opts,
        info: info
      })
    end

    def fetch_categories_children(page_opts, info, id) do
      user = GraphQL.current_user(info)

      FetchPage.run(%FetchPage{
        queries: Category.Queries,
        query: Category,
        # cursor_fn: Tags.cursor(:followers),
        page_opts: page_opts,
        base_filters: [parent_category: id, user: user],
        data_filters: [:default, page: [desc: [id: page_opts]]]
      })
    end

    @doc """
    Retrieves an Page of categorys according to various filters

    Used by:
    * GraphQL resolver single-parent resolution
    """
    def page(
          cursor_fn,
          page_opts,
          base_filters \\ [],
          data_filters \\ [],
          count_filters \\ []
        )

    def page(
          cursor_fn,
          %{} = page_opts,
          base_filters,
          data_filters,
          count_filters
        ) do
      base_q = Queries.query(Category, base_filters)
      data_q = Queries.filter(base_q, data_filters)
      count_q = Queries.filter(base_q, count_filters)

      with {:ok, [data, counts]} <-
             repo().transact_many(all: data_q, count: count_q) do
        {:ok, Page.new(data, counts, cursor_fn, page_opts)}
      end
    end

    @doc """
    Retrieves an Pages of categorys according to various filters

    Used by:
    * GraphQL resolver bulk resolution
    """
    def pages(
          cursor_fn,
          group_fn,
          page_opts,
          base_filters \\ [],
          data_filters \\ [],
          count_filters \\ []
        )

    def pages(
          cursor_fn,
          group_fn,
          page_opts,
          base_filters,
          data_filters,
          count_filters
        ) do
      Bonfire.API.GraphQL.Pagination.pages(
        Queries,
        Category,
        cursor_fn,
        group_fn,
        page_opts,
        base_filters,
        data_filters,
        count_filters
      )
    end

    #### CATEGORY FIELD RESOLVERS

    def members_count(group, _args, _info) do
      {:ok, Bonfire.Classify.Categories.members_count(group)}
    end

    @dim_keys [:membership, :visibility, :participation, :default_content_visibility]

    def boundaries(group, _args, _info) do
      slugs = Bonfire.Boundaries.Presets.group_dimension_slugs(group)
      vis_opts = Bonfire.Common.Config.get(:preset_dimensions, %{}, :bonfire_boundaries)

      dims =
        for key <- @dim_keys, slug = slugs[key], is_binary(slug) do
          opt = get_in(vis_opts, [key, :options, slug]) || %{}

          %{
            key: key,
            slug: slug,
            label: opt[:label],
            icon: opt[:icon],
            description: opt[:description]
          }
        end

      {:ok, dims}
    end

    def user_groups(user, args, _info) do
      type = args[:type]
      opts = [type: type] |> Enum.reject(fn {_, v} -> is_nil(v) end)
      {tree, page_info} = Bonfire.Classify.my_followed_tree(user, opts)

      categories =
        for {cat, _children} <- tree || [], is_map(cat) do
          cat
        end

      {:ok, %{edges: categories, page_info: page_info, total_count: length(categories)}}
    end

    #### GROUP MEMBERSHIP MUTATIONS

    def join_group(%{group_id: group_id}, info) do
      with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info),
           {:ok, group} <- Categories.get(group_id, current_user: user),
           {:ok, result} <- Categories.join_group(user, group) do
        {:ok,
         Map.merge(result, %{
           user: user,
           group: group,
           role: if(result[:member], do: Categories.member_role(user, group))
         })}
      end
    end

    def leave_group(%{group_id: group_id}, info) do
      with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info),
           {:ok, group} <- Categories.get(group_id, current_user: user),
           {:ok, result} <- Categories.leave_and_unfollow_group(user, group) do
        {:ok, Map.merge(result, %{user: user, group: group, role: nil})}
      end
    end

    def add_member(%{group_id: group_id, account_id: account_id}, info) do
      with {:ok, admin} <- GraphQL.current_user_or_not_logged_in(info),
           {:ok, group} <- Categories.get(group_id, current_user: admin),
           {:ok, result} <- Categories.add_member(admin, group, account_id) do
        {:ok,
         with {:ok, member} <- Bonfire.Common.Needles.get(account_id, skip_boundary_check: true) do
           Map.merge(result, %{user: member, group: group})
         end}
      end
    end

    def remove_member(%{group_id: group_id, account_id: account_id}, info) do
      with {:ok, admin} <- GraphQL.current_user_or_not_logged_in(info),
           {:ok, group} <- Categories.get(group_id, current_user: admin),
           {:ok, _} <- Categories.remove_member(admin, group, account_id) do
        {:ok, true}
      end
    end

    def accept_join_request(%{request_id: request_id}, info) do
      with {:ok, admin} <- GraphQL.current_user_or_not_logged_in(info),
           {:ok, result} <- Categories.accept_join_request(admin, request_id) do
        {:ok,
         Map.merge(result, %{user: admin, group: nil, role: if(result[:member], do: "member")})}
      end
    end

    def group_join_requests(%{group_id: group_id} = args, info) do
      with {:ok, admin} <- GraphQL.current_user_or_not_logged_in(info),
           {:ok, group} <- Categories.get(group_id, current_user: admin),
           true <- Bonfire.Boundaries.can?(admin, :mediate, group) do
        limit = join_request_limit(args[:limit])

        entries =
          Bonfire.Social.Requests.all_by_object(group, Bonfire.Data.Social.Follow,
            skip_boundary_check: true,
            preload: :subject
          )
          |> Enum.filter(&is_nil(e(&1, :ignored_at, nil)))
          |> Enum.take(limit)
          |> Enum.map(&join_request_entry(&1, group))
          |> Enum.reject(&is_nil/1)

        {:ok, %{entries: entries, page_info: %{}}}
      else
        false -> {:error, "Not authorised"}
        other -> other
      end
    end

    defp join_request_entry(request, group) do
      case e(request, :edge, :subject, nil) do
        nil ->
          nil

        requester ->
          %{
            request_id: Enums.id(request),
            account: requester,
            relationship: %{user: requester, group: group, member: false, role: "requested"}
          }
      end
    end

    defp join_request_limit(limit) when is_integer(limit) and limit > 0, do: limit
    defp join_request_limit(_), do: 50

    def members(group, args, info) do
      user = GraphQL.current_user(info)
      group = repo().maybe_preload(group, tree: [])
      opts = Keyword.new(args |> Map.to_list() |> Enum.reject(fn {_, v} -> is_nil(v) end))
      result = Categories.list_members(group, opts)
      edges = Map.get(result, :edges, result || [])

      custodian_id = e(group, :tree, :custodian_id, nil)

      entries =
        Enum.map(edges, fn member ->
          role =
            args[:role] ||
              if custodian_id == Enums.id(member), do: "admin", else: "member"

          %{
            account: member,
            relationship: %{user: member, group: group, member: true, role: role}
          }
        end)

      {:ok, %{entries: entries, page_info: Map.get(result, :page_info, %{})}}
    end

    #### MUTATIONS

    def create_category(attrs, info) do
      repo().transact_with(fn ->
        category_input = Map.get(attrs, :category, %{})
        {boundary, category_input} = Map.pop(category_input, :boundary, %{})
        preset = boundary[:preset]
        overrides_list = boundary[:overrides] || []
        dimensions_list = boundary[:dimensions] || []

        dim_attrs = resolve_boundary_dims(preset, dimensions_list)

        merged =
          Map.merge(attrs, %{
            is_public: true,
            category: Map.merge(category_input, dim_attrs)
          })

        with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info),
             {:ok, category} <- Bonfire.Classify.Categories.create(user, merged),
             :ok <- apply_overrides(category, user, overrides_list) do
          {:ok, category}
        end
      end)
    end

    defp resolve_boundary_dims(preset, dimensions_list) do
      base =
        case Bonfire.Boundaries.Presets.group_preset_meta(preset) do
          %{} = meta ->
            meta
            |> Map.take([:membership, :visibility, :participation, :default_content_visibility])

          _ ->
            %{}
        end

      explicit =
        for %{key: k, value: v} <- dimensions_list,
            key = String.to_existing_atom(k),
            do: {key, v},
            into: %{}

      dims = Map.merge(base, explicit)

      if preset, do: Map.put(dims, :preset_slug, preset), else: dims
    rescue
      ArgumentError -> %{}
    end

    defp apply_overrides(_group, _user, []), do: :ok

    defp apply_overrides(group, user, overrides_list) do
      override_map =
        Map.new(overrides_list, fn %{key: k, value: v} ->
          {Bonfire.Common.Types.maybe_to_atom(to_string(k)), v}
        end)

      current_dims = Bonfire.Boundaries.Presets.group_dimension_slugs(group)

      new_dims =
        Bonfire.Classify.Boundaries.dims_from_layer2_overrides(current_dims, override_map)

      if new_dims != current_dims,
        do: Bonfire.Classify.Boundaries.apply(group, user, new_dims),
        else: :ok
    end

    ### decorators

    def name(%{profile: %{name: name}}, _, _info) when not is_nil(name) do
      {:ok, name}
    end

    def name(%{name: name}, _, _info) when not is_nil(name) do
      {:ok, name}
    end

    # def name(%{name: name, context_id: context_id}, _, _info)
    #     when is_nil(name) and not is_nil(context_id) do

    #   # TODO: optimise so it doesn't repeat these queries (for context and summary fields)
    #   with {:ok, context} <- Bonfire.Common.Needles.get(id: context_id) do
    #     name = if Map.has_key?(context, :name), do: context.name
    #     {:ok, name}
    #   end
    # end

    def name(_, _, _) do
      {:ok, nil}
    end

    def summary(%{profile: %{summary: summary}}, _, _info)
        when not is_nil(summary) do
      {:ok, summary}
    end

    def summary(%{summary: summary}, _, _info) when not is_nil(summary) do
      {:ok, summary}
    end

    # def summary(%{summary: summary, context_id: context_id}, _, _info)
    #     when is_nil(summary) and not is_nil(context_id) do

    #   # TODO: optimise so it doesn't repeat these queries (for context and summary fields)
    #   with {:ok, context} <- Bonfire.Common.Needles.get(context_id) do
    #     summary = if Map.has_key?(context, :summary), do: context.summary
    #     {:ok, summary}
    #   end
    # end

    def summary(_, _, _) do
      {:ok, nil}
    end

    # def search_category(%{query: id}, info) do
    #   {:ok, Simulate.long_node_list(&Simulate.tag/0)}
    #   |> GraphQL.response(info)
    # end

    def update_category(%{category_id: id} = changes, info) do
      repo().transact_with(fn ->
        category_input = Map.get(changes, :category, %{})
        boundary = Map.get(category_input, :boundary, %{})
        preset = boundary[:preset]
        overrides_list = boundary[:overrides] || []
        dimensions_list = boundary[:dimensions] || []

        with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info),
             {:ok, category} <- category(%{category_id: id}, info),
             {:ok, c} <- Categories.update(user, category, changes),
             :ok <- maybe_apply_boundary_changes(c, user, preset, dimensions_list, overrides_list) do
          {:ok, c}
        end
      end)
    end

    defp maybe_apply_boundary_changes(group, user, preset, dimensions_list, overrides_list) do
      if preset || dimensions_list != [] do
        dim_attrs = resolve_boundary_dims(preset, dimensions_list)
        dims = Map.drop(dim_attrs, [:preset_slug])

        with :ok <- Bonfire.Classify.Boundaries.apply(group, user, dims),
             :ok <- apply_overrides(group, user, overrides_list) do
          if preset, do: Bonfire.Common.Settings.put([:preset_slug], preset, scope: group)
          :ok
        end
      else
        apply_overrides(group, user, overrides_list)
      end
    end

    def ensure_update_allowed(user, c) do
      if Classify.ensure_update_allowed(user, c) do
        :ok
      else
        GraphQL.not_permitted("to update this")
      end
    end

    # def delete_category(%{id: id}, info) do
    #   with {:ok, user} <- GraphQL.current_user_or_not_logged_in(info),
    #        {:ok, c} <- category(%{id: id}, info),
    #        :ok <- Classify.ensure_delete_allowed(user, c),
    #        {:ok, c} <- Categories.soft_delete(c, user) do
    #     {:ok, true}
    #   end
    # end
  end
end
