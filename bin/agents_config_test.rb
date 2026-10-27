#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Test for agents_config CLI. Runs in a throwaway temp HOME so the real
# ~/.gemini and ~/.config/opencode are never touched.
#
# Run: ruby /home/guga/agents_config/bin/agents_config_test.rb

require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "socket"
require "yaml"
require "minitest/autorun"

SCRIPT = File.expand_path("agents_config", __dir__)
load SCRIPT

class AgentsConfigTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir("agents_config_home")
    # Pre-create the tool config roots so the CLI's mkdir_p is a no-op there.
    FileUtils.mkdir_p(File.join(@home, ".gemini", "config"))
    FileUtils.mkdir_p(File.join(@home, ".config", "opencode"))
    FileUtils.mkdir_p(File.join(@home, ".cursor"))
    FileUtils.mkdir_p(File.join(@home, ".codex"))
    FileUtils.mkdir_p(File.join(@home, ".pi", "agent"))
  end

  def teardown
    FileUtils.rm_rf(@home)
  end

  def run_cli(*args)
    out = `env HOME=#{@home} ruby #{SCRIPT} #{args.join(' ')} 2>&1`
    [out, $?.success?]
  end

  def run_cli_at(script, home, *args)
    stdout, stderr, status = Open3.capture3({ "HOME" => home }, "ruby", script, *args)
    [stdout + stderr, status.success?]
  end

  def parse_frontmatter(file_path)
    content = File.read(file_path)
    if content =~ /\A# agents_config:generated\n---\n(.*?)\n---\n/m
      YAML.safe_load($1) || {}
    elsif content =~ /\A---\n(.*?)\n---\n# agents_config:generated\n/m
      YAML.safe_load($1) || {}
    else
      {}
    end
  end

  def parse_codex_toml(file_path)
    content = File.read(file_path)
    res = {}
    res[:generated] = content.start_with?("# agents_config:generated\n")
    if content =~ /^name\s*=\s*"(.*)"$/
      res[:name] = $1.gsub('\"', '"').gsub('\\\\', '\\')
    end
    if content =~ /^description\s*=\s*"(.*)"$/
      res[:description] = $1.gsub('\"', '"').gsub('\\\\', '\\')
    end
    if content =~ /developer_instructions\s*=\s*"""\n(.*?)"""\s*\z/m
      res[:developer_instructions] = $1.gsub('\"\"\"', '"""').gsub('\\\\', '\\')
    end
    res
  end

  def test_list
    out, ok = run_cli("--list")
    assert ok
    assert_includes out, "gemini"
    assert_includes out, "opencode"
    assert_includes out, "cursor"
    assert_includes out, "codex"
    assert_includes out, "pi"
    assert_includes out, File.join(@home, ".pi", "agent")
  end

  def test_gemini_install_creates_flat_generated_files_with_correct_models
    out, ok = run_cli("gemini")
    assert ok, out
    assert_match(/\+ .*\.gemini\/config\/AGENTS\.md -> /, out)
    assert_match(/~ .*\.gemini\/config\/agents\/sprinter\.md \(generated\)/, out)

    # Verify AGENTS.md symlink
    rules = File.join(@home, ".gemini", "config", "AGENTS.md")
    assert File.symlink?(rules)
    assert_equal File.join(STORE, "AGENTS.md"), File.expand_path(File.readlink(rules))

    # Verify orchestrator (Pro model, primary mode -> no subagent: true)
    orch_file = File.join(@home, ".gemini", "config", "agents", "orchestrator.md")
    assert File.file?(orch_file)
    refute File.symlink?(orch_file)
    orch_fm = parse_frontmatter(orch_file)
    assert_equal "orchestrator", orch_fm["name"]
    assert_equal "gemini-2.5-pro", orch_fm["model"]
    refute orch_fm.key?("subagent"), "orchestrator (primary mode) should not have subagent: true"

    # Verify principal (Pro model, subagent mode -> subagent: true)
    princ_file = File.join(@home, ".gemini", "config", "agents", "principal.md")
    assert File.file?(princ_file)
    princ_fm = parse_frontmatter(princ_file)
    assert_equal "principal", princ_fm["name"]
    assert_equal "gemini-2.5-pro", princ_fm["model"]
    assert_equal true, princ_fm["subagent"]

    # Verify sprinter (Flash model, subagent mode -> subagent: true)
    sprinter_file = File.join(@home, ".gemini", "config", "agents", "sprinter.md")
    assert File.file?(sprinter_file)
    sprinter_fm = parse_frontmatter(sprinter_file)
    assert_equal "sprinter", sprinter_fm["name"]
    assert_equal "gemini-2.5-flash", sprinter_fm["model"]
    assert_equal true, sprinter_fm["subagent"]

    # Verify cartographer (Flash model, subagent mode -> subagent: true)
    carto_file = File.join(@home, ".gemini", "config", "agents", "cartographer.md")
    assert File.file?(carto_file)
    carto_fm = parse_frontmatter(carto_file)
    assert_equal "cartographer", carto_fm["name"]
    assert_equal "gemini-2.5-flash", carto_fm["model"]
    assert_equal true, carto_fm["subagent"]
  end

  def test_all_gemini_agents_have_correct_model_and_subagent_attributes
    out, ok = run_cli("gemini")
    assert ok, out

    pro_agents = %w[
      orchestrator principal infra-platform
      rails-backend-watchmaker frontend-vue-watchmaker image-analyst redteam
    ]

    flash_agents = %w[
      cartographer sprinter watchmaker rails-backend frontend-vue
      qa-tester security-guardian designer docs-writer janitor
    ]

    pro_agents.each do |name|
      file = File.join(@home, ".gemini", "config", "agents", "#{name}.md")
      assert File.file?(file), "Expected #{file} to exist"
      fm = parse_frontmatter(file)
      assert_equal name, fm["name"]
      assert_equal "gemini-2.5-pro", fm["model"], "Expected #{name} to use gemini-2.5-pro"
      if name == "orchestrator"
        refute fm.key?("subagent"), "orchestrator should not have subagent: true"
      else
        assert_equal true, fm["subagent"], "#{name} should have subagent: true"
      end
    end

    flash_agents.each do |name|
      file = File.join(@home, ".gemini", "config", "agents", "#{name}.md")
      assert File.file?(file), "Expected #{file} to exist"
      fm = parse_frontmatter(file)
      assert_equal name, fm["name"]
      assert_equal "gemini-2.5-flash", fm["model"], "Expected #{name} to use gemini-2.5-flash"
      assert_equal true, fm["subagent"], "#{name} should have subagent: true"
    end
  end

  def test_cursor_install_creates_flat_generated_files_with_yaml_frontmatter
    out, ok = run_cli("cursor")
    assert ok, out
    assert_match(/\+ .*\.cursor\/AGENTS\.md -> /, out)
    assert_match(/~ .*\.cursor\/agents\/sprinter\.md \(generated\)/, out)

    # Verify AGENTS.md symlink
    rules = File.join(@home, ".cursor", "AGENTS.md")
    assert File.symlink?(rules)
    assert_equal File.join(STORE, "AGENTS.md"), File.expand_path(File.readlink(rules))

    # Verify sprinter
    sprinter_file = File.join(@home, ".cursor", "agents", "sprinter.md")
    assert File.file?(sprinter_file)
    refute File.symlink?(sprinter_file)
    sprinter_fm = parse_frontmatter(sprinter_file)
    assert_equal "sprinter", sprinter_fm["name"]
    assert_equal "Fast implementation engineer for small, direct, reviewable code changes.", sprinter_fm["description"]
    refute sprinter_fm.key?("model"), "cursor frontmatter should not include model"
    refute sprinter_fm.key?("subagent"), "cursor frontmatter should not include subagent"

    content = File.read(sprinter_file)
    assert content.start_with?("# #{GENERATED_MARKER}\n---\n")
    assert_includes content, "You are Sprinter, a fast implementation engineer."
  end

  def test_all_cursor_agents_have_name_and_description_only
    out, ok = run_cli("cursor")
    assert ok, out

    agent_files = Dir.glob(File.join(@home, ".cursor", "agents", "*.md"))
    refute_empty agent_files

    agent_files.each do |agent_path|
      assert our_generated?(agent_path), "#{agent_path} should be marked as generated"
      fm = parse_frontmatter(agent_path)
      assert fm.is_a?(Hash), "Frontmatter for #{agent_path} should be a valid Hash"
      assert fm["name"], "Frontmatter for #{agent_path} must have name"
      assert fm["description"], "Frontmatter for #{agent_path} must have description"
      refute fm.key?("model"), "#{agent_path} should not have model key"
      refute fm.key?("subagent"), "#{agent_path} should not have subagent key"
    end
  end

  def test_cursor_remove_and_prune
    run_cli("cursor")
    file = File.join(@home, ".cursor", "agents", "sprinter.md")
    rules = File.join(@home, ".cursor", "AGENTS.md")
    assert File.file?(file)
    assert File.symlink?(rules)

    out, ok = run_cli("cursor", "--remove", "--prune")
    assert ok, out
    refute File.exist?(file)
    refute File.exist?(rules)
    refute File.exist?(File.join(@home, ".cursor", "agents"))
    assert File.exist?(File.join(@home, ".cursor"))
  end

  def test_codex_install_creates_toml_files_with_correct_fields
    out, ok = run_cli("codex")
    assert ok, out
    assert_match(/\+ .*\.codex\/AGENTS\.md -> /, out)
    assert_match(/~ .*\.codex\/agents\/sprinter\.toml \(generated\)/, out)

    # Verify AGENTS.md symlink
    rules = File.join(@home, ".codex", "AGENTS.md")
    assert File.symlink?(rules)
    assert_equal File.join(STORE, "AGENTS.md"), File.expand_path(File.readlink(rules))

    # Verify sprinter
    sprinter_file = File.join(@home, ".codex", "agents", "sprinter.toml")
    assert File.file?(sprinter_file)
    refute File.symlink?(sprinter_file)
    assert our_generated?(sprinter_file)

    parsed = parse_codex_toml(sprinter_file)
    assert parsed[:generated]
    assert_equal "sprinter", parsed[:name]
    assert_equal "Fast implementation engineer for small, direct, reviewable code changes.", parsed[:description]
    assert_includes parsed[:developer_instructions], "You are Sprinter, a fast implementation engineer."
  end

  def test_all_codex_agents_have_valid_toml_structure
    out, ok = run_cli("codex")
    assert ok, out

    toml_files = Dir.glob(File.join(@home, ".codex", "agents", "*.toml"))
    refute_empty toml_files

    toml_files.each do |agent_path|
      assert our_generated?(agent_path), "#{agent_path} should be marked as generated"
      parsed = parse_codex_toml(agent_path)
      assert parsed[:generated], "#{agent_path} missing generated header"
      assert parsed[:name], "#{agent_path} missing name"
      assert parsed[:description], "#{agent_path} missing description"
      assert parsed[:developer_instructions], "#{agent_path} missing developer_instructions"
      refute_empty parsed[:developer_instructions]
    end
  end

  def test_codex_remove_and_prune
    run_cli("codex")
    file = File.join(@home, ".codex", "agents", "sprinter.toml")
    rules = File.join(@home, ".codex", "AGENTS.md")
    assert File.file?(file)
    assert File.symlink?(rules)

    out, ok = run_cli("codex", "--remove", "--prune")
    assert ok, out
    refute File.exist?(file)
    refute File.exist?(rules)
    refute File.exist?(File.join(@home, ".codex", "agents"))
    assert File.exist?(File.join(@home, ".codex"))
  end

  def test_codex_remove_does_not_touch_real_files
    dest_dir = File.join(@home, ".codex", "agents")
    FileUtils.mkdir_p(dest_dir)
    real = File.join(dest_dir, "custom.toml")
    File.write(real, 'name = "custom"')
    out, ok = run_cli("codex", "--remove")
    assert ok, out
    assert File.exist?(real)
    assert_equal 'name = "custom"', File.read(real)
  end

  def test_opencode_install_symlinks_agents_dir_and_emits_routing_config
    jsonc = File.join(@home, ".config", "opencode", "opencode.jsonc")
    File.write(jsonc, '{ "sentinel": "owner-curated-opencode-jsonc" }')
    jsonc_before = File.read(jsonc)

    out, ok = run_cli("opencode")
    assert ok, out

    agents_dir = File.join(@home, ".config", "opencode", "agents")
    assert File.symlink?(agents_dir), out
    assert File.exist?(agents_dir), out
    assert_equal AGENTS_DIR, File.expand_path(File.readlink(agents_dir))

    rules = File.join(@home, ".config", "opencode", "AGENTS.md")
    assert File.symlink?(rules), out
    assert File.exist?(rules), out
    assert_equal File.join(STORE, "AGENTS.md"), File.expand_path(File.readlink(rules))

    config_path = File.join(@home, ".config", "opencode", "opencode.json")
    assert File.file?(config_path), out
    config = JSON.parse(File.read(config_path))
    assert_equal ["agent"], config.keys,
                 "emitted opencode.json must contain ONLY the agent block"

    marker = File.join(@home, ".config", "opencode", ".opencode_routing_generated")
    assert File.file?(marker), out
    assert_equal "# #{GENERATED_MARKER}\n", File.read(marker)

    # A hand-made opencode.jsonc (never referenced by the installer) must be
    # untouched by install.
    assert_equal jsonc_before, File.read(jsonc), "opencode.jsonc must not be touched"
  end

  def test_opencode_emits_translated_models_for_every_agent_and_plan
    out, ok = run_cli("opencode")
    assert ok, out
    routing = JSON.parse(File.read(File.join(@home, ".config", "opencode", "opencode.json"))).fetch("agent")
    # Derive the expected map from the canonical store through the same
    # default-resolution transform the install path uses: the test process and
    # the CLI subprocess share hostname + committed hosts.json, so derived ==
    # emitted on any machine (no machine-dependent hardcoded ids here).
    canon = JSON.parse(File.read(OPENCODE_CONFIG)).fetch("agent")
    expected = canon.each_with_object({}) do |(name, entry), map|
      model = entry.is_a?(Hash) ? entry["model"] : nil
      map[name] = { "model" => opencode_model_id(model) } if model.is_a?(String) && !model.strip.empty?
    end
    # Built-in "plan" carries a model and routes; disable-only built-ins do not.
    assert expected.key?("plan"), "\"plan\" must carry a model in the canonical map"
    refute expected.key?("explore")
    refute expected.key?("build")
    assert_equal Dir.glob(File.join(AGENTS_DIR, "*.md")).sort.map { |p| File.basename(p, ".md") }.sort,
                 (expected.keys - ["plan"]).sort,
                 "expected model map must cover every canonical agent"
    assert_equal expected.keys.sort, routing.keys.sort,
                 "routing must contain exactly the modeled agents"
    expected.each do |name, entry|
      assert_equal entry, routing.fetch(name),
                   "wrong routing entry for #{name}: #{routing[name].inspect}"
    end
    # Disable-only built-ins carry no model and must not become routing entries.
    refute routing.key?("explore")
    refute routing.key?("build")
  end

  def test_opencode_remove_only_withdraws_routing_config
    config_dir = File.join(@home, ".config", "opencode")
    jsonc = File.join(config_dir, "opencode.jsonc")
    File.write(jsonc, '{ "sentinel": "owner-curated-opencode-jsonc" }')
    jsonc_before = File.read(jsonc)

    # (A) A normal install + --remove withdraws only the routing file + marker.
    run_cli("opencode")
    config_path = File.join(config_dir, "opencode.json")
    assert File.file?(config_path)
    assert File.symlink?(File.join(config_dir, "agents"))
    assert File.symlink?(File.join(config_dir, "AGENTS.md"))

    out, ok = run_cli("opencode", "--remove")
    assert ok, out
    refute File.exist?(config_path), "emitted opencode.json must be removed"
    refute File.exist?(File.join(config_dir, ".opencode_routing_generated")),
           "marker must be removed"
    assert_equal jsonc_before, File.read(jsonc),
                 "opencode.jsonc must survive --remove byte-identical (never referenced)"
    assert File.symlink?(File.join(config_dir, "agents")),
           "agents/ symlink must survive --remove (symlinks are never withdrawn)"
    assert File.symlink?(File.join(config_dir, "AGENTS.md")),
           "AGENTS.md symlink must survive --remove"

    # (B) Without the marker, --remove must leave opencode.json untouched.
    run_cli("opencode")
    before = File.read(config_path)
    File.delete(File.join(config_dir, ".opencode_routing_generated"))
    out, ok = run_cli("opencode", "--remove")
    assert ok, out
    assert_equal before, File.read(config_path),
                 "no marker => opencode.json is not managed by us and stays untouched"
  end

  def test_opencode_install_preserves_foreign_agents_symlink
    foreign_dir = File.join(@home, "foreign_agents")
    FileUtils.mkdir_p(foreign_dir)
    dest = File.join(@home, ".config", "opencode", "agents")
    File.symlink(foreign_dir, dest)

    out, ok = run_cli("opencode")
    assert ok, out
    assert_includes out, "foreign symlink present, not managed by us"
    assert File.symlink?(dest)
    assert_equal foreign_dir, File.expand_path(File.readlink(dest))
    # Install is per-artifact: the foreign agents/ link is left alone, the
    # remaining artifacts (AGENTS.md, routing config) still install.
    assert File.symlink?(File.join(@home, ".config", "opencode", "AGENTS.md"))
    assert File.file?(File.join(@home, ".config", "opencode", "opencode.json"))
  end

  def test_opencode_install_preserves_foreign_broken_agents_symlink
    dest = File.join(@home, ".config", "opencode", "agents")
    File.symlink("/nonexistent/foreign_agents", dest)

    out, ok = run_cli("opencode")
    assert ok, out
    assert_includes out, "foreign symlink present, not managed by us"
    assert File.symlink?(dest)
    assert_equal "/nonexistent/foreign_agents", File.readlink(dest)
  end

  def test_opencode_install_refuses_to_clobber_real_agents_dir
    dest = File.join(@home, ".config", "opencode", "agents")
    FileUtils.mkdir_p(dest)
    foreign = File.join(dest, "custom.md")
    File.write(foreign, "keep me")

    out, ok = run_cli("opencode")
    assert ok, out
    assert_includes out, "real file/dir present, not a symlink"
    assert File.directory?(dest)
    refute File.symlink?(dest), "a real agents dir is never replaced by a symlink"
    assert_equal "keep me", File.read(foreign)
  end

  def test_opencode_install_is_idempotent
    run_cli("opencode")
    config_path = File.join(@home, ".config", "opencode", "opencode.json")
    marker = File.join(@home, ".config", "opencode", ".opencode_routing_generated")
    before = File.read(config_path)
    assert before.size > 0, "opencode install should emit a routing config"

    out2, ok = run_cli("opencode") # second run
    assert ok, out2
    assert_equal before, File.read(config_path),
                 "opencode.json must stay byte-identical on idempotent re-run"
    assert File.file?(marker), "marker must survive idempotent re-run"
    refute_includes out2, "~ #{config_path}", "idempotent re-run must not rewrite the config"
    refute_includes out2, "! skip", "idempotent re-run must not warn about clobbering files"
    refute_includes out2, "not managed by us", "our own generated config is ours, not foreign"
  end

  def test_opencode_install_preserves_foreign_opencode_json
    config_path = File.join(@home, ".config", "opencode", "opencode.json")
    marker = File.join(@home, ".config", "opencode", ".opencode_routing_generated")

    # 1. Invalid JSON: must never be adopted or clobbered, no marker written.
    File.write(config_path, "{ not valid json")
    out, ok = run_cli("opencode")
    assert ok, out
    assert_includes out, "! skip #{config_path}: existing file is not managed by us"
    assert_equal "{ not valid json", File.read(config_path)
    refute opencode_config_owned?(config_path)
    refute File.exist?(marker)

    # 2. Valid JSON but foreign structure (e.g. the owner's full real config):
    #    no adoption path exists; the file bytes are preserved verbatim.
    foreign = JSON.dump("$schema" => "https://opencode.ai/config.json", "theme" => "custom")
    File.write(config_path, foreign)
    out, ok = run_cli("opencode")
    assert ok, out
    assert_includes out, "! skip #{config_path}: existing file is not managed by us"
    assert_equal foreign, File.read(config_path)
    refute opencode_config_owned?(config_path)
    refute File.exist?(marker)
    # The symlink artifacts still install (install is per-artifact, config is
    # skipped conservatively).
    assert File.symlink?(File.join(@home, ".config", "opencode", "agents"))
  end

  def test_opencode_invalid_or_missing_model_config_fails_before_symlinks_are_created
    invalid_config = File.join(@home, "invalid-opencode.json")
    File.write(invalid_config, JSON.dump("agent" => { "sprinter" => {} }))
    agents_link = File.join(@home, ".config", "opencode", "agents")
    File.symlink(AGENTS_DIR, agents_link)

    error = assert_raises(RuntimeError) { opencode_agent_routing(invalid_config) }
    assert_match(/agent\.cartographer\.model/, error.message,
                 "the first store agent missing from the agent block must be named")
    assert File.symlink?(agents_link)
    assert_equal AGENTS_DIR, File.expand_path(File.readlink(agents_link))

    assert_raises(Errno::ENOENT) { opencode_agent_routing(File.join(@home, "missing-opencode.json")) }
    assert File.symlink?(agents_link)
    assert_equal AGENTS_DIR, File.expand_path(File.readlink(agents_link))
  end

  def test_opencode_cli_invalid_routing_config_creates_no_target_paths
    cases = {
      "invalid" => "{ not json",
      "incomplete" => JSON.dump("agent" => { "sprinter" => {} }),
      "missing" => nil,
    }

    cases.each do |label, config|
      sandbox = Dir.mktmpdir("agents_config_#{label}")
      repo = File.join(sandbox, "repo")
      home = File.join(sandbox, "home")
      FileUtils.cp_r(STORE, repo)
      config_path = File.join(repo, "opencode.json")
      config.nil? ? File.delete(config_path) : File.write(config_path, config)

      out, ok = run_cli_at(File.join(repo, "bin", "agents_config"), home, "opencode")
      refute ok, "#{label} config unexpectedly succeeded: #{out}"
      refute File.exist?(File.join(home, ".config", "opencode", "agents")),
             "#{label} config created the opencode agents symlink"
      refute File.exist?(File.join(home, ".config", "opencode", "AGENTS.md")),
             "#{label} config created opencode rules"
      refute File.exist?(File.join(home, ".config", "opencode", "opencode.json")),
             "#{label} config created opencode.json"
      refute File.exist?(File.join(home, ".config", "opencode", ".opencode_routing_generated")),
             "#{label} config created the routing marker"
    ensure
      FileUtils.rm_rf(sandbox) if sandbox
    end
  end

  def test_opencode_cli_emits_canonical_ids_for_host_without_hosts_entry
    sandbox = Dir.mktmpdir("agents_config_unmapped_host")
    repo = File.join(sandbox, "repo")
    home = File.join(sandbox, "home")
    FileUtils.cp_r(STORE, repo)
    # Empty hosts map: no machine is mapped, so the emitted ids must be the
    # canonical store ids byte-identically, cloud markers included (the exact
    # regression PR #3 caused for the Mac).
    File.write(File.join(repo, "hosts.json"), JSON.dump({}))

    out, ok = run_cli_at(File.join(repo, "bin", "agents_config"), home, "opencode")
    assert ok, out
    config = JSON.parse(File.read(File.join(home, ".config", "opencode", "opencode.json")))
    assert_equal ["agent"], config.keys
    assert File.file?(File.join(home, ".config", "opencode", ".opencode_routing_generated"))
    canon = JSON.parse(File.read(File.join(repo, "opencode.json"))).fetch("agent")
    canon.each do |name, entry|
      model = entry.is_a?(Hash) ? entry["model"] : nil
      next unless model.is_a?(String) && !model.strip.empty?
      assert_equal model, config.fetch("agent").fetch(name).fetch("model"),
                   "unmapped host must get the canonical id with its cloud marker intact"
    end
  ensure
    FileUtils.rm_rf(sandbox) if sandbox
  end

  def test_opencode_cli_translates_ids_for_mapped_hostname
    sandbox = Dir.mktmpdir("agents_config_mapped_host")
    repo = File.join(sandbox, "repo")
    home = File.join(sandbox, "home")
    FileUtils.cp_r(STORE, repo)
    # Map the hostname of THIS test process: the CLI subprocess inherits it, so
    # the emitted ids must be the host-config-resolved ones.
    hostname = Socket.gethostname
    sandbox_hosts = { hostname => { "provider" => "ollama-cloud", "strip_cloud_marker" => true } }
    File.write(File.join(repo, "hosts.json"), JSON.dump(sandbox_hosts))

    out, ok = run_cli_at(File.join(repo, "bin", "agents_config"), home, "opencode")
    assert ok, out
    config = JSON.parse(File.read(File.join(home, ".config", "opencode", "opencode.json")))
    assert_equal ["agent"], config.keys
    assert File.file?(File.join(home, ".config", "opencode", ".opencode_routing_generated"))
    canon = JSON.parse(File.read(File.join(repo, "opencode.json"))).fetch("agent")
    host_config = hosts_config_for(hostname, sandbox_hosts)
    canon.each do |name, entry|
      model = entry.is_a?(Hash) ? entry["model"] : nil
      next unless model.is_a?(String) && !model.strip.empty?
      expected = opencode_model_id(model, host_config)
      assert_equal expected, config.fetch("agent").fetch(name).fetch("model"),
                   "mapped host #{hostname.inspect} must get translated ids"
      assert expected.start_with?("ollama-cloud/"),
             "provider swap must be observable in the emitted id"
    end
  ensure
    FileUtils.rm_rf(sandbox) if sandbox
  end

  def test_pi_install_generates_frontmatter_first_agents_with_opencode_models
    out, ok = run_cli("pi")
    assert ok, out
    agents_dir = File.join(@home, ".pi", "agent", "agents")
    assert File.directory?(agents_dir)
    refute File.symlink?(agents_dir)
    assert_equal "# #{GENERATED_MARKER}\n", File.read(File.join(agents_dir, PI_AGENTS_DIR_MARKER))
    rules = File.join(@home, ".pi", "agent", "AGENTS.md")
    assert File.symlink?(rules)
    assert File.exist?(rules)
    assert_equal File.join(STORE, "AGENTS.md"), File.expand_path(File.readlink(rules))
    pi_models = JSON.parse(File.read(File.join(@home, ".pi", "agent", "models.json")))
    ollama = pi_models.fetch("providers").fetch("ollama")
    assert_equal "http://localhost:11434/v1", ollama.fetch("baseUrl")
    assert_equal "openai-completions", ollama.fetch("api")
    assert_equal "ollama", ollama.fetch("apiKey")
    agent_cfg = JSON.parse(File.read(File.join(STORE, "opencode.json"))).fetch("agent")
    expected_ids = Dir.glob(File.join(AGENTS_DIR, "*.md")).sort.map do |path|
      name = File.basename(path, ".md")
      agent_cfg.fetch(name).fetch("model").split("/", 2).fetch(1)
    end.uniq.sort
    assert_equal expected_ids,
                 ollama.fetch("models").map { |model| model.fetch("id") }.sort
    assert File.file?(File.join(@home, ".pi", "agent", PI_MODELS_MARKER))
    expected_models = JSON.parse(File.read(File.join(STORE, "opencode.json"))).fetch("agent")
    Dir.glob(File.join(agents_dir, "*.md")).sort.each do |agent_path|
      content = File.read(agent_path)
      assert content.start_with?("---\n"), "Pi must see frontmatter first in #{agent_path}"
      frontmatter = parse_frontmatter(agent_path)
      name = File.basename(agent_path, ".md")
      assert_equal name, frontmatter["name"]
      assert_equal expected_models.fetch(name).fetch("model"), frontmatter["model"]
      assert_includes content, "# #{GENERATED_MARKER}\n"
    end
  end

  def test_pi_install_adopts_and_regenerates_legacy_models_json
    models_path = File.join(@home, ".pi", "agent", "models.json")
    marker_path = File.join(@home, ".pi", "agent", PI_MODELS_MARKER)
    legacy_content = JSON.pretty_generate(
      "providers" => {
        "ollama" => {
          "models" => [{ "id" => "kimi-k2.7-code:cloud" }]
        }
      }
    )
    File.write(models_path, legacy_content)
    refute pi_models_owned?(models_path)
    refute File.exist?(marker_path)

    out, ok = run_cli("pi")
    assert ok, out
    assert_includes out, "~ #{models_path} (adopted legacy Pi models, regenerated)"
    assert pi_models_owned?(models_path)
    assert File.file?(marker_path)

    regenerated = JSON.parse(File.read(models_path))
    model_ids = regenerated.fetch("providers").fetch("ollama").fetch("models").map { |m| m.fetch("id") }.sort
    # Derive from the checked-in opencode.json (same precedent as the
    # frontmatter-first pi test) so this does not rot on config bumps.
    agent_cfg = JSON.parse(File.read(File.join(STORE, "opencode.json"))).fetch("agent")
    expected_ids = Dir.glob(File.join(AGENTS_DIR, "*.md")).sort.map do |path|
      name = File.basename(path, ".md")
      agent_cfg.fetch(name).fetch("model").split("/", 2).fetch(1)
    end.uniq.sort
    assert_equal expected_ids, model_ids
  end

  def test_pi_install_preserves_foreign_or_invalid_models_json
    models_path = File.join(@home, ".pi", "agent", "models.json")
    marker_path = File.join(@home, ".pi", "agent", PI_MODELS_MARKER)

    # 1. Invalid JSON
    File.write(models_path, "{ not valid json")
    out, ok = run_cli("pi")
    assert ok, out
    assert_includes out, "! skip #{models_path}: existing file is not managed by us"
    assert_equal "{ not valid json", File.read(models_path)
    refute pi_models_owned?(models_path)
    refute File.exist?(marker_path)

    # 2. Valid JSON but missing providers key
    File.write(models_path, JSON.dump("not_providers" => "something"))
    out, ok = run_cli("pi")
    assert ok, out
    assert_includes out, "! skip #{models_path}: existing file is not managed by us"
    assert_equal JSON.dump("not_providers" => "something"), File.read(models_path)
    refute pi_models_owned?(models_path)
    refute File.exist?(marker_path)

    # 3. Valid JSON but providers is not a Hash
    File.write(models_path, JSON.dump("providers" => ["not", "a", "hash"]))
    out, ok = run_cli("pi")
    assert ok, out
    assert_includes out, "! skip #{models_path}: existing file is not managed by us"
    assert_equal JSON.dump("providers" => ["not", "a", "hash"]), File.read(models_path)
    refute pi_models_owned?(models_path)
    refute File.exist?(marker_path)
  end

  def test_pi_remove_and_prune
    run_cli("pi")
    root = File.join(@home, ".pi", "agent")
    assert File.directory?(File.join(root, "agents"))
    assert File.symlink?(File.join(root, "AGENTS.md"))

    out, ok = run_cli("pi", "--remove", "--prune")
    assert ok, out
    refute File.exist?(File.join(root, "agents"))
    refute File.exist?(File.join(root, "AGENTS.md"))
    assert File.exist?(root)
  end

  def test_install_preserves_foreign_valid_agents_dir_symlink
    foreign_dir = File.join(@home, "foreign_agents")
    FileUtils.mkdir_p(foreign_dir)
    dest = File.join(@home, ".pi", "agent", "agents")
    File.symlink(foreign_dir, dest)

    out, ok = run_cli("pi")
    assert ok, out
    assert_includes out, "foreign symlink present, not managed by us"
    assert File.symlink?(dest)
    assert_equal foreign_dir, File.expand_path(File.readlink(dest))
  end

  def test_pi_install_preserves_foreign_real_agents_dir
    dest = File.join(@home, ".pi", "agent", "agents")
    FileUtils.mkdir_p(dest)
    foreign = File.join(dest, "custom.md")
    File.write(foreign, "do not touch")

    out, ok = run_cli("pi")
    assert ok, out
    assert_includes out, "real directory present, not managed by us"
    assert_equal "do not touch", File.read(foreign)
    refute File.exist?(File.join(dest, PI_AGENTS_DIR_MARKER))
  end

  def test_pi_invalid_or_missing_model_config_fails_before_legacy_link_is_replaced
    invalid_config = File.join(@home, "invalid-opencode.json")
    File.write(invalid_config, JSON.dump("agent" => { "sprinter" => {} }))
    legacy_dir = File.join(@home, ".pi", "agent", "agents")
    File.symlink(AGENTS_DIR, legacy_dir)

    error = assert_raises(RuntimeError) { pi_agent_models(invalid_config) }
    assert_match(/agent\.cartographer\.model/, error.message)
    assert File.symlink?(legacy_dir)
    assert_equal AGENTS_DIR, File.expand_path(File.readlink(legacy_dir))

    assert_raises(Errno::ENOENT) { pi_agent_models(File.join(@home, "missing-opencode.json")) }
    assert File.symlink?(legacy_dir)
    assert_equal AGENTS_DIR, File.expand_path(File.readlink(legacy_dir))
  end

  def test_pi_cli_invalid_model_config_creates_no_target_paths
    cases = {
      "invalid" => "{ not json",
      "incomplete" => JSON.dump("agent" => { "sprinter" => {} }),
      "missing" => nil,
    }

    cases.each do |label, config|
      sandbox = Dir.mktmpdir("agents_config_#{label}")
      repo = File.join(sandbox, "repo")
      home = File.join(sandbox, "home")
      FileUtils.cp_r(STORE, repo)
      config_path = File.join(repo, "opencode.json")
      config.nil? ? File.delete(config_path) : File.write(config_path, config)

      out, ok = run_cli_at(File.join(repo, "bin", "agents_config"), home, "pi")
      refute ok, "#{label} config unexpectedly succeeded: #{out}"
      refute File.exist?(File.join(home, ".pi")), "#{label} config created ~/.pi"
      refute File.exist?(File.join(home, ".pi", "agent")), "#{label} config created Pi root"
      refute File.exist?(File.join(home, ".pi", "agent", "agents")), "#{label} config created Pi agents"
      refute File.exist?(File.join(home, ".pi", "agent", "AGENTS.md")), "#{label} config created Pi rules"
    ensure
      FileUtils.rm_rf(sandbox) if sandbox
    end
  end

  def test_pi_migrates_installer_owned_legacy_agents_symlink
    legacy_dir = File.join(@home, ".pi", "agent", "agents")
    File.symlink(AGENTS_DIR, legacy_dir)

    out, ok = run_cli("pi")
    assert ok, out
    assert_includes out, "old Pi layout"
    assert File.directory?(legacy_dir)
    refute File.symlink?(legacy_dir)
    assert File.file?(File.join(legacy_dir, "sprinter.md"))
  end

  def test_install_preserves_foreign_broken_agents_dir_symlink
    dest = File.join(@home, ".pi", "agent", "agents")
    File.symlink("/nonexistent/foreign_agents", dest)

    out, ok = run_cli("pi")
    assert ok, out
    assert_includes out, "foreign symlink present, not managed by us"
    assert File.symlink?(dest)
    assert_equal "/nonexistent/foreign_agents", File.readlink(dest)
  end

  def test_install_is_idempotent
    run_cli("gemini")
    out2, ok = run_cli("gemini") # second run
    assert ok
    file = File.join(@home, ".gemini", "config", "agents", "sprinter.md")
    assert File.file?(file)
    assert_equal "gemini-2.5-flash", parse_frontmatter(file)["model"]
  end

  def test_install_replaces_wrong_symlink
    # Pre-place a wrong symlink at the dest.
    wrong = File.join(@home, "wrong_target.md")
    FileUtils.touch(wrong)
    dest = File.join(@home, ".gemini", "config", "agents", "sprinter.md")
    FileUtils.mkdir_p(File.dirname(dest))
    File.symlink(wrong, dest)
    out, ok = run_cli("gemini")
    assert ok, out
    refute File.symlink?(dest)
    assert File.file?(dest)
    assert_equal "gemini-2.5-flash", parse_frontmatter(dest)["model"]
  end

  def test_install_replaces_broken_symlink
    dest = File.join(@home, ".gemini", "config", "agents", "sprinter.md")
    FileUtils.mkdir_p(File.dirname(dest))
    File.symlink("/nonexistent/does/not/exist", dest)
    out, ok = run_cli("gemini")
    assert ok, out
    refute File.symlink?(dest)
    assert File.file?(dest)
    assert_equal "gemini-2.5-flash", parse_frontmatter(dest)["model"]
  end

  def test_install_refuses_to_clobber_real_file
    dest_dir = File.join(@home, ".gemini", "config", "agents")
    FileUtils.mkdir_p(dest_dir)
    real = File.join(dest_dir, "sprinter.md")
    File.write(real, "hand-written, do not touch")
    out, ok = run_cli("gemini")
    # Script exits 0 overall (it skips, doesn't hard-fail), but warns.
    assert_includes out, "skip"
    # The real file is untouched.
    assert_equal "hand-written, do not touch", File.read(real)
    refute File.symlink?(real)
  end

  def test_remove_deletes_only_our_generated_files
    run_cli("gemini")
    file = File.join(@home, ".gemini", "config", "agents", "sprinter.md")
    assert File.file?(file)
    out, ok = run_cli("gemini", "--remove")
    assert ok, out
    refute File.exist?(file)
  end

  def test_remove_prune_cleans_empty_dirs
    run_cli("gemini")
    out, ok = run_cli("gemini", "--remove", "--prune")
    assert ok, out
    refute File.exist?(File.join(@home, ".gemini", "config", "agents"))
    # config_root itself survives
    assert File.exist?(File.join(@home, ".gemini", "config"))
  end

  def test_remove_does_not_touch_real_files
    dest_dir = File.join(@home, ".gemini", "config", "agents")
    FileUtils.mkdir_p(dest_dir)
    real = File.join(dest_dir, "sprinter.md")
    File.write(real, "keep me")
    out, ok = run_cli("gemini", "--remove")
    assert ok, out
    assert File.exist?(real)
    assert_equal "keep me", File.read(real)
  end

  def test_migrate_old_gemini_layout_cleans_folders_and_creates_flat_files
    # Setup legacy layout: .gemini/config/agents/<name>/agent.md pointing into STORE
    %w[sprinter cartographer orchestrator].each do |name|
      old_dir = File.join(@home, ".gemini", "config", "agents", name)
      FileUtils.mkdir_p(old_dir)
      old_symlink = File.join(old_dir, "agent.md")
      File.symlink(File.join(STORE, "agents", "#{name}.md"), old_symlink)
    end

    out, ok = run_cli("gemini")
    assert ok, out

    # Verify old directories and agent.md symlinks are removed
    %w[sprinter cartographer orchestrator].each do |name|
      old_dir = File.join(@home, ".gemini", "config", "agents", name)
      old_symlink = File.join(old_dir, "agent.md")
      refute File.exist?(old_symlink), "Old symlink #{old_symlink} should have been removed"
      refute File.exist?(old_dir), "Old directory #{old_dir} should have been pruned"

      # Verify new flat file exists and is valid
      new_file = File.join(@home, ".gemini", "config", "agents", "#{name}.md")
      assert File.file?(new_file), "New flat file #{new_file} should exist"
      fm = parse_frontmatter(new_file)
      assert_equal name, fm["name"]
    end
  end

  def test_description_with_special_characters_generates_valid_yaml
    out, ok = run_cli("gemini")
    assert ok, out

    agent_files = Dir.glob(File.join(@home, ".gemini", "config", "agents", "*.md"))
    refute_empty agent_files

    agent_files.each do |agent_path|
      content = File.read(agent_path)
      match = content.match(/\A# agents_config:generated\n---\n(.*?)\n---\n/m)
      assert match, "#{agent_path} should match generated layout"
      fm = YAML.safe_load(match[1])
      assert fm.is_a?(Hash), "Frontmatter for #{agent_path} should be a valid Hash"
      assert fm["name"], "Frontmatter for #{agent_path} must have name"
      assert fm["description"], "Frontmatter for #{agent_path} must have description"
      assert fm["model"], "Frontmatter for #{agent_path} must have model"
    end
  end

  def test_render_generated_agent_escapes_colons_and_quotes
    custom_src = File.join(@home, "custom_agent.md")
    custom_desc = %q(Tricky description: with colons, 'single' and "double" quotes, and symbols: @ # & *)
    File.write(custom_src, <<~MD)
      ---
      description: #{custom_desc.inspect}
      mode: subagent
      ---
      Prompt body.
    MD
    rendered = render_generated_agent(custom_src, "custom_agent")
    assert rendered.start_with?("# #{GENERATED_MARKER}\n---\n")
    match = rendered.match(/\A# #{GENERATED_MARKER}\n---\n(.*?)\n---\n(.*)\z/m)
    assert match
    fm = YAML.safe_load(match[1])
    assert_equal "custom_agent", fm["name"]
    assert_equal custom_desc, fm["description"]
    assert_equal "gemini-2.5-flash", fm["model"]
    assert_equal true, fm["subagent"]
    assert_includes match[2], "Prompt body."
  end

  def test_render_generated_agent_for_cursor_and_codex_with_escapes
    custom_src = File.join(@home, "custom_complex.md")
    custom_desc = 'Tricky "description" with \backslashes\ and colons: yes'
    custom_body = "Prompt with \"quotes\", \\d+ regex,\n\"\"\"\ntriple quotes\n\"\"\"\nand trailing quote \"\n"
    File.write(custom_src, <<~MD)
      #{YAML.dump({ "description" => custom_desc })}---
      #{custom_body}
    MD

    # Cursor
    cursor_rendered = render_generated_agent(custom_src, "custom_complex", format: :cursor)
    assert cursor_rendered.start_with?("# #{GENERATED_MARKER}\n---\n")
    match_c = cursor_rendered.match(/\A# #{GENERATED_MARKER}\n---\n(.*?)\n---\n(.*)\z/m)
    assert match_c
    cursor_fm = YAML.safe_load(match_c[1])
    assert_equal "custom_complex", cursor_fm["name"]
    assert_equal custom_desc, cursor_fm["description"]
    refute cursor_fm.key?("model")
    assert_includes match_c[2], custom_body

    # Codex
    codex_rendered = render_generated_agent(custom_src, "custom_complex", format: :codex)
    assert codex_rendered.start_with?("# #{GENERATED_MARKER}\n")
    assert_includes codex_rendered, 'name = "custom_complex"'
    assert_includes codex_rendered, 'description = "Tricky \\"description\\" with \\\\backslashes\\\\ and colons: yes"'
    assert_includes codex_rendered, 'developer_instructions = """'
    assert_includes codex_rendered, '\"\"\"'
    assert_includes codex_rendered, '\\\\d+'
  end

  def test_opencode_model_id_translation
    hosts = { "vectra-server" => { "provider" => "ollama-cloud", "strip_cloud_marker" => true } }
    # Ticket-pinned examples from opencode.json, resolved for a mapped host.
    assert_equal "ollama-cloud/deepseek-v4.1-flash:1017", opencode_model_id("ollama/deepseek-v4.1-flash:1017-cloud", nil, hosts: hosts, hostname: "vectra-server")
    assert_equal "ollama-cloud/glm-5.3-flash", opencode_model_id("ollama/glm-5.3-flash:cloud", nil, hosts: hosts, hostname: "vectra-server")
    assert_equal "ollama-cloud/glm-5.3", opencode_model_id("ollama/glm-5.3:cloud", nil, hosts: hosts, hostname: "vectra-server")
    assert_equal "ollama-cloud/kimi-k3", opencode_model_id("ollama/kimi-k3:cloud", nil, hosts: hosts, hostname: "vectra-server")
    assert_equal "ollama-cloud/mistral-large-4", opencode_model_id("ollama/mistral-large-4:cloud", nil, hosts: hosts, hostname: "vectra-server")
    # Ids without a trailing cloud marker keep their id under the swapped provider.
    assert_equal "ollama-cloud/qwen3:32b", opencode_model_id("ollama/qwen3:32b", nil, hosts: hosts, hostname: "vectra-server")

    # Fail-fast on malformed input, regardless of host config.
    assert_raises(ArgumentError, "missing provider prefix must raise") { opencode_model_id("deepseek-v4.1-flash:1017-cloud") }
    assert_raises(ArgumentError, "empty id must raise") { opencode_model_id("ollama/") }
    assert_raises(ArgumentError, "empty input must raise") { opencode_model_id("") }
  end

  def test_opencode_model_id_passthrough_for_hosts_without_entries
    cloud = "ollama/deepseek-v4.1-flash:1017-cloud"
    # Hostname absent from a provided map: canonical id byte-identical, marker kept.
    assert_equal cloud, opencode_model_id(cloud, nil, hosts: {}, hostname: "some-mac")
    # Hostname absent from the real committed hosts.json: same passthrough.
    assert_equal cloud, opencode_model_id(cloud, nil, hostname: "no-such-host-in-the-map")
    # A mapped host without strip flag keeps the marker but swaps the provider.
    hosts = { "other-server" => { "provider" => "ollama-cloud" } }
    assert_equal "ollama-cloud/deepseek-v4.1-flash:1017-cloud", opencode_model_id(cloud, nil, hosts: hosts, hostname: "other-server")
  end

  def test_load_hosts_config_failsafe_on_missing_or_invalid_file
    Dir.mktmpdir do |dir|
      capture_io do
        # Missing file.
        assert_nil load_hosts_config(File.join(dir, "missing_hosts.json"))
        # Invalid JSON.
        File.write(File.join(dir, "hosts.json"), "{ nope")
        assert_nil load_hosts_config(File.join(dir, "hosts.json"))
        # Valid JSON that is not an object.
        File.write(File.join(dir, "hosts.json"), "[1, 2]")
        assert_nil load_hosts_config(File.join(dir, "hosts.json"))
      end
    end

    hosts = { "vectra-server" => { "provider" => "ollama-cloud", "strip_cloud_marker" => true } }
    assert_equal hosts, load_hosts_config(HOSTS_FILE)
  end

  def test_hosts_config_for_resolves_entries_and_defaults_to_passthrough
    hosts = { "vectra-server" => { "provider" => "ollama-cloud", "strip_cloud_marker" => true } }
    assert_equal hosts["vectra-server"], hosts_config_for("vectra-server", hosts)
    assert_nil hosts_config_for("some-mac", hosts)
    assert_nil hosts_config_for("", hosts)
    capture_io do
      assert_nil hosts_config_for("vectra-server", JSON.dump({ "vectra-server" => 5 }))
      # Real-file default path for a hostname with no entry: nil => passthrough
      # (the commented plan variant — nil for "vectra-server" itself — is the
      # same invocation the last line pins to the committed map's entry, so it
      # cannot be nil while hosts.json is valid).
      assert_nil hosts_config_for("no-such-host-passed-explicitly", nil)
    end
    assert_equal hosts["vectra-server"], hosts_config_for("vectra-server")
  end

  def test_opencode_agent_routing_resolves_ids_per_host
    canon = JSON.parse(File.read(OPENCODE_CONFIG)).fetch("agent")
    hosts = { "vectra-server" => { "provider" => "ollama-cloud", "strip_cloud_marker" => true } }

    routing = opencode_agent_routing(OPENCODE_CONFIG, "vectra-server", hosts)
    canon.each do |name, entry|
      model = entry.is_a?(Hash) ? entry["model"] : nil
      next unless model.is_a?(String) && !model.strip.empty?
      assert_equal opencode_model_id(model, hosts["vectra-server"]), routing.fetch(name).fetch("model")
    end

    unmapped = opencode_agent_routing(OPENCODE_CONFIG, "no-such-host-in-the-map")
    canon.each do |name, entry|
      model = entry.is_a?(Hash) ? entry["model"] : nil
      next unless model.is_a?(String) && !model.strip.empty?
      assert_equal model, unmapped.fetch(name).fetch("model")
    end
  end

  def test_parse_agent_file_handles_non_hash_frontmatter
    custom_src = File.join(@home, "scalar_fm.md")
    File.write(custom_src, <<~MD)
      ---
      just a string, not a hash map
      ---
      Prompt body.
    MD
    fm, body = parse_agent_file(custom_src)
    assert_equal({}, fm)
    assert_equal "Prompt body.\n", body
  end

  def test_all_installs_every_target
    out, ok = run_cli("--all")
    assert ok, out
    assert File.exist?(File.join(@home, ".gemini", "config", "agents", "sprinter.md"))
    assert File.exist?(File.join(@home, ".gemini", "config", "AGENTS.md"))
    assert File.symlink?(File.join(@home, ".config", "opencode", "agents"))
    assert_equal AGENTS_DIR,
                 File.expand_path(File.readlink(File.join(@home, ".config", "opencode", "agents")))
    assert File.exist?(File.join(@home, ".config", "opencode", "AGENTS.md"))
    routing = JSON.parse(File.read(File.join(@home, ".config", "opencode", "opencode.json")))
    assert routing.key?("agent"), "opencode install must emit the routing config"
    assert File.exist?(File.join(@home, ".config", "opencode", ".opencode_routing_generated"))
    assert File.exist?(File.join(@home, ".cursor", "agents", "sprinter.md"))
    assert File.exist?(File.join(@home, ".cursor", "AGENTS.md"))
    assert File.exist?(File.join(@home, ".codex", "agents", "sprinter.toml"))
    assert File.exist?(File.join(@home, ".codex", "AGENTS.md"))
    assert File.exist?(File.join(@home, ".pi", "agent", "agents"))
    assert File.exist?(File.join(@home, ".pi", "agent", "AGENTS.md"))
  end

  def test_all_removes_every_target
    run_cli("--all")
    out, ok = run_cli("--all", "--remove", "--prune")
    assert ok, out
    refute File.exist?(File.join(@home, ".gemini", "config", "agents"))
    # opencode differs from other targets by design: --remove is routing-only,
    # so the agents/ + AGENTS.md symlinks are deliberately left in place and the
    # config dir is never pruned (the owner's opencode.jsonc may live there).
    assert File.symlink?(File.join(@home, ".config", "opencode", "agents"))
    assert File.symlink?(File.join(@home, ".config", "opencode", "AGENTS.md"))
    refute File.exist?(File.join(@home, ".config", "opencode", "opencode.json"))
    refute File.exist?(File.join(@home, ".config", "opencode", ".opencode_routing_generated"))
    refute File.exist?(File.join(@home, ".cursor", "agents"))
    refute File.exist?(File.join(@home, ".codex", "agents"))
    refute File.exist?(File.join(@home, ".pi", "agent", "agents"))
    refute File.exist?(File.join(@home, ".pi", "agent", "AGENTS.md"))
    assert File.exist?(File.join(@home, ".pi", "agent"))
  end
end
