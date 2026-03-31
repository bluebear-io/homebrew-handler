# Homebrew Formula for BlueBear CLI - AI Coding Agent Governance
# DEN-750: Single unified Go binary for macOS and Linux
# DEN-1017: Simplified installer — OAuth moved to Go binary (`bluebear enable`)
#
# Installation:
#   brew tap Blue-Bear-Security/handler
#   brew install bluebear

require "json"
require "open3"

# DEN-577: Environment configuration for multi-environment support
BLUEBEAR_ENVIRONMENT = ""
BLUEBEAR_ENV_SUFFIX = BLUEBEAR_ENVIRONMENT.empty? ? "" : "-#{BLUEBEAR_ENVIRONMENT}"
BINARY_PREFIX = "bluebear"

class Bluebear < Formula
  desc "BlueBear - Secure AI coding agent governance for Claude, Codex, Copilot, and more"
  homepage "https://bluebearsecurity.io"
  version "0.6.11"

  # Platform-specific configuration (macOS and Linux)
  if OS.mac?
    if Hardware::CPU.arm?
      platform_suffix = "macos-arm64"
    else
      platform_suffix = "macos-x86_64"
    end
  else
    if Hardware::CPU.arm?
      platform_suffix = "linux-arm64"
    else
      platform_suffix = "linux-x86_64"
    end
  end

  # SHA256 checksums for download verification.
  # Production: verified against GitHub Release downloads (stable, content-addressable).
  # Dev/PR: sha256 omitted — GitHub Actions re-packages artifact ZIPs on each download,
  # producing non-deterministic hashes. Downloads are authenticated via gh CLI or HOMEBREW_GITHUB_API_TOKEN.
  # Note: `sha256 :no_check` is only supported for Casks, not Formulas (Homebrew/brew#17175).
  # Omitting sha256 entirely lets Homebrew skip verification for dev/PR artifacts.
  if BLUEBEAR_ENVIRONMENT.empty?
    if OS.mac?
      if Hardware::CPU.arm?
        sha256 "8873a6c2e7f3f79ba3dc2cce73045ab14b45b4562fcab8237c5076ab57db01f7"
      else
        sha256 "bff578983e77edc12c00573c94cc3e06555e7327b34e0efaed047a88dad8fe6f"
      end
    else
      if Hardware::CPU.arm?
        sha256 "73eb42a5ef2727bcd94697f1bd4d9a40a077db6d9f341c96a3e5f003baafdbad"
      else
        sha256 "f9d67c4e7a009576a64b7bf0baceb117dc383d39d51be4d09a4e3f3eae816659"
      end
    end
  end

  # DEN-1017: Distribution source depends on environment.
  # Production (BLUEBEAR_ENVIRONMENT empty): GitHub Release assets (public, no auth).
  # Dev/PR: GitHub Actions artifacts (zip-wrapped, requires GitHub auth).
  # DEN-1287: Falls back to `gh auth token` when HOMEBREW_GITHUB_API_TOKEN is not set.
  if BLUEBEAR_ENVIRONMENT.empty?
    url "https://github.com/Blue-Bear-Security/homebrew-handler/releases/download/handler-v0.6.11/bluebear-#{platform_suffix}.tar.gz"
  else
    # Dev/PR: per-platform artifact IDs, zip-wrapped by GitHub Actions.
    # Platforms with empty artifact IDs are omitted (e.g., linux-arm64 when ARM64 build is skipped).
    artifact_ids = {
      "macos-arm64" => "",
      "macos-x86_64" => "",
      "linux-arm64" => "",
      "linux-x86_64" => "",
    }.reject { |_, v| v.empty? }

    artifact_id = artifact_ids[platform_suffix]
    odie "No binary available for platform #{platform_suffix} in this build" if artifact_id.nil?

    github_token = ENV["HOMEBREW_GITHUB_API_TOKEN"] || `gh auth token 2>/dev/null`.strip
    odie "GitHub auth token not found. Set HOMEBREW_GITHUB_API_TOKEN or run 'gh auth login'" if github_token.empty?

    url "https://api.github.com/repos/Blue-Bear-Security/blueden/actions/artifacts/#{artifact_id}/zip",
        header: "Authorization: Bearer #{github_token}"
  end

  def install
    platform = OS.mac? ? (Hardware::CPU.arm? ? "macos-arm64" : "macos-x86_64") : (Hardware::CPU.arm? ? "linux-arm64" : "linux-x86_64")

    ohai "Installing BlueBear v#{version} for #{platform}"

    # Dev/PR artifacts are ZIP-wrapped by GitHub Actions API.
    # Homebrew extracts the outer ZIP but not the inner tar.gz, so extract it here.
    inner_archive = Dir["bluebear-*.tar.gz"].first
    if inner_archive && !Dir.exist?("BlueBear.app") && !File.file?("bluebear")
      ohai "Extracting inner archive: #{inner_archive}"
      system "tar", "xzf", inner_archive
    end

    # Find the extracted binary
    # macOS archives contain BlueBear.app bundle; Linux archives contain raw binary
    if Dir.exist?("BlueBear.app")
      binary_path = "BlueBear.app/Contents/MacOS/bluebear"
    elsif File.file?("bluebear")
      binary_path = "bluebear"
    else
      binary_path = Dir["bluebear-*"].find { |f| File.file?(f) && !f.end_with?('.tar.gz', '.sha256') }
    end

    if binary_path
      # Make executable and install
      chmod 0755, binary_path
      bin.install binary_path => BINARY_PREFIX
      ohai "Installed #{BINARY_PREFIX}"

      # Generate and install shell completions
      ohai "Installing shell completions..."
      generate_completions
    else
      opoo "Could not find bluebear binary"
      ohai "Contents of buildpath:"
      Dir["*"].each { |f| puts "  #{f}" }
    end
  end

  def generate_completions
    # Generate shell completions using the installed binary
    # Note: Cobra generates completions for "bluebear" but we may install as a different name
    # (e.g., bluebear-pr-478 for PR environments), so we replace the command name in the output
    output = Utils.safe_popen_read(bin/BINARY_PREFIX, "completion", "bash")
    output = output.gsub("bluebear", BINARY_PREFIX)
    (bash_completion/BINARY_PREFIX).write output

    output = Utils.safe_popen_read(bin/BINARY_PREFIX, "completion", "zsh")
    output = output.gsub("bluebear", BINARY_PREFIX)
    (zsh_completion/"_#{BINARY_PREFIX}").write output

    output = Utils.safe_popen_read(bin/BINARY_PREFIX, "completion", "fish")
    output = output.gsub("bluebear", BINARY_PREFIX)
    (fish_completion/"#{BINARY_PREFIX}.fish").write output
  rescue => e
    opoo "Could not generate shell completions: #{e.message}"
  end

  def post_install
    # DEN-1017: The Go binary handles all auth — formula just calls `enable`.
    # BLUEBEAR_ENVIRONMENT tells the binary which config dir to use (e.g., ~/.bluebear-pr-672/).
    ohai "Running #{BINARY_PREFIX} enable..."
    ENV["BLUEBEAR_ENVIRONMENT"] = BLUEBEAR_ENVIRONMENT unless BLUEBEAR_ENVIRONMENT.empty?
    system("#{HOMEBREW_PREFIX}/bin/#{BINARY_PREFIX}", "enable")
  end

  def caveats
    config_file = File.expand_path("~/.bluebear#{BLUEBEAR_ENV_SUFFIX}/config")
    config_exists = File.exist?(config_file)

    if config_exists
      <<~EOS
        BlueBear has been installed and configured!

        Configuration: #{config_file}
        Documentation: https://app.bluebearsecurity.io/docs

        Before uninstalling, run: #{BINARY_PREFIX} disable
      EOS
    else
      <<~EOS
        BlueBear has been installed!

        \e[33mAuthentication may not have completed.\e[0m

        To authenticate, run: #{BINARY_PREFIX} enable

        Documentation: https://app.bluebearsecurity.io/docs

        Before uninstalling, run: #{BINARY_PREFIX} disable
      EOS
    end
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/#{BINARY_PREFIX} version")
  end
end
