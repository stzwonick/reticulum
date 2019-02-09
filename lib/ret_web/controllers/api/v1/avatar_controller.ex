defmodule RetWeb.Api.V1.AvatarController do
  use RetWeb, :controller

  alias Ret.{Account, Repo, Avatar, Storage, OwnedFile}

  plug(RetWeb.Plugs.RateLimit when action in [:create, :update])

  def create(conn, params) do
    create_or_update(conn, params, %Avatar{})
  end

  defp create_or_update(conn, params, avatar) do
    account = conn |> Guardian.Plug.current_resource()

    files_to_promotoe =
      params["files"]
      |> Enum.map(fn {k, v} -> {String.to_atom(k), List.to_tuple(v)} end)
      |> Enum.into(%{})

    owned_file_results = Storage.promote(files_to_promotoe, account)

    promotion_error =
      owned_file_results |> Map.values() |> Enum.filter(&(elem(&1, 0) == :error)) |> Enum.at(0)

    case promotion_error do
      nil ->
        %{
          gltf: {:ok, gltf_file},
          bin: {:ok, bin_file},
          base_map: {:ok, base_map}
        } = owned_file_results

        owned_files =
          owned_file_results |> Enum.map(fn {k, {:ok, file}} -> {k, file} end) |> Enum.into(%{})

        {result, avatar} =
          avatar
          |> Avatar.changeset(account, owned_files, params)
          |> IO.inspect()
          |> Repo.insert_or_update()

        avatar = avatar |> Repo.preload([:gltf_owned_file, :bin_owned_file])

        case result do
          :ok ->
            conn |> render("create.json", avatar: avatar)

          :error ->
            conn |> send_resp(422, "invalid avatar")
        end

      {:error, :not_found} ->
        conn |> send_resp(404, "no such file(s)")

      {:error, :not_allowed} ->
        conn |> send_resp(401, "")
    end
  end

  # TODO rename the refference images to something more reasonable
  @image_names %{
    base_map_owned_file: "Bot_PBS_BaseColor.jpg",
    emissive_map_owned_file: "Bot_PBS_Emmissive.jpg",
    normal_map_owned_file: "Bot_PBS_Normal.png",
    ao_metalic_roughness_map_owned_file: "Bot_PBS_Metallic.jpg"
  }

  @image_columns Map.keys(@image_names)

  def show(conn, %{"id" => avatar_sid}) do
    avatar =
      Avatar
      |> Repo.get_by(avatar_sid: avatar_sid)
      |> Repo.preload([:account, :gltf_owned_file, :bin_owned_file])
      |> Repo.preload(@image_columns)

    case Storage.fetch(avatar.gltf_owned_file) do
      {:ok, %{"content_type" => content_type, "content_length" => content_length}, stream} ->
        image_customizations =
          @image_columns
          |> Enum.map(fn col -> customization_for_image(col, Map.get(avatar, col)) end)
          |> Enum.reject(&is_nil/1)

        IO.inspect(image_customizations)

        customizations = [
          {["images"], image_customizations},
          # This currently works because the input is known to have been a glb, which always has a single buffer which we exttract as part of upload
          {["buffers"],
           [
             %{
               uri: avatar.bin_owned_file |> OwnedFile.uri_for() |> URI.to_string()
             }
           ]}
        ]

        gltf =
          stream
          |> Enum.join("")
          |> Poison.decode!()
          |> apply_customizations(customizations)

        conn
        # |> put_resp_content_type("model/gltf", nil)
        |> send_resp(200, gltf |> Poison.encode!())

      {:error, :not_found} ->
        conn |> send_resp(404, "")

      {:error, :not_allowed} ->
        conn |> send_resp(401, "")
    end
  end

  defp customization_for_image(_col, _owned_file = nil) do
    nil
  end

  defp customization_for_image(col, owned_file) do
    %{
      name: @image_names[col],
      uri: owned_file |> OwnedFile.uri_for() |> URI.to_string()
    }
  end

  defp apply_customizations(gltf, customization_set) do
    Enum.reduce(customization_set, gltf, &apply_customization/2)
  end

  # defp apply_customization({path = ["buffers"], replacements}, gltf) do
  #   gltf |> Kernel.put_in(path, replacements)
  # end

  defp apply_customization({path, replacements}, gltf) do
    gltf |> Kernel.update_in(path, &apply_replacement(&1, replacements))
  end

  # TODO this is currently hardcoded to match on name and always replaces the whole node. We likely will want to expand the format of a "customization" to include more details about how to match and what to do with matches
  defp apply_replacement(old_data, replacements) do
    Enum.map(old_data, fn old_value ->
      Enum.find(replacements, old_value, &(&1[:name] == old_value["name"]))
    end)
  end
end