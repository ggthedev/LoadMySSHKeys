# typed: false
# frozen_string_literal: true

class Sshkeymanager < Formula
  desc "Manages SSH keys, agent, and loads keys for shell sessions"
  homepage "https://github.com/ggthedev/SSHKEYSMANAGER"
  url "https://github.com/ggthedev/SSHKEYSMANAGER/archive/refs/tags/0.0.1.tar.gz"
  sha256 "6fa89fc75a733000f5804dd8d9bd8b83e291c9b3cd472ac65dad96030fe853d2"
  version "0.0.1"

  head "https://github.com/ggthedev/SSHKEYSMANAGER.git", branch: "main"

  depends_on "coreutils" # Provides 'date' with nanoseconds needed by the script
  # Make gnu-getopt optional on macOS
  depends_on "gnu-getopt" => :optional if OS.mac?

  def install
    # Install the main script to bin
    bin.install "sshkeymanager.sh"
    # Install the agent setup script to libexec as it's meant to be sourced
    libexec.install "ssh_agent_setup.sh"

    # Use inreplace only if macOS AND the optional gnu-getopt was built
    if OS.mac? && build.with?("gnu-getopt")
      # Replace the simple `getopt` call with the full path to Homebrew's gnu-getopt
      inreplace bin/"sshkeymanager.sh", "getopt", Formula["gnu-getopt"].opt_bin/"getopt"
    end
  end

  def caveats
    s = <<~EOS
      The main utility `sshkeymanager.sh` has been installed to:
        #{opt_bin}/sshkeymanager.sh

      To activate the SSH agent setup for your shell sessions, add the following
      line to your shell profile (e.g., ~/.zshrc, ~/.bash_profile, ~/.profile):

        source "#{opt_libexec}/ssh_agent_setup.sh"

      Ensure you remove any previous manual sourcing of the agent script.

      Configuration and logs are typically stored in:
        ~/.config/sshkeymanager/
        ~/Library/Logs/sshkeymanager/ (macOS) or ~/.local/log/sshkeymanager/ (Linux fallback)

      Restart your shell or source your profile for changes to take effect.
    EOS

    if OS.mac?
      s += <<~EOS

        On macOS, it is recommended to install with gnu-getopt for full compatibility
        with command-line options:
          brew reinstall sshkeymanager --with-gnu-getopt
      EOS
    end

    s # Return the combined caveats string
  end

  test do
    # Test syntax of the sourced script
    system "bash", "-n", libexec/"ssh_agent_setup.sh"

    # Test presence and basic execution of the main script
    assert_predicate bin/"sshkeymanager.sh", :exist?
    assert_predicate bin/"sshkeymanager.sh", :executable?
    # Check if running with --help works (replace with a more meaningful basic command if needed)
    shell_output("#{bin}/sshkeymanager.sh --help")
  end
end 