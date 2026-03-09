# Homebrew Cask for BlueBear CLI - AI Coding Agent Governance
# DEN-750: Single unified Go binary with proper uninstall hooks
# DEN-1017: Simplified installer — OAuth moved to Go binary (`bluebear enable`)
#
# Casks provide uninstall stanzas that formulas lack, enabling proper cleanup
# when running `brew uninstall --cask bluebear`.
#
# Installation:
#   brew tap Blue-Bear-Security/client-releases-artifacts
#   brew install --cask bluebear
#
# Usage:
#   bluebear status              # Check daemon status
#   bluebear enable              # Enable daemon (runs OAuth if needed)

require "json"
require "open3"

# DEN-577: Environment configuration for multi-environment support
# These constants are replaced by generate-formulas.sh during build
BLUEBEAR_ENVIRONMENT = ""
BLUEBEAR_ENV_SUFFIX = BLUEBEAR_ENVIRONMENT.empty? ? "" : "-#{BLUEBEAR_ENVIRONMENT}"
BINARY_PREFIX = "bluebear"

cask "bluebear" do
  version "0.6.2"

  # DEN-1017: Distribution source depends on environment.
  # Production (BLUEBEAR_ENVIRONMENT empty): GitHub Release assets (public, no auth).
  # Dev/PR: GitHub Actions artifacts (zip-wrapped, requires HOMEBREW_GITHUB_API_TOKEN).
  if BLUEBEAR_ENVIRONMENT.empty?
    sha256 "388a3df8a511d49b0ddcc0f7ba8db1a98a24e691c7499c8400769e03e70512b4"
    url "https://github.com/Blue-Bear-Security/homebrew-handler/releases/download/handler-v0.6.2/bluebear-macos-arm64.tar.gz"
  else
    sha256 :no_check
    url "",
        header: "Authorization: Bearer #{ENV.fetch("HOMEBREW_GITHUB_API_TOKEN")}"
  end

  name "BlueBear"
  desc "Secure AI coding agent governance for Claude, Codex, Copilot, and more"
  homepage "https://bluebearsecurity.io"

  # Link the binary from inside the .app bundle
  binary "BlueBear.app/Contents/MacOS/bluebear", target: "#{BINARY_PREFIX}"

  # DEN-1017: Simplified postflight — all auth logic is now in the Go binary.
  postflight do
    # Remove quarantine attribute to prevent Gatekeeper blocking
    system_command "xattr", args: ["-cr", staged_path.to_s], print_stderr: false

    # Register .app bundle with Launch Services so macOS can find its icon
    # for Login Items & Extensions and "App Background Activity" notifications
    system_command "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
      args: ["-f", "#{staged_path}/BlueBear.app"],
      print_stderr: false

    # Generate and install shell completions
    # Note: Cobra generates completions for "bluebear" but we may install as a different name
    # (e.g., bluebear-pr-478 for PR environments), so we replace the command name in the output
    ohai "Installing shell completions..."
    begin
      zsh_completions_dir = "#{HOMEBREW_PREFIX}/share/zsh/site-functions"
      bash_completions_dir = "#{HOMEBREW_PREFIX}/etc/bash_completion.d"
      fish_completions_dir = "#{HOMEBREW_PREFIX}/share/fish/vendor_completions.d"

      FileUtils.mkdir_p(zsh_completions_dir)
      FileUtils.mkdir_p(bash_completions_dir)
      FileUtils.mkdir_p(fish_completions_dir)

      # Generate zsh completion and replace command name
      zsh_output, zsh_status = Open3.capture2("#{HOMEBREW_PREFIX}/bin/#{BINARY_PREFIX}", "completion", "zsh")
      if zsh_status.success?
        zsh_output = zsh_output.gsub("bluebear", BINARY_PREFIX)
        File.write("#{zsh_completions_dir}/_#{BINARY_PREFIX}", zsh_output)
        ohai "Installed zsh completion"
      end

      # Generate bash completion and replace command name
      bash_output, bash_status = Open3.capture2("#{HOMEBREW_PREFIX}/bin/#{BINARY_PREFIX}", "completion", "bash")
      if bash_status.success?
        bash_output = bash_output.gsub("bluebear", BINARY_PREFIX)
        File.write("#{bash_completions_dir}/#{BINARY_PREFIX}", bash_output)
        ohai "Installed bash completion"
      end

      # Generate fish completion and replace command name
      fish_output, fish_status = Open3.capture2("#{HOMEBREW_PREFIX}/bin/#{BINARY_PREFIX}", "completion", "fish")
      if fish_status.success?
        fish_output = fish_output.gsub("bluebear", BINARY_PREFIX)
        File.write("#{fish_completions_dir}/#{BINARY_PREFIX}.fish", fish_output)
        ohai "Installed fish completion"
      end
    rescue => e
      opoo "Could not install shell completions: #{e.message}"
    end

    # DEN-1017: The Go binary handles all auth — cask just calls `enable`.
    # DEN-842: Use Ruby's system() instead of system_command so that stdin is
    # inherited and the Go binary can prompt the user interactively.
    ohai "Running #{BINARY_PREFIX} enable..."
    system("#{HOMEBREW_PREFIX}/bin/#{BINARY_PREFIX}", "enable")
  end

  # Run bluebear disable before removal - THIS IS WHY WE USE CASK!
  # All operations wrapped in begin/rescue to prevent upgrade failures from leaving
  # orphaned .upgrading directories when any step fails
  uninstall_preflight do
    begin
      ohai "Running #{BINARY_PREFIX} disable..."
      system_command "#{HOMEBREW_PREFIX}/bin/#{BINARY_PREFIX}", args: ["disable"]
    rescue => e
      opoo "Could not disable daemon: #{e.message}"
    end

    # Remove shell completions
    ohai "Removing shell completions..."
    begin
      zsh_completion = "#{HOMEBREW_PREFIX}/share/zsh/site-functions/_#{BINARY_PREFIX}"
      bash_completion = "#{HOMEBREW_PREFIX}/etc/bash_completion.d/#{BINARY_PREFIX}"
      fish_completion = "#{HOMEBREW_PREFIX}/share/fish/vendor_completions.d/#{BINARY_PREFIX}.fish"

      FileUtils.rm_f(zsh_completion) if File.exist?(zsh_completion)
      FileUtils.rm_f(bash_completion) if File.exist?(bash_completion)
      FileUtils.rm_f(fish_completion) if File.exist?(fish_completion)
    rescue => e
      opoo "Could not remove shell completions: #{e.message}"
    end

    # PR environments: always clean up config (ephemeral, for testing)
    # Production: keep config for seamless upgrades - use 'brew uninstall --zap' for full cleanup
    begin
      unless BLUEBEAR_ENVIRONMENT.empty?
        require 'etc'
        real_home = Etc.getpwuid.dir
        config_dir = "#{real_home}/.bluebear#{BLUEBEAR_ENV_SUFFIX}"
        if Dir.exist?(config_dir)
          ohai "Removing PR environment config: #{config_dir}"
          FileUtils.rm_rf(config_dir)
        end
      end
    rescue => e
      opoo "Could not remove config directory: #{e.message}"
    end
  end

  # Clean up config on zap (brew uninstall --zap) - fallback if uninstall_preflight missed it
  zap trash: [
    "~/.bluebear#{BLUEBEAR_ENV_SUFFIX}",
    "#{HOMEBREW_PREFIX}/share/zsh/site-functions/_#{BINARY_PREFIX}",
    "#{HOMEBREW_PREFIX}/etc/bash_completion.d/#{BINARY_PREFIX}",
    "#{HOMEBREW_PREFIX}/share/fish/vendor_completions.d/#{BINARY_PREFIX}.fish",
  ]
end
