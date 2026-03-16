defmodule Hl7toagent.ConfigLoaderTest do
  use ExUnit.Case, async: true

  alias Hl7toagent.ConfigLoader

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "hl7toagent_config_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  defp write_config(dir, lua_source) do
    path = Path.join(dir, "config.lua")
    File.write!(path, lua_source)
    path
  end

  describe "load_config!/2 channels" do
    test "parses a file_watcher channel", %{tmp_dir: dir} do
      path = write_config(dir, ~S"""
      channel("inbox", {
        source = file_watcher({ dir = "./inbox", pattern = "*.hl7" }),
        soul = "souls/triage.md",
        skills = { "skills/logger.lua" }
      })
      """)

      {channels, crons} = ConfigLoader.load_config!(path, dir)

      assert length(channels) == 1
      assert crons == []

      ch = hd(channels)
      assert ch.name == "inbox"
      assert ch.soul == Path.join(dir, "souls/triage.md")
      assert ch.skills == [Path.join(dir, "skills/logger.lua")]
      assert {:file_watcher, %{dir: _, pattern: "*.hl7"}} = ch.source
    end

    test "parses an mllp channel", %{tmp_dir: dir} do
      path = write_config(dir, ~S"""
      channel("hl7_receiver", {
        source = mllp({ port = 4567 }),
        soul = "souls/hl7.md",
        skills = { "skills/a.lua", "skills/b.lua" }
      })
      """)

      {[ch], []} = ConfigLoader.load_config!(path, dir)
      assert ch.name == "hl7_receiver"
      assert ch.source == {:mllp, %{port: 4567}}
      assert length(ch.skills) == 2
    end

    test "parses an http channel", %{tmp_dir: dir} do
      path = write_config(dir, ~S"""
      channel("webhook", {
        source = http({ port = 8080, path = "/hook" }),
        soul = "souls/webhook.md",
        skills = {}
      })
      """)

      {[ch], []} = ConfigLoader.load_config!(path, dir)
      assert ch.name == "webhook"
      assert ch.source == {:http, %{port: 8080, path: "/hook"}}
    end

    test "parses an imap channel with defaults", %{tmp_dir: dir} do
      path = write_config(dir, ~S"""
      channel("email", {
        source = imap({
          host = "imap.example.com",
          username = "user",
          password = "pass"
        }),
        soul = "souls/email.md",
        skills = {}
      })
      """)

      {[ch], []} = ConfigLoader.load_config!(path, dir)
      assert ch.name == "email"
      assert {:imap, imap} = ch.source
      assert imap.host == "imap.example.com"
      assert imap.port == 993
      assert imap.mailbox == "INBOX"
      assert imap.ssl == true
      assert imap.poll_interval == 30
      assert imap.mark_read == true
      assert imap.search == "UNSEEN"
    end

    test "parses multiple channels in order", %{tmp_dir: dir} do
      path = write_config(dir, ~S"""
      channel("first", {
        source = http({ port = 8001, path = "/" }),
        soul = "souls/a.md",
        skills = {}
      })
      channel("second", {
        source = http({ port = 8002, path = "/" }),
        soul = "souls/b.md",
        skills = {}
      })
      """)

      {channels, []} = ConfigLoader.load_config!(path, dir)
      assert length(channels) == 2
      assert Enum.map(channels, & &1.name) == ["first", "second"]
    end

    test "resolves builtin skills without prepending project dir", %{tmp_dir: dir} do
      path = write_config(dir, ~S"""
      channel("ch", {
        source = http({ port = 8080, path = "/" }),
        soul = "souls/s.md",
        skills = { "builtin:log", "skills/custom.lua" }
      })
      """)

      {[ch], []} = ConfigLoader.load_config!(path, dir)
      assert "builtin:log" in ch.skills
      assert Path.join(dir, "skills/custom.lua") in ch.skills
    end

    test "preserves model field", %{tmp_dir: dir} do
      path = write_config(dir, ~S"""
      channel("ch", {
        source = http({ port = 8080, path = "/" }),
        soul = "souls/s.md",
        skills = {},
        model = "openai:gpt-4o"
      })
      """)

      {[ch], []} = ConfigLoader.load_config!(path, dir)
      assert ch.model == "openai:gpt-4o"
    end
  end

  describe "load_config!/2 crons" do
    test "parses a cron job", %{tmp_dir: dir} do
      path = write_config(dir, ~S"""
      channel("target", {
        source = http({ port = 8080, path = "/" }),
        soul = "souls/s.md",
        skills = {}
      })
      cron("poller", {
        interval = 60,
        script = "skills/poll.lua",
        channel = "target"
      })
      """)

      {channels, crons} = ConfigLoader.load_config!(path, dir)
      assert length(channels) == 1
      assert length(crons) == 1

      cron = hd(crons)
      assert cron.name == "poller"
      assert cron.interval == 60
      assert cron.script == Path.join(dir, "skills/poll.lua")
      assert cron.channel == "target"
      assert cron.sandbox_dir == dir
    end
  end

  describe "load_config!/2 smtp" do
    test "stores smtp config in application env", %{tmp_dir: dir} do
      path = write_config(dir, ~S"""
      smtp({
        host = "smtp.example.com",
        port = 465,
        username = "user",
        password = "pass",
        from = "bot@example.com",
        allowed_recipients = { "alice@example.com", "bob@example.com" }
      })
      channel("ch", {
        source = http({ port = 8080, path = "/" }),
        soul = "souls/s.md",
        skills = {}
      })
      """)

      ConfigLoader.load_config!(path, dir)

      smtp = Application.get_env(:hl7toagent, :smtp)
      assert smtp[:relay] == "smtp.example.com"
      assert smtp[:port] == 465
      assert smtp[:from] == "bot@example.com"
      assert length(smtp[:allowed_recipients]) == 2
    end
  end

  describe "load_config!/2 env()" do
    test "reads environment variables in config", %{tmp_dir: dir} do
      System.put_env("HL7_TEST_PORT", "9999")

      path = write_config(dir, ~S"""
      channel("ch", {
        source = mllp({ port = tonumber(env("HL7_TEST_PORT")) }),
        soul = "souls/s.md",
        skills = {}
      })
      """)

      {[ch], []} = ConfigLoader.load_config!(path, dir)
      assert ch.source == {:mllp, %{port: 9999}}
    after
      System.delete_env("HL7_TEST_PORT")
    end
  end

  describe "load_config!/2 file_watcher replies" do
    test "parses file_watcher with replies flag", %{tmp_dir: dir} do
      path = write_config(dir, ~S"""
      channel("replies", {
        source = file_watcher({ dir = "./outbox", pattern = "*.eml", replies = true }),
        soul = "souls/s.md",
        skills = {}
      })
      """)

      {[ch], []} = ConfigLoader.load_config!(path, dir)
      assert {:file_watcher, opts} = ch.source
      assert opts.replies == true
    end
  end
end
