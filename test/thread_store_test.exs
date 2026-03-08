defmodule Hl7toagent.Channel.ThreadStoreTest do
  use ExUnit.Case, async: false

  alias Hl7toagent.Channel.ThreadStore

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "hl7toagent_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)

    start_supervised!({ThreadStore, project_dir: tmp_dir})

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    :ok
  end

  test "create and get thread" do
    messages = [%{"role" => "system", "content" => "You are helpful."}, %{"role" => "user", "content" => "Hello"}]
    {:ok, thread_id} = ThreadStore.create_thread("test_channel", messages)

    assert is_binary(thread_id)

    {:ok, thread} = ThreadStore.get_thread(thread_id)
    assert thread.channel_name == "test_channel"
    assert thread.messages == messages
  end

  test "update thread" do
    {:ok, thread_id} = ThreadStore.create_thread("ch", [%{"role" => "user", "content" => "Hi"}])

    new_messages = [
      %{"role" => "user", "content" => "Hi"},
      %{"role" => "assistant", "content" => "Hello!"},
      %{"role" => "user", "content" => "How are you?"}
    ]

    :ok = ThreadStore.update_thread(thread_id, new_messages)

    {:ok, thread} = ThreadStore.get_thread(thread_id)
    assert length(thread.messages) == 3
  end

  test "get nonexistent thread returns error" do
    assert {:error, :not_found} = ThreadStore.get_thread("nonexistent")
  end

  test "add and find by ref" do
    {:ok, thread_id} = ThreadStore.create_thread("ch", [%{"role" => "user", "content" => "test"}])

    message_id = "<abc123@example.com>"
    :ok = ThreadStore.add_ref(thread_id, message_id)

    {:ok, found_id} = ThreadStore.find_by_ref(message_id)
    assert found_id == thread_id
  end

  test "find_by_ref returns error for unknown ref" do
    assert {:error, :not_found} = ThreadStore.find_by_ref("<unknown@example.com>")
  end

  test "multiple refs can point to same thread" do
    {:ok, thread_id} = ThreadStore.create_thread("ch", [%{"role" => "user", "content" => "test"}])

    :ok = ThreadStore.add_ref(thread_id, "<msg1@example.com>")
    :ok = ThreadStore.add_ref(thread_id, "<msg2@example.com>")

    {:ok, id1} = ThreadStore.find_by_ref("<msg1@example.com>")
    {:ok, id2} = ThreadStore.find_by_ref("<msg2@example.com>")
    assert id1 == thread_id
    assert id2 == thread_id
  end
end
