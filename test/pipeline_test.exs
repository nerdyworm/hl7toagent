defmodule Hl7toagent.Channel.PipelineTest do
  use ExUnit.Case, async: true

  alias Hl7toagent.Channel.Pipeline

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "hl7toagent_pipeline_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{project_dir: tmp_dir}
  end

  describe "stage/2" do
    test "moves file to processing/ and returns contents", %{project_dir: dir} do
      inbox = Path.join(dir, "inbox")
      File.mkdir_p!(inbox)
      source = Path.join(inbox, "test.hl7")
      File.write!(source, "MSH|^~\\&|")

      assert {:ok, processing_path, "MSH|^~\\&|"} = Pipeline.stage(source, dir)
      assert String.contains?(processing_path, "/processing/")
      assert String.ends_with?(processing_path, "_test.hl7")
      assert File.exists?(processing_path)
      refute File.exists?(source)
    end

    test "returns error when source file doesn't exist", %{project_dir: dir} do
      assert {:error, msg} = Pipeline.stage(Path.join(dir, "nope.txt"), dir)
      assert msg =~ "failed to read"
    end
  end

  describe "stage_data/3" do
    test "writes raw data to processing/", %{project_dir: dir} do
      assert {:ok, path} = Pipeline.stage_data("hello world", "msg.txt", dir)
      assert String.contains?(path, "/processing/")
      assert String.ends_with?(path, "_msg.txt")
      assert File.read!(path) == "hello world"
    end

    test "creates processing directory if missing", %{project_dir: dir} do
      refute File.exists?(Path.join(dir, "processing"))
      assert {:ok, _} = Pipeline.stage_data("data", "f.txt", dir)
      assert File.dir?(Path.join(dir, "processing"))
    end
  end

  describe "archive/2" do
    test "moves file from processing to archive/YYYY/MM/DD/", %{project_dir: dir} do
      {:ok, processing_path} = Pipeline.stage_data("content", "test.hl7", dir)

      assert {:ok, archive_path} = Pipeline.archive(processing_path, dir)
      assert String.contains?(archive_path, "/archive/")
      assert String.ends_with?(archive_path, Path.basename(processing_path))
      assert File.exists?(archive_path)
      refute File.exists?(processing_path)

      # Verify date-based directory structure
      {{y, m, d}, _} = :calendar.local_time()
      expected_date_path = "#{y}/#{String.pad_leading("#{m}", 2, "0")}/#{String.pad_leading("#{d}", 2, "0")}"
      assert String.contains?(archive_path, expected_date_path)
    end

    test "returns error when processing file doesn't exist", %{project_dir: dir} do
      assert {:error, _} = Pipeline.archive(Path.join(dir, "processing/nope.txt"), dir)
    end
  end

  describe "full lifecycle" do
    test "stage → archive", %{project_dir: dir} do
      # Stage raw data
      {:ok, processing_path} = Pipeline.stage_data("HL7 message", "adt.hl7", dir)
      assert File.exists?(processing_path)

      # Archive it
      {:ok, archive_path} = Pipeline.archive(processing_path, dir)
      assert File.exists?(archive_path)
      assert File.read!(archive_path) == "HL7 message"
      refute File.exists?(processing_path)
    end
  end
end
