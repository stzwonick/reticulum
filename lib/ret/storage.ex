defmodule Ret.Storage do
  require Logger

  @expiring_file_path "expiring"
  @owned_file_path "owned"

  alias Ret.{OwnedFile, Repo, Account}

  def store(path, content_type, key, promotion_token \\ nil)

  # Given a Plug.Upload, a content-type, and an optional encryption key, returns an id
  # that can be used to fetch a stream to the uploaded file after this call.
  def store(%Plug.Upload{path: path}, content_type, key, promotion_token) do
    store(path, content_type, key, promotion_token)
  end

  # Given a path to a file, a content-type, and an optional encryption key, returns an id
  # that can be used to fetch a stream to the uploaded file after this call.
  def store(path, content_type, key, promotion_token) do
    with storage_path when is_binary(storage_path) <- module_config(:storage_path) do
      {:ok, %{size: content_length}} = File.stat(path)
      uuid = Ecto.UUID.generate()

      [file_path, meta_file_path, blob_file_path] = paths_for_uuid(uuid, @expiring_file_path)
      File.mkdir_p!(file_path)

      case write_blob_file(path, blob_file_path, key) do
        :ok ->
          meta = %{
            content_type: content_type,
            content_length: content_length,
            promotion_token: promotion_token
          }

          meta_file_path |> File.write!(Poison.encode!(meta))

          {:ok, uuid}

        {:error, _reason} = err ->
          err
      end
    else
      _ -> {:error, :not_allowed}
    end
  end

  def fetch(id, key) when is_binary(id) and is_binary(key) do
    fetch_blob(id, key, @expiring_file_path)
  end

  def fetch(%OwnedFile{owned_file_uuid: id, key: key}) do
    fetch_blob(id, key, @owned_file_path)
  end

  defp fetch_blob(id, key, subpath) do
    with storage_path when is_binary(storage_path) <- module_config(:storage_path),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         [_file_path, meta_file_path, blob_file_path] <- paths_for_uuid(uuid, subpath),
         [{:ok, _}, {:ok, _}] <- [File.stat(meta_file_path), File.stat(blob_file_path)],
         meta <- File.read!(meta_file_path) |> Poison.decode!(),
         {:ok, stream} <- read_blob_file(blob_file_path, meta, key) do
      {:ok, meta, stream}
    else
      {:error, :invalid_key} -> {:error, :not_allowed}
      _ -> {:error, :not_allowed}
    end
  end

  def promote(nil, _key, _promotion_token, _account) do
    {:error, :not_found}
  end

  def promote(_id, nil, _promotion_token, _account) do
    {:error, :not_allowed}
  end

  # Promotes an expiring stored file to a permanently stored file in the specified Account.
  def promote(id, key, promotion_token, %Account{} = account) do
    # Check if this file has already been promoted
    OwnedFile
    |> Repo.get_by(owned_file_uuid: id)
    |> promote_or_return_owned_file(id, key, promotion_token, account)
  end

  # Promotes multiple files into the given account.
  #
  # Given a map that has { id, key } or { id, key, promotion_token} tuple values, returns a similarly-keyed map
  # that has the return values of promote as values.
  def promote(map, %Account{} = account) when is_map(map) do
    map
    |> Enum.map(fn
      {k, {id, key}} -> {k, promote(id, key, nil, account)}
      {k, {id, key, promotion_token}} -> {k, promote(id, key, promotion_token, account)}
    end)
    |> Enum.into(%{})
  end

  defp promote_or_return_owned_file(%OwnedFile{} = owned_file, _id, _key, _promotion_token, _account) do
    {:ok, owned_file}
  end

  # Promoting a stored file to being owned has two side effects: the file is moved
  # into the owned files directory (which prevents it from being vacuumed) and an
  # OwnedFile record is inserted into the database which includes the decryption key.
  # If the stored file has an associated promotion token, the given promotion token is verified against it.
  # If the given promotion token fails verification, the file is not promoted.
  defp promote_or_return_owned_file(nil, id, key, promotion_token, account) do
    with(
      storage_path when is_binary(storage_path) <- module_config(:storage_path),
      {:ok, uuid} <- Ecto.UUID.cast(id),
      [_, meta_file_path, blob_file_path] <- paths_for_uuid(uuid, @expiring_file_path),
      [dest_path, dest_meta_file_path, dest_blob_file_path] <- paths_for_uuid(uuid, @owned_file_path),
      [{:ok, _}, {:ok, _}] <- [File.stat(meta_file_path), File.stat(blob_file_path)],
      %{"content_type" => content_type, "content_length" => content_length, "promotion_token" => actual_promotion_token} <-
        File.read!(meta_file_path) |> Poison.decode!(),
      {:ok} <- check_promotion_token(actual_promotion_token, promotion_token),
      {:ok} <- check_blob_file_key(blob_file_path, key)
    ) do
      owned_file_params = %{
        owned_file_uuid: id,
        key: key,
        content_type: content_type,
        content_length: content_length
      }

      owned_file =
        %OwnedFile{}
        |> OwnedFile.changeset(account, owned_file_params)
        |> Repo.insert!()

      File.mkdir_p!(dest_path)
      File.rename(meta_file_path, dest_meta_file_path)
      File.rename(blob_file_path, dest_blob_file_path)

      {:ok, owned_file}
    else
      {:error, :invalid_key} -> {:error, :not_allowed}
      _ -> {:error, :not_found}
    end
  end

  # If an owned file does not have a promotion token associated with it, it can be promoted with any given 
  # promotion token, including nil.
  defp check_promotion_token(nil, _token), do: {:ok}
  defp check_promotion_token(actual_token, token) when actual_token == token, do: {:ok}
  defp check_promotion_token(actual_token, token) when actual_token != token, do: {:error, :invalid_key}

  # Vacuums up TTLed out files
  def vacuum do
    Logger.info("Stored Files: Beginning Vacuum.")

    with storage_path when is_binary(storage_path) <- module_config(:storage_path),
         ttl when is_integer(ttl) <- module_config(:ttl) do
      process_blob = fn blob_file, _acc ->
        {:ok, %{atime: atime}} = File.stat(blob_file)

        now = DateTime.utc_now()
        atime_datetime = atime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")
        seconds_since_access = DateTime.diff(now, atime_datetime)

        if seconds_since_access > ttl do
          Logger.info("Stored Files: Removing #{blob_file} after #{seconds_since_access}s since last access.")

          File.rm!(blob_file)
          File.rm(blob_file |> String.replace_suffix(".blob", ".meta.json"))
        end
      end

      :filelib.fold_files(
        "#{storage_path}/#{@expiring_file_path}",
        "\\.blob$",
        true,
        process_blob,
        nil
      )

      # TODO clean empty dirs
    end

    Logger.info("Stored Files: Vacuum Finished.")
  end

  def demote_inactive_owned_files do
    inactive_owned_files = OwnedFile.inactive()

    inactive_owned_files
    |> Enum.map(& &1.owned_file_uuid)
    |> Enum.each(&move_file_to_expiring_storage/1)

    inactive_owned_files
    |> Enum.each(&Repo.delete/1)
  end

  defp move_file_to_expiring_storage(uuid) do
    with(
      [_, meta_file_path, blob_file_path] <- paths_for_uuid(uuid, @owned_file_path),
      [dest_path, dest_meta_file_path, dest_blob_file_path] <- paths_for_uuid(uuid, @expiring_file_path)
    ) do
      File.mkdir_p!(dest_path)
      File.rename(meta_file_path, dest_meta_file_path)
      File.rename(blob_file_path, dest_blob_file_path)
    end
  end

  def uri_for(id, content_type, token \\ nil) do
    file_host = Application.get_env(:ret, Ret.Storage)[:host] || RetWeb.Endpoint.url()
    ext = MIME.extensions(content_type) |> List.first()
    filename = [id, ext] |> Enum.reject(&is_nil/1) |> Enum.join(".")

    "#{file_host}/files/#{filename}#{
      if token do
        "?" <> URI.encode_query(token: token)
      else
        ""
      end
    }"
    |> URI.parse()
  end

  defp check_blob_file_key(_source_path, nil) do
    {:error, :invalid_key}
  end

  defp check_blob_file_key(source_path, key) do
    Ret.Crypto.stream_check_key(source_path, key |> Ret.Crypto.hash())
  end

  defp read_blob_file(source_path, _meta, key) do
    Ret.Crypto.stream_decrypt_file(source_path, key |> Ret.Crypto.hash())
  end

  defp write_blob_file(source_path, destination_path, key) do
    Ret.Crypto.encrypt_file(source_path, destination_path, key |> Ret.Crypto.hash())
  end

  defp module_config(key) do
    Application.get_env(:ret, __MODULE__)[key]
  end

  defp paths_for_uuid(uuid, subpath) do
    path = "#{module_config(:storage_path)}/#{subpath}/#{String.slice(uuid, 0, 2)}/#{String.slice(uuid, 2, 2)}"

    blob_file_path = "#{path}/#{uuid}.blob"
    meta_file_path = "#{path}/#{uuid}.meta.json"

    [path, meta_file_path, blob_file_path]
  end
end
