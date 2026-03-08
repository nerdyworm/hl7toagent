defmodule Hl7toagent.Channel.Pipeline do
  @moduledoc """
  Deterministic file lifecycle: inbox → processing → archive.
  No LLM involvement in file movement.
  """

  require Logger

  @doc """
  Stage an existing file (e.g. from FileWatcher inbox) into the processing directory.
  Reads the file, moves it to processing/, returns {:ok, processing_path, contents}.
  """
  def stage(source_path, project_dir) do
    case File.read(source_path) do
      {:ok, contents} ->
        filename = Path.basename(source_path)
        processing_path = processing_dest(project_dir, filename)
        File.mkdir_p!(Path.dirname(processing_path))

        case File.rename(source_path, processing_path) do
          :ok ->
            {:ok, processing_path, contents}

          {:error, reason} ->
            {:error, "failed to stage #{source_path}: #{reason}"}
        end

      {:error, reason} ->
        {:error, "failed to read #{source_path}: #{reason}"}
    end
  end

  @doc """
  Stage raw data (e.g. from MLLP or HTTP) by writing it to the processing directory.
  Returns {:ok, processing_path}.
  """
  def stage_data(data, filename, project_dir) do
    processing_path = processing_dest(project_dir, filename)
    File.mkdir_p!(Path.dirname(processing_path))

    case File.write(processing_path, data) do
      :ok -> {:ok, processing_path}
      {:error, reason} -> {:error, "failed to write staged file: #{reason}"}
    end
  end

  @doc """
  Archive a processed file from processing/ into archive/YYYY/MM/DD/.
  """
  def archive(processing_path, project_dir) do
    filename = Path.basename(processing_path)
    {{y, m, d}, _} = :calendar.local_time()

    archive_path =
      Path.join([
        project_dir,
        "archive",
        Integer.to_string(y),
        String.pad_leading(Integer.to_string(m), 2, "0"),
        String.pad_leading(Integer.to_string(d), 2, "0"),
        filename
      ])

    File.mkdir_p!(Path.dirname(archive_path))

    case File.rename(processing_path, archive_path) do
      :ok ->
        Logger.info("Archived #{Path.basename(processing_path)} → #{Path.relative_to(archive_path, project_dir)}")
        {:ok, archive_path}

      {:error, reason} ->
        Logger.warning("Failed to archive #{processing_path}: #{reason}")
        {:error, reason}
    end
  end

  defp processing_dest(project_dir, filename) do
    ts = System.system_time(:millisecond)
    Path.join([project_dir, "processing", "#{ts}_#{filename}"])
  end
end
