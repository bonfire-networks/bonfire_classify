defmodule Bonfire.Classify.Web.GroupNavigation do
  @moduledoc "Preserves the entry page while navigating between a group and its topics."

  @doc """
  Resolves a local entry page, falling back to the groups directory.

      iex> Bonfire.Classify.Web.GroupNavigation.return_to(%{}, "http://localhost:4000/feed?sort=latest")
      "/feed?sort=latest"
      iex> Bonfire.Classify.Web.GroupNavigation.return_to(%{"group_from" => "/feed?sort=latest"}, "http://localhost:4000/+notes")
      "/feed?sort=latest"
      iex> Bonfire.Classify.Web.GroupNavigation.return_to(%{}, "http://localhost:4000/group/books")
      "/groups"
      iex> Bonfire.Classify.Web.GroupNavigation.return_to(%{"group_from" => "//example.com"})
      "/groups"
  """
  def return_to(params, referer \\ nil) do
    validate(params["group_from"]) || from_referer(referer) || "/groups"
  end

  @doc """
  Carries the entry page on a child or parent link.

      iex> Bonfire.Classify.Web.GroupNavigation.link("/+notes", "/groups")
      "/+notes?group_from=%2Fgroups"
  """
  def link(path, return_to) do
    path
    |> Bonfire.Common.URIs.append_params_uri(%{"group_from" => validate(return_to) || "/groups"})
    |> URI.to_string()
  end

  defp from_referer(referer) when is_binary(referer) do
    uri = URI.parse(referer)
    params = URI.decode_query(uri.query || "")
    validate(params["group_from"]) || validate(URI.to_string(%URI{path: uri.path, query: uri.query}))
  end

  defp from_referer(_), do: nil

  defp validate(path) when is_binary(path) do
    uri = URI.parse(path)
    decoded = URI.decode(path)

    if String.starts_with?(path, "/") and not String.starts_with?(decoded, "//") and
         not String.contains?(decoded, ["\\", "\r", "\n"]) and is_nil(uri.host) and
         is_nil(uri.scheme) and
         not String.starts_with?(URI.decode(uri.path || ""), ["/group/", "/&", "/+", "/topic/"]) do
      path
    end
  end

  defp validate(_), do: nil
end
