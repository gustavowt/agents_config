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
      orchestrator principal feature-lead infra-platform
      rails-backend-watchmaker frontend-vue-watchmaker image-analyst redteam
    ]

    flash_agents = %w[
      cartographer sprinter watchmaker rails-backend frontend-vue
      qa-tester security-guardian designer docs-writer duckdb-specialist
      ionic-cross-platform janitor
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

  def test_opencode_install_creates_dir_symlink
    out, ok = run_cli("opencode")
    assert ok, out
    link = File.join(@home, ".config", "opencode", "agents")
    assert File.symlink?(link)
    assert File.exist?(link)
    assert_equal File.join(STORE, "agents"), File.expand_path(File.readlink(link))
    rules = File.join(@home, ".config", "opencode", "AGENTS.md")
    assert File.symlink?(rules)
    assert File.exist?(rules)
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
    assert_equal %w[deepseek-v4-flash:0731-cloud glm-5.2:cloud kimi-k3:cloud],
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
    assert File.exist?(File.join(@home, ".config", "opencode", "agents"))
    assert File.exist?(File.join(@home, ".config", "opencode", "AGENTS.md"))
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
    refute File.exist?(File.join(@home, ".config", "opencode", "agents"))
    refute File.exist?(File.join(@home, ".cursor", "agents"))
    refute File.exist?(File.join(@home, ".codex", "agents"))
    refute File.exist?(File.join(@home, ".pi", "agent", "agents"))
    refute File.exist?(File.join(@home, ".pi", "agent", "AGENTS.md"))
    assert File.exist?(File.join(@home, ".pi", "agent"))
  end
end
